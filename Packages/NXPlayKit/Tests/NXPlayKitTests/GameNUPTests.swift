import Foundation
import Testing

@testable import NXPlayKit

/// Switch 2 games as one NUP file (issue #12), and which of a folder's game files nxnative builds from.
@Suite struct GameNUPTests {
    let root: URL
    static let id: UInt64 = 0x0400_74A0_1BF1_2000
    static let idText = "040074A01BF12000"

    init() {
        root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-nup-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// The start of a NUP, as far as the title ID goes: the superblock, then the table of contents' header and its
    /// package records.
    static func nup(_ packages: [(id: UInt64, kind: UInt8)], version: UInt8 = 1) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x80 + 0x30)
        bytes.replaceSubrange(0..<3, with: Array("NUP".utf8))
        bytes[3] = version
        bytes[0x08] = 0x80  // the table of contents' offset
        bytes[0x48] = UInt8(packages.count)
        for package in packages {
            var record = [UInt8](repeating: 0, count: 0x40)
            for i in 0..<8 { record[i] = UInt8(truncatingIfNeeded: package.id >> (8 * UInt64(i))) }
            record[0x18] = package.kind
            bytes += record
        }
        return Data(bytes)
    }

    private func write(_ path: String, _ data: Data = Data([1])) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func writeDump(in folder: String) throws {
        try write("\(folder)/base/exefs/main.npdm", GameDumpTests.npdm(programID: Self.id))
        try write("\(folder)/base/romfs/a.bin")
    }

    private func scanned(_ folder: String) throws -> Game {
        try #require(GameScanner.game(at: root.appending(path: folder)))
    }

    @Test func aNUPIsAGameNamedByItsPackages() throws {
        try write("Bananza/game.nup", Self.nup([(Self.id, 0), (Self.id + 0x800, 1)]))
        let game = try scanned("Bananza")
        #expect(game.name == "Bananza")
        #expect(game.titleID == Self.idText)
        #expect(game.isNUP && !game.isDump && game.isUnencrypted && game.isSwitch2)
        #expect(game.hasPackages && game.canExtract)
    }

    @Test func aCapitalExtensionCounts() throws {
        try write("Bananza/GAME.NUP", Self.nup([(Self.id, 0)]))
        #expect(try scanned("Bananza").isNUP)
    }

    @Test func aPlaceholderBaseTakesItsIDFromTheUpdate() {
        let records = Self.nup([(0, 0), (Self.id + 0x800, 1), (Self.id + 0x1001, 2)]).dropFirst(0xB0)
        #expect(GameNUP.titleID(records: records) == Self.idText)
    }

    @Test func aDLCDoesntNameTheGame() {
        let records = Self.nup([(0, 0), (Self.id + 0x1001, 2)]).dropFirst(0xB0)
        #expect(GameNUP.titleID(records: records) == nil)
    }

    @Test func aFileThatIsntANUPIsNoGame() throws {
        try write("Odd/game.nup", Data("not a nup".utf8))
        #expect(GameScanner.game(at: root.appending(path: "Odd")) == nil)
    }

    @Test func aNUPItCantReadIsStillAGameWithoutAnID() throws {
        // nxnative says what's wrong with it when it builds
        try write("Short/game.nup", Data("NUP".utf8))
        try write("Newer/game.nup", Self.nup([(Self.id, 0)], version: 2))
        try write("Empty/game.nup", Self.nup([]))
        for folder in ["Short", "Newer", "Empty"] {
            let game = try scanned(folder)
            #expect(game.isNUP && game.titleID == nil)
        }
    }

    @Test func nspsBesideANUPOrADumpAreWhatGetsBuilt() throws {
        try write("WithNUP/game.nsp")
        try write("WithNUP/game.nup", Self.nup([(Self.id, 0)]))
        try write("WithDump/game.nsp")
        try writeDump(in: "WithDump")
        for folder in ["WithNUP", "WithDump"] {
            let game = try scanned(folder)
            #expect(game.hasPackages && !game.isUnencrypted && game.titleID == nil)
        }
    }

    @Test func aNUPBesideADumpIsWhatGetsBuilt() throws {
        try write("Both/game.nup", Self.nup([(Self.id, 0)]))
        try writeDump(in: "Both")
        let game = try scanned("Both")
        #expect(game.isNUP && !game.isDump)
    }

    @Test func removingANUPTakesTheFile() throws {
        try write("Bananza/game.nup", Self.nup([(Self.id, 0)]))
        try write("Bananza/Notes.txt")
        let removal = GameRemoval(game: try scanned("Bananza"), removesSaves: false, home: root)
        #expect(removal.items.map(\.lastPathComponent) == ["game.nup"])
        #expect(removal.others.map(\.lastPathComponent) == ["Notes.txt"])
    }
}
