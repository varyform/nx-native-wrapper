import Foundation

/// The builds of the Macs this one builds on (Settings › Remote), where they meet this Mac's library: a game in a
/// games folder both Macs have (SharedFolders) shows the other Mac's build of it as its own job, and can't start one
/// here until it's done, as two Macs building into one folder would spoil each other's build.
extension Library {
    /// This Mac's games by where they are in a games folder that may be shared; nothing while no Mac is paired, so the
    /// folders get no id file until there's a use for one.
    func sharedGames() -> [String: Game] {
        guard !macLink.hosts.isEmpty else { return [:] }
        var ids = sharedFolderIDs
        var shared: [String: Game] = [:]
        for game in games {
            if let key = SharedFolders.key(of: game.folder, roots: roots, ids: &ids) { shared[key] = game }
        }
        sharedFolderIDs = ids
        return shared
    }

    /// A host's builds changed: which of this Mac's games another Mac builds now, and a refresh for the ones it just
    /// finished, whose build is now in their folder.
    func remoteBuildsChanged(finished: [Game]) {
        let local = Set(games.map(\.id))
        var covered: [Game.ID: Job] = [:]
        for mirrors in macLink.jobs.values {
            for job in mirrors.values where local.contains(job.game.id) && job.remote?.wasActive == true {
                // the running one wins over one that has ended
                if let other = covered[job.game.id], other.status.isActive, !job.status.isActive { continue }
                covered[job.game.id] = job
            }
        }
        if covered.keys.sorted() != sharedJobs.keys.sorted()
            || covered.contains(where: { sharedJobs[$0.key] !== $0.value })
        {
            sharedJobs = covered
        }
        if finished.contains(where: { local.contains($0.id) }) { refresh() }
        startNextExtraction()
    }

    /// Another Mac builds the game now.
    public func isBuildingElsewhere(_ game: Game) -> Bool {
        sharedJobs[game.id]?.status.isActive == true
    }
}
