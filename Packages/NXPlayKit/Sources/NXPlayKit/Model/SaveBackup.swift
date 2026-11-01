import Foundation

/// Saves backed up to a Git repository (Settings › Save backup): a clone of the player's own, private repository with
/// a folder per game, named after the game and its title ID. While a game plays, its Mac save (`run/save`) is looked
/// at every few seconds; once a change has settled it is copied into the game's folder, committed and pushed, and once
/// more when the game ends. What happened goes into the play's log.
@MainActor
final class SaveBackup {
    static let interval: Duration = .seconds(5)

    private var watches: [Game.ID: Task<Void, Never>] = [:]
    private let repository = SaveRepository()

    /// Follows a play until it ends. Polling rather than file events: the save folder may not exist yet (a first play
    /// builds the game, then the game makes it), and a write in progress has to settle before it is copied anyway.
    /// `save`: the folder the play uses instead of the build's (the Mac app's own save, Library+AppSave.swift).
    func watch(_ job: Job, into repo: URL, save: URL? = nil, interval: Duration = SaveBackup.interval) {
        let game = job.game
        let saveFolder: @Sendable () -> URL? = { save ?? Self.saveFolder(of: game) }
        guard watches[game.id] == nil, let folder = Self.folderName(for: game) else { return }
        watches[game.id] = Task { [weak self, repository] in
            var settle = SaveSettle()
            while job.status.isActive {
                try? await Task.sleep(for: interval)
                let save = saveFolder()
                let print = await Task.detached { save.map(SaveSettle.fingerprint) }.value
                guard settle.changed(print), let save else { continue }
                let note = await repository.backUp(
                    save, into: repo, folder: folder, game: game.name)
                if let note { job.note(note) }
            }
            // the game has quit: its last writes are complete
            if let save = saveFolder(),
                let note = await repository.backUp(
                    save, into: repo, folder: folder, game: game.name)
            {
                job.note(note)
            }
            self?.watches[game.id] = nil
        }
    }

    /// The game's folder in the repository: its name lower-cased, words joined by dashes, then its title ID, as
    /// `the-legend-of-zelda-tears-of-the-kingdom-0100f2c0115b6000`. Accents fold into plain letters; other scripts
    /// leave the title ID alone. Nil without a title ID (nothing built, so no save).
    nonisolated static func folderName(for game: Game) -> String? {
        guard let id = game.titleID?.lowercased() else { return nil }
        let words = game.name
            .replacing(/['’]/, with: "")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
            .map(String.init)
        return (words + [id]).joined(separator: "-")
    }

    /// `<title ID>_build/run/save`, the Mac host's save (DM_SAVE), once it exists.
    nonisolated static func saveFolder(of game: Game) -> URL? {
        GameScanner.children(of: game.folder)
            .filter(GameScanner.isBuildFolder)
            .map { $0.appending(path: "run/save", directoryHint: .isDirectory) }
            .first { GameScanner.isDirectory($0) }
    }
}

/// When a save is worth backing up: it changed since the last backup and stayed the same for one look, so a game
/// writing it in several steps is not caught halfway.
struct SaveSettle {
    private var previous: [String: String]?
    private var backedUp: [String: String]?

    mutating func changed(_ now: [String: String]?) -> Bool {
        defer { previous = now }
        guard let now, now == previous, now != backedUp else { return false }
        backedUp = now
        return true
    }

    /// Every file under the folder: relative path → size and modification time.
    static func fingerprint(_ folder: URL) -> [String: String] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard
            let files = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys)
        else { return [:] }
        var print: [String: String] = [:]
        let base = folder.standardizedFileURL.path + "/"
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { continue }
            let path = file.standardizedFileURL.path.replacing(base, with: "", maxReplacements: 1)
            print[path] =
                "\(values.fileSize ?? 0) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return print
    }
}

/// The Git side, one backup at a time (two games can play at once). Runs the system's git with the player's own
/// configuration and credentials (SSH agent, keychain); nothing may prompt, so a missing credential fails the push
/// instead of hanging it.
actor SaveRepository {
    /// Mirrors the save into the game's folder, commits it and pushes → a line for the log, nil when nothing changed.
    func backUp(_ save: URL, into repo: URL, folder: String, game: String) -> String? {
        guard FileManager.default.fileExists(atPath: repo.appending(path: ".git").path) else {
            return "save backup: \(repo.path) is not a Git repository (Settings › Save backup)"
        }
        let target = repo.appending(path: folder, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let copy = run(
            "/usr/bin/rsync", ["-a", "--delete", save.path + "/", target.path + "/"], in: repo)
        guard copy.code == 0 else {
            return "save backup: copying the save failed: \(copy.lastLine)"
        }

        git(["add", "-A", "--", folder], in: repo)
        let changed = git(["diff", "--cached", "--name-only", "--", folder], in: repo).output
            .split(separator: "\n").count
        guard changed > 0 else { return nil }
        let stamp = Date.now.formatted(
            .iso8601.year().month().day().time(includingFractionalSeconds: false))
        let commit = git(
            ["commit", "-q", "-m", "\(game): save of \(stamp)", "--", folder], in: repo)
        guard commit.code == 0 else { return "save backup: commit failed: \(commit.lastLine)" }

        let files = changed == 1 ? "1 file" : "\(changed) files"
        return "save backup: committed \(files) in \(folder), " + push(repo)
    }

    /// Pushes the branch: sets its upstream on origin the first time, and replays the commit on top of the remote
    /// when another Mac pushed in between (each game has a folder of its own, so they don't conflict).
    private func push(_ repo: URL) -> String {
        let hasUpstream = git(["rev-parse", "--abbrev-ref", "@{u}"], in: repo).code == 0
        if !hasUpstream {
            guard git(["remote", "get-url", "origin"], in: repo).code == 0 else {
                return "not pushed: the repository has no remote"
            }
            let first = git(["push", "-q", "-u", "origin", "HEAD"], in: repo)
            return first.code == 0 ? "pushed" : "push failed: \(first.lastLine)"
        }
        if git(["push", "-q"], in: repo).code == 0 { return "pushed" }
        let rebase = git(["pull", "-q", "--rebase", "--autostash"], in: repo)
        guard rebase.code == 0 else {
            git(["rebase", "--abort"], in: repo)
            return "push failed and the remote could not be merged: \(rebase.lastLine)"
        }
        let again = git(["push", "-q"], in: repo)
        return again.code == 0 ? "pushed" : "push failed: \(again.lastLine)"
    }

    struct Result {
        let code: Int32
        let output: String
        var lastLine: String {
            output.split(separator: "\n").last.map(String.init) ?? "exit \(code)"
        }
    }

    @discardableResult
    private func git(_ arguments: [String], in repo: URL) -> Result {
        run("/usr/bin/git", ["-C", repo.path] + arguments, in: repo)
    }

    private func run(_ tool: String, _ arguments: [String], in directory: URL) -> Result {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = environment["GIT_SSH_COMMAND"] ?? "ssh -o BatchMode=yes"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            return Result(code: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            code: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
