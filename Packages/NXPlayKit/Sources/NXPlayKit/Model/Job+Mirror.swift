import Foundation

/// A build running on another Mac, mirrored by a Job without a process: the same progress, status and log as the
/// host's, so a card, the status bar and the log show it as they do one here. Cancel asks the host to stop it.
@MainActor public final class RemoteBuild {
    /// The host's name, as Settings › Remote shows it.
    public let macName: String
    let jobID: UUID
    /// The host's log lines this mirror has, counted the host's way (dropped ones included).
    var logTotal = 0
    /// The build was seen queued or running: only then does it stand for its game in a shared folder, so an old
    /// result on the host doesn't cover this Mac's own.
    var wasActive = false
    let onCancel: @MainActor () -> Void

    init(macName: String, jobID: UUID, onCancel: @escaping @MainActor () -> Void) {
        self.macName = macName
        self.jobID = jobID
        self.onCancel = onCancel
    }

    func cancel() { onCancel() }
}

extension Job {
    static func mirror(_ remote: RemoteJob, of game: Game, on build: RemoteBuild) -> Job {
        let kind: Kind =
            switch remote.kind {
            case .extract: .extract
            case .play: .play
            case .rebuild, .other: .rebuild
            }
        let job = Job(
            kind: kind, game: game,
            command: NXPlayCommand(script: URL(filePath: "/usr/bin/true"), arguments: [], environment: [:]))
        job.remote = build
        // joined part way: the lines before the host's last chunk aren't fetched
        build.logTotal = max(0, remote.logTotal - MacWire.logChunk)
        job.log.append([.own("nxplay: building on \(build.macName)")])
        if build.logTotal > 0 { job.log.append([.own("…")]) }
        job.apply(remote)
        return job
    }

    /// The host's job as it is now, and the log lines it sent that aren't here yet.
    func apply(_ remote: RemoteJob) {
        guard let build = self.remote else { return }
        if status != remote.status { status = remote.status }
        if remote.status.isActive { build.wasActive = true }
        if progress != remote.progress { progress = remote.progress }
        if note != remote.note { note = remote.note }
        if warnings != remote.warnings { warnings = remote.warnings }
        if gameStarted != remote.gameStarted { gameStarted = remote.gameStarted }
        let end = remote.logFrom + remote.log.count
        // no lines: the host wasn't asked for them (a poll before the mirror was there), nothing to move on from
        guard !remote.log.isEmpty, end > build.logTotal else { return }
        if remote.logFrom > build.logTotal { log.append([.own("…")]) }  // the host dropped lines in between
        log.append(Array(remote.log.suffix(end - max(build.logTotal, remote.logFrom))))
        build.logTotal = end
    }
}
