import AppKit
import SwiftUI

/// A tab's page: a grouped form at the window's width, scrolling in whatever height the window is given. The window
/// resizes only vertically: a page sized to its content couldn't be made smaller on a laptop's screen (General ran
/// under the Dock), and one that measured its content to size the window resized it in a loop while it animated to a
/// tab, until AppKit gave up and NX Play crashed (issue #23).
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }.settingsPage()
    }
}

extension View {
    /// A Settings tab's form, at the window's fixed width and any height.
    func settingsPage() -> some View {
        formStyle(.grouped)
            .frame(width: 600)
            .frame(minHeight: 200, maxHeight: .infinity)
    }
}

/// SwiftUI gives the Settings window no resize handle, whatever its content allows, and takes it off again as it sets
/// the window up; this adds it back each time it's gone. The width stays the pages' own, so only the height changes.
/// SwiftUI also opens the window at a height of its own, whatever it was, so the height the player gives it is kept
/// here and set again at each opening.
struct VerticallyResizableWindow: NSViewRepresentable {
    static let heightKey = "settingsWindowHeight"
    /// The first opening's: room for most of General.
    static let defaultHeight: CGFloat = 640

    func makeNSView(context: Context) -> NSView { WindowHook() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowHook: NSView {
        private var watch: NSKeyValueObservation?
        private var resized: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let resized { NotificationCenter.default.removeObserver(resized) }
            resized = nil
            watch = nil
            guard let window else { return }
            // AppKit changes a window's style on the main thread
            watch = window.observe(\.styleMask, options: [.initial, .new]) { window, _ in
                MainActor.assumeIsolated {
                    guard !window.styleMask.contains(.resizable) else { return }
                    DispatchQueue.main.async { window.styleMask.insert(.resizable) }
                }
            }
            // after SwiftUI has given the window its own height
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, window == self.window else { return }
                restoreHeight(of: window)
                resized = NotificationCenter.default.addObserver(
                    forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
                ) { [weak window] _ in
                    MainActor.assumeIsolated { window.map(Self.keepHeight) }
                }
            }
        }

        private static func keepHeight(of window: NSWindow) {
            UserDefaults.standard.set(Double(window.frame.height), forKey: VerticallyResizableWindow.heightKey)
        }

        /// Grown or shrunk from the top edge down, as a drag of the bottom edge would, and kept on the screen.
        private func restoreHeight(of window: NSWindow) {
            let saved = UserDefaults.standard.double(forKey: VerticallyResizableWindow.heightKey)
            var height = saved > 0 ? CGFloat(saved) : VerticallyResizableWindow.defaultHeight
            var frame = window.frame
            if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
                height = min(height, frame.maxY - screen.minY)
            }
            height = max(height, window.minSize.height)
            guard abs(height - frame.height) > 0.5 else { return }
            frame.origin.y = frame.maxY - height
            frame.size.height = height
            window.setFrame(frame, display: true)
        }
    }
}
