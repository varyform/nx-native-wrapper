import Foundation

/// Finds the games in a folder laid out the way build_ipa_from_nsp.py leaves it:
/// `<root>/<game>/*.nsp` and `<root>/<game>/<title ID>_build/extract/v<version>/{icon.jpg,control.nacp}`. A Switch 2
/// game is a NUP file (GameNUP) or a dump of its files (GameDump) in place of the NSPs.
public enum GameScanner {
    static let packageExtensions: Set<String> = ["nsp", "nsz", "xci", "xcz", GameNUP.fileExtension]
    static let launcherName = "start_mac.sh"
    /// nxplay's mark of a kept build (Keep This Build).
    static let keepName = "keep"

    /// Every games folder's games, by name; a folder that isn't there (a disk not connected) has none.
    public static func scan(roots: [URL]) -> [Game] {
        var seen = Set<Game.ID>()
        return roots.flatMap(games(in:))
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A folder of games, one per subfolder; or, with none, a game's own folder: its files at the top level.
    static func games(in root: URL) -> [Game] {
        let inside = children(of: root).compactMap(game(at:))
        if inside.isEmpty, let game = game(at: root) { return [game] }
        return inside
    }

    public static func game(at folder: URL) -> Game? {
        guard isDirectory(folder) else { return nil }
        let entries = children(of: folder)
        let encrypted = entries.filter {
            let ext = $0.pathExtension.lowercased()
            return ext != GameNUP.fileExtension && packageExtensions.contains(ext)
        }
        let nups = entries.filter(GameNUP.isNUP)
        let packages = encrypted + nups
        // what nxnative builds from: the NSPs when there are any, else the NUP, else the dump (its nup_file, dump_folder)
        let nup = encrypted.isEmpty ? nups.first : nil
        let isDump = packages.isEmpty && GameDump.isDump(folder)
        let hasPackages = !packages.isEmpty || isDump
        let builds = entries.filter(isBuildFolder).map(Build.init(folder:))
        // a build with nothing but its run folder holds the saves of a removed game (Remove Game keeps them): no game
        // until its files come back
        guard hasPackages || builds.contains(where: \.hasContent) else { return nil }

        // A derived profile can leave a second build folder: take the most finished one, then the newest
        let build = builds.max { ($0.rank, $0.modified) < ($1.rank, $1.modified) }
        let nacp = build?.nacpURL.flatMap(NACP.init(contentsOf:))
        let state: Game.State =
            build?.isReady == true ? .ready : build?.extract != nil ? .extracted : .notExtracted

        return Game(
            folder: folder,
            name: nacp?.title ?? folder.lastPathComponent,
            // a NUP or a dump names its game before the build does
            titleID: build.map { String($0.folder.lastPathComponent.dropLast("_build".count)) }
                ?? nup.flatMap(GameNUP.titleID(of:))
                ?? (isDump ? GameDump.titleID(of: folder) : nil),
            version: nacp?.displayVersion,
            languages: nacp?.languages ?? [],
            iconURL: build?.iconURL,
            buildFolder: build?.folder,
            ipaURL: newest(entries.filter { $0.pathExtension.lowercased() == "ipa" }),
            ipaGameFiles: build.flatMap { ipaGameFiles(in: $0.folder) },
            xcodeBuildFolder: build.map {
                $0.folder.appending(path: "xcode-derived-data", directoryHint: .isDirectory)
            }
            .flatMap { isDirectory($0) ? $0 : nil },
            // nxnative's app: <game name>.app with its Mac host inside (not any app that happens to be there)
            macAppURL: newest(entries.filter(isMacApp)),
            hasPackages: hasPackages,
            isNUP: nup != nil,
            isDump: isDump,
            // a copied folder carries the mark on itself, a copied file on itself
            isCopying: isBeingCopied(folder) || packages.contains(where: isBeingCopied),
            lastPlayed: build.flatMap {
                try? $0.folder.appending(path: "run/last_played")
                    .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            },
            added: (try? folder.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])).flatMap {
                $0.addedToDirectoryDate ?? $0.creationDate
            },
            isKept: build.map {
                FileManager.default.fileExists(atPath: $0.folder.appending(path: keepName).path)
            } ?? false,
            macAppOutdated: build.flatMap { build in
                newest(entries.filter(isMacApp)).map { isOutdated(app: $0, build: build.folder) }
            } ?? false,
            nxnativeLink: Library.nxnativeLink(in: folder),
            state: state
        )
    }

    /// Finder dates what it is still copying 24 January 1984 (the Mac's launch day) and puts the source's
    /// creation date back when the copy is complete; nothing real is that old. Only the item dragged gets the
    /// mark: a copied game folder carries it while the files inside have today's date, a copied file carries it
    /// itself. A day either side covers the time zone. Other copies leave no such mark: browsers and torrent
    /// clients use another extension until a file is complete, rsync a hidden name, and cp nothing at all.
    static func isBeingCopied(_ url: URL) -> Bool {
        guard let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        else { return false }
        return abs(created.timeIntervalSince(finderCopyDate)) < 86_400
    }

    static let finderCopyDate = Date(timeIntervalSince1970: 443_750_400)  // 1984-01-24 00:00 UTC

    struct Build {
        let folder: URL
        /// The newest `extract/v<version>` (the version the build packs).
        let extract: URL?
        let iconURL: URL?
        let nacpURL: URL?
        let isReady: Bool
        let modified: Date
        /// More than the player's data (the run folder's saves and caches, the cheats): something extracted or built.
        let hasContent: Bool

        var rank: Int { isReady ? 2 : extract != nil ? 1 : 0 }

        init(folder: URL) {
            let fm = FileManager.default
            let versions = GameScanner.extractVersions(in: folder)
            func first(_ name: String) -> URL? {
                versions.lazy.map { $0.appending(path: name) }.first {
                    fm.fileExists(atPath: $0.path)
                }
            }
            self.folder = folder
            extract = versions.first
            iconURL = first("icon.jpg")
            nacpURL = first("control.nacp")
            // the same check nxplay makes before it reuses a launcher
            isReady =
                fm.fileExists(atPath: folder.appending(path: GameScanner.launcherName).path)
                && fm.isExecutableFile(atPath: folder.appending(path: "tools/dmhost").path)
            modified =
                (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            hasContent = GameScanner.children(of: folder).contains {
                !GameScanner.playerData.contains($0.lastPathComponent)
            }
        }
    }

    /// What a build folder holds of the player's own, which removing the build keeps: `run` (the saves) and `cheats`
    /// (nxnative's cheat files and the player's toggles, at `<DM_ROOT>/cheats`: the build folder is `DM_ROOT` in
    /// start_mac.sh).
    static let playerData: Set<String> = ["run", "cheats"]

    /// nxnative's app: `<game name>.app` with its Mac host inside, not any app that happens to be there.
    static func isMacApp(_ url: URL) -> Bool {
        url.pathExtension == "app"
            && FileManager.default.isExecutableFile(
                atPath: url.appending(path: "Contents/MacOS/dmhost").path)
    }

    /// The app was packed with other nxnative code than the build's launcher runs, as nxplay decides it: by the code
    /// `app.tree` records (nxplay --mac-app), else, for an app from before that, by being older than the launcher. No
    /// launcher: nothing to compare (Play has only the app's build to go by).
    static func isOutdated(app: URL, build: URL) -> Bool {
        let launcher = build.appending(path: launcherName)
        guard FileManager.default.fileExists(atPath: launcher.path) else { return false }
        func modified(_ url: URL) -> Date? {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        let tree = build.appending(path: "app.tree")
        if let packed = try? String(contentsOf: tree, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !packed.isEmpty
        {
            guard let built = ProfileNews.builtTree(build), built != packed else { return false }
            // other code: the older of the two has it, as the checkout only moves forward. An app packed after the build
            // (Make Mac App after an nxnative update) runs newer code, and nxplay plays it (the checkout's code too)
            guard let packedAt = modified(tree), let builtAt = modified(launcher) else {
                return true
            }
            return packedAt < builtAt
        }
        guard let packed = modified(app.appending(path: "Contents/Info.plist")),
            let built = modified(launcher)
        else { return false }
        return packed < built
    }

    /// `extract/v<number>` folders, newest version first.
    static func extractVersions(in build: URL) -> [URL] {
        children(of: build.appending(path: "extract", directoryHint: .isDirectory))
            .compactMap { url -> (Int, URL)? in
                let name = url.lastPathComponent
                guard name.hasPrefix("v"), let version = Int(name.dropFirst()), isDirectory(url)
                else { return nil }
                return (version, url)
            }
            .sorted { $0.0 > $1.0 }
            .map(\.1)
    }

    /// The RomFS image an IPA built without the game files needs on the device: nxplay names it in
    /// `ipa-game-files` (a build with them inside removes the file). Nil once the image is gone.
    static func ipaGameFiles(in build: URL) -> URL? {
        guard let text = try? String(contentsOf: build.appending(path: "ipa-game-files"), encoding: .utf8),
            let path = text.split(separator: "\n").first, path.hasPrefix("/")
        else { return nil }
        let image = URL(filePath: String(path))
        return FileManager.default.fileExists(atPath: image.path) ? image : nil
    }

    static func newest(_ files: [URL]) -> URL? {
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
        return files.max { modified($0) < modified($1) }
    }

    static func isBuildFolder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasSuffix("_build") else { return false }
        let id = name.dropLast("_build".count)
        return id.count == 16 && id.allSatisfy(\.isHexDigit) && isDirectory(url)
    }

    static func children(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
