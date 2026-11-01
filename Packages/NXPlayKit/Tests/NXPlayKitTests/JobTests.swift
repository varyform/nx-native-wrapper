import Foundation
import Testing

@testable import NXPlayKit

/// Job against stand-in scripts for nxplay.
@MainActor @Suite struct JobTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-job-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func streamsOutputProgressAndTheExitCode() async throws {
        let job = try job(
            running: """
                echo "args: $*"
                echo '{"ev": "stage", "k": 2, "n": 4, "name": "shader split", "step": "reading", "t": 1793000000}'
                echo '{"ev": "progress", "k": 2, "name": "shader split", "step": "reading", "frac": 0.5, "eta": null, "t": 1793000000}'
                echo "Traceback (most recent call last):" >&2
                exit 3
                """, arguments: ["--build-only", "/games/A"])

        job.start()
        try await finished(job)

        #expect(job.status == .failed(3))
        #expect(job.log.lines.map(\.text).contains("args: --build-only /games/A"))
        #expect(job.progress?.stage == 2 && job.progress?.percent == 50)
        let shown = job.log.lines.map(\.text)
        #expect(shown.contains { $0.hasSuffix("[2/4] shader split · reading …") })
        #expect(!shown.contains { $0.hasPrefix("{") })  // events become lines, never raw JSON
        #expect(shown.contains("Traceback (most recent call last):"))
        #expect(job.log.lines.last?.text == "nxplay: failed (exit 3)")
        // NX Play's own lines are blue, as nxplay's are
        #expect(job.log.lines.last?.segments.first?.style.foreground == .standard(4))
        #expect(job.log.lines.first?.segments.first?.style.foreground == .standard(4))
    }

    @Test func cancelStopsTheWholeProcessTree() async throws {
        let pidFile = folder.appending(path: "child.pid")
        let job = try job(
            running: """
                sleep 60 &
                echo $! > '\(pidFile.path)'
                echo started
                wait
                """)

        job.stopGrace = 0.2
        job.start()
        try await until { job.log.lines.map(\.text).contains("started") }
        let child = try #require(
            Int32(
                String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(
                    in: .whitespacesAndNewlines)))
        job.cancel()
        try await finished(job)

        #expect(job.status == .cancelled)
        // the background child ignores SIGINT: the SIGTERM after it ends it
        try await until { kill(child, 0) != 0 }
    }

    @Test func aPlayIsPreparingUntilItBuildsOrTheGameStarts() async throws {
        let play = try job(
            running: """
                echo "nxnative: up to date"
                sleep 0.5
                echo "nxplay: starting the game"
                sleep 0.5
                """, kind: .play)
        play.start()
        try await until { play.note == "nxnative: up to date" }
        #expect(play.isPreparing && play.showsProgress)
        #expect(play.progressText == "nxnative: up to date")
        try await until { play.gameStarted }
        #expect(!play.isPreparing && !play.showsProgress)  // the game runs: no progress to show
        try await finished(play)

        // a build's first stage ends the preparing too
        let building = try job(
            running: """
                echo '{"ev": "stage", "k": 2, "n": 4, "name": "shader split", "step": "reading", "t": 1793000000}'
                echo '{"ev": "progress", "k": 2, "name": "shader split", "step": "reading", "frac": 0.5, "eta": null, "t": 1793000000}'
                sleep 0.5
                """, kind: .play)
        building.start()
        try await until { building.progress != nil }
        #expect(!building.isPreparing && building.isBuilding)
        try await finished(building)
    }

    /// NXPLAY_UPDATE=ask: nxplay's question shows on the job, and the answer reaches nxplay's stdin.
    @Test func aPlayAsksAndHearsTheAnswer() async throws {
        let job = try job(
            running: """
                echo '{"ev": "ask", "about": "update", "commits": 9, "game": [{"hash": "abc1234", "subject": "Fix the intro"}], "shaders": "recompile", "estimate": 600, "app": true}'
                read -r answer
                echo "answer: $answer"
                """, kind: .play)
        var asked = 0
        job.onAsk = { _ in asked += 1 }

        job.start()
        try await until { job.ask != nil }
        #expect(asked == 1)
        #expect(job.ask?.commits == 9 && job.ask?.shaders == .recompile)
        #expect(job.ask?.gameCommits.map(\.subject) == ["Fix the intro"])
        #expect(job.ask?.estimateText == "About 10 min, as last time (the Mac app included)")
        job.answer(.current)
        try await finished(job)

        #expect(job.ask == nil)
        #expect(job.status == .succeeded)
        #expect(job.log.lines.map(\.text).contains("answer: current"))
    }

    @Test func notPlayingEndsThePlayAsCancelled() async throws {
        let job = try job(
            running: """
                echo '{"ev": "ask", "about": "update", "commits": -1, "game": [], "shaders": "odd"}'
                read -r answer
                [[ "$answer" == cancel ]] && exit 0
                exit 1
                """, kind: .play)

        job.start()
        try await until { job.ask != nil }
        #expect(job.ask?.commits == nil && job.ask?.shaders == .unknown)
        #expect(job.ask?.headline == "New nxnative code, none of it for this game")
        job.answer(.cancel)
        try await finished(job)
        #expect(job.status == .cancelled)
    }

    private func job(running body: String, arguments: [String] = [], kind: Job.Kind = .extract)
        throws -> Job
    {
        let script = folder.appending(path: "nxplay")
        try ("#!/bin/bash\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
        let game = Game(
            folder: folder, name: "Test", titleID: nil, version: nil, languages: [], iconURL: nil,
            buildFolder: nil, ipaURL: nil, xcodeBuildFolder: nil, hasPackages: true,
            state: .notExtracted)
        return Job(
            kind: kind, game: game,
            command: NXPlayCommand(
                script: script, arguments: arguments,
                environment: ProcessInfo.processInfo.environment))
    }

    private func finished(_ job: Job) async throws {
        try await until { !job.status.isActive }
    }

    private func until(timeout: Duration = .seconds(15), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
