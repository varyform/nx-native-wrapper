import Foundation

/// Which games two Macs both have: a games folder can be on a disk both reach (a file server, a shared drive), under
/// another path on each. Each games folder gets a hidden `.nxplay-folder-id` file with an id of its own, so a game is
/// the same one on both Macs when its folder has the same id and the same place in it.
enum SharedFolders {
    static let markerName = ".nxplay-folder-id"

    /// The games folder's id, made the first time (nil when the folder can't be written and has none).
    static func id(of root: URL) -> String? {
        let file = root.appending(path: markerName)
        if let id = read(file) { return id }
        let made = UUID().uuidString
        // the folder may be shared with a Mac making its own at the same moment: whichever is written first wins
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if descriptor >= 0 {
            _ = made.withCString { write(descriptor, $0, strlen($0)) }
            close(descriptor)
        }
        return read(file)
    }

    /// Where the game is: its games folder's id and its folder's path inside it ("" for a game's own folder).
    static func key(of game: URL, roots: [URL], ids: inout [URL: String]) -> String? {
        let path = game.standardizedFileURL.path
        for root in roots {
            let base = root.standardizedFileURL.path
            let inside: String
            if path == base {
                inside = ""
            } else if path.hasPrefix(base.hasSuffix("/") ? base : base + "/") {
                inside = String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                continue
            }
            if ids[root] == nil { ids[root] = id(of: root) }
            guard let id = ids[root] else { return nil }
            return id + "/" + inside.lowercased()
        }
        return nil
    }

    private static func read(_ file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}
