import Foundation

/// A game's file mods (issue #27): `<game folder>/Mods/<mod>/`, each holding a `romfs` folder of the files it
/// replaces or adds. nxnative's host layers them over the game's RomFS (DM_ROMFS_OVERLAY, dm/host/hle_fs.c): a read
/// looks in each folder in turn before the game's own files, and a folder's listing merges them all, so the first mod
/// wins a file two change and a mod can add files. No rebuild: it takes effect at the next start, on the Mac only.
/// A mod's code plugins (`exefs/subsdk<N>`, exlaunch's) load on the Mac once nxnative's scripts/prepare_mod.py has
/// rewritten them into `exefs/nxnative/`, which nxplay does before a play; the host finds them beside the RomFS folder
/// the overlay lists (dm/host/hle_exl.c). Code that replaces the game's own (`exefs/main`, `exefs_patches`) can't work,
/// as nxnative rewrites the game's code when it builds it.
public struct GameMod: Identifiable, Equatable, Sendable {
    public enum Problem: Equatable, Sendable {
        /// Neither files nor code plugins at any of the layouts mods come in.
        case noRomFS
        /// nxnative splits DM_ROMFS_OVERLAY at colons.
        case colonInPath
    }

    /// The mod's folder name, which the order file keeps.
    public let name: String
    public let folder: URL
    /// The folder nxnative layers over the game's RomFS.
    public let romfs: URL?
    public var isOn: Bool
    /// Its code plugins (subsdk<N>), in the `exefs` folder beside where its RomFS is or would be.
    public let plugins: [String]
    /// The folder whose `exefs` holds the plugins, with a RomFS folder or none.
    public let codeRoot: URL?
    /// It changes the game's own code (`exefs/main`, `exefs_patches`), which nxnative can't use.
    public let hasOtherCode: Bool
    /// The title ID its layout names, when that's another game's (a mod for another release).
    public let otherTitle: String?
    public var id: String { name }

    public var problem: Problem? {
        guard let path = overlayPath else { return .noRomFS }
        return path.contains(":") ? .colonInPath : nil
    }

    /// What DM_ROMFS_OVERLAY lists for it: its RomFS, or for code alone where the RomFS would be, which the host
    /// finds the code beside and skips as a folder that isn't there.
    var overlayPath: String? {
        romfs?.path ?? codeRoot?.appending(path: "romfs", directoryHint: .isDirectory).path
    }

    /// It loads at the next start.
    public var loads: Bool { isOn && problem == nil }
}

/// What a mod's files are, worked out off the main thread: how many, and how many an earlier mod covers.
public struct GameModFiles: Equatable, Sendable {
    public let count: Int
    /// The files an earlier mod that loads also has, by that mod's name: those come from it.
    public let covered: [String: Int]
}

public enum GameMods {
    public static let folderName = "Mods"
    /// The order the mods load in and which are off, one `on` or `off`, a tab and the folder's name a line.
    static let orderFile = "order.txt"
    /// The longest DM_ROMFS_OVERLAY nxnative keeps (`overlay[4096]` in hle_fs.c's mount table, with its NUL).
    static let overlayLimit = 4095

