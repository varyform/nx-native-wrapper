import AVFoundation
import SwiftUI
import UIKit

/// Scan QR Code: the camera reads the pairing QR code NX Play shows on the Mac (Settings › Devices › Show QR Code…).
/// Only an NX Play pairing link is taken: any other code says so, without showing what it holds. Without a camera,
/// or without access to it, the link can be pasted instead (Copy Link on the Mac, through Universal Clipboard).
struct QRScannerSheet: View {
    let onLink: (PairingLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var access = CameraAccess.checking
    @State private var message: String?

    enum CameraAccess {
        case checking, allowed, denied, unavailable
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch access {
                case .checking:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .allowed:
                    QRCameraView(onCode: take)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(alignment: .bottom) {
                            Text("Point the camera at the QR code in NX Play › Settings › Devices on the Mac.")
                                .font(.callout).multilineTextAlignment(.center).padding(10)
                                .background(.thinMaterial, in: Capsule()).padding()
                        }
                        .accessibilityLabel("Camera viewfinder")
                case .denied:
                    ContentUnavailableView {
                        Label("Camera access is off", systemImage: "camera")
                    } description: {
                        Text("Allow NX Play to use the camera in Settings, or copy the link on the Mac and paste it here.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                case .unavailable:
                    ContentUnavailableView(
                        "No camera here", systemImage: "camera.metering.unknown",
                        description: Text("Copy the link on the Mac (Show QR Code… › Copy Link) and paste it here."))
                }
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .font(.callout)
                }
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in take(strings.first ?? "") }
                }
                .labelStyle(.titleAndIcon)
            }
            .padding()
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .horizontalToolbar()
        }
        .task { access = await Self.cameraAccess() }
    }

    private func take(_ text: String) {
        guard PairingLink.looksLikeLink(text) else {
            message = PairingError.notAPairingLink.localizedDescription
            return
        }
        do {
            let link = try PairingLink.parse(text)
            message = nil
            onLink(link)
        } catch {
            message = error.localizedDescription
        }
    }

    static func cameraAccess() async -> CameraAccess {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .allowed
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video) ? .allowed : .denied
        default: return .denied
        }
    }
}

/// The camera's picture, reading QR codes; `onCode` gets each new one (the same code again within a few seconds is
/// ignored, so a wrong code's message doesn't flicker).
private struct QRCameraView: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        ScannerController(onCode: onCode)
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) {
        controller.stop()
    }
}

private final class ScannerController: UIViewController {
    /// The session lives on its own queue, as AVFoundation asks; the session is used only there. Its codes go to
    /// `sink`, set once at the start: the queue reads nothing the main actor changes (QRCodeSink).
    private final class Session: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        let session = AVCaptureSession()
        let queue = DispatchQueue(label: "org.nxplay.ios.scanner")
        let sink: QRCodeSink

        init(sink: QRCodeSink) {
            self.sink = sink
            super.init()
        }

        func configure() -> Bool {
            guard let camera = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input)
            else { return false }
            session.beginConfiguration()
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                return false
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: queue)
            output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
            session.commitConfiguration()
            return true
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection
        ) {
            guard let text = objects.lazy.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first
            else { return }
            sink.deliver(text)
        }
    }

    private let sink: QRCodeSink
    private let scanner: Session
    private let onCode: @MainActor (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var last: (text: String, at: Date)?

    init(onCode: @escaping @MainActor (String) -> Void) {
        let sink = QRCodeSink()
        self.sink = sink
        self.scanner = Session(sink: sink)
        self.onCode = onCode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let preview = AVCaptureVideoPreviewLayer(session: scanner.session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.preview = preview
        sink.open { [weak self] text in self?.seen(text) }
        let scanner = scanner
        scanner.queue.async {
            if scanner.configure() { scanner.session.startRunning() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    private func seen(_ text: String) {
        if let last, last.text == text, Date().timeIntervalSince(last.at) < 3 { return }
        last = (text, Date())
        onCode(text)
    }

    /// The scanner has gone: codes already on their way are dropped (QRCodeSink), then the camera stops.
    func stop() {
        sink.close()
        let scanner = scanner
        scanner.queue.async { scanner.session.stopRunning() }
    }
}
