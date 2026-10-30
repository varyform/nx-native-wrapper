import Foundation
import Testing

@testable import NXPlayKit

/// nxnative's settings list, the global values and a game's own in nxnative's store (docs/frontends.md).
@MainActor @Suite final class GameSettingsTests {
    private var suites: [String] = []
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        suites.forEach(removeTestDefaults)
        try? FileManager.default.removeItem(at: root)
    }

    /// Animal Well's list as settings.py writes it, shortened, with a row of a kind from a later schema and a
    /// malformed one.
    static let json = """
        {"schema": 1, "game": "010020D01AD24000", "settings": [
         {"env": "DM_OPMODE", "kind": "choice", "section": "Game", "label": "Console mode", "note": "", "default": "1",
          "options": [["1", "Docked"], ["0", "Handheld"]], "level": "basic"},
         {"env": "DM_LANG", "kind": "choice", "section": "Game", "label": "Game language", "note": "", "default": "en-US",
          "options": [["en-US", "American English"], ["ja", "Japanese"]], "level": "basic"},
         {"env": "DM_FULLSCREEN", "kind": "choice", "section": "Game", "label": "Display mode", "note": "", "default": "0",
          "options": [["0", "Window"], ["1", "Fullscreen"]], "level": "basic"},
         {"env": "DM_RUMBLE", "kind": "toggle", "section": "Controls", "label": "Game rumble", "note": "", "default": "1",
          "on": "1", "off": "0", "level": "basic"},
         {"env": "DM_RUMBLE_GAIN", "kind": "range", "section": "Controls", "label": "Rumble strength", "note": "",
          "default": "1.0", "min": 0, "max": 3, "step": 0.1, "needs": "DM_RUMBLE=1"},
         {"env": "DM_FUTURE", "kind": "colour", "section": "Game", "label": "Later", "note": "", "default": "x"},
         {"env": "DM_BROKEN", "kind": "range", "section": "Game", "label": "Broken", "note": "", "default": "1",
          "min": true, "max": 2, "step": 1},
         {"env": "DM_METAL_HUD", "kind": "toggle", "section": "Performance", "label": "Performance HUD",
          "note": "Apple's overlay.", "default": "0", "on": "1", "off": "0"}
        ]}
        """

    private func list() throws -> LauncherSettings {
        try #require(LauncherSettings.parse(Data(Self.json.utf8)))
    }

    private func store() -> UserDefaults {
        let suite = testDefaultsName()
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    /// A library with one built game, its list read; the game's choices in a test store.
    private func library() throws -> (Library, Game, UserDefaults) {
        let game = root.appending(path: "ANIMAL WELL", directoryHint: .isDirectory)
        let build = game.appending(path: "010020D01AD24000_build", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: build.appending(path: "tools"), withIntermediateDirectories: true)
        try Data([1]).write(to: game.appending(path: "ANIMAL WELL.nsp"))
        try Data("#!/bin/sh\n".utf8).write(to: build.appending(path: GameScanner.launcherName))
        FileManager.default.createFile(
            atPath: build.appending(path: "tools/dmhost").path, contents: Data(),
            attributes: [.posixPermissions: 0o755])
        try Data(Self.json.utf8).write(to: build.appending(path: LauncherSettings.fileName))

        let library = Library(defaults: store(), isScreenshot: true)
        let choices = store()
        library.choicesStore = { _ in choices }
        library.root = root
        let found = try #require(library.games.first)
        #expect(library.settingsLists[found.id] != nil)
        return (library, found, choices)
    }

    @Test func readsTheListAndSkipsWhatItCannotDraw() throws {
        let settings = try list()
        #expect(settings.settings.map(\.env).contains("DM_FUTURE") == false)
        #expect(settings.settings.map(\.env).contains("DM_BROKEN") == false)  // a boolean is no number
        let gain = try #require(settings["DM_RUMBLE_GAIN"])
        #expect(gain.kind == .range(min: 0, max: 3, step: 0.1))
        #expect(gain.needs == .init(env: "DM_RUMBLE", value: "1"))
        #expect(gain.accepts("2.5") && !gain.accepts("3.5") && gain.same("1", "1.0"))
        #expect(settings["DM_OPMODE"]?.isBasic == true)
    }

    @Test func aGamesOwnValueGoesToNxnativesStoreAndWinsOverTheGlobalOne() throws {
        let (library, game, store) = try library()
        let mode = try #require(library.settingsLists[game.id]?["DM_OPMODE"])
        library.setGlobal("0", for: "DM_OPMODE")
        #expect(library.value(mode, for: game) == "0" && library.own(mode, for: game) == nil)

        library.setOwn("1", mode, for: game)
        #expect(store.string(forKey: "launcher.DM_OPMODE") == "1")
        #expect(library.value(mode, for: game) == "1")
        library.setOwn("7", mode, for: game)  // not offered: no value of its own
        #expect(store.object(forKey: "launcher.DM_OPMODE") == nil)
        // one a later build stopped offering is ignored, and left for the Mac app's window to replace
        store.set("9", forKey: "launcher.DM_OPMODE")
        #expect(library.value(mode, for: game) == "0" && library.own(mode, for: game) == nil)
        #expect(store.string(forKey: "launcher.DM_OPMODE") == "9")
    }

    @Test func aPlayPassesWhatDiffersFromTheTestedDefaults() throws {
        let (library, game, store) = try library()
        let list = try #require(library.settingsLists[game.id])
        library.setGlobal("ja", for: "DM_LANG")
        library.setGlobal("1", for: "DM_METAL_HUD")
        library.setGlobal("1", for: "DM_FULLSCREEN")
        store.set("0", forKey: "launcher.DM_FULLSCREEN")  // the game's own: in a window
        store.set("2.5", forKey: "launcher.DM_RUMBLE_GAIN")
        store.set("1", forKey: "launcher.DM_NOT_LISTED")
        #expect(
            library.playEnvironment(for: game) == [
                "DM_LANG": "ja", "DM_METAL_HUD": "1", "DM_RUMBLE_GAIN": "2.5",
            ])

        library.clearOwn(list, for: game)
        #expect(library.playEnvironment(for: game)["DM_FULLSCREEN"] == "1")
        #expect(store.string(forKey: "launcher.DM_NOT_LISTED") == "1")  // only the list's keys go
    }

    @Test func theLanguagePlaysItsRegionalTwin() throws {
        let (library, found, _) = try library()
        let lang = try #require(library.settingsLists[found.id]?["DM_LANG"])
        // the languages its control data lists (the test's build has none extracted)
        let game = Game(
            folder: found.folder, name: found.name, titleID: found.titleID, version: nil,
            languages: ["en-US", "ja"], iconURL: nil, buildFolder: found.buildFolder, ipaURL: nil,
            xcodeBuildFolder: nil, hasPackages: true, state: .ready)
        library.setGlobal("en-GB", for: "DM_LANG")  // the game has American English
        #expect(library.globalValue(lang, for: game) == "en-US")
        library.setGlobal("fr", for: "DM_LANG")  // and no French at all: its default, nothing passed
        #expect(library.globalValue(lang, for: game) == nil)
        #expect(library.value(lang, for: game) == "en-US")
        #expect(library.playEnvironment(for: game)["DM_LANG"] == nil)
    }

    @Test func settingsGamesListsEverySettingAndEveryLanguage() throws {
        let (library, _, _) = try library()
        let rows = library.globalSettings
        #expect(rows.map(\.env).contains("DM_RUMBLE_GAIN"))
        guard case .choice(let languages) = rows.first(where: { $0.env == "DM_LANG" })?.kind else {
            Issue.record("no language row")
            return
        }
        #expect(languages.count == GameLanguage.all.count)
        #expect(library.sharedDefault(for: "DM_OPMODE") == "1")
    }

    @Test func theOldPlayingSettingsBecomeGlobalValues() {
        let defaults = store()
        defaults.set("ja", forKey: Library.Keys.language)
        defaults.set(true, forKey: Library.Keys.metalHUD)
        #expect(
            Library.loadGlobalChoices(defaults) == ["DM_LANG": "ja", "DM_METAL_HUD": "1"])
        defaults.set(["DM_OPMODE": "0"], forKey: Library.Keys.globalSettings)
        #expect(Library.loadGlobalChoices(defaults) == ["DM_OPMODE": "0"])
    }

    @Test func theStoreIsTheMacAppsDomain() {
        #expect(SavedChoices.domain(titleID: "010020D01AD24000") == "org.nxnative.010020d01ad24000")
    }
}