    static func folder(of game: Game) -> URL {
        game.folder.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// The game's mods in their order: the order file's first, then the folders it doesn't list yet, by name and on,
    /// as a mod dropped into the folder is meant to be used.
    static func scan(_ folder: URL, titleID: String?) -> [GameMod] {
        let names = GameScanner.children(of: folder).filter { GameScanner.isDirectory($0) }.map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let saved = order(in: folder)
        let listed = saved.map(\.name).filter(names.contains)
        let new = names.filter { name in !saved.contains { $0.name == name } }
        return (listed + new).map { name in
            let on = saved.first { $0.name == name }?.on ?? true
            return mod(folder.appending(path: name, directoryHint: .isDirectory), on: on, titleID: titleID)
        }
    }

    /// The order file's lines, in order; a line it can't read is left out.
    static func order(in folder: URL) -> [(name: String, on: Bool)] {
        let text = (try? String(contentsOf: folder.appending(path: orderFile), encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, parts[0] == "on" || parts[0] == "off" else { return nil }
            return (String(parts[1]), parts[0] == "on")
        }
    }

    static func save(_ mods: [GameMod], in folder: URL) throws {
        let lines = mods.map { "\($0.isOn ? "on" : "off")\t\($0.name)" }
        let text =
            "# NX Play: the order the mods load in, the first winning a file two of them change; off is not loaded\n"
            + lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: folder.appending(path: orderFile), options: .atomic)
    }

    /// The layouts mods are shared in: `romfs` at the top, or inside Atmosphère's `atmosphere/contents/<title ID>/`,
    /// `contents/<title ID>/` or `<title ID>/`. With several title IDs, this game's.
    static func mod(_ folder: URL, on: Bool, titleID: String?) -> GameMod {
        var places: [(URL, String?)] = [(folder, nil)]
        for parent in [folder.appending(path: "atmosphere/contents"), folder.appending(path: "contents"), folder] {
            for child in GameScanner.children(of: parent) where isTitleID(child.lastPathComponent) {
                places.append((child, child.lastPathComponent.uppercased()))
            }
        }
        let own = titleID?.uppercased()
        let found = places.filter { GameScanner.isDirectory($0.0.appending(path: "romfs")) }
            .sorted { ($0.1 == nil || $0.1 == own ? 0 : 1) < ($1.1 == nil || $1.1 == own ? 0 : 1) }.first
        // code plugins sit beside the RomFS the host is given; with no RomFS, at this game's place first
        let coded = places.filter { !plugins(in: $0.0).isEmpty }
            .sorted { ($0.1 == nil || $0.1 == own ? 0 : 1) < ($1.1 == nil || $1.1 == own ? 0 : 1) }.first
        let place = found ?? coded
        let names = place.map { plugins(in: $0.0) } ?? []
        // code nxnative can't use: one that replaces the game's, or Atmosphère's patches to it
        let other =
            places.contains { GameScanner.isDirectory($0.0.appending(path: "exefs")) && plugins(in: $0.0).isEmpty }
            || places.contains { FileManager.default.fileExists(atPath: $0.0.appending(path: "exefs/main").path) }
            || GameScanner.isDirectory(folder.appending(path: "atmosphere/exefs_patches"))
            || GameScanner.isDirectory(folder.appending(path: "exefs_patches"))
        let otherTitle = place?.1.flatMap { $0 == own || own == nil ? nil : $0 }
        return GameMod(
            name: folder.lastPathComponent, folder: folder,
            romfs: found.map { $0.0.appending(path: "romfs", directoryHint: .isDirectory) }, isOn: on,
            plugins: names, codeRoot: names.isEmpty ? nil : place?.0, hasOtherCode: other, otherTitle: otherTitle)
    }

    /// exlaunch's plugin names, as the host takes them (is_subsdk_name): subsdk and a number, under 16 characters.
    static func plugins(in place: URL) -> [String] {
        GameScanner.children(of: place.appending(path: "exefs", directoryHint: .isDirectory))
            .filter { url in
                let name = url.lastPathComponent
                return name.count < 16 && name.hasPrefix("subsdk") && name.count > 6
                    && name.dropFirst(6).allSatisfy { $0.isASCII && $0.isNumber }
                    && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }
            .map(\.lastPathComponent)
            .sorted { Int($0.dropFirst(6)) ?? 0 < Int($1.dropFirst(6)) ?? 0 }
    }

    private static func isTitleID(_ name: String) -> Bool {
        name.count == 16 && name.allSatisfy(\.isHexDigit)
    }

    /// DM_ROMFS_OVERLAY for a play: the mods that load, in order, as long as nxnative keeps the whole list ("" for
    /// none, which also overrides a value in the Mac app's env.txt); and the ones left out for its length.
    static func overlay(_ mods: [GameMod]) -> (value: String, loaded: [GameMod], tooLong: [GameMod]) {
        var paths: [String] = [], loaded: [GameMod] = [], tooLong: [GameMod] = []
        for mod in mods where mod.loads {
            guard let path = mod.overlayPath else { continue }
            if (paths + [path]).joined(separator: ":").utf8.count > overlayLimit {
                tooLong.append(mod)
            } else {
                paths.append(path)
                loaded.append(mod)
            }
        }
        return (paths.joined(separator: ":"), loaded, tooLong)
    }

    /// Each mod's files, relative to its `romfs`, and how many of them a mod before it that loads also has.
    static func files(_ mods: [GameMod]) -> [String: GameModFiles] {
        var seen: [String: String] = [:]  // a file → the first loading mod that has it
        var result: [String: GameModFiles] = [:]
        for mod in mods {
            let paths = mod.romfs.map(relativeFiles) ?? []
            var covered: [String: Int] = [:]
            for path in paths {
                if let first = seen[path] {
                    covered[first, default: 0] += 1
                } else if mod.loads {
                    seen[path] = mod.name
                }
            }
            // a mod that doesn't load covers nothing, and nothing covers it but the mods before it
            result[mod.name] = GameModFiles(count: paths.count, covered: covered)
        }
        return result
    }

    /// The host compares paths as the game gives them, so a file is its path as is.
    private static func relativeFiles(_ romfs: URL) -> [String] {
        let base = romfs.standardizedFileURL.path
        guard
            let walk = FileManager.default.enumerator(
                at: romfs, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        return walk.compactMap { item -> String? in
            guard let url = item as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { return nil }
            let path = url.standardizedFileURL.path
            return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : nil
        }
    }
}
