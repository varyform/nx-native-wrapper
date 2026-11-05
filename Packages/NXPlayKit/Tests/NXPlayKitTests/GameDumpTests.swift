import Foundation
import Testing

@testable import NXPlayKit

/// Switch 2 games: a dump of the game's files in place of NSPs, as nxnative builds them.
@Suite struct GameDumpTests {
    let root: URL
    static let id = "040041E0212AE000"

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-dump-\(UUID().uuidString)", directoryHint: .isDirectory)
        try write("FastFusion/base/exefs/main.npdm", Self.npdm(programID: 0x0400_41E0_212A_E000))
        for path in [
            "FastFusion/base/exefs/main", "FastFusion/base/romfs/tracks/a.bin",
            "FastFusion/updates/262144/exefs/main", "FastFusion/updates/262144/romfs/a.bin",
            "FastFusion/Notes.txt",
        ] {
            try write(path)
        }
    }

    /// main.npdm as far as the title ID goes: the META header, and the ACI0 section its offset at 0x70 points to,
    /// with the program ID at 0x10 into it.
    static func npdm(programID: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes.replaceSubrange(0..<4, with: Array("META".utf8))
        bytes[0x70] = 0x80  // ACI0 offset
        bytes[0x74] = 0x40  // ACI0 size
        bytes.replaceSubrange(0x80..<0x84, with: Array("ACI0".utf8))
        for i in 0..<8 { bytes[0x90 + i] = UInt8(truncatingIfNeeded: programID >> (8 * UInt64(i))) }
        return Data(bytes)
    }

    private func write(_ path: String, _ data: Data = Data([1])) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @Test func aDumpIsAGameNamedByItsNPDM() throws {
        let game = try #require(GameScanner.scan(root: root).first)
        #expect(game.name == "FastFusion")
        #expect(game.titleID == Self.id)
        #expect(game.isDump && game.isSwitch2)
        #expect(game.hasPackages && game.canExtract)
        #expect(game.state == .notExtracted)
    }

    @Test func aFolderOnlyLikeADumpIsNoGame() throws {
        try write("Half/base/exefs/main.npdm", Self.npdm(programID: 1))  // no romfs
        try write("Odd/base/exefs/main.npdm", Data("not an npdm".utf8))
        try write("Odd/base/romfs/a.bin")
        let games = GameScanner.scan(root: root)
        #expect(games.map(\.name) == ["FastFusion", "Odd"])
        // a dump whose NPDM can't be read is still the game files; nxnative says what's wrong with it
        #expect(games[1].isDump && games[1].titleID == nil)
    }

    @Test func everyLayoutNxnativeBuildsIsAGame() throws {
        let npdm = Self.npdm(programID: 0x0400_0000_0000_1000)
        try write("Flat/exefs/main.npdm", npdm)
        try write("Flat/romfs/a.bin")
        try write("UpdateOnly/updates/65536/exefs/main.npdm", npdm)
        try write("UpdateOnly/updates/65536/romfs/a.bin")
        try write("RomFSInUpdate/base/exefs/main.npdm", npdm)
        try write("RomFSInUpdate/updates/65536/romfs/a.bin")
        for name in ["Flat", "UpdateOnly", "RomFSInUpdate"] {
            let game = try #require(GameScanner.game(at: root.appending(path: name)))
            #expect(game.isDump && game.titleID == "0400000000001000", "\(name)")
        }
    }

    @Test func theNewestWholeUpdateNamesAGameWithNoBase() throws {
        try write("Two/updates/131072/exefs/main.npdm", Self.npdm(programID: 0x0400_0000_0000_2000))
        try write("Two/updates/131072/romfs/a.bin")
        try write("Two/updates/65536/exefs/main.npdm", Self.npdm(programID: 0x0400_0000_0000_1000))
        try write("Two/updates/65536/romfs/a.bin")
        try write("Two/updates/999999/exefs/main.npdm", Self.npdm(programID: 0x0400_0000_0000_3000))  // no RomFS
        let game = try #require(GameScanner.game(at: root.appending(path: "Two")))
        #expect(game.titleID == "0400000000002000")
    }

    @Test func foldersThatOnlyLookLikeAnUpdateAreNoGame() throws {
        try write("Named/updates/latest/exefs/main.npdm", Self.npdm(programID: 1))
        try write("Named/updates/latest/romfs/a.bin")
        try write("NoCode/updates/65536/romfs/a.bin")
        #expect(GameScanner.game(at: root.appending(path: "Named")) == nil)
        #expect(GameScanner.game(at: root.appending(path: "NoCode")) == nil)
    }

    @Test func removingAFlatDumpTakesItsFolders() throws {
        try write("Flat/exefs/main.npdm", Self.npdm(programID: 1))
        try write("Flat/romfs/a.bin")
        try write("Flat/Notes.txt")
        let game = try #require(GameScanner.game(at: root.appending(path: "Flat")))
        let removal = GameRemoval(game: game, removesSaves: false, home: root)
        #expect(Set(removal.items.map(\.lastPathComponent)) == ["exefs", "romfs"])
        #expect(removal.others.map(\.lastPathComponent) == ["Notes.txt"])
    }

    @Test func removingADumpTakesItsFoldersAndLeavesTheRest() throws {
        let game = try #require(GameScanner.game(at: root.appending(path: "FastFusion")))
        let removal = GameRemoval(game: game, removesSaves: false, home: root)
        #expect(Set(removal.items.map(\.lastPathComponent)) == ["base", "updates"])
        #expect(removal.others.map(\.lastPathComponent) == ["Notes.txt"])
    }

    @Test func anNSPGamesBaseFolderIsNotItsFiles() throws {
        try write("Wonder/Wonder.nsp")
        try write("Wonder/base/mod.txt")
        let game = try #require(GameScanner.game(at: root.appending(path: "Wonder")))
        #expect(!game.isDump && !game.isSwitch2)
        let removal = GameRemoval(game: game, removesSaves: false, home: root)
        #expect(removal.others.map(\.lastPathComponent) == ["base"])
    }
}
