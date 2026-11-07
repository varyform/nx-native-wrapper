import Foundation
import Testing
import zlib

@testable import NXPlayKit

@Suite struct NACPTests {
    /// A NACP as newer SDKs write it: the title entries raw-deflated behind a u16 size (the rest
    /// of the file stays where uncompressed NACPs keep it).
    static func compressedNacp(
        entries: [(Int, String)], version: String, languageFlags: UInt32 = 0
    ) -> Data {
        var titles = [UInt8](repeating: 0, count: 0x6000)
        for (language, title) in entries {
            titles.replaceSubrange(
                language * 0x300..<language * 0x300 + title.utf8.count, with: Array(title.utf8))
        }
        let deflated = deflate(titles)
        var bytes = [UInt8](repeating: 0, count: 0x4000)
        bytes[0] = UInt8(deflated.count & 0xff)
        bytes[1] = UInt8(deflated.count >> 8)
        bytes.replaceSubrange(2..<2 + deflated.count, with: deflated)
        bytes.replaceSubrange(0x3060..<0x3060 + version.utf8.count, with: Array(version.utf8))
        for i in 0..<4 { bytes[0x302C + i] = UInt8(truncatingIfNeeded: languageFlags >> (8 * i)) }
        return Data(bytes)
    }

    /// Raw deflate (window bits -15), the NACP title compression — `zlib.compress`'s output is
    /// zlib-wrapped and would not exercise the format.
    static func deflate(_ input: [UInt8]) -> [UInt8] {
        var stream = z_stream()
        deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        defer { deflateEnd(&stream) }
        var out = [UInt8](repeating: 0, count: 0x3000)
        let produced = input.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                stream.next_in = UnsafeMutablePointer(
                    mutating: src.baseAddress!.assumingMemoryBound(to: UInt8.self))
                stream.avail_in = uInt(src.count)
                stream.next_out = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
                stream.avail_out = uInt(dst.count)
                zlib.deflate(&stream, Z_FINISH)
                return Int(stream.total_out)
            }
        }
        return Array(out.prefix(produced))
    }

    static func nacp(
        title: String, publisher: String = "Nintendo", version: String, language: Int = 0,
        languageFlags: UInt32 = 0
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x4000)
        func put(_ text: String, at offset: Int) {
            bytes.replaceSubrange(offset..<offset + text.utf8.count, with: Array(text.utf8))
        }
        put(title, at: language * 0x300)
        put(publisher, at: language * 0x300 + 0x200)
        put(version, at: 0x3060)
        for i in 0..<4 { bytes[0x302C + i] = UInt8(truncatingIfNeeded: languageFlags >> (8 * i)) }
        return Data(bytes)
    }

    @Test func readsTheSupportedLanguages() {
        // bits 0 (en-US), 2 (ja), 14 (zh-Hans)
        let nacp = NACP(
            data: Self.nacp(title: "T", version: "1", languageFlags: 1 | 1 << 2 | 1 << 14))
        #expect(nacp?.languages == ["en-US", "ja", "zh-Hans"])
    }

    @Test func choosesThePreferredLanguageOrItsRegionalTwin() {
        func game(_ languages: [String]) -> Game {
            Game(
                folder: URL(filePath: "/g"), name: "G", titleID: nil, version: nil,
                languages: languages,
                iconURL: nil, buildFolder: nil, ipaURL: nil, xcodeBuildFolder: nil, hasPackages: true, state: .ready)
        }
        #expect(GameLanguage.choose("ja", for: game(["en-US", "ja"])) == "ja")
        #expect(GameLanguage.choose("en-US", for: game(["en-GB", "fr"])) == "en-GB")
        #expect(GameLanguage.choose("ko", for: game(["en-US"])) == nil)
        #expect(GameLanguage.choose("ko", for: game([])) == "ko")
        #expect(GameLanguage.choose("", for: game(["ja"])) == nil)
    }

    @Test func readsTitlePublisherAndVersion() throws {
        let nacp = try #require(NACP(data: Self.nacp(title: "Metroid Dread", version: "2.1.0")))
        #expect(nacp.title == "Metroid Dread")
        #expect(nacp.publisher == "Nintendo")
        #expect(nacp.displayVersion == "2.1.0")
    }

    @Test func takesTheFirstLanguageWithAName() {
        #expect(
            NACP(data: Self.nacp(title: "メトロイド", version: "1.0.0", language: 2))?.title == "メトロイド")
    }

    @Test func rejectsShortData() {
        #expect(NACP(data: Data(count: 0x100)) == nil)
    }

    @Test func readsACompressedTitle() throws {
        // a newer SDK's NACP (Breath of the Wild repacks, Mario 1.2.1): the title entries are a
        // u16 size + raw deflate inflating to 32 entries, the rest at its usual offsets
        let nacp = try #require(
            NACP(
                data: Self.compressedNacp(
                    entries: [(0, "The Legend of Zelda: Breath of the Wild")],
                    version: "1.9.0", languageFlags: 1 | 1 << 2)))
        #expect(nacp.title == "The Legend of Zelda: Breath of the Wild")
        #expect(nacp.displayVersion == "1.9.0")
        #expect(nacp.languages == ["en-US", "ja"])
    }

    @Test func readsTheCompressedTitlesBeyondTheSixteenth() {
        // the compressed form holds 32 language entries; a name past the first 16 still counts
        let nacp = NACP(data: Self.compressedNacp(entries: [(17, "Zelda")], version: "1"))
        #expect(nacp?.title == "Zelda")
    }

    @Test func readsAnUncompressedTitleWhoseFirstBytesAreNoStream() {
        // " /" reads as a 0x2f20-byte deflate size in range; 'Game' then fails to inflate, and
        // only inflating to exactly the 32 entries counts as compressed (nacp.py checks the same)
        let nacp = NACP(data: Self.nacp(title: " /Game", version: "1"))
        #expect(nacp?.title == "/Game")
    }
}
