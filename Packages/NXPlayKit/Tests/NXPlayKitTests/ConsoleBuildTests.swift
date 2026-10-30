import Foundation
import Testing

@testable import NXPlayKit

/// Console Mode's marks for the games being built.
@MainActor @Suite struct ConsoleBuildTests {
    private func job(_ name: String, _ kind: Job.Kind, _ status: Job.Status, lines: [String] = [])
        -> Job
    {
        let game = Game(
            folder: URL(filePath: "/games/\(name)"), name: name, titleID: nil, version: nil,
            languages: [], iconURL: nil, buildFolder: nil, ipaURL: nil, xcodeBuildFolder: nil,
            hasPackages: true, state: .ready)
        let job = Job(
            kind: kind, game: game,
            command: NXPlayCommand(
                script: URL(filePath: "/usr/bin/true"), arguments: [], environment: [:]))
        job.showScreenshot(lines, status: status)
        return job
    }

    @Test func tilesMarkBuildsNotAPlayGettingReady() {
        let stage =
            #"{"ev": "stage", "k": 8, "n": 9, "name": "Mac shaders", "step": "compiling", "t": 1}"#
        let rebuild = job("Dread", .rebuild, .running, lines: [stage])
        let queued = job("Wonder", .extract, .queued)
        let preparing = job("Zelda", .play, .running)  // nxplay checks nxnative: it may not build at all
        let builds = Carousel.builds([rebuild, queued, preparing])
        guard case .running(let fraction) = builds[rebuild.game.id] else {
            Issue.record("the rebuild isn't marked")
            return
        }
        #expect(abs(fraction - 7.0 / 9) < 0.01)
        #expect(builds[queued.game.id] == .queued)
        #expect(builds[preparing.game.id] == nil)
    }
}
