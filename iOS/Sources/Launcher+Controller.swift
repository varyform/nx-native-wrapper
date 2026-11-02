import Foundation

/// The controller in the launcher: moves the highlight through the grid; A opens the game, and in its sheet plays
/// it (or installs it when it isn't here); Y installs again; B closes the sheet.
extension Launcher {
    func handle(_ command: Controller.Command) {
        guard mac?.device != nil else { return }
        if let id = sheetGame {
            guard let game = games.first(where: { $0.id == id }) else { return sheetGame = nil }
            switch command {
            case .confirm: primaryAction(game)
            case .alternate: if game.canInstall, game.job?.isActive != true { startInstall(game) }
            case .back: sheetGame = nil
            case .up, .down, .left, .right: break
            }
            return
        }
        let order = sortedGames
        guard !order.isEmpty else { return }
        guard let index = order.firstIndex(where: { $0.id == selected }) else {
            return selected = order[0].id  // the first press shows the highlight
        }
        if command == .confirm { return sheetGame = order[index].id }
        if command == .alternate { return startInstall(order[index]) }
        let step =
            switch command {
            case .left: -1
            case .right: 1
            case .up: -columns
            case .down: columns
            case .confirm, .alternate, .back: 0
            }
        selected = order[min(max(index + step, 0), order.count - 1)].id
    }

    /// The sheet's main button: Play when the game is here, else Install.
    func primaryAction(_ game: RemoteGame) {
        if installedVersion(game) != nil {
            sheetGame = nil
            Task { await play(game) }
        } else if game.canInstall, game.job?.isActive != true {
            startInstall(game)
        }
    }

    func startInstall(_ game: RemoteGame) {
        Task { await install(game) }
    }
}
