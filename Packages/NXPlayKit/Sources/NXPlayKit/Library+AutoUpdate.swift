import AppKit
import CoreGraphics

/// Settings › Updates › Install updates automatically when idle: a downloaded update installs, as Restart to Update
/// does, once no game, build or file work runs and the player isn't using NX Play (it's in the background, or nothing
/// was typed or clicked for a while). Checked each minute, as idleness comes without an event to wait for.
extension Library {
    /// How long without a key, click or controller press NX Play counts as unused while it's in front.
    static let idleInput: TimeInterval = 10 * 60

    func watchForIdleUpdate() {
        idleUpdateTimer?.invalidate()
        idleUpdateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installUpdateIfIdle() }
        }
    }

    func installUpdateIfIdle() {
        guard installUpdatesWhenIdle, case .ready = updater.state, !quitsWhenIdle, isIdle, !isInUse else { return }
        restartToUpdate()
    }

    /// NX Play is in front and was used lately; a controller counts, as Console Mode is played from the sofa.
    private var isInUse: Bool {
        guard NSApp?.isActive == true else { return false }
        let anyInput = CGEventType(rawValue: ~0)!
        let input = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return input < Self.idleInput || gamepad.secondsSinceLastInput < Self.idleInput
    }
}
