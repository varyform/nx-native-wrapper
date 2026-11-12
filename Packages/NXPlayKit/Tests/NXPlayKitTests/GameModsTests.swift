import Foundation
import Testing

@testable import NXPlayKit

/// A game's file mods, layered over its RomFS through nxnative's DM_ROMFS_OVERLAY (issue #27).
@Suite struct GameModsTests {
    let root: URL
    let mods: URL
    static let id = "0100F2C0115B6000"

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-mods-\(UUID().uuidString)", directoryHint: .isDirectory)
        mods = root.appending(path: "Game/Mods", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
    }

    /// A mod with these files, under `layout` inside its folder ("" for `romfs` at the top).
    @discardableResult
    func mod(_ name: String, _ files: [String], layout: String = "") throws -> URL {
        let romfs = mods.appending(path: name).appending(path: layout).appending(path: "romfs")
        for file in files {
            let url = romfs.appending(path: file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.utf8).write(to: url)
        }
        return romfs
    }

    var game: Game {
        Game(
            folder: root.appending(path: "Game"), name: "Game", titleID: Self.id, version: nil, languages: [],
            iconURL: nil, buildFolder: nil, ipaURL: nil, xcodeBuildFolder: nil, hasPackages: true, state: .ready)
    }

    @Test func newModsAreOnInNameOrderAfterTheSavedOnes() throws {
        try mod("b", ["x"])
        try mod("a", ["x"])
        try mod("c", ["x"])
        #expect(GameMods.scan(mods, titleID: Self.id).map(\.name) == ["a", "b", "c"])

        try Data("# comment\noff\tc\non\tb\non\tgone\n".utf8).write(to: mods.appending(path: "order.txt"))
        let scanned = GameMods.scan(mods, titleID: Self.id)
        #expect(scanned.map(\.name) == ["c", "b", "a"])  // a folder the file doesn't list yet comes last
        #expect(scanned.map(\.isOn) == [false, true, true])

        // the last mod turned off stays off
        var off = scanned
        for index in off.indices { off[index].isOn = false }
        try GameMods.save(off, in: mods)
        #expect(GameMods.scan(mods, titleID: Self.id).allSatisfy { !$0.isOn })
    }

