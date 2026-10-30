import AppKit
import SwiftUI

/// Console Mode's screen: the window covers its screen with the menu bar and the Dock hidden, on the Space it is on,
/// and goes back to what it was when Console Mode ends.
///
/// Not macOS full screen: that puts the window on a Space of its own, and a game, which opens its own full-screen
/// Space from the desktop, hands the screen back to the desktop when it quits. macOS then brings forward the last app
/// used there (not NX Play, which wasn't there), and NX Play can't take the screen back: activation is cooperative
/// since macOS 14. A window covering the desktop is the last app used there, so a quitting game returns to it.
/// The menu bar and the Dock come back by themselves while another app is in front.
struct ConsoleWindowController: NSViewRepresentable {
    let consoleMode: Bool

    @MainActor final class Coordinator {
        /// How the window was before Console Mode; nil while it is not covering.
        var saved: Saved?
        /// Console Mode as last asked: NX Play opened in it has no window yet at the first update.
        var wanted = false
        var terminationObserver: (any NSObjectProtocol)?
        /// Waiting for the player's macOS full screen to end before covering.
        var fullScreenExitObserver: (any NSObjectProtocol)?

        struct Saved {
            let frame: NSRect
            let fullSizeContent: Bool
            let transparentTitlebar: Bool
            let titleVisibility: NSWindow.TitleVisibility
            let hiddenButtons: [NSWindow.ButtonType: Bool]
            let movable: Bool
            let collectionBehavior: NSWindow.CollectionBehavior
        }

        static let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        func cover(_ window: NSWindow) {
            guard saved == nil else { return }
            // a window the player put in macOS full screen leaves it first, then covers
            if window.styleMask.contains(.fullScreen) {
                guard fullScreenExitObserver == nil else { return }
                fullScreenExitObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
                ) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let observer = self.fullScreenExitObserver {
                            NotificationCenter.default.removeObserver(observer)
                        }
                        self.fullScreenExitObserver = nil
                        if let window { self.cover(window) }
                    }
                }
                window.toggleFullScreen(nil)
                return
            }
            saved = Saved(
                frame: window.frame,
                fullSizeContent: window.styleMask.contains(.fullSizeContentView),
                transparentTitlebar: window.titlebarAppearsTransparent,
                titleVisibility: window.titleVisibility,
                hiddenButtons: Dictionary(
                    uniqueKeysWithValues: Self.buttons.map {
                        ($0, window.standardWindowButton($0)?.isHidden ?? false)
                    }),
                movable: window.isMovable,
                collectionBehavior: window.collectionBehavior)
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            for button in Self.buttons { window.standardWindowButton(button)?.isHidden = true }
            window.isMovable = false
            // no macOS full screen (⌃⌘F, the green button) on top of it
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
            if let screen = window.screen ?? NSScreen.main {
                window.setFrame(screen.frame, display: true)
            }
            window.makeKeyAndOrderFront(nil)
            if terminationObserver == nil {
                // quitting in Console Mode: the window's saved frame is the normal one, not the whole screen
                terminationObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.willTerminateNotification, object: nil, queue: .main
                ) { [weak self, weak window] _ in
                    MainActor.assumeIsolated { if let window { self?.restore(window) } }
                }
            }
        }

        func restore(_ window: NSWindow) {
            guard let saved else { return }
            self.saved = nil
            NSApp.presentationOptions = []
            window.collectionBehavior = saved.collectionBehavior
            window.isMovable = saved.movable
            for (button, hidden) in saved.hiddenButtons {
                window.standardWindowButton(button)?.isHidden = hidden
            }
            window.titleVisibility = saved.titleVisibility
            window.titlebarAppearsTransparent = saved.transparentTitlebar
            if !saved.fullSizeContent { window.styleMask.remove(.fullSizeContentView) }
            window.setFrame(saved.frame, display: true, animate: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { WindowView(coordinator: context.coordinator) }

    func updateNSView(_ view: NSView, context: Context) {
        let state = context.coordinator
        let consoleMode = consoleMode
        state.wanted = consoleMode
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if consoleMode { state.cover(window) } else { state.restore(window) }
        }
    }

    /// Covers the screen once the view is in its window, for NX Play opened in Console Mode.
    final class WindowView: NSView {
        let coordinator: Coordinator

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, coordinator.wanted else { return }
            DispatchQueue.main.async { [coordinator] in
                if coordinator.wanted { coordinator.cover(window) }
            }
        }
    }
}
