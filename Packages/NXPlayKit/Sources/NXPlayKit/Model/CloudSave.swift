import CryptoKit
import Darwin
import Foundation

/// nxnative's cloud saves (DM_SAVE_SYNC) seen from before a play: the save here, the one in the cloud folder's
/// `<title ID>/save.dmsync` and the one last synced (`<save>.sync`), compared as the host's save sync does
/// (dm/host/save_sync.c), so Play can ask the player when both changed instead of the newer one winning.
public enum CloudSave {
    /// A save as the save sync sees it: its hash ("" for no save), the newest file's time, where it was saved.
    public struct Snapshot: Equatable, Sendable {
        public let hash: String
        public let saved: Date?
        /// The model the cloud's save came from ("iPhone17,1"); empty for this Mac's.
        public var device = ""
    }

    /// What the start has to decide: nothing (the host goes the one way there is), a save on each side that changed
    /// since they were last the same, or nothing it can know: the cloud's save is there but couldn't be read (iCloud
    /// couldn't download it, offline).
    public enum Check: Equatable, Sendable {
        case nothingToChoose
        case bothChanged(here: Snapshot, cloud: Snapshot)
        case cloudUnread
    }

    /// DM_SAVE_SYNC_CHOICE: set at every start, which tells the host the player is asked, so it never picks between
    /// two changed saves on its own. A choice names the cloud's save it was made on: if that one changed since the
    /// check, the host uses neither.
    public enum Choice: Equatable, Sendable {
        case none, cloud(String), here(String)
        /// The cloud's save couldn't be read before the play: the host doesn't wait for it again, and with both saves
        /// changed replaces neither, so the next play asks. `ask` is only for a play that compared the two.
        case offline

        var environment: String {
            switch self {
            case .none: "ask"
            case .offline: "offline"
            case .cloud(let hash): "cloud:\(hash)"
            case .here(let hash): "local:\(hash.isEmpty ? "none" : hash)"
            }
        }
    }

    /// The cloud's file for the game (save_sync.c cloud_file): `icloud` is iCloud Drive › nxnative Saves, a folder
    /// already named after the title ID is the game's own. Nil with cloud saves off.
    static func file(target: String, titleID: String, home: URL) -> URL? {
        guard target != "0", !target.isEmpty else { return nil }
        var folder =
            target == "icloud"
            ? home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/nxnative Saves").path
            : target
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        let id = titleID.uppercased()
        let base = URL(filePath: folder, directoryHint: .isDirectory)
        let own = base.lastPathComponent.caseInsensitiveCompare(id) == .orderedSame
        return (own ? base : base.appending(path: id, directoryHint: .isDirectory)).appending(path: "save.dmsync")
    }

    /// ss_decide's "both": each side has a save, they differ, and neither is the one last synced (or there's no
    /// sync yet). A cloud file that isn't this game's leaves nothing to choose: the host decides.
    static func check(save: URL, cloud: URL, titleID: String) -> Check {
        let bytes: Data?
        do { bytes = try headerBytes(of: cloud) } catch { return .cloudUnread }
        guard let bytes, let remote = header(bytes, titleID: titleID), let here = scan(save) else {
            return .nothingToChoose
        }
        let base = self.base(of: save)
        guard !remote.hash.isEmpty, !here.hash.isEmpty, here.hash != remote.hash,
            base.isEmpty || (here.hash != base && remote.hash != base)
        else { return .nothingToChoose }
        return .bothChanged(here: here, cloud: remote)
    }

    // MARK: - The formats (save_sync.c)

    /// The header of a packed save: "DMSYNC1\n", u32 version 1, u32 entries, 32 hex digits of the hash, i64 saved,
    /// char title[24], char device[64]. Only the header is read: the rest is the host's to check.
    static func header(of file: URL, titleID: String) -> Snapshot? {
        (try? headerBytes(of: file)).flatMap { $0 }.flatMap { header($0, titleID: titleID) }
    }

    private static func header(_ data: Data, titleID: String) -> Snapshot? {
        guard data.count == 144, data.prefix(8) == Data("DMSYNC1\n".utf8), integer(data, at: 8, UInt32.self) == 1
        else { return nil }
        let title = text(data, 56..<80)
        guard title.caseInsensitiveCompare(titleID) == .orderedSame else { return nil }
        let hash = text(data, 16..<48)
        guard hash.isEmpty || (hash.count == 32 && hash.allSatisfy(\.isHexDigit)) else { return nil }
        let saved = integer(data, at: 48, Int64.self)
        return Snapshot(
            hash: hash, saved: saved > 0 ? Date(timeIntervalSince1970: TimeInterval(saved)) : nil,
            device: text(data, 80..<144))
    }

