import AppKit
import Foundation

/// A failed job's help as the card shows it: the reading of its output at once, then what nxnative has for the game,
/// which takes git and the network.
public struct FailureReport: Sendable {
    public let help: FailureHelp
    /// nxnative's commits for the game newer than the checkout's code: nil while looking.
    public var newer: [ProfileCommit]?
    /// nxnative's issues naming the game: nil while looking or when GitHub couldn't be asked.
    public var issues: [NXNativeIssue]?
    /// The issue lookup is done, with or without an answer.
    public var issuesChecked = false
}

/// Why a job failed (FailureHelp), and what nxnative has for the game since: its newer commits, from the checkout's
/// upstream, and its issues, from GitHub.
extension Library {
    func explainFailure(_ job: Job) {
        guard let help = FailureHelp.read(
            job.log.lines.map(\.text), status: job.status, allowsOtherMetal: allowOtherMetal) else {
            failures[job.id] = nil
            return
        }
        failures[job.id] = FailureReport(help: help)
        checkForFixes(job)
    }

    /// Looks again, from the card: a fix can land minutes after the failure.
    public func checkForFixes(_ job: Job) {
        // screenshots and tests: no git, no network
        guard !isScreenshot, var report = failures[job.id], report.help.isNXNatives, let id = job.game.titleID
        else { return }
        report.newer = nil
        report.issues = nil
        report.issuesChecked = false
        failures[job.id] = report
        let repo = URL(filePath: nxnativeRepo(for: job.game), directoryHint: .isDirectory)
        let jobID = job.id
        Task {
            let newer = await Task.detached(priority: .utility) {
                ProfileNews.fetch(repo: repo)
                return ProfileNews.newer(repo: repo, titleID: id)
            }.value
            failures[jobID]?.newer = newer
        }
        guard lookUpIssues else {
            failures[jobID]?.issuesChecked = true
            return
        }
        Task {
            let issues = await NXNativeIssues.shared.issues(titleID: id)
            failures[jobID]?.issues = issues
            failures[jobID]?.issuesChecked = true
        }
    }

    /// The build nxplay put back after a failed rebuild, as it is: without the nxnative code that failed.
    public func playCurrentBuild(_ game: Game) {
        currentBuildOnce.insert(game.id)
        play(game)
        // a play that didn't start (a question, a busy game) doesn't carry the choice to a later one
        if jobs[game.id]?.kind != .play || jobs[game.id]?.status.isActive != true { currentBuildOnce.remove(game.id) }
    }

    /// What an nxnative issue needs to know, for the clipboard: the game, the code, the Mac, and the end of the output.
    public func failureDetails(_ job: Job) -> String {
        let repo = URL(filePath: nxnativeRepo(for: job.game), directoryHint: .isDirectory)
        let commit = ProfileNews.git(repo, ["rev-parse", "--short=8", "HEAD"]) ?? "unknown"
        let help = failures[job.id]?.help
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let tail = job.log.lines.suffix(80).map(\.text).joined(separator: "\n")
        return """
            ### What happened
            \(help?.title ?? "The build failed") (exit \(help.map { String($0.exitCode) } ?? "?"))

            ### Game, title ID and version
            \(job.game.name), \(job.game.titleID ?? "unknown"), \(job.game.version ?? "unknown version")

            ### nxnative commit
            \(commit)

            ### Device and OS
            \(Self.macModel), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)

            ### Log (the last lines)
            ```
            \(tail)
            ```
            """
    }

    /// "Mac17,8"
    nonisolated static var macModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)
    }
}
