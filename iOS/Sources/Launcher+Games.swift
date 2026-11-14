import UIKit

/// The grid's order, what's installed here, and installing and playing a game.
extension Launcher {
    /// The grid's order: the games on this device first, ready to play, then the rest by name.
    var sortedGames: [RemoteGame] {
        games.sorted {
            (installedVersion($0) == nil ? 1 : 0, $0.name) < (installedVersion($1) == nil ? 1 : 0, $1.name)
        }
    }

    /// Installed games whose signature runs out within two days (or has): Renew installs them again.
    var expiring: [RemoteGame] {
        games.filter { installedVersion($0) != nil && Expiry.isSoon($0.expires) && $0.job?.isActive != true }
    }

    func renewExpiring() {
        // the Mac queues installs and runs them one at a time
        for game in expiring where game.canInstall { startInstall(game) }
    }

    /// Deleted from this device since the Mac installed it (or saw it here).
    func wasRemoved(_ game: RemoteGame) -> Bool {
        game.titleID.map { removed.contains($0.uppercased()) } ?? false
    }

    func installedVersion(_ game: RemoteGame) -> String? {
        game.titleID.flatMap { installed[$0.uppercased()] }
    }

    func install(_ game: RemoteGame) async {
        guard let mac, let device = mac.device else { return }
        do {
            _ = try await mac.client.install(game, on: device)
            await refresh()
            startPolling()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Opens the game by the URL scheme nxplay adds when it installs one (nxplay-<title ID>). A game installed
    /// before that has none: reinstalling adds it.
    func play(_ game: RemoteGame) async {
        guard let id = game.titleID, let url = URL(string: "nxplay-\(id.lowercased())://") else {
            return
        }
        if !(await UIApplication.shared.open(url)) {
            problem =
                "\(game.name) can't be opened from here: reinstall it from the Mac once, then it can."
        }
    }
}
