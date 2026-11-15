import Foundation
import Testing

@testable import NXPlayKit

@Suite struct GameRemovalTests {
    let root: URL
    let home: URL
    static let id = "0100000000FA0000"

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-remove-\(UUID().uuidString)", directoryHint: .isDirectory)
        root = base.appending(path: "games", directoryHint: .isDirectory)
        home = base.appending(path: "home", directoryHint: .isDirectory)
        let id = Self.id
        for path in [
            "Fake/Fake [\(id)][v0].nsp", "Fake/Fake.ipa", "Fake/Fake.app/Contents/MacOS/dmhost",
            "Fake/Fake.app.key", "Fake/\(id)_survey/survey.md",
            "Fake/\(id)_build/extract/v0/icon.jpg", "Fake/\(id)_build/start_mac.sh",
            "Fake/\(id)_build/run/save/progress.bin", "Fake/\(id)_build/run/save_device/sys.bin",
            "Fake/\(id)_build/run/last_played", "Fake/\(id)_build/run/temp/cache.bin",
            "Fake/\(id)_build/cheats/0123456789ABCDEF.txt",
            "Fake/\(id)_build/cheats/0123456789ABCDEF.enabled",
            "Fake/Notes.txt",
        ] {
            try write(root.appending(path: path))
        }
        try write(home.appending(path: "Library/Application Support/nxnative/\(id)/save/app.bin"))
    }

    private func write(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
    }

    private var game: Game { GameScanner.game(at: root.appending(path: "Fake"))! }
    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path)
    }

    @Test func keepsTheSavesAndWhatIsntOurs() {
        let removal = GameRemoval(game: game, removesSaves: false, home: home)
        #expect(removal.others.map(\.lastPathComponent) == ["Notes.txt"])
        #expect(removal.appData != nil)
        #expect(removal.perform().isEmpty)

        let build = "Fake/\(Self.id)_build"
        for kept in [
            "Fake/Notes.txt", "\(build)/run/save/progress.bin", "\(build)/run/save_device/sys.bin",
            "\(build)/run/last_played", "\(build)/cheats/0123456789ABCDEF.txt",
            "\(build)/cheats/0123456789ABCDEF.enabled",
        ] {
            #expect(exists(kept), "\(kept)")
        }
        for gone in [
            "Fake/Fake [\(Self.id)][v0].nsp", "Fake/Fake.ipa", "Fake/Fake.app", "Fake/Fake.app.key",
            "Fake/\(Self.id)_survey", "\(build)/extract", "\(build)/start_mac.sh",
            "\(build)/run/temp",
        ] {
            #expect(!exists(gone), "\(gone)")
        }
        // the Mac app's save stays too
        #expect(FileManager.default.fileExists(atPath: removal.appData!.path))
        // the saves and cheats left behind aren't a game in the library
        #expect(GameScanner.scan(roots: [root]).isEmpty)
    }

    @Test func aGameBackWithItsFilesFindsItsSaves() throws {
        GameRemoval(game: game, removesSaves: false, home: home).perform()
        try write(root.appending(path: "Fake/Fake [\(Self.id)][v0].nsp"))
        let back = try #require(GameScanner.scan(roots: [root]).first)
        #expect(back.titleID == Self.id && back.state == .notExtracted)
        #expect(exists("Fake/\(Self.id)_build/run/save/progress.bin"))
        // its cheats wait for it too
        #expect(exists("Fake/\(Self.id)_build/cheats/0123456789ABCDEF.txt"))
    }

    @Test func removingTheSavesTooEmptiesTheFolder() throws {
        try FileManager.default.removeItem(at: root.appending(path: "Fake/Notes.txt"))
        let removal = GameRemoval(game: game, removesSaves: true, home: home)
        #expect(removal.perform().isEmpty)
        #expect(!exists("Fake"))  // nothing else was in it
        #expect(!FileManager.default.fileExists(atPath: removal.appData!.path))
    }

    /// A build folder linked from another volume (issue #32): removing the saves too empties it, not just the link.
    @Test func aLinkedBuildGoesWithWhatIsInIt() throws {
        let build = root.appending(path: "Fake/\(Self.id)_build")
        let elsewhere = root.deletingLastPathComponent().appending(path: "image/\(Self.id)_build")
        try FileManager.default.createDirectory(
            at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: build, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: build, withDestinationURL: elsewhere)

        let removal = GameRemoval(game: game, removesSaves: true, home: home)
        #expect(removal.size() > 1)  // what's in it, not the link's few bytes
        #expect(removal.perform().isEmpty)
        #expect(!exists("Fake/\(Self.id)_build"))
        let left = try FileManager.default.contentsOfDirectory(atPath: elsewhere.path)
        #expect(left == [], "\(left)")
    }

    @MainActor @Test func confirmationPhrasesHaveNoApostrophes() {
        #expect(GameRemoval.phrases.count == 3)
        #expect(GameRemoval.phrases.allSatisfy { !$0.contains("'") && !$0.contains("\u{2019}") })
        // typed any which way, as Free Up Space's
        #expect(
            Cleanup.normalized("yes remove the game") == Cleanup.normalized("Yes, remove the game"))
    }
}
