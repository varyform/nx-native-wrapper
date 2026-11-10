import AppKit
import SwiftUI

/// Giving NX Play Full Disk Access, which macOS asks for nowhere on its own: System Settings opens at the Full Disk
/// Access list, and a small window beside it holds NX Play's icon to drag into that list. It floats, so it stays in
/// view while System Settings is the active app, and it sees the access turn on by trying the folder that needs it.
@MainActor @Observable
public final class FullDiskAccessGuide {
    public static let shared = FullDiskAccessGuide()

    public private(set) var granted = false
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var onGranted: (() -> Void)?

    /// What needs the access, tried until it opens.
    @ObservationIgnored var hasAccess: () -> Bool = {
        DeviceInstallCopies.apps(in: DeviceInstallCopies.folder) != nil
    }

    static let systemSettings = "com.apple.systempreferences"

    public func show(onGranted: @escaping () -> Void = {}) {
        self.onGranted = onGranted
        granted = hasAccess()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        if !granted { openSettings() }
        watch()
    }

    public func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    func openSettings() {
        NSWorkspace.shared.open(DeviceInstallCopies.fullDiskAccessSettings)
        // System Settings takes a moment to open its window, more when it wasn't running
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                if let frame = Self.settingsFrame() {
                    place(beside: frame)
                    return
                }
            }
        }
    }

    private func watch() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.granted, self.hasAccess() else { return }
                self.granted = true
                self.timer?.invalidate()
                self.onGranted?()
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "Full Disk Access"
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FullDiskAccessView(guide: self))
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        panel.center()
        return panel
    }

    /// To the left of System Settings, tops level; on the screen, over its edge when there's no room.
    private func place(beside settings: NSRect) {
        guard let panel else { return }
        let size = panel.frame.size
        var origin = NSPoint(x: settings.minX - size.width - 16, y: settings.maxY - size.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(settings) })?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
    }

    /// System Settings' main window in AppKit's coordinates. Window bounds need no permission, unlike their titles.
    static func settingsFrame() -> NSRect? {
        let pids = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: systemSettings).map(\.processIdentifier))
        guard !pids.isEmpty,
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
            let primary = NSScreen.screens.first?.frame
        else { return nil }
        let frames = windows.compactMap { window -> CGRect? in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                window[kCGWindowLayer as String] as? Int == 0,
                let bounds = window[kCGWindowBounds as String] as? NSDictionary
            else { return nil }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary)
        }
        // its biggest: the settings window, not a sheet or a popover
        guard let top = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        // Core Graphics counts from the primary screen's top, AppKit from its bottom
        return NSRect(x: top.minX, y: primary.maxY - top.maxY, width: top.width, height: top.height)
    }
}

struct FullDiskAccessView: View {
    let guide: FullDiskAccessGuide

    var body: some View {
        VStack(spacing: 14) {
            AppIconDrag(url: Bundle.main.bundleURL)
                .frame(width: 96, height: 96)
                .help("Drag into the Full Disk Access list")
            Text(Bundle.main.bundleURL.deletingPathExtension().lastPathComponent)
                .font(.headline)
            if guide.granted {
                Label("Full Disk Access is on.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Done") { guide.close() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Text(
                    "Drag the icon into the Full Disk Access list in System Settings, and turn it on there."
                )
                .multilineTextAlignment(.center)
                Text(
                    "NX Play uses it for one folder: where Xcode's device service keeps its copies of the games you installed on a device."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for access…").foregroundStyle(.secondary)
                }
                // macOS keeps one entry per app ID: one left by another build of NX Play shows as on but doesn't
                // match this one, and the folder stays closed without a word
                Text(
                    "Still waiting once it's on? Quit NX Play and open it again. If NX Play was in the list before, remove it with − and drag it in again."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Open System Settings") { guide.openSettings() }
                    Button("Close") { guide.close() }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(width: 300)
    }
}

/// The app's icon, dragged as the app itself: System Settings' privacy lists take an app dropped from Finder.
private struct AppIconDrag: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> DragView { DragView(url: url) }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView, NSDraggingSource {
        let url: URL
        let icon: NSImage

        init(url: URL) {
            self.url = url
            icon = NSWorkspace.shared.icon(forFile: url.path)
            super.init(frame: .zero)
            setAccessibilityRole(.image)
            setAccessibilityLabel("NX Play")
        }

        required init?(coder: NSCoder) { nil }

        override var mouseDownCanMoveWindow: Bool { false }

        override func draw(_ dirtyRect: NSRect) { icon.draw(in: bounds) }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDown(with event: NSEvent) {}

        override func mouseDragged(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(bounds, contents: icon)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
            -> NSDragOperation
        {
            context == .outsideApplication ? .copy : []
        }
    }
}
