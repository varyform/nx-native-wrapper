import Foundation
import Testing

@testable import NXPlayKit

/// A class, so each test's settings domains are removed when it ends: a suite's plist otherwise stays in
/// ~/Library/Preferences for good.
@MainActor @Suite final class LibraryTests {
    private var suites: [String] = []

    deinit {
        suites.forEach(removeTestDefaults)
    }

    private func defaults() -> UserDefaults {
        let suite = testDefaultsName()
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func library() -> Library {
        Library(defaults: defaults(), isScreenshot: true)  // no devicectl
    }

    private func job(_ name: String, _ status: Job.Status, kind: Job.Kind = .rebuild) -> Job {
        let game = Game(
            folder: URL(filePath: "/games/\(name)"), name: name, titleID: nil, version: nil,
            languages: [],
            iconURL: nil, buildFolder: nil, ipaURL: nil, xcodeBuildFolder: nil, hasPackages: true,
            state: .ready)
        let job = Job(
            kind: kind, game: game,
            command: NXPlayCommand(
                script: URL(filePath: "/usr/bin/true"), arguments: [], environment: [:]))
        job.showScreenshot(["output"], status: status)
        return job
    }

    @Test func aFailedJobOpensTheLogOnItsGame() {
        let library = library()
        library.showsLog = false
        library.selection = "/games/Other"

        library.finished(job("Done", .succeeded))
        #expect(!library.showsLog && library.selection == "/games/Other")  // success leaves it alone

        library.finished(job("Broken", .failed(1)))
        #expect(library.showsLog)
        #expect(library.selection == "/games/Broken")
    }

    @Test func theControllerMovesThroughTheGamesInGridOrder() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-nav-\(UUID().uuidString)")
        for (folder, built) in [
            ("A Fresh", false), ("B Built", true), ("C Fresh", false), ("D Built", true),
        ] {
            let game = root.appending(path: folder)
            try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
            try Data([1]).write(to: game.appending(path: "\(folder).nsp"))
            if built {
                let extract = game.appending(path: "0100000000010000_build/extract/v0")
                try FileManager.default.createDirectory(
                    at: extract, withIntermediateDirectories: true)
            }
        }
        let library = library()
        library.root = root
        let names = { library.selectedGame?.folder.lastPathComponent }

        // extracted games first, as the grid's sections and the carousel show them
        #expect(
            library.navigableGames.map(\.folder.lastPathComponent) == [
                "B Built", "D Built", "A Fresh", "C Fresh",
            ])
        library.handle(.right)
        #expect(names() == "B Built")  // nothing selected: the first
        library.handle(.down)
        library.handle(.right)
        #expect(names() == "A Fresh")
        for _ in 0..<5 { library.handle(.right) }
        #expect(names() == "C Fresh")  // stops at the end
        for _ in 0..<9 { library.handle(.left) }
        #expect(names() == "B Built")

        // Console Mode has only the games it can play; an unextracted selection moves to the first of them
        library.handle(.right)
        library.handle(.right)
        #expect(names() == "A Fresh")
        library.handle(.menu)
        #expect(library.navigableGames.map(\.folder.lastPathComponent) == ["B Built", "D Built"])
        #expect(names() == "B Built")
        for _ in 0..<5 { library.handle(.right) }
        #expect(names() == "D Built")

