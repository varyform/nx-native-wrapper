import CryptoKit
import Darwin
import Foundation

/// A game's NSZ or XCZ and the NSP or XCI nxnative unpacked it to in `<build>/nsp/`. With "Keep only the unpacked
/// copy" on, the unpacked file takes the compressed one's place in the game folder: the library holds one copy of the
/// game instead of two, and no build unpacks it again.
public enum CompressedPackages {
    public struct Pair: Hashable, Sendable {
        public let compressed: URL
        public let unpacked: URL
        /// What moving the compressed file away frees.
        public let size: Int64

        /// nxnative's record of the conversion: its source's name, size and modification time.
        var record: URL { unpacked.deletingLastPathComponent().appending(path: unpacked.lastPathComponent + ".key") }
        /// Beside the compressed file, under the unpacked file's name.
        var destination: URL {
            compressed.deletingLastPathComponent().appending(path: unpacked.lastPathComponent)
        }
    }

    /// nxnative's COMPRESSED: what nsz -D makes of each.
    static let unpackedExtensions = ["nsz": "nsp", "xcz": "xci"]

    /// The game's compressed files that nxnative unpacked completely from exactly that file: its record names the
    /// file as it is now (a replaced NSZ doesn't match), and a file under the unpacked name isn't already beside it.
    static func pairs(of game: Game) -> [Pair] {
        guard let build = game.buildFolder else { return [] }
        let converted = build.appending(path: "nsp", directoryHint: .isDirectory)
        return GameScanner.children(of: game.folder)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { file -> Pair? in
                guard let ext = unpackedExtensions[file.pathExtension.lowercased()],
                    let stat = stat(of: file), stat.isFile
                else { return nil }
                let unpacked = converted.appending(
                    path: file.deletingPathExtension().lastPathComponent + "." + ext)
                let pair = Pair(compressed: file, unpacked: unpacked, size: stat.size)
                guard let made = Self.stat(of: unpacked), made.isFile, made.size > 0,
                    let record = try? String(contentsOf: pair.record, encoding: .utf8),
                    record.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init)
                        == fingerprint(name: file.lastPathComponent, size: stat.size, modified: stat.modified),
                    !FileManager.default.fileExists(atPath: pair.destination.path)
                else { return nil }
                return pair
            }
    }

    /// The unpacked file into the game folder, then the compressed one away (`remove`: to the Trash) and the
    /// record with it. Moved back when the compressed one can't go: nxnative would find the game twice.
    static func swap(_ pair: Pair, remove: (URL) throws -> Void = trash) throws {
        let files = FileManager.default
        try files.moveItem(at: pair.unpacked, to: pair.destination)
        do {
            try remove(pair.compressed)
        } catch {
            try? files.moveItem(at: pair.destination, to: pair.unpacked)
            throw error
        }
        try? files.removeItem(at: pair.record)
    }

    static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// nxnative's fingerprint(name, size, mtime_ns) (decompress_nsz): sha256 over each item's Python repr, each
    /// after "\0repr\0".
    static func fingerprint(name: String, size: Int64, modified: Int64) -> String {
        var hash = SHA256()
        for item in [pythonRepr(name), String(size), String(modified)] {
            hash.update(data: Data("\0repr\0".utf8))
            hash.update(data: Data(item.utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Python's repr of a str: single quotes unless the text has one and no double quote; backslashes, the quote
    /// and control characters escaped. Anything it gets wrong only fails to match, and the files stay as they are.
    static func pythonRepr(_ text: String) -> String {
        let quote: Character = text.contains("'") && !text.contains("\"") ? "\"" : "'"
        var out = String(quote)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where Character(scalar) == quote: out += "\\" + String(quote)
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\x%02x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + String(quote)
    }

    struct FileStat {
        let isFile: Bool
        let size: Int64
        /// st_mtime_ns, as Python's stat gives it.
        let modified: Int64
    }

    static func stat(of url: URL) -> FileStat? {
        var info = Darwin.stat()
        // fstatat: Darwin.stat names the struct here; follows a link, as Python's stat does
        guard fstatat(AT_FDCWD, url.path, &info, 0) == 0 else { return nil }
        return FileStat(
            isFile: info.st_mode & S_IFMT == S_IFREG, size: Int64(info.st_size),
            modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec))
    }
}
