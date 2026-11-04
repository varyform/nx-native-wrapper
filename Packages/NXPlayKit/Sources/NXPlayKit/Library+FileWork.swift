import Foundation

/// Work that deletes a game's files: Free Up Space's Delete and Remove Game, from the window or the control API alike.
/// Such work runs one at a time, first come first served, and holds the games it touches while it runs: no build,
/// play or install starts on them (`run` refuses) and nothing removes them meanwhile. Each one decides only once it
/// runs, from the disk as it is then. Two deletions asked for at the same time from the same scan are judged one after
/// the other: once one has taken a game's files, the other sees a game whose build is all it has left, and refuses.
extension Library {
    /// The file work's turn, FIFO: one at a time.
    @MainActor final class FileWorkGate {
        private var held = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            guard held else {
                held = true
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        /// Hands the turn to the next one waiting, or frees it.
        func release() {
            if waiting.isEmpty { held = false } else { waiting.removeFirst().resume() }
        }

        var isHeld: Bool { held }
    }

    /// File work holds the game now: nothing starts on it, and Remove Game waits.
    public func isReserved(_ game: Game) -> Bool { (reservedGames[game.id] ?? 0) > 0 }

    /// Runs `work` as file work: after the file work before it, with `games` held for its whole length, and counted
    /// as work bin/install's quit waits for.
    func fileWork<T>(holding games: Set<Game.ID>, _ work: () async -> T) async -> T {
        tasksInFlight += 1
        await fileWorkGate.acquire()
        for id in games { reservedGames[id, default: 0] += 1 }
        let result = await work()
        for id in games {
            let count = (reservedGames[id] ?? 1) - 1
            reservedGames[id] = count > 0 ? count : nil
        }
        fileWorkGate.release()
        tasksInFlight -= 1
        quitIfIdle()
        return result
    }

    /// The games of the library that own these paths (standardized, as `freeUpSpace` compares them): in the game's
    /// folder, or its build folder.
    func games(owning paths: [String]) -> Set<Game.ID> {
        Set(
            games.filter { game in
                let roots = ([game.folder] + (game.buildFolder.map { [$0] } ?? [])).map(\.standardizedFileURL.path)
                return paths.contains { path in roots.contains { path == $0 || path.hasPrefix($0 + "/") } }
            }.map(\.id))
    }

    /// Free Up Space's Delete, for the window and the control API alike: these files and folders, exactly as a scan
    /// listed them, deleted for good, all or none. As file work, and only once the library has read the games folder
    /// again and a fresh scan says, right then, that each one is listed, not blocked, not busy, and not a build going
    /// with its own game's files. `sizes`: what the caller measured, for the freed total.
    func freeUpSpace(_ wanted: [URL], sizes: [URL: Int64] = [:]) async -> CleanupOutcome {
        let paths = Array(Set(wanted.map { $0.standardizedFileURL.path })).sorted()
        guard !paths.isEmpty else { return .refused("Nothing is selected") }
        return await fileWork(holding: games(owning: paths)) { () async -> CleanupOutcome in
            // the disk as it is now: deletions before this one have finished, and the games' states follow them
            refresh()
            let held = Set(reservedGames.keys)
            let busy = Set(games.filter(isBusy).map(\.id))
            let games = self.games
            let fresh = await Task.detached {
                CleanupScanner.groups(games: games, busy: busy, measuring: false)
            }.value
            var listed: [String: (file: CleanupFile, group: CleanupGroup)] = [:]
            for group in fresh {
                for file in group.files { listed[file.url.standardizedFileURL.path] = (file, group) }
            }
            var chosen: [(file: CleanupFile, group: CleanupGroup)] = []
            for path in paths {
                let name = URL(filePath: path).lastPathComponent
                guard let found = listed[path] else {
                    return .notListed("\(name) isn't something Free Up Space lists now: look again (cleanup.scan)")
                }
                if let blocked = found.file.blocked { return .refused("\(name): \(blocked)") }
                // held for this work from the start: a game found only now (just copied in) waits for a new look
                guard held.contains(found.group.game.id) else {
                    return .refused("\(name) is in a game that just changed: look again")
                }
                chosen.append(found)
            }
            for group in Set(chosen.map(\.group.game.id)) {
                let roles = chosen.filter { $0.group.game.id == group }.map(\.file.role)
                if roles.contains(.original), roles.contains(.build) {
                    let game = chosen.first { $0.group.game.id == group }!.group.game.name
                    return .refused(
                        "\(game): a game's build and its game files never go together (without both it couldn't play or be built again)")
                }
            }
            let known = Dictionary(sizes.map { ($0.key.standardizedFileURL.path, $0.value) }, uniquingKeysWith: { a, _ in a })
            let listedFiles = chosen.map { found in
                var file = found.file
                if let size = known[file.url.standardizedFileURL.path] {
                    file.size = size
                    file.measuring = false
                }
                return file
            }
            // what deleting frees, for what the caller hadn't measured: off the main actor
            let files = await Task.detached { listedFiles.map { $0.measuring ? CleanupScanner.measure($0) : $0 } }.value
            // the scan was a wait: nothing can have started on a held game, but a job is checked for again right
            // before deleting, however it came
            if let started = chosen.first(where: { found in jobs[found.group.game.id]?.status.isActive == true }) {
                return .refused("\(started.group.game.name) is busy: wait until its build or game finishes")
            }
            // Keep This Build can't change on a held game (changeKept refuses), and its marker is read from the disk
            // again all the same: one written since the scan, by anything, protects the build as the scan's would
            if let kept = chosen.first(where: { found in
                found.file.role == .build
                    && found.group.game.keepFile.map { FileManager.default.fileExists(atPath: $0.path) } == true
            }) {
                return .refused("\(kept.file.url.lastPathComponent): Kept: turn off Keep This Build first.")
            }
            let failures = await Cleanup.remove(files)
            refresh()
            let removed = files.filter { failures[$0.url] == nil }
            let size = removed.reduce(0) { $0 + $1.size }
            if failures.isEmpty { return .done(removed.map(\.url), size: size) }
            return .failed(
                "\(removed.count) of \(files.count) removed. Not removed: "
                    + failures.map { "\($0.key.lastPathComponent) (\($0.value))" }.sorted().joined(separator: "; "),
                removed: removed.map(\.url), notRemoved: Set(failures.keys))
        }
    }
}

/// How a Free Up Space deletion went.
public enum CleanupOutcome: Sendable, Equatable {
    case done([URL], size: Int64)
    /// Nothing was deleted: the selection no longer holds as it was chosen.
    case refused(String)
    /// Nothing was deleted: one of the paths isn't something a scan lists now.
    case notListed(String)
    /// Some of it couldn't be deleted.
    case failed(String, removed: [URL], notRemoved: Set<URL>)
}
