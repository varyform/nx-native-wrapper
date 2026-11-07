import SwiftUI

/// A game's actions: play it here, or have the Mac install (or reinstall) it. Follows the live game by id, so an
/// install's progress shows as the list refreshes. With a controller: A plays (or installs), Y reinstalls, B closes.
struct GameSheet: View {
    @Environment(Launcher.self) private var launcher
    let gameID: String

    var body: some View {
        if let game = launcher.games.first(where: { $0.id == gameID }) {
            content(game)
        } else {
            ContentUnavailableView("The game is gone from the Mac", systemImage: "questionmark.folder")
        }
    }

    private func content(_ game: RemoteGame) -> some View {
        let installed = launcher.installedVersion(game)
        let job = game.job.flatMap { $0.kind == "install" ? $0 : nil }
        let hints = launcher.controller.isConnected
        return NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        if let image = launcher.icons[game.id] {
                            Image(uiImage: image).resizable().frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(game.name).font(.title2.bold())
                            Text(
                                installed.map { "On this \(UIDevice.current.model) · \($0)" }
                                    ?? (launcher.wasRemoved(game) ? "Removed from this " : "Not on this ")
                                    + UIDevice.current.model)
                                .foregroundStyle(.secondary)
                            if let version = game.version {
                                Text("On the Mac: \(version)").foregroundStyle(.secondary)
                            }
                            if installed != nil, let expires = game.expires {
                                Text(
                                    "\(Expiry.text(expires)) (\(expires.formatted(date: .abbreviated, time: .shortened)))"
                                )
                                .foregroundStyle(Expiry.isSoon(expires) ? .orange : .secondary)
                            }
                        }
                    }
                }
                if let job, job.isActive {
                    Section("Installing") {
                        ProgressView(value: job.fraction) { Text(job.text) }
                        Text("The Mac builds the game, then installs it over Wi-Fi or the cable. Keep both awake.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        if installed != nil {
                            Button { launcher.primaryAction(game) } label: {
                                hint("a.circle", "Play", shown: hints)
                            }
                            .font(.headline)
                        }
                        if game.canInstall {
                            Button { launcher.startInstall(game) } label: {
                                hint(
                                    installed == nil ? "a.circle" : "y.circle",
                                    installed != nil || launcher.wasRemoved(game)
                                        ? "Reinstall from the Mac" : "Install", shown: hints)
                            }
                        } else {
                            Text(
                                game.kept
                                    ? "Kept on the Mac: Keep This Build stops device installs."
                                    : "The Mac has no game files to build it from."
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                    if let job, job.status == "failed" {
                        Section("Last install failed") {
                            Text((job.lastLines ?? [job.text]).joined(separator: "\n"))
                                .font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle(game.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button { launcher.sheetGame = nil } label: { hint("b.circle", "Done", shown: hints) }
            }
            .horizontalToolbar()
        }
    }

    /// A button's title, with the controller button that does the same in front while a controller is connected.
    private func hint(_ symbol: String, _ title: String, shown: Bool) -> some View {
        HStack(spacing: 6) {
            if shown { Image(systemName: symbol) }
            Text(title)
        }
    }
}
