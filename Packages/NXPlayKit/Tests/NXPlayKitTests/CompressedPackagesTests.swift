import Foundation
import Testing

@testable import NXPlayKit

/// Keep Only the Unpacked Copy: which NSZ files give way to nxnative's unpacked NSP, and how.
@Suite struct CompressedPackagesTests {
    /// A game folder with Game.nsz and the build's nsp/Game.nsp; recorded: nxnative's record of that conversion.
    private func folder(recorded: Bool = true) throws -> (Game, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "nxplay-unpacked-\(UUID())")
        let build = root.appending(path: "0100DC0012E48000_build")
        let converted = build.appending(path: "nsp")
        try FileManager.default.createDirectory(at: converted, withIntermediateDirectories: true)
        let nsz = root.appending(path: "Game [0100DC0012E48000][v0].nsz")
        try Data(repeating: 1, count: 10).write(to: nsz)
        try Data(repeating: 2, count: 30).write(to: converted.appending(path: "Game [0100DC0012E48000][v0].nsp"))
        if recorded { try record(nsz) }
        let game = Game(
            folder: root, name: "Game", titleID: "0100DC0012E48000", version: nil, languages: [], iconURL: nil,
            buildFolder: build, ipaURL: nil, xcodeBuildFolder: nil, hasPackages: true, state: .ready)
        return (game, root)
    }

    /// What nxnative writes beside a conversion: the source's fingerprint, then a newline.
    private func record(_ nsz: URL) throws {
        let stat = try #require(CompressedPackages.stat(of: nsz))
        let key = CompressedPackages.fingerprint(
            name: nsz.lastPathComponent, size: stat.size, modified: stat.modified)
        let record = nsz.deletingLastPathComponent().appending(
            path: "0100DC0012E48000_build/nsp/\(nsz.deletingPathExtension().lastPathComponent).nsp.key")
        try (key + "\n").write(to: record, atomically: true, encoding: .utf8)
    }

    /// Values from nxnative's own fingerprint(), run in Python: a record it wrote matches only if these do.
    @Test func theFingerprintIsNxnatives() {
        #expect(
            CompressedPackages.fingerprint(name: "Game.nsz", size: 1234, modified: 1_700_000_000_123_456_789)
                == "3c5f1aef290d89fe4bc8b2029e54d9e9a4f2350c1303f78fdbf8b1d61ebeb3c8")
        #expect(
            CompressedPackages.fingerprint(
                name: "Assassin's Creed [01][v0].nsz", size: 7_667_462_409, modified: 1_699_999_999_000_000_001)
                == "ac4378bff26a70a9692708acd80825363f413895ffe34e405db1436c0ba95951")
        #expect(
            CompressedPackages.fingerprint(name: "Pokémon \"Let's Go\".xcz", size: 5, modified: 6)
                == "91e967ecf2352ac8c2c56b8f97968db714a083a8f76a89d8a46a9b270520763d")
        #expect(CompressedPackages.pythonRepr("Pokémon \"Let's Go\".xcz") == #"'Pokémon "Let\'s Go".xcz'"#)
    }

    @Test func theUnpackedCopyTakesTheCompressedOnesPlace() throws {
        let (game, root) = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let pairs = CompressedPackages.pairs(of: game)
        #expect(pairs.count == 1)
        #expect(pairs.first?.size == 10)
        try CompressedPackages.swap(#require(pairs.first)) { try FileManager.default.removeItem(at: $0) }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(names == ["0100DC0012E48000_build", "Game [0100DC0012E48000][v0].nsp"])
        let converted = root.appending(path: "0100DC0012E48000_build/nsp")
        #expect(try FileManager.default.contentsOfDirectory(atPath: converted.path).isEmpty)
        #expect(CompressedPackages.pairs(of: game).isEmpty)
    }

    @Test func onlyAConversionOfTheFileAsItIsNowCounts() throws {
        let (unrecorded, root) = try folder(recorded: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CompressedPackages.pairs(of: unrecorded).isEmpty)

        let (game, other) = try folder()
        defer { try? FileManager.default.removeItem(at: other) }
        // another NSZ under the same name: its conversion isn't made yet
        try Data(repeating: 3, count: 11).write(to: other.appending(path: "Game [0100DC0012E48000][v0].nsz"))
        #expect(CompressedPackages.pairs(of: game).isEmpty)
    }

    @Test func aFileUnderTheUnpackedNameStaysUntouched() throws {
        let (game, root) = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([9]).write(to: root.appending(path: "Game [0100DC0012E48000][v0].nsp"))
        #expect(CompressedPackages.pairs(of: game).isEmpty)
    }

    /// Both in the folder would be the game twice to nxnative.
    @Test func theUnpackedCopyGoesBackWhenTheCompressedOneCantGo() throws {
        let (game, root) = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = try #require(CompressedPackages.pairs(of: game).first)
        struct Refused: Error {}
        #expect(throws: Refused.self) { try CompressedPackages.swap(pair) { _ in throw Refused() } }
        #expect(FileManager.default.fileExists(atPath: pair.unpacked.path))
        #expect(FileManager.default.fileExists(atPath: pair.compressed.path))
        #expect(!FileManager.default.fileExists(atPath: pair.destination.path))
        #expect(CompressedPackages.pairs(of: game).count == 1)
    }
}
