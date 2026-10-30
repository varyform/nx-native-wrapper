import Darwin
import Foundation

/// What Free Up Space can delete, per game, with sizes: run it off the main thread.
public enum CleanupScanner {
    /// Without `measuring`, the big folders (builds, Xcode builds) are listed unmeasured, for `measure` to fill in.
    public static func groups(games: [Game], busy: Set<Game.ID> = [], measuring: Bool = true)
        -> [CleanupGroup]
    {
        games.compactMap { game in
            let files = files(of: game, busy: busy.contains(game.id), measuring: measuring)
            return files.isEmpty ? nil : CleanupGroup(game: game, files: files)
        }
    }

    /// A big folder's size: from the cache while the folder is unchanged since it was measured, else walked.
    static func measure(_ file: CleanupFile, cache: SizeCache? = nil) -> CleanupFile {
        var file = file
        let stamp = SizeCache.stamp(of: file)
        if let cache, let stamp, let size = cache.size(of: file.url, stamp: stamp) {
            file.size = size
        } else {
            file.size =
                switch file.role {
                case .build: buildContents(file.url).reduce(0) { $0 + size(of: $1) }
                // a Mac app is APFS clones of its build's files: what deleting it frees is what isn't shared
                case .macApp: size(of: file.url, ownOnly: true) + size(of: appKey(file.url))
                default: size(of: file.url)
                }
            if let cache, let stamp { cache.store(file.size, of: file.url, stamp: stamp) }
        }
        file.measuring = false
        return file
    }

    static func files(of game: Game, busy: Bool, measuring: Bool = true) -> [CleanupFile] {
        func list(_ folder: URL?, _ extensions: Set<String>, _ role: CleanupFile.Role)
            -> [CleanupFile]
        {
            guard let folder else { return [] }
            return GameScanner.children(of: folder)
                .filter {
                    extensions.contains($0.pathExtension.lowercased())
                        && !GameScanner.isDirectory($0)
                }
                .sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                        == .orderedAscending
                }
                .map {
                    CleanupFile(
                        url: $0, size: size(of: $0), role: role,
                        blocked: blocked(role, game, busy: busy))
                }
        }
        var files =
            list(game.folder, GameScanner.packageExtensions, .original)
            + list(
                game.buildFolder?.appending(path: "nsp", directoryHint: .isDirectory),
                ["nsp", "xci"], .converted)
        // listed when there is something to remove; measured now or later
        func big(_ url: URL, _ role: CleanupFile.Role) -> CleanupFile {
            let file = CleanupFile(
                url: url, size: 0, measuring: true, role: role,
                blocked: blocked(role, game, busy: busy))
            return measuring ? measure(file) : file
        }
        if let build = game.buildFolder, !buildContents(build).isEmpty {
            files.append(big(build, .build))
        }
        files += list(game.folder, ["ipa"], .ipa)
        if let xcode = game.buildFolder?.appending(
            path: "xcode-derived-data", directoryHint: .isDirectory),
            GameScanner.isDirectory(xcode)
        {
            files.append(big(xcode, .xcodeBuild))
        }
        files += macApps(in: game.folder).map { big($0, .macApp) }
        return files
    }

    /// nxnative's apps in a game folder: `<name>.app` with its Mac host inside, not any app that happens to be there.
    static func macApps(in folder: URL) -> [URL] {
        GameScanner.children(of: folder)
            .filter {
                $0.pathExtension == "app"
                    && FileManager.default.isExecutableFile(
                        atPath: $0.appending(path: "Contents/MacOS/dmhost").path)
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
    }

    /// `<name>.app.key` beside an app: nxnative's record of what it packed.
    static func appKey(_ app: URL) -> URL {
        app.deletingLastPathComponent().appending(path: app.lastPathComponent + ".key")
    }

    /// Game files go only once the game is built for the Mac: it keeps playing from its build. A build goes only while
    /// the game files are there to build it again (and not while kept). IPAs and Xcode builds can always go: Build IPA
    /// and Install on Device make them again. Nothing goes while the game is building or running.
    static func blocked(_ role: CleanupFile.Role, _ game: Game, busy: Bool) -> String? {
        if busy { return "Busy: wait until its build or game finishes." }
        if role == .build {
            // the build is how a game without its files still plays: without either, it couldn't come back
            if !game.hasPackages {
                return "No game files to build it again from: it would no longer play."
            }
            if game.isCopying { return "Its game files are still being copied in." }
            return game.isKept ? "Kept: turn off Keep This Build first." : nil
        }
        guard role == .original || role == .converted else { return nil }
        if game.isCopying { return "Still being copied into the folder." }
        return switch game.state {
        case .ready: nil
        case .extracted: "Not built for the Mac yet: play it once first."
        case .notExtracted: "Not extracted: these files are the game."
        }
    }

    /// What removing a build deletes: everything in `<id>_build` but the saves (`run/save*`: the save, the device
    /// save, their cloud sync record and backups), which nothing can make again, when it was last played (Console
    /// Mode's order), and what Free Up Space lists on its own: the NSPs converted from NSZ (`nsp/`) and the Xcode
    /// build.
    static func buildContents(_ build: URL) -> [URL] {
        let kept: Set<String> = ["run", "nsp", "xcode-derived-data"]
        let run = build.appending(path: "run", directoryHint: .isDirectory)
        return GameScanner.children(of: build).filter { !kept.contains($0.lastPathComponent) }
            + GameScanner.children(of: run).filter {
                !$0.lastPathComponent.hasPrefix("save") && $0.lastPathComponent != "last_played"
            }
    }

    /// Space on disk, a folder with everything in it. fts, as du walks: it reads each folder's entries with their
    /// sizes in one go, where a URL enumerator asks for each file's values on its own (Tears of the Kingdom's 514,000
    /// shader files: 3.8 s against 6.1 s with the disk's cache warm). Hard links count once. `ownOnly`: only what no
    /// APFS clone shares, what deleting it would free (a Mac app's 4.9 GB of clones of its build free 30 MB); where
    /// the volume can't tell, everything.
    static func size(of url: URL, ownOnly: Bool = false) -> Int64 {
        let path = url.path(percentEncoded: false)
        return path.withCString { cPath -> Int64 in
            var paths: [UnsafeMutablePointer<CChar>?] = [strdup(cPath), nil]
            defer { free(paths[0]) }
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return 0 }
            defer { fts_close(fts) }
            var total: Int64 = 0
            var seen = Set<[UInt64]>()
            while let entry = fts_read(fts) {
                let info = Int32(entry.pointee.fts_info)
                guard info == FTS_F || info == FTS_SL || info == FTS_DEFAULT,
                    let stat = entry.pointee.fts_statp?.pointee
                else { continue }
                if stat.st_nlink > 1, !seen.insert([UInt64(stat.st_dev), stat.st_ino]).inserted {
                    continue
                }
                let own = ownOnly && info == FTS_F ? privateSize(entry.pointee.fts_accpath) : nil
                total += own ?? Int64(stat.st_blocks) * 512
            }
            return total
        }
    }
}

