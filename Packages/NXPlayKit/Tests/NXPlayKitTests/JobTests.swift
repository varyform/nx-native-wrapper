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
