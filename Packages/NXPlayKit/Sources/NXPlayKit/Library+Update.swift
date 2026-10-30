import Foundation

/// Console Mode's update card: an update waits quietly in the top bar until the player asks for it.
extension Library {
    /// Y, or the pill: the card, in Console Mode while an update is ready.
    func openUpdate() {
        guard consoleMode, case .ready = updater.state else { return }
        showsUpdate = true
    }

    /// The card open: A restarts to update, B or Y close it; the directions do nothing, so a stray press while
    /// reaching for the row doesn't dismiss it.
    func handleUpdate(_ command: Gamepad.Command) {
        switch command {
        case .confirm:
            restartToUpdate()
            showsUpdate = false
        case .back, .info: showsUpdate = false
        case .left, .right, .up, .down, .menu: break
        }
    }
}