extension CleanupScanner {
    /// A file's bytes that no APFS clone shares (ATTR_CMNEXT_PRIVATESIZE); nil where the volume doesn't say.
    static func privateSize(_ path: UnsafePointer<CChar>?) -> Int64? {
        guard let path else { return nil }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        // the length, the returned attributes, then the size
        var buffer = [UInt8](repeating: 0, count: 64)
        guard
            getattrlist(
                path, &list, &buffer, buffer.count,
                UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)) == 0
        else { return nil }
        return buffer.withUnsafeBytes { raw in
            let returned = raw.load(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            return raw.loadUnaligned(
                fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: Int64.self)
        }
    }
}

/// Big folders' sizes as last measured, kept across launches: a build's size changes only when it is built again,
/// so opening Free Up Space doesn't walk hundreds of thousands of files each time. An entry holds while the folder's
/// stamp is the same: the newest modification time among the folder and its first level (a rebuild rewrites the
/// launcher and the patched modules there; a play writes `run/`, which a build's size leaves out).
final class SizeCache: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var entries: [String: Entry]

    struct Entry: Codable {
        let stamp: Double
        let size: Int64
    }

    init(file: URL = SizeCache.defaultFile) {
        self.file = file
        entries =
            (try? Data(contentsOf: file)).flatMap {
                try? JSONDecoder().decode([String: Entry].self, from: $0)
            }
            ?? [:]
    }

    static var defaultFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "com.varyform.nxplay/sizes.json")
    }

    func size(of url: URL, stamp: Double) -> Int64? {
        lock.withLock { entries[url.path].flatMap { $0.stamp == stamp ? $0.size : nil } }
    }

    func store(_ size: Int64, of url: URL, stamp: Double) {
        let data = lock.withLock { () -> Data? in
            entries[url.path] = Entry(stamp: stamp, size: size)
            return try? JSONEncoder().encode(entries)
        }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data?.write(to: file, options: .atomic)
    }

    /// The folder's own modification time and its first level's (for a build, the parts its size counts). A Mac app's
    /// own share also changes when its build does (removed, its clones become the app's alone): the game folder's
    /// build folders count too.
    static func stamp(of file: CleanupFile) -> Double? {
        let builds =
            file.role == .macApp
            ? GameScanner.children(of: file.url.deletingLastPathComponent()).filter {
                $0.lastPathComponent.hasSuffix("_build")
            } : []
        let items =
            [file.url] + builds
            + (file.role == .build
                ? CleanupScanner.buildContents(file.url) : GameScanner.children(of: file.url))
        let dates = items.compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        return dates.max()?.timeIntervalSince1970
    }
}
