import Foundation
import Testing

@testable import NXPlayKit

/// Play's choice between NX Play's save and the Mac app's own (issue #8).
@MainActor @Suite final class AppSaveTests {
    let base: URL
    let home: URL
    static let id = "0100000000FA0000"
    private var suites: [String] = []

    init() {
        base = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-appsave-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = base.appending(path: "home", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
        suites.forEach(removeTestDefaults)
    }

    private func write(_ url: URL, _ data: Data = Data([1]), modified: Date = .now) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private var support: URL {
        home.appending(path: "Library/Application Support/nxnative/\(Self.id)")
    }

    /// A built game with a Mac app; `nxplay`/`app`: when each save was last written, nil for none.
    private func game(nxplay: Date?, app: Date?, env: String? = nil) throws -> Game {
        let folder = base.appending(path: "games/Fake", directoryHint: .isDirectory)
        try write(folder.appending(path: "Fake [\(Self.id)][v0].nsp"))
        let host = folder.appending(path: "Fake.app/Contents/MacOS/dmhost")
        try write(host)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)
        try write(folder.appending(path: "\(Self.id)_build/start_mac.sh"))
        try write(folder.appending(path: "\(Self.id)_build/tools/dmhost"))
        if let nxplay { try write(folder.appending(path: "\(Self.id)_build/run/save/a.bin"), modified: nxplay) }
        if let app { try write(support.appending(path: "save/a.bin"), Data([2]), modified: app) }
        if let env { try write(support.appending(path: "env.txt"), Data(env.utf8)) }
        let game = try #require(GameScanner.game(at: folder))
        #expect(game.macAppURL != nil)
        return game
    }

    @Test func asksWhenTheAppsOwnSaveDiffers() throws {
        let old = Date.now.addingTimeInterval(-86400)
        let save = try #require(AppSave(game: try game(nxplay: old, app: .now), home: home))
        #expect(save.differs)
        #expect(save.appIsNewer)
        #expect(save.usesApp(.app) && save.usesApp(.newer) && !save.usesApp(.nxplay))
    }

    @Test func theDeviceSaveCountsToo() throws {
        let now = Date.now
        let game = try game(nxplay: now, app: now)
        #expect(AppSave(game: game, home: home)?.differs == false)
        try write(support.appending(path: "save_device/d.bin"))
        #expect(AppSave(game: game, home: home)?.differs == true)
    }

    @Test func nothingToChooseWithoutTheAppsOwnSave() throws {
        #expect(AppSave(game: try game(nxplay: .now, app: nil), home: home) == nil)
    }

    @Test func nothingToChooseWhenTheAppSharesNXPlaysSave() throws {
        let shared = try game(nxplay: .now, app: .now, env: "\(AppSave.mark)\nDM_SAVE=/x\n")
        #expect(AppSave(game: shared, home: home) == nil)
    }

    @Test func nothingToChooseWhenThePlayerSetTheAppsSave() throws {
        let own = try game(nxplay: .now, app: .now, env: "DM_SAVE=/elsewhere\n")
        #expect(AppSave(game: own, home: home) == nil)
    }

    @Test func anEmptyNXPlaySaveMakesTheAppsNewer() throws {
        let save = try #require(AppSave(game: try game(nxplay: nil, app: .now), home: home))
        #expect(save.differs && save.appIsNewer)
    }

    private func library() -> Library {
        let suite = testDefaultsName()
        suites.append(suite)
        return Library(defaults: UserDefaults(suiteName: suite)!, isScreenshot: true)
    }

    @Test func aKeptChoiceIsRememberedAndForgotten() throws {
        let game = try game(nxplay: .now, app: .now)
        let library = library()
        library.saveChoices[Self.id] = .app
        #expect(library.saveChoice(for: game) == .app)
        library.forgetSaveChoice(for: game)
        #expect(library.saveChoice(for: game) == nil)
    }

    @Test func theControllerMovesThroughTheRowsAndCancels() throws {
        let game = try game(nxplay: .distantPast, app: .now)
        let library = library()
        library.saveQuestion = SaveQuestion(
            game: game, appSave: try #require(AppSave(game: game, home: home)))
        #expect(library.saveQuestion?.focus == .newer)
        library.handle(.down)
        library.handle(.confirm)
        #expect(library.saveQuestion?.remember == true)
        library.handle(.up)
        library.handle(.up)
        #expect(library.saveQuestion?.focus == .app)
        library.handle(.back)
        #expect(library.saveQuestion == nil)
        #expect(library.saveChoice(for: game) == nil)
    }
}