    @Test func findsTheRomFSInTheLayoutsModsComeIn() throws {
        let top = try mod("Top", ["a"])
        let atmosphere = try mod("Atmosphere", ["a"], layout: "atmosphere/contents/\(Self.id.lowercased())")
        let contents = try mod("Contents", ["a"], layout: "contents/\(Self.id)")
        let bare = try mod("Bare", ["a"], layout: Self.id)
        let other = try mod("Other", ["a"], layout: "atmosphere/contents/0100000000010000")
        try mod("Both", ["a"], layout: "atmosphere/contents/0100000000010000")
        let both = try mod("Both", ["a"], layout: "atmosphere/contents/\(Self.id)")
        try FileManager.default.createDirectory(
            at: mods.appending(path: "Code/atmosphere/contents/\(Self.id)/exefs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: mods.appending(path: "Atmosphere/atmosphere/contents/\(Self.id)/exefs"),
            withIntermediateDirectories: true)

        let found = Dictionary(uniqueKeysWithValues: GameMods.scan(mods, titleID: Self.id).map { ($0.name, $0) })
        for (name, romfs) in [("Top", top), ("Atmosphere", atmosphere), ("Contents", contents), ("Bare", bare)] {
            #expect(found[name]?.romfs?.standardizedFileURL == romfs.standardizedFileURL, "\(name)")
            #expect(found[name]?.otherTitle == nil)
        }
        #expect(found["Both"]?.romfs?.standardizedFileURL == both.standardizedFileURL)  // this game's first
        #expect(found["Other"]?.romfs?.standardizedFileURL == other.standardizedFileURL)
        #expect(found["Other"]?.otherTitle == "0100000000010000")
        #expect(found["Atmosphere"]?.hasExeFS == true && found["Atmosphere"]?.problem == nil)
        #expect(found["Code"]?.problem == .noRomFS && found["Code"]?.hasExeFS == true)
    }

    @Test func theOverlayListsTheModsThatLoadInOrder() throws {
        let a = try mod("a", ["x"]), c = try mod("c", ["x"])
        try mod("b", ["x"])
        try mod("d:e", ["x"])
        try Data("on\tc\non\ta\noff\tb\n".utf8).write(to: mods.appending(path: "order.txt"))
        let scanned = GameMods.scan(mods, titleID: Self.id)
        #expect(scanned.first { $0.name == "d:e" }?.problem == .colonInPath)
        let overlay = GameMods.overlay(scanned)
        #expect(overlay.value == [c, a].map(\.path).joined(separator: ":"))
        #expect(overlay.loaded.map(\.name) == ["c", "a"] && overlay.tooLong.isEmpty)

        // past nxnative's 4,095 bytes the rest is left out whole, not cut in the middle of a path
        let long = (0..<60).map { i in
            GameMod(
                name: "\(i)", folder: root, romfs: URL(filePath: "/" + String(repeating: "m", count: 99)), isOn: true,
                hasExeFS: false, otherTitle: nil)
        }
        let cut = GameMods.overlay(long)
        #expect(cut.value.utf8.count <= 4095 && cut.loaded.count == 40 && cut.tooLong.count == 20)
    }

    @Test func countsTheFilesAnEarlierModCovers() throws {
        try mod("first", ["Model/link.bfres", "Text/msg.sarc"])
        try mod("second", ["Model/link.bfres", "Model/new.bfres"])
        try mod("off", ["Text/msg.sarc"])
        try Data("on\tfirst\noff\toff\non\tsecond\n".utf8).write(to: mods.appending(path: "order.txt"))
        let files = GameMods.files(GameMods.scan(mods, titleID: Self.id))
        #expect(files["first"] == GameModFiles(count: 2, covered: [:]))
        #expect(files["second"] == GameModFiles(count: 2, covered: ["first": 1]))
        #expect(files["off"] == GameModFiles(count: 1, covered: ["first": 1]))
    }

    @MainActor @Test func aPlayPassesTheModsAndSaysThem() throws {
        let suite = "nxplay-mods-\(UUID().uuidString)"
        let library = Library(defaults: UserDefaults(suiteName: suite)!, isScreenshot: true)
        let game = game
        try FileManager.default.removeItem(at: mods)
        #expect(library.modsEnvironment(for: game).isEmpty)  // no Mods folder: nothing set

        try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
        #expect(library.modsEnvironment(for: game) == ["DM_ROMFS_OVERLAY": "", "NXPLAY_MODS": "none"])
        let a = try mod("a", ["x"])
        try FileManager.default.createDirectory(at: mods.appending(path: "empty"), withIntermediateDirectories: true)
        #expect(
            library.modsEnvironment(for: game)
                == ["DM_ROMFS_OVERLAY": a.path, "NXPLAY_MODS": "a, empty (left out: no romfs folder)"])
    }

    @Test func seesAModAddedButNotTheOrderFile() async throws {
        // a game folder that never had a Mods folder: it is made while watched
        let game = root.appending(path: "Watched", directoryHint: .isDirectory)
        let mods = game.appending(path: "Mods", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let watch = { FolderWatch.changes(in: mods, root: game, ignoring: ["order.txt"]) }
        let build = game.appending(path: "01009320084A4000_build/run")
        #expect(
            try await Self.first(watch()) {
                try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            } == false)
        #expect(
            try await Self.first(watch()) {
                try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
            } == true)
        #expect(try await Self.first(watch()) { try GameMods.save([], in: mods) } == false)
        #expect(
            try await Self.first(watch()) {
                try FileManager.default.createDirectory(
                    at: mods.appending(path: "new/romfs"), withIntermediateDirectories: true)
            } == true)
    }

    /// Whether the stream says something changed within two seconds of the step.
    static func first(_ changes: AsyncStream<Void>, after step: @Sendable () throws -> Void) async throws -> Bool {
        try await Task.sleep(for: .milliseconds(300))  // FSEvents starts from now: let it start first
        try step()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in changes { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let got = await group.next() ?? false
            group.cancelAll()
            return got
        }
    }

    @MainActor @Test func movingAndTurningOffSaveTheOrder() async throws {
        let suite = "nxplay-mods-\(UUID().uuidString)"
        let library = Library(defaults: UserDefaults(suiteName: suite)!, isScreenshot: true)
        let game = game
        for name in ["a", "b", "c"] { try mod(name, ["x"]) }
        await library.loadMods(for: game)
        library.moveMod("c", before: "a", for: game)
        library.moveMod("a", before: nil, for: game)
        library.setMod("b", on: false, for: game)
        #expect(library.gameMods[game.id]?.map(\.name) == ["c", "b", "a"])
        let saved = GameMods.scan(mods, titleID: Self.id)
        #expect(saved.map(\.name) == ["c", "b", "a"] && saved.map(\.isOn) == [true, false, true])
    }
}
