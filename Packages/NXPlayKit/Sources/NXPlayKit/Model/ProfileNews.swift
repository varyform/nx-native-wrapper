import Foundation

/// An nxnative commit that changed a game's profile.
public struct ProfileCommit: Equatable, Hashable, Sendable, Identifiable {
    public let hash: String
    public let subject: String
    /// "3 days ago".
    public let age: String
    public var id: String { hash }
}

/// nxnative's changes to the profiles of the games built here, since each was built: what the next play's rebuild
/// brings them. A build's launcher records the nxnative tree it was made from (nxplay's "# nxnative tree" line); the
/// commit with that tree is where its news start, and they run to the upstream's tip, which NX Play fetches itself
/// (only fetches: nxplay still moves the checkout when a game plays).
enum ProfileNews {
    /// The same, each game's from the checkout it builds with: `own` names the games pinned to theirs.
    static func read(repo: URL, builds: [String: String], own: [String: URL]) -> [String: [ProfileCommit]] {
        var news = read(repo: repo, builds: builds.filter { own[$0.key] == nil })
        for checkout in Set(own.values) {
            let pinned = builds.filter { own[$0.key] == checkout }
            news.merge(read(repo: checkout, builds: pinned)) { _, new in new }
        }
        return news
    }

    /// Title ID → the commits since its build that changed dm/games/<title ID>, newest first.
    static func read(repo: URL, builds: [String: String]) -> [String: [ProfileCommit]] {
        guard !builds.isEmpty else { return [:] }
        let tip = git(repo, ["rev-parse", "--verify", "--quiet", "@{u}"]) != nil ? "@{u}" : "HEAD"
        // tree → its newest commit, over recent history (a build older than that has no news to show)
        var commits: [String: String] = [:]
        for line in (git(repo, ["log", "--format=%H %T", "-n", "5000", tip, "HEAD"]) ?? "")
            .split(separator: "\n")
        {
            let parts = line.split(separator: " ").map(String.init)
            if parts.count == 2, commits[parts[1]] == nil { commits[parts[1]] = parts[0] }
        }
        var out: [String: [ProfileCommit]] = [:]
        for (titleID, tree) in builds {
            guard let base = commits[tree],
                let log = git(
                    repo,
                    [
                        "log", "--no-merges", "--format=%h%x09%s%x09%ar", "\(base)..\(tip)", "--",
                        "dm/games/\(titleID)",
                    ])
            else { continue }
            let found = log.split(separator: "\n").compactMap { line -> ProfileCommit? in
                let cells = line.split(separator: "\t", maxSplits: 2).map(String.init)
                return cells.count == 3
                    ? ProfileCommit(hash: cells[0], subject: cells[1], age: cells[2]) : nil
            }
            if !found.isEmpty { out[titleID] = found }
        }
        return out
    }

    /// The upstream's new commits, without touching the checkout.
    static func fetch(repo: URL) { _ = git(repo, ["fetch", "--quiet"]) }

    /// The tree a build was made from: its launcher's "# nxnative tree <sha>" line.
    static func builtTree(_ build: URL) -> String? {
        guard
            let text = try? String(
                contentsOf: build.appending(path: GameScanner.launcherName), encoding: .utf8)
        else { return nil }
        return text.split(separator: "\n").lazy.compactMap { line -> String? in
            line.hasPrefix("# nxnative tree ")
                ? String(line.dropFirst("# nxnative tree ".count)).trimmingCharacters(
                    in: .whitespaces)
                : nil
        }.first
    }

    /// git's output, nil when it fails.
    static func git(_ repo: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + arguments
        // never a prompt for credentials: a fetch that needs them just fails
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["GIT_TERMINAL_PROMPT": "0"], uniquingKeysWith: { _, new in new })
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
