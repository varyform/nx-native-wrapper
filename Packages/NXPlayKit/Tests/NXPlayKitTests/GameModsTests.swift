import Foundation
import Testing

@testable import NXPlayKit

@Suite struct GameModsTests {
    /// <root>/game/Mods/<mod>/romfs/<files…>.
    static func gameFolder(withMods mods: [String: [String]], in root: URL) throws -> URL {
        let fm = FileManager.default
        let game = root.appending(path: "game")
        for (mod, files) in mods {
            for file in files {
                let path = game.appending(path: "Mods/\(mod)/romfs/\(file)")
                try fm.createDirectory(
                    at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: path.path, contents: Data())
            }
        }
        return game
    }

    static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "game-mods-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func everyModIsOnAlphabeticallyUntilAnOrderFileSaysOtherwise() throws {
        let root = try Self.root()
        let game = try Self.gameFolder(withMods: ["B": ["a"], "A": ["b"]], in: root)
        let mods = try #require(GameMods(for: game))
        #expect(mods.enabled.map(\.name) == ["A", "B"])
        #expect(mods.overlayArgument == mods.enabled.map(\.root.path).joined(separator: ":"))
    }

    @Test func theOrderFileListsTheEnabledInPriorityOrder() throws {
        let root = try Self.root()
        let game = try Self.gameFolder(withMods: ["A": ["x"], "B": ["x"], "C": ["y"]], in: root)
        try "B\n".write(
            to: game.appending(path: "Mods/order.txt"), atomically: true, encoding: .utf8)
        let mods = try #require(GameMods(for: game))
        #expect(mods.enabled.map(\.name) == ["B"])
        #expect(mods.overlayArgument == game.appending(path: "Mods/B/romfs").path)
    }

    @Test func twoModsCanChangeTheSameFileTheFirstWins() throws {
        let root = try Self.root()
        let game = try Self.gameFolder(
            withMods: ["first": ["shared/file.bin", "only-1"], "second": ["shared/file.bin", "only-2"]],
            in: root)
        try "first\nsecond\n".write(
            to: game.appending(path: "Mods/order.txt"), atomically: true, encoding: .utf8)
        let mods = try #require(GameMods(for: game, countFiles: true))
        let second = mods.enabled.last!
        #expect(second.shadowed == 1 && second.shadowedBy == "first")
        #expect(mods.overlayArgument?.contains("first/romfs:") == true)
    }

    @MainActor @Test func togglingAndMovingWritesTheOrderFile() throws {
        let root = try Self.root()
        let game = try Self.gameFolder(withMods: ["A": ["x"], "B": ["y"], "C": ["z"]], in: root)
        let suite = testDefaultsName()
        defer { removeTestDefaults(suite) }
        let library = Library(defaults: UserDefaults(suiteName: suite)!, isScreenshot: true)
        let a = GameMod(name: "A", root: game.appending(path: "Mods/A/romfs"), enabled: true)
        let c = GameMod(name: "C", root: game.appending(path: "Mods/C/romfs"), enabled: true)
        library.setMod(a, enabled: false, for: Self.game(in: game))
        library.moveMod(c, up: true, for: Self.game(in: game))
        let order = try String(
            contentsOf: game.appending(path: "Mods/order.txt"), encoding: .utf8)
        #expect(order.split(separator: "\n").map(String.init) == ["C", "B"])
    }

    static func game(in folder: URL) -> Game {
        Game(
            folder: folder, name: "G", titleID: nil, version: nil, languages: [], iconURL: nil,
            buildFolder: nil, ipaURL: nil, xcodeBuildFolder: nil, hasPackages: true, state: .ready)
    }
}
