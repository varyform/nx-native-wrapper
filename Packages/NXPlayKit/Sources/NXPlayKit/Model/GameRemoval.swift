import Foundation

/// Game › Remove Game…: what removing a game deletes, and what stays. Only what NX Play and nxnative put in the game's
/// folder goes: the game files, the build, the survey, the IPAs and the Mac app; anything else the player keeps there
/// (a mod, notes) stays, and the folder goes only once it is empty.
///
/// The saves stay unless the player asks otherwise: in the build's `run/` (the save, the device save, their backups
/// and cloud-sync record, and when it was last played), which the library doesn't count as a game on its own. Put the
/// game files back in the folder and the game plays on from them.
public struct GameRemoval: Sendable {
    public let game: Game
    /// Deleted.
    public let items: [URL]
    /// The saves: left in place, or deleted with the rest when `removesSaves`.
    public let saves: [URL]
    /// The Mac app's own data (`~/Library/Application Support/nxnative/<title ID>`: its save), when it has any;
    /// deleted only with the saves.
    public let appData: URL?
    /// What else is in the folder, which stays.
    public let others: [URL]
    public let removesSaves: Bool

    /// The phrases one of which the player types to confirm: no apostrophes, which keyboards write two ways.
    public static let phrases = [
        "Yes, remove the game", "I do not like it anymore", "Yes, I am sure",
    ]

    public init(
        game: Game, removesSaves: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.game = game
        self.removesSaves = removesSaves
        let entries = GameScanner.children(of: game.folder)
        let titleID = game.titleID?.uppercased()
        func ours(_ url: URL) -> Bool {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            if GameScanner.packageExtensions.contains(ext) || ext == "ipa" { return true }
            // nxnative's Mac app and the stamp it keeps beside it
            if ext == "app" || name.hasSuffix(".app.key") { return true }
            let stem = name.split(separator: "_").first.map(String.init)?.uppercased()
            return stem == titleID && (name.hasSuffix("_build") || name.hasSuffix("_survey"))
        }
        let builds = entries.filter { ours($0) && $0.lastPathComponent.hasSuffix("_build") }
        let saves = builds.flatMap { build in
            GameScanner.children(of: build.appending(path: "run", directoryHint: .isDirectory))
                .filter {
                    $0.lastPathComponent.hasPrefix("save") || $0.lastPathComponent == "last_played"
                }
        }
        self.saves = saves
        // what's ours goes whole, but a build whose saves stay: everything in it except them
        let whole = entries.filter { ours($0) && (removesSaves || !builds.contains($0)) }
        let partial =
            removesSaves
            ? []
            : builds.flatMap { build in
                GameScanner.children(of: build).filter { $0.lastPathComponent != "run" }
                    + GameScanner.children(
                        of: build.appending(path: "run", directoryHint: .isDirectory)
                    ).filter { !saves.contains($0) }
            }
        items = whole + partial
        others = entries.filter { !ours($0) }
        let data = titleID.map {
            home.appending(
                path: "Library/Application Support/nxnative/\($0)", directoryHint: .isDirectory)
        }
        appData = data.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    private var deleted: [URL] { items + (removesSaves ? appData.map { [$0] } ?? [] : []) }

    /// Space it frees: run it off the main thread (a build can hold half a million files).
    public func size() -> Int64 {
        deleted.reduce(0) { $0 + CleanupScanner.size(of: $1) }
    }

    /// Deletes for good, then the folder itself when nothing is left in it. → what couldn't be deleted.
    public func perform() -> [String] {
        var failures: [String] = []
        let fm = FileManager.default
        for item in deleted {
            do {
                try fm.removeItem(at: item)
            } catch {
                failures.append("\(item.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // the folder goes once empty (Finder's .DS_Store aside)
        let left = (try? fm.contentsOfDirectory(atPath: game.folder.path)) ?? []
        if left.allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(at: game.folder) }
        return failures
    }
}
