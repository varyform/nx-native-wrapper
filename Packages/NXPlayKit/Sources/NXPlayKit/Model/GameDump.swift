import Foundation

/// A game as a folder of its files, the way nxnative builds a Switch 2 game (its README's "Switch 2 games",
/// scripts/pack_dump.py): `base/exefs/` (main, main.npdm, sdk, …) and `base/romfs/`, optionally `updates/<version>/`
/// and `dlc/<title ID>/`. Its files aren't encrypted, so it needs no prod.keys, and it carries no icon or name.
enum GameDump {
    /// The folders of a dump, which are the game files (Remove Game deletes them).
    static let folders: Set<String> = ["base", "updates", "dlc"]

    /// The layout pack_dump.py's is_dump checks.
    static func isDump(_ folder: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: npdm(folder).path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && GameScanner.isDirectory(folder.appending(path: "base/romfs", directoryHint: .isDirectory))
    }

    /// The title ID before anything is built: the program ID in main.npdm's ACI0 section, as pack_dump.py reads it.
    static func titleID(of folder: URL) -> String? {
        guard let data = try? Data(contentsOf: npdm(folder)) else { return nil }
        return titleID(npdm: data)
    }

    static func titleID(npdm data: Data) -> String? {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return (0..<4).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) }
        }
        guard bytes.starts(with: Array("META".utf8)), let offset = u32(0x70), let size = u32(0x74),
            size >= 0x18, offset + 0x18 <= bytes.count,
            Array(bytes[offset..<offset + 4]) == Array("ACI0".utf8)
        else { return nil }
        let id = (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + 0x10 + $1]) << (8 * $1) }
        return String(format: "%016llX", id)
    }

    private static func npdm(_ folder: URL) -> URL { folder.appending(path: "base/exefs/main.npdm") }
}
