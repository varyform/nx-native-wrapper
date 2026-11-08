import Foundation
import Testing

@testable import NXPlayKit

/// Play's question before updating (issue #7), answered with a controller in Console Mode (issue #9).
@MainActor @Suite final class UpdatePromptTests {
    private var suites: [String] = []

    deinit { suites.forEach(removeTestDefaults) }

    private func library() -> Library {
        let suite = testDefaultsName()
        suites.append(suite)
        let library = Library(defaults: UserDefaults(suiteName: suite)!, isScreenshot: true)
        let game = Game(
            folder: URL(filePath: "/games/Dread"), name: "Dread", titleID: nil, version: nil,
            languages: [], iconURL: nil, buildFolder: nil, ipaURL: nil, xcodeBuildFolder: nil,
            hasPackages: true, state: .ready)
        let job = Job(
            kind: .play, game: game,
            command: NXPlayCommand(
                script: URL(filePath: "/usr/bin/true"), arguments: [], environment: [:]))
        let ask = UpdateAsk(
            commits: 9, gameCommits: [], shaders: .reused, estimate: nil, hasApp: false)
        library.updatePrompt = UpdatePrompt(job: job, ask: ask)
        return library
    }

    @Test func theWindowShowsTheControllersRowOnceOneIsConnected() {
        let library = library()
        #expect(!library.consoleMode && !library.showsControllerFocus)  // nothing to answer with but the mouse
        library.gamepad.sample = [(name: "Xbox Wireless Controller", battery: 1)]
        #expect(library.showsControllerFocus)
    }

    @Test func theControllerReachesEveryRowAndStopsAtTheEnds() {
        let library = library()
        #expect(library.updatePrompt?.focus == .update)
        library.handle(.up)
        #expect(library.updatePrompt?.focus == .update)
        library.handle(.down)
        #expect(library.updatePrompt?.focus == .current)
        library.handle(.right)
        #expect(library.updatePrompt?.focus == .cancel)
        library.handle(.down)
        #expect(library.updatePrompt?.focus == .cancel)
        library.handle(.left)
        #expect(library.updatePrompt?.focus == .current)
    }

    @Test func theLastRowDoesntPlay() {
        let library = library()
        library.handle(.down)
        library.handle(.down)
        library.handle(.confirm)
        #expect(library.updatePrompt == nil)
    }

    @Test func bStillDoesntPlay() {
        let library = library()
        library.handle(.back)
        #expect(library.updatePrompt == nil)
    }
}
