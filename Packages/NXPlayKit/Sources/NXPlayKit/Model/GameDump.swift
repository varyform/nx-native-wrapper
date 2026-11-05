import Foundation

/// A game as a folder of its files, the way nxnative builds a Switch 2 game (its README's "Switch 2 games",
/// scripts/pack_dump.py): `base/exefs/` (main, main.npdm, sdk, …) and `base/romfs/`, optionally `updates/<version>/`
/// and `dlc/<title ID>/`. `base/` can also be `exefs/` and `romfs/` directly in the folder, as `nup extract` writes
/// them, and an update's folder can be the whole game, with no base at all. Its files aren't encrypted, so it needs no
/// prod.keys, and it carries no icon or name.
enum GameDump {
    /// The folders of a dump, which are the game files (Remove Game deletes them).
    static let folders: Set<String> = ["base", "updates", "dlc", "exefs", "romfs"]

    /// The layouts pack_dump.py's is_dump accepts: a base game's code with a RomFS beside it or in an update, or an
    /// update with its code and RomFS and no base.
    static func isDump(_ folder: URL) -> Bool {
        let updates = updates(of: folder)
        guard let base = base(of: folder) else { return updates.contains(where: isVersion) }
        return hasRomFS(base) || updates.contains(where: hasRomFS)
    }

    /// The title ID before anything is built: the program ID in main.npdm's ACI0 section, as pack_dump.py reads it,
    /// from the base game, else the newest whole update.
    static func titleID(of folder: URL) -> String? {
        guard let code = base(of: folder) ?? updates(of: folder).last(where: isVersion),
            let data = try? Data(contentsOf: npdm(code))
        else { return nil }
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

    /// The base game's folder: `base/`, or the folder itself when it holds the version directly.
    private static func base(of folder: URL) -> URL? {
        let base = folder.appending(path: "base", directoryHint: .isDirectory)
        if hasCode(base) { return base }
        return isVersion(folder) ? folder : nil
    }

    /// `updates/<version>/`, oldest first; the version is a decimal number.
    private static func updates(of folder: URL) -> [URL] {
        let parent = folder.appending(path: "updates", directoryHint: .isDirectory)
        let versions: [(Int, URL)] = GameScanner.children(of: parent).compactMap { url in
            let name = url.lastPathComponent
            guard name.allSatisfy({ $0.isASCII && $0.isNumber }), let version = Int(name),
                GameScanner.isDirectory(url)
            else { return nil }
            return (version, url)
        }
        return versions.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func isVersion(_ folder: URL) -> Bool { hasCode(folder) && hasRomFS(folder) }

    private static func hasCode(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: npdm(folder).path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func hasRomFS(_ folder: URL) -> Bool {
        GameScanner.isDirectory(folder.appending(path: "romfs", directoryHint: .isDirectory))
    }

    private static func npdm(_ version: URL) -> URL { version.appending(path: "exefs/main.npdm") }
}
