import Foundation

/// A game as one NUP container (https://github.com/a55uka/nup, SPEC.md), which nxnative builds a Switch 2 game from
/// (its README's "Switch 2 games", scripts/pack_nup.py): the base game, updates and DLC in one `.nup` file. Its files
/// aren't encrypted, so it needs no prod.keys.
enum GameNUP {
    static let fileExtension = "nup"

    /// What pack_nup.py's is_nup checks: nxnative ignores a `.nup` without the magic.
    static func isNUP(_ file: URL) -> Bool {
        guard file.pathExtension.lowercased() == fileExtension,
            let handle = try? FileHandle(forReadingFrom: file)
        else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 3)) == Data("NUP".utf8)
    }

    /// The title ID before anything is built, from the package records at the start of the file. A library scan runs
    /// this, so it must not read a game of tens of GB, nor main.npdm, which is usually zstd-compressed. nxnative reads
    /// the ID from the code when it builds; this one only labels the game until then.
    static func titleID(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let superblock = try? handle.read(upToCount: superblockSize),
            let (offset, count) = packageRange(superblock: superblock),
            (try? handle.seek(toOffset: UInt64(offset))) != nil,
            let records = try? handle.read(upToCount: count * packageSize)
        else { return nil }
        return titleID(records: records)
    }

    /// The base package's ID, or, when the base is an empty placeholder with ID 0 and an update holds the whole game
    /// (Pokémon Pokopia), the base ID that update belongs to: the same but for the low bits.
    static func titleID(records data: Data) -> String? {
        let records = [UInt8](data)
        let packages = stride(from: 0, to: records.count - packageSize + 1, by: packageSize).map { at in
            let id = (0..<8).reduce(UInt64(0)) { $0 | UInt64(records[at + $1]) << (8 * $1) }
            return (id: id, kind: records[at + kindOffset])
        }
        let ids =
            packages.filter { $0.kind == baseKind }.map(\.id)
            + packages.filter { $0.kind == updateKind }.map { $0.id & ~0xFFF }
        return ids.first { $0 != 0 }.map { String(format: "%016llX", $0) }
    }

    /// Where the package records are, and how many: right after the table of contents' header, which the superblock
    /// gives the offset of. Nil for anything but a NUP of the format version nxnative reads.
    static func packageRange(superblock data: Data) -> (offset: Int, count: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= superblockSize, bytes.starts(with: Array("NUP".utf8)), bytes[3] == 1
        else { return nil }
        let tocOffset = (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[0x08 + $1]) << (8 * $1) }
        let count = (0..<4).reduce(0) { $0 | Int(bytes[0x48 + $1]) << (8 * $1) }
        guard count > 0, count <= maxPackages, tocOffset < UInt64(Int32.max) else { return nil }
        return (Int(tocOffset) + tocHeaderSize, count)
    }

    private static let superblockSize = 0x80
    private static let tocHeaderSize = 0x30
    private static let packageSize = 0x40
    private static let kindOffset = 0x18
    private static let baseKind: UInt8 = 0
    private static let updateKind: UInt8 = 1
    /// A base, its updates and its DLC; the header is checked no further here, so a damaged one can't ask for much.
    private static let maxPackages = 4096
}
