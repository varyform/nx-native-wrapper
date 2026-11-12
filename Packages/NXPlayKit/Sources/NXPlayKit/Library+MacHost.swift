import Foundation

/// Allow Remote Builds (Settings › Remote): what a paired Mac may ask of this one. It sees the games and their builds,
/// and may build, rebuild or stop building one; it can't play, change settings or reach the files.
extension Library {
    func answerMac(_ call: MacCall, from client: PairedMac) async -> MacReply {
        switch call {
        case .poll(let logs):
            return .snapshot(macSnapshot(logs: logs))
        case .build(let id, let rebuild):
            return remoteBuild(id, rebuild: rebuild, for: client)
        case .cancel(let id):
            guard let job = jobs[id], job.status.isActive else { return .failure("Nothing is building there.") }
            guard job.kind == .extract || job.kind == .rebuild else {
                return .failure("\(job.game.name) is playing there: only a build can be stopped from another Mac.")
            }
            job.note("nxplay: stopped from \(client.name)")
            job.cancel()
            return .ok
        case .icon(let id):
            guard let game = games.first(where: { $0.id == id }), let icon = icon(for: game) else { return .icon(nil) }
            return .icon(try? Data(contentsOf: icon))
        case .pair, .hello, .unpair:
            return .failure("Already handled.")
        }
    }

    private func remoteBuild(_ id: String, rebuild: Bool, for client: PairedMac) -> MacReply {
        guard let game = games.first(where: { $0.id == id }) else {
            return .failure("That game isn\u{2019}t in the library there any more.")
        }
        guard !isBusy(game) else { return .failure("\(game.name) is already busy there.") }
        if rebuild {
            guard !game.isKept else { return .failure(Self.keptBuildProblem) }
            guard game.canBuildFromFiles else { return .failure("\(game.name) has no game files to build from.") }
        } else {
            guard game.canExtract else { return .failure("\(game.name) can\u{2019}t be built: it is already.") }
        }
        run(rebuild ? .rebuild : .extract, game, select: false)
        guard let job = jobs[game.id], job.status.isActive else {
            return .failure(problem ?? "The build didn\u{2019}t start.")
        }
        job.note("nxplay: started from \(client.name)")
        return .ok
    }

    func macSnapshot(logs: [String: Int]) -> MacSnapshot {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let busy = Set(jobs.values.filter { $0.status.isActive }.map(\.game.id))
        var ids = sharedFolderIDs
        let list = games.map { game -> RemoteGame in
            let free = !busy.contains(game.id) && sharedJobs[game.id] == nil
            return RemoteGame(
                id: game.id, name: game.name, titleID: game.titleID, version: game.version,
                isExtracted: game.isExtracted, isReady: game.state == .ready, isKept: game.isKept,
                canBuild: free && game.canExtract, canRebuild: free && game.canBuildFromFiles && !game.isKept,
                hasIcon: icon(for: game) != nil,
                shared: SharedFolders.key(of: game.folder, roots: roots, ids: &ids),
                job: jobs[game.id].map { remoteJob($0, logFrom: logs[game.id]) })
        }
        sharedFolderIDs = ids
        return MacSnapshot(name: MacLink.computerName, version: version, games: list)
    }

    private func remoteJob(_ job: Job, logFrom: Int?) -> RemoteJob {
        let kind: RemoteJob.Kind =
            switch job.kind {
            case .extract: .extract
            case .rebuild: .rebuild
            case .play: .play
            default: .other
            }
        let buffer = job.log
        var from = buffer.total
        var lines: [LogLine] = []
        if let logFrom {
            from = min(max(logFrom, buffer.dropped), buffer.total)
            lines = Array(buffer.lines[(from - buffer.dropped)...].prefix(MacWire.logChunk))
        }
        return RemoteJob(
            id: job.id, kind: kind, status: job.status, progress: job.progress, note: job.note,
            warnings: job.warnings, gameStarted: job.gameStarted, logTotal: buffer.total, logFrom: from,
            log: lines)
    }
}
