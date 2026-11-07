import Foundation
import zlib

/// The parts of a Switch control.nacp the library uses: language entries of name (0x200 bytes)
/// + publisher (0x100 bytes), 16 of them or 32 when compressed (see `titles`), the
/// supported-language bits at 0x302C and the display version at 0x3060.
public struct NACP: Equatable, Sendable {
    public let title: String?
    public let publisher: String?
    public let displayVersion: String?
    /// Language codes the game supports, in GameLanguage order; empty when the control data lists none.
    public let languages: [String]

    static let entrySize = 0x300
    static let entryCount = 16
    static let titleBytes = entryCount * entrySize
    static let languageFlagsOffset = 0x302C
    static let displayVersionOffset = 0x3060

    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.displayVersionOffset + 0x10 else { return nil }
        let titles = Self.titles(bytes)
        // the first language with a name: American English when the game has it
        let entry = (0..<titles.count / Self.entrySize).lazy
            .map { $0 * Self.entrySize }
            .map { (Self.string(titles, $0, 0x200), Self.string(titles, $0 + 0x200, 0x100)) }
            .first { $0.0 != nil }
        title = entry?.0
        publisher = entry?.1
        displayVersion = Self.string(bytes, Self.displayVersionOffset, 0x10)
        let flags = (0..<4).reduce(UInt32(0)) {
            $0 | UInt32(bytes[Self.languageFlagsOffset + $1]) << (8 * $1)
        }
        languages = GameLanguage.all.enumerated().filter { flags >> $0.offset & 1 == 1 }.map(
            \.element.code)
    }

    public init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    /// The title entries, 0x300 bytes each: the NACP's own title bytes, or the 0x6000 they inflate
    /// to when a newer SDK stores them compressed — a u16 size, then raw deflate (Mario 1.2.1's
    /// NACP does this; nxnative's nacp.py and nx_extract's TitleName decode it the same way).
    /// The uncompressed bytes on any failure, since a real title can start with a small u16 too.
    static func titles(_ bytes: [UInt8]) -> [UInt8] {
        let n = Int(bytes[0]) | Int(bytes[1]) << 8
        guard n > 0, n <= Self.titleBytes - 2, 2 + n <= bytes.count
        else { return Array(bytes[0..<Self.titleBytes]) }
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { return Array(bytes[0..<Self.titleBytes]) }
        defer { inflateEnd(&stream) }
        var inflated = [UInt8](repeating: 0, count: 2 * Self.titleBytes)
        var status = Z_OK
        let produced = bytes[2..<2 + n].withUnsafeBytes { src in
            inflated.withUnsafeMutableBytes { dst in
                stream.next_in = UnsafeMutablePointer(
                    mutating: src.baseAddress!.assumingMemoryBound(to: UInt8.self))
                stream.avail_in = uInt(src.count)
                stream.next_out = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
                stream.avail_out = uInt(dst.count)
                status = inflate(&stream, Z_FINISH)
                return Int(stream.total_out)
            }
        }
        guard status == Z_STREAM_END, produced == inflated.count
        else { return Array(bytes[0..<Self.titleBytes]) }
        return inflated
    }

    static func string(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> String? {
        let field = bytes[offset..<offset + length]
        let end = field.firstIndex(of: 0) ?? field.endIndex
        let text = String(decoding: bytes[offset..<end], as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
