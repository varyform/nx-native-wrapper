import Foundation

/// A game's RomFS mods: folders in <game>/Mods, each a romfs/ tree of files that override the
/// game's own (Atmosphère's contents/<title ID>/romfs layout, so a Switch mod drops in as it is).
/// The host's DM_ROMFS_OVERLAY takes the enabled roots in order and the first hit wins a path, so
/// two mods can change the same file and the rest of both still merge in — order.txt inside Mods
/// keeps that priority: enabled names, one per line, first winning. Mods left out of it are off;
/// no order.txt means everything on, alphabetical.
public struct GameMod: Identifiable {
    public let name: String
    /// Its overlay root (<game>/Mods/<name>/romfs): the path DM_ROMFS_OVERLAY names.
    public let root: URL
    public var enabled: Bool
    /// Files it overrides; counted only for the menu's summary.
    public var files: Set<String> = []
    /// Of its files, how many a higher-priority enabled mod also overrides, and by whom.
    public var shadowed = 0
    public var shadowedBy: String?
    public var id: String { name }
}

public struct GameMods {
    public static let folderName = "Mods"
    public static let orderName = "order.txt"
    public static let rootName = "romfs"

    /// <game>/Mods.
    public let url: URL
    /// Every mod, in the order the menu shows them: the enabled by priority, then the rest by name.
    public private(set) var mods: [GameMod]
    public var enabled: [GameMod] { mods.filter(\.enabled) }

    /// The mods of a game's folder; nil when it has no Mods (or an empty one), so menus skip it.
    /// countFiles walks every mod's files — for the menu's sizes and conflict hints; the play
    /// command only needs the roots.
    public init?(for folder: URL, countFiles: Bool = false) {
        let modsURL = folder.appending(path: Self.folderName)
        let fm = FileManager.default
        guard
            let names = try? fm.contentsOfDirectory(atPath: modsURL.path).filter({
                var directory: ObjCBool = false
                return fm.fileExists(
                    atPath: modsURL.appending(path: $0).path, isDirectory: &directory)
                    && directory.boolValue
            }), !names.isEmpty
        else { return nil }
        let listed =
            (try? String(contentsOf: modsURL.appending(path: Self.orderName), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        let kept = listed.filter(names.contains)
        let on = kept.map {
            GameMod(name: $0, root: Self.root(of: $0, in: modsURL), enabled: true)
        }
        let off = Set(names).subtracting(kept).sorted().map {
            // no order.txt yet: everything on; written one: off
            GameMod(name: $0, root: Self.root(of: $0, in: modsURL), enabled: listed.isEmpty)
        }
        url = modsURL
        mods = on + off
        if countFiles { count() }
    }

    /// The DM_ROMFS_OVERLAY value: the enabled roots in priority order.
    public var overlayArgument: String? {
        let roots = enabled.map(\.root.path)
        return roots.isEmpty ? nil : roots.joined(separator: ":")
    }

    /// Writes order.txt: the enabled names in priority order.
    private func saveOrder() throws {
        try enabled.map(\.name).joined(separator: "\n").write(
            to: url.appending(path: Self.orderName), atomically: true, encoding: .utf8)
    }

    /// The file paths a mod's romfs/ overrides, relative to it.
    static func files(under root: URL) -> Set<String> {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard
            let all = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys)
        else { return [] }
        let base = root.standardizedFileURL.path + "/"
        var files = Set<String>()
        for case let file as URL in all {
            guard (try? file.resourceValues(forKeys: Set(keys)))?.isRegularFile == true
            else { continue }
            files.insert(file.standardizedFileURL.path.replacing(base, with: "", maxReplacements: 1))
        }
        return files
    }

    /// Each enabled mod's file set, then which of them an earlier enabled mod also claims.
    private mutating func count() {
        var earlier = Set<String>()
        var earlierBy: [String: String] = [:]
        for i in mods.indices {
            mods[i].files = Self.files(under: mods[i].root)
            guard mods[i].enabled else { continue }
            for file in mods[i].files where earlier.contains(file) {
                mods[i].shadowed += 1
                mods[i].shadowedBy = mods[i].shadowedBy ?? earlierBy[file]
            }
            for file in mods[i].files where !earlier.contains(file) {
                earlier.insert(file)
                earlierBy[file] = mods[i].name
            }
        }
    }

    static func root(of name: String, in url: URL) -> URL {
        url.appending(path: "\(name)/\(rootName)", directoryHint: .isDirectory)
    }

    /// A mod on or off, its order kept.
    public mutating func set(enabled: Bool, _ mod: GameMod) throws {
        guard let i = mods.firstIndex(where: { $0.id == mod.id }) else { return }
        mods[i].enabled = enabled
        try saveOrder()
    }

    /// An enabled mod one place in the priority order — the order the first-hit overlay resolves a
    /// same-file claim by.
    public mutating func move(_ mod: GameMod, up: Bool) throws {
        let ids = enabled.map(\.id)
        guard let i = ids.firstIndex(of: mod.id) else { return }
        let j = i + (up ? -1 : 1)
        guard ids.indices.contains(j) else { return }
        mods.swapAt(i, j)
        try saveOrder()
    }
}

extension Library {
    /// A game's mods (for the menu; countFiles for its sizes and conflict hints).
    public func mods(for game: Game, countFiles: Bool = false) -> GameMods? {
        GameMods(for: game.folder, countFiles: countFiles)
    }

    /// A game's enabled mods as one DM_ROMFS_OVERLAY argument, nil when none are on.
    func modsArgument(for game: Game) -> String? {
        GameMods(for: game.folder)?.overlayArgument
    }

    /// Turns a mod on or off and saves order.txt.
    func setMod(_ mod: GameMod, enabled: Bool, for game: Game) {
        guard var mods = GameMods(for: game.folder) else { return }
        try? mods.set(enabled: enabled, mod)
    }

    /// Moves an enabled mod one place in the priority order and saves order.txt.
    func moveMod(_ mod: GameMod, up: Bool, for game: Game) {
        guard var mods = GameMods(for: game.folder) else { return }
        try? mods.move(mod, up: up)
    }
}