        // the search narrows the grid, the list and their navigation (every word, in any field), not Console Mode
        library.search = "built d"
        #expect(library.navigableGames.map(\.folder.lastPathComponent) == ["B Built", "D Built"])
        library.handle(.menu)
        #expect(library.shownGames.map(\.folder.lastPathComponent) == ["D Built"])
        #expect(library.navigableGames.map(\.folder.lastPathComponent) == ["D Built"])
        library.search = "0100000000010000"
        #expect(library.shownGames.map(\.folder.lastPathComponent) == ["B Built", "D Built"])
        library.search = "nothing"
        #expect(library.shownGames.isEmpty)
    }

    @Test func consoleModeStartsAtTheGamePlayedLast() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-played-\(UUID().uuidString)")
        let now = Date.now
        for (folder, played) in [
            ("A Never", nil), ("B Earlier", now.addingTimeInterval(-86_400)), ("C Never", nil),
            ("D Latest", now), ("E Fresh", nil),
        ] as [(String, Date?)] {
            let game = root.appending(path: folder)
            try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
            try Data([1]).write(to: game.appending(path: "\(folder).nsp"))
            guard folder != "E Fresh" else { continue }  // not extracted: not in the carousel
            let build = game.appending(path: "0100000000010000_build")
            try FileManager.default.createDirectory(
                at: build.appending(path: "extract/v0"), withIntermediateDirectories: true)
            if let played {
                let mark = build.appending(path: "run/last_played")
                try FileManager.default.createDirectory(
                    at: mark.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: mark)
                try FileManager.default.setAttributes(
                    [.modificationDate: played], ofItemAtPath: mark.path)
            }
        }
        let library = library()
        library.root = root
        library.selection = library.games.first { $0.name == "A Never" }?.id

        // the grid keeps name order; the carousel puts the latest play first, the never played after by name
        #expect(library.navigableGames.first?.name == "A Never")
        library.consoleMode = true
        #expect(
            library.navigableGames.map(\.name) == ["D Latest", "B Earlier", "A Never", "C Never"])
        #expect(library.selectedGame?.name == "D Latest")
    }

    @Test func keepThisBuildWritesAndRemovesTheKeepFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-keep-\(UUID().uuidString)")
        let build = root.appending(path: "Game/0100000000010000_build")
        try FileManager.default.createDirectory(
            at: build.appending(path: "extract/v0"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: build.appending(path: "tools"), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: build.appending(path: "start_mac.sh").path, contents: nil)
        FileManager.default.createFile(
            atPath: build.appending(path: "tools/dmhost").path, contents: nil,
            attributes: [.posixPermissions: 0o755])
        let library = library()
        library.root = root
        let keep = build.appending(path: "keep").path

        library.setKept(true, try #require(library.games.first))
        #expect(FileManager.default.fileExists(atPath: keep))
        #expect(library.games.first?.isKept == true)

        library.setKept(false, try #require(library.games.first))
        #expect(!FileManager.default.fileExists(atPath: keep))
        #expect(library.games.first?.isKept == false)
        #expect(library.problem == nil)
    }

    @Test func aKeptBuildRefusesTheBuildsThatRewriteIt() throws {
        let library = library()
        var game = job("Kept", .succeeded).game
        game.isKept = true
        library.buildIPA(game)
        #expect(library.problem == Library.keptBuildProblem)
        #expect(library.jobs.isEmpty)
        library.problem = nil
        library.makeMacApp(game)
        #expect(library.problem == Library.keptBuildProblem)
        #expect(library.jobs.isEmpty)
    }

    @Test func installQuitsOnlyOnceNothingRuns() async {
        let library = library()
        var quits = 0
        library.terminate = { quits += 1 }
        let game = job("Playing", .running)
        library.jobs[game.game.id] = game

        library.requestQuitWhenIdle(true)
        #expect(quits == 0)  // a game is running
        game.showScreenshot(["output"], status: .succeeded)
        library.finished(game)
        #expect(quits == 1)

        // cancelled install: nothing quits after that
        library.requestQuitWhenIdle(false)
        await library.inFlight {}
        #expect(quits == 1)

        // file work in flight holds the quit back until it ends
        library.requestQuitWhenIdle(false)
        await library.inFlight {
            library.requestQuitWhenIdle(true)
            #expect(quits == 1)
        }
        #expect(quits == 2)
    }

    @Test func theOtherMetalFailureSuggestsTheSetting() {
        let library = library()
        let job = job("Wonder", .failed(1))
        job.showScreenshot(
            [
                "[RED] this Mac's Metal compiler is not the one the shaders were tested with (dm/gfx/tools/dmsh_chain.lock): …"
            ], status: .failed(1))

        library.finished(job)
        #expect(library.problem?.contains("Allow a Metal compiler") == true)

        library.problem = nil
        library.allowOtherMetal = true
        library.finished(job)
        #expect(library.problem == nil)  // already on: the log says the rest
    }

    @Test func menuTogglesConsoleModeAndBackLeavesIt() {
        let library = library()
        library.handle(.menu)
        #expect(library.consoleMode)
        library.handle(.back)
        #expect(!library.consoleMode)
        library.handle(.confirm)  // no games: nothing to start
        #expect(library.jobs.isEmpty)
    }

    @Test func theLogStateIsRemembered() {
        let defaults = defaults()
        let first = Library(defaults: defaults, isScreenshot: true)
        #expect(!first.showsLog && first.logHeight == 240 && first.viewStyle == .grid)  // defaults
        first.showsLog = true
        first.showsLog = false
        first.logHeight = 333
        first.viewStyle = .list

        let next = Library(defaults: defaults, isScreenshot: true)
        #expect(!next.showsLog && next.logHeight == 333 && next.viewStyle == .list)
    }

    @Test func theLogStaysShownForSomeoneWhoAlreadyHadIt() {
        let defaults = defaults()
        defaults.set("/games", forKey: Library.Keys.root)  // chose a folder before the default changed
        #expect(Library(defaults: defaults, isScreenshot: true).showsLog)
    }

    @Test func downOpensConsoleModesDetails() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-details-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["A", "B"] {
            let extract = root.appending(path: "\(folder)/0100000000010000_build/extract/v0")
            try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)
            try Data([1]).write(to: root.appending(path: "\(folder)/\(folder).nsp"))
        }
        let library = library()
        library.root = root
        library.handle(.menu)
        let first = library.selection

        library.handle(.down)
        #expect(library.showsDetails && library.detailsFocus == .text)
        // up and down go to the panel, which scrolls (or closes, up at the top)
        let serial = library.detailsScroll.serial
        library.handle(.up)
        #expect(library.detailsScroll == .init(down: false, serial: serial + 1))
        #expect(library.showsDetails)
        // left and right still choose the game while the text has the focus
        library.handle(.right)
        #expect(library.selection != first && library.showsDetails)
        // no screenshots: A doesn't open the viewer
        library.detailsFocus = .screenshots
        library.handle(.confirm)
        #expect(!library.viewingShot)
        // B closes the details, not Console Mode, and the focus starts over
        library.handle(.back)
        #expect(!library.showsDetails && library.consoleMode && library.detailsFocus == .text)
    }

    @Test func opensInTheModeItWasLeftIn() {
        let defaults = defaults()
        defaults.set("/games", forKey: Library.Keys.root)
        Library(defaults: defaults, isScreenshot: true).consoleMode = true
        #expect(Library(defaults: defaults, isScreenshot: true).consoleMode)
        Library(defaults: defaults, isScreenshot: true).consoleMode = false
        #expect(!Library(defaults: defaults, isScreenshot: true).consoleMode)

        // no games folder yet: the window that asks for one, not an empty Console Mode
        defaults.removeObject(forKey: Library.Keys.root)
        defaults.set(true, forKey: Library.Keys.consoleMode)
        #expect(!Library(defaults: defaults, isScreenshot: true).consoleMode)
    }

    @Test func controllersBecomePlayers() {
        #expect(Gamepad.numbers(count: 3, merged: false, keyboardOwnPlayer: false) == [1, 2, 3])
        #expect(Gamepad.numbers(count: 2, merged: false, keyboardOwnPlayer: true) == [2, 3])
        #expect(Gamepad.numbers(count: 2, merged: true, keyboardOwnPlayer: true) == [1, 1])
        // nxnative has 8 players: a ninth controller isn't used
        #expect(
            Gamepad.numbers(count: 9, merged: false, keyboardOwnPlayer: false).last == .some(nil))
        #expect(
            Gamepad.numbers(count: 8, merged: false, keyboardOwnPlayer: true).last == .some(nil))

        // each said either way, so the shell's environment can't decide
        #expect(
            Library.controllerEnvironment(.each) == ["DM_PAD_MERGE": "0", "DM_KBD_PLAYER": nil])
        #expect(
            Library.controllerEnvironment(.keyboardOwn) == [
                "DM_PAD_MERGE": "0", "DM_KBD_PLAYER": "own",
            ])
        #expect(
            Library.controllerEnvironment(.merged) == ["DM_PAD_MERGE": "1", "DM_KBD_PLAYER": nil])

        let defaults = defaults()
        let first = Library(defaults: defaults, isScreenshot: true)
        first.controllerPlayers = .keyboardOwn
        #expect(first.gamepad.keyboardOwnPlayer && !first.gamepad.merged)
        let next = Library(defaults: defaults, isScreenshot: true)
        #expect(next.controllerPlayers == .keyboardOwn && next.gamepad.keyboardOwnPlayer)
    }

    @Test func cloudSavesBecomeTheHostsSwitch() {
        #expect(Library.cloudSaveTarget("") == "0")  // off is said, not left to the shell's environment
        #expect(Library.cloudSaveTarget("icloud") == "icloud")
        #expect(Library.cloudSaveTarget("~/Saves") == NSHomeDirectory() + "/Saves")
        #expect(Library.cloudSaveTarget("/Volumes/Cloud/Saves") == "/Volumes/Cloud/Saves")

        let defaults = defaults()
        Library(defaults: defaults, isScreenshot: true).cloudSaves = "icloud"
        #expect(Library(defaults: defaults, isScreenshot: true).cloudSaves == "icloud")
    }

    @Test func knowsTheGamesNxnativeHasAProfileFor() throws {
        let repo = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repo) }
        let games = repo.appending(path: "dm/games")
        for name in ["0100F2C0115B6000", "0100abc000000000", "__pycache__"] {
            try FileManager.default.createDirectory(
                at: games.appending(path: name), withIntermediateDirectories: true)
        }
        for name in ["0100F2C0115B6000", "0100abc000000000"] {
            try Data().write(to: games.appending(path: "\(name)/game.tsv"))
        }
        try Data().write(to: games.appending(path: "game.py"))
        #expect(Library.profiles(repo: repo.path) == ["0100F2C0115B6000", "0100ABC000000000"])
        #expect(Library.profiles(repo: repo.appending(path: "missing").path).isEmpty)
    }
}
