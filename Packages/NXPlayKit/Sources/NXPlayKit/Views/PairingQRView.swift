import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings › Devices › Show QR Code…: the pairing link (PairingLink) as a QR code for NX Play on the iPhone or iPad
/// to scan, with the addresses it carries. The link holds the pairing code, so the sheet keeps it off screenshots and
/// screen sharing (its window's sharingType), closes itself after a few minutes, and Copy Link marks the clipboard as
/// concealed and empties it again after two minutes.
struct PairingQRView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    /// The addresses left out of the code, by the player.
    @State private var excluded: Set<Endpoint> = []
    @State private var copied = false

    static let lifetime: Duration = .seconds(180)

    var body: some View {
        let all = Array(library.remoteEndpoints.prefix(NXPlayPairing.maxEndpoints))
        let chosen = all.filter { !excluded.contains($0) }
        let link = library.pairingLink(endpoints: chosen)
        let left = chosen.filter { !(link?.endpoints.contains($0) ?? false) }
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair an iPhone or iPad").font(.title2.bold())
            HStack(alignment: .top, spacing: 20) {
                Group {
                    if let url = link?.url, let image = Self.qrImage(url.absoluteString) {
                        Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                    } else {
                        ContentUnavailableView("Pick an address", systemImage: "qrcode")
                    }
                }
                .frame(width: 240, height: 240)
                .padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Pairing QR code")
                VStack(alignment: .leading, spacing: 8) {
                    Text("In NX Play on the device: **Scan QR Code**, or open the camera and tap the code.")
                    Text("Addresses in the code").font(.headline).padding(.top, 4)
                    ForEach(all, id: \.self) { endpoint in
                        Toggle(isOn: Binding(
                            get: { !excluded.contains(endpoint) },
                            set: { if $0 { excluded.remove(endpoint) } else { excluded.insert(endpoint) } }
                        )) {
                            HStack {
                                Image(systemName: endpoint.kind.symbol).frame(width: 18)
                                Text(verbatim: endpoint.display).monospaced()
                                Text(endpoint.kind.title).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !left.isEmpty {
                        Label(
                            "Left out to fit the code: \(left.map(\.display).joined(separator: ", ")). Leave out an address above to make room.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption).foregroundStyle(.orange)
                    }
                    Text(
                        "The device tries them in this order. Later it sends the code only to these addresses: at another address, pair again with a new QR code. Leave out the addresses of networks the device never joins."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 380, alignment: .leading)
            }
            Label(
                "The code lets a device in, as the pairing code does. Show it only to your own devices; New Code makes it stop working.",
                systemImage: "lock")
            .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(copied ? "Copied" : "Copy Link") {
                    if let url = link?.url { Self.copyConcealed(url.absoluteString) }
                    copied = true
                }
                .disabled(link?.url == nil)
                .help("For pasting on the device: Universal Clipboard carries it. The clipboard is emptied again after two minutes.")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 680)
        .background(ScreenCaptureShield())
        .task {
            // the code doesn't stay on screen once the device has had time to scan it
            try? await Task.sleep(for: Self.lifetime)
            dismiss()
        }
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
            let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }

    /// Puts the link on the clipboard marked concealed and transient (nspasteboard.org: clipboard managers don't keep
    /// it), and takes it off after two minutes unless something else was copied since.
    @MainActor static func copyConcealed(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let change = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(120))
            if pasteboard.changeCount == change { pasteboard.clearContents() }
        }
    }
}

/// Keeps its window out of screenshots, recordings and screen sharing while it's shown (NSWindow.sharingType), and
/// puts the window back as it was after.
private struct ScreenCaptureShield: NSViewRepresentable {
    final class ShieldView: NSView {
        private weak var shielded: NSWindow?
        private var previous: NSWindow.SharingType = .readOnly

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let shielded, shielded !== window { shielded.sharingType = previous }
            guard let window, window !== shielded else { return }
            previous = window.sharingType
            window.sharingType = .none
            shielded = window
        }

        func restore() {
            shielded?.sharingType = previous
            shielded = nil
        }
    }

    func makeNSView(context: Context) -> ShieldView { ShieldView() }
    func updateNSView(_ nsView: ShieldView, context: Context) {}
    static func dismantleNSView(_ nsView: ShieldView, coordinator: ()) { nsView.restore() }
}