    /// A packed save's first 144 bytes (fewer for a file that isn't one); nil when there's no file. Throws when the
    /// file is there and can't be read: reading one iCloud keeps only listed downloads it, and fails offline.
    static func headerBytes(of file: URL) throws -> Data? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            if !FileManager.default.fileExists(atPath: file.path) { return nil }
            throw error
        }
        defer { try? handle.close() }
        return try handle.read(upToCount: 144) ?? Data()
    }

    /// `<save>.sync`'s `base` line: the hash of the save last the same here and in the cloud, "" for none.
    static func base(of save: URL) -> String {
        let file = URL(filePath: save.path + ".sync")
        let lines = (try? String(contentsOf: file, encoding: .utf8))?.split(whereSeparator: \.isNewline) ?? []
        return lines.compactMap { line -> String? in
            guard line.hasPrefix("base\t") else { return nil }
            let hash = String(line.dropFirst(5).prefix(32))
            return hash.count == 32 && hash.allSatisfy({ "0123456789abcdef".contains($0) }) ? hash : nil
        }.last ?? ""
    }

    /// ss_scan: the hash runs over every entry of `save` and `<save>_device` (a folder with nothing but Finder's
    /// .DS_Store is no save), depth first, names in byte order, without .DS_Store or links: each entry's first 16
    /// header bytes (type, path and guest-name lengths, size), its path, its guest name and a file's contents. The
    /// first 16 bytes of the SHA-256, in hex. Nil when a file can't be read.
    static func scan(_ save: URL) -> Snapshot? {
        var scan = Scan()
        for (folder, name) in [(save.path, "save"), (save.path + "_device", "save_device")]
        where hasEntries(folder) {
            guard scan.walk(folder, name) else { return nil }
        }
        guard scan.files > 0 else { return Snapshot(hash: "", saved: nil) }
        let hash = scan.sha.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
        return Snapshot(hash: hash, saved: Date(timeIntervalSince1970: TimeInterval(scan.saved)))
    }

    private struct Scan {
        var sha = SHA256()
        var files = 0
        var saved: Int64 = 0

        mutating func walk(_ folder: String, _ relative: String) -> Bool {
            guard let names = CloudSave.names(folder) else { return false }
            for name in names where name != ".DS_Store" {
                let path = folder + "/" + name, rel = relative + "/" + name
                var info = Darwin.stat()
                guard lstat(path, &info) == 0 else { return false }
                switch info.st_mode & S_IFMT {
                case S_IFDIR: guard entry(path, rel, info, file: false), walk(path, rel) else { return false }
                case S_IFREG: guard entry(path, rel, info, file: true) else { return false }
                default: continue  // links: the host never makes one in a save
                }
            }
            return true
        }

        private mutating func entry(_ path: String, _ rel: String, _ info: Darwin.stat, file: Bool) -> Bool {
            let guest = CloudSave.guestName(path)
            let relBytes = Array(rel.utf8)
            guard relBytes.count <= UInt16.max else { return false }
            var header = [UInt8](repeating: 0, count: 16)
            header[0] = file ? 2 : 1
            header.replaceSubrange(2..<4, with: withUnsafeBytes(of: UInt16(relBytes.count).littleEndian, Array.init))
            header.replaceSubrange(4..<6, with: withUnsafeBytes(of: UInt16(guest.count).littleEndian, Array.init))
            let size = file ? UInt64(info.st_size) : 0
            header.replaceSubrange(8..<16, with: withUnsafeBytes(of: size.littleEndian, Array.init))
            sha.update(data: header)
            sha.update(data: relBytes)
            sha.update(data: guest)
            guard file else { return true }
            guard let handle = FileHandle(forReadingAtPath: path) else { return false }
            defer { try? handle.close() }
            var left = size
            while left > 0 {
                guard let chunk = try? handle.read(upToCount: Int(min(left, 1 << 16))), !chunk.isEmpty
                else { return false }  // shorter than its size: being written
                sha.update(data: chunk)
                left -= UInt64(chunk.count)
            }
            files += 1
            saved = max(saved, Int64(info.st_mtimespec.tv_sec))
            return true
        }
    }

    /// A folder's names in byte order (strcmp), without . and ..; nil when it can't be read.
    private static func names(_ folder: String) -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return nil }
        return names.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    private static func hasEntries(_ folder: String) -> Bool {
        names(folder)?.contains { $0 != ".DS_Store" } ?? false
    }

    /// hle_fs.c's guest name: the game's own name for a file whose host name had to differ (a case collision).
    private static func guestName(_ path: String) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let got = getxattr(path, "org.d2rmobile.guest-name", &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        return got > 0 ? Array(buffer.prefix(got)) : []
    }

    private static func integer<T: FixedWidthInteger>(_ data: Data, at offset: Int, _: T.Type) -> T {
        data.subdata(in: offset..<offset + MemoryLayout<T>.size).withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
    }

    /// A NUL-padded field.
    private static func text(_ data: Data, _ range: Range<Int>) -> String {
        String(decoding: data.subdata(in: range).prefix { $0 != 0 }, as: UTF8.self)
    }
}
