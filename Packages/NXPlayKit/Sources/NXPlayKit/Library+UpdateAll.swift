import Foundation

/// Tools › Update All Builds…: every game brought up to date with nxnative, one build after another, so a game is ready
/// when the player wants it (a build after an nxnative or Xcode update can take an hour, mostly shaders). Optionally
/// only while the Mac is on its power adapter; the Mac stays awake while a build runs.
extension Library {
    /// The games it builds: built ones with their game files, not kept, not busy; the one played last first.
    public var updatableGames: [Game] {
        games.filter { $0.state == .ready && $0.canBuildFromFiles && !$0.isKept && !isBusy($0) }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }

    /// The built games it leaves alone, and why: kept on purpose, or without the game files to build from.
    public var updateSkips: (kept: Int, noFiles: Int) {
        let built = games.filter { $0.state == .ready }
        return (
            built.filter(\.isKept).count, built.filter { !$0.isKept && !$0.canBuildFromFiles }.count
        )
    }

    /// Queues them: nxplay --build-only, which pulls nxnative and rebuilds only a game built from other nxnative code,
    /// so one that's current takes seconds.
    public func updateAll(onlyWhilePluggedIn: Bool) {
        buildsWaitForPower = onlyWhilePluggedIn
        for game in updatableGames { run(.extract, game, select: false) }
        startNextExtraction()
    }

    /// While waiting on battery, looks again every 30 seconds for the adapter.
    func setWaitingForPower(_ waiting: Bool) {
        if waitingForPower != waiting { waitingForPower = waiting }
        if waiting, powerTimer == nil {
            powerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.startNextExtraction() }
            }
        } else if !waiting {
            powerTimer?.invalidate()
            powerTimer = nil
        }
    }

    /// No idle sleep and no App Nap while a build runs: an overnight queue would otherwise stop when the Mac sleeps, and
    /// a build in the background run slower. The display may still sleep. Waiting for the adapter holds nothing.
    func holdAwakeWhileBuilding() {
        let building = jobs.values.contains { $0.kind != .play && $0.status == .running }
        if building, buildActivity == nil {
            buildActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Building games")
        } else if !building, let activity = buildActivity {
            ProcessInfo.processInfo.endActivity(activity)
            buildActivity = nil
        }
    }
}
