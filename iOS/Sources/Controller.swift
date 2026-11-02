import GameController
import Observation

/// A game controller as the launcher's remote: the d-pad or left stick moves through the games, A chooses, B goes
/// back, Y reinstalls. Its own handling rather than the system's: the same buttons on every controller, as NX Play's
/// Console Mode on the Mac.
@MainActor @Observable
final class Controller {
    enum Command: Sendable { case up, down, left, right, confirm, back, alternate }

    /// A controller is connected: the launcher shows its highlight and button hints.
    private(set) var isConnected = false
    @ObservationIgnored var onCommand: ((Command) -> Void)?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// The stick's direction last sent: it moves once per push, like a d-pad press.
    @ObservationIgnored private var stick: Command?

    init() {
        let center = NotificationCenter.default
        observers = [
            // every controller again rather than the note's: setting the handlers twice is harmless
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { GCController.controllers().forEach { self?.attach($0) } }
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isConnected = GCController.controllers().contains { $0.extendedGamepad != nil }
                }
            },
        ]
        GCController.controllers().forEach(attach)
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        isConnected = true
        let buttons: [(GCControllerButtonInput, Command)] = [
            (pad.dpad.up, .up), (pad.dpad.down, .down), (pad.dpad.left, .left),
            (pad.dpad.right, .right), (pad.buttonA, .confirm), (pad.buttonB, .back),
            (pad.buttonY, .alternate),
        ]
        for (button, command) in buttons {
            // handlers run on the main queue (GCController's default handlerQueue)
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                MainActor.assumeIsolated { self?.onCommand?(command) }
            }
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.moveStick(x: x, y: y) }
        }
    }

    /// Past half way in one direction sends it once; back near the middle lets it send again.
    private func moveStick(x: Float, y: Float) {
        let direction: Command? =
            max(abs(x), abs(y)) < 0.5 ? nil
            : abs(x) > abs(y) ? (x > 0 ? .right : .left) : (y > 0 ? .up : .down)
        guard direction != stick else { return }
        stick = direction
        if let direction { onCommand?(direction) }
    }
}
