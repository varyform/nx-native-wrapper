import Foundation

/// One file of a game save: its path inside the save folder, size and last change.
public struct SaveFile: Hashable, Sendable {
    public let path: String
    public let size: Int
    public let modified: Date

    public init(path: String, size: Int, modified: Date) {
        self.path = path
        self.size = size
        self.modified = modified
    }

    /// The files under a save folder on this Mac; none when it does not exist. Hidden files (Finder's
    /// .DS_Store) are not the game's: they are neither compared nor copied to a device.
    public static func list(_ folder: URL) -> [SaveFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard
            let walk = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        let base = folder.resolvingSymlinksInPath().path + "/"
        return walk.compactMap { item -> SaveFile? in
            guard let url = item as? URL, let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { return nil }
            let path = url.resolvingSymlinksInPath().path
            return SaveFile(
                path: path.hasPrefix(base)
                    ? String(path.dropFirst(base.count)) : url.lastPathComponent,
                size: values.fileSize ?? 0,
                modified: values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.path < $1.path }
    }
}

/// The Mac's save beside a device's, file by file.
public struct SaveComparison: Sendable {
    public enum Side: Sendable { case mac, device }

    public enum Status: Sendable {
        case same
        case newer(Side)
        case only(Side)
        /// Same time, different size: neither can be called newer.
        case differs
    }

    public struct Row: Identifiable, Sendable {
        public let path: String
        public let mac: SaveFile?
        public let device: SaveFile?
        public let status: Status
        public var id: String { path }
    }

    public let rows: [Row]

    /// Copies keep the modification time; the device reports whole seconds.
    static let tolerance: TimeInterval = 2

    public init(mac: [SaveFile], device: [SaveFile]) {
        let macFiles = Dictionary(mac.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let deviceFiles = Dictionary(device.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        rows = Set(macFiles.keys).union(deviceFiles.keys).sorted().map { path in
            let (m, d) = (macFiles[path], deviceFiles[path])
            let status: Status =
                switch (m, d) {
                case (let m?, let d?):
                    if abs(m.modified.timeIntervalSince(d.modified)) < Self.tolerance {
                        m.size == d.size ? .same : .differs
                    } else {
                        .newer(m.modified > d.modified ? .mac : .device)
                    }
                case (_?, nil): .only(.mac)
                default: .only(.device)
                }
            return Row(path: path, mac: m, device: d, status: status)
        }
    }

    public var isIdentical: Bool {
        rows.allSatisfy { if case .same = $0.status { true } else { false } }
    }

    /// The latest change on each side.
    public func latest(_ side: Side) -> Date? {
        rows.compactMap { side == .mac ? $0.mac?.modified : $0.device?.modified }.max()
    }

    /// The side whose save changed last, when the two differ.
    public var newer: Side? {
        guard !isIdentical else { return nil }
        switch (latest(.mac), latest(.device)) {
        case (let m?, let d?): return m >= d ? .mac : .device
        case (_?, nil): return .mac
        case (nil, _?): return .device
        default: return nil
        }
    }
}

/// A game's save as nxnative keeps it: the save folder (DM_SAVE) and what it writes beside it, the device save
/// (`<save>_device`), the saves of local users 2 to 8 (`<save>_user2`…`_user8`) and their registry (`<save>.users`, a
/// file). nxnative's docs/frontends.md asks a front end to move and back these up together.
enum SaveSet {
    struct Member: Equatable {
        /// What follows the save's name: "" for the save itself, "_device", "_user2", ".users".
        let suffix: String
        let url: URL
        let isFolder: Bool
    }

    static let folderSuffixes = [""] + ["_device"] + (2...8).map { "_user\($0)" }
    static let registrySuffix = ".users"

    /// The members that exist, the save first.
    static func members(of save: URL) -> [Member] {
        let base = save.standardizedFileURL.path.trimmingSuffix("/")
        let folders = folderSuffixes.compactMap { suffix -> Member? in
            let url = URL(filePath: base + suffix, directoryHint: .isDirectory)
            return GameScanner.isDirectory(url) ? Member(suffix: suffix, url: url, isFolder: true) : nil
        }
        let registry = URL(filePath: base + registrySuffix, directoryHint: .notDirectory)
        let file = FileManager.default.fileExists(atPath: registry.path) && !GameScanner.isDirectory(registry)
        return folders + (file ? [Member(suffix: registrySuffix, url: registry, isFolder: false)] : [])
    }

    /// Every file of the set, its path under the save's for the save itself and under the suffix for the others
    /// (`_device/d.bin`, `_user2/slot.bin`, `.users`), one list to compare.
    static func files(_ save: URL) -> [SaveFile] {
        members(of: save).flatMap { member -> [SaveFile] in
            guard member.isFolder else {
                let values = try? member.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return [
                    SaveFile(
                        path: member.suffix, size: values?.fileSize ?? 0,
                        modified: values?.contentModificationDate ?? .distantPast)
                ]
            }
            let files = SaveFile.list(member.url)
            guard !member.suffix.isEmpty else { return files }
            return files.map {
                SaveFile(path: member.suffix + "/" + $0.path, size: $0.size, modified: $0.modified)
            }
        }
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        var s = self
        while s.count > 1, s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        return s
    }
}
