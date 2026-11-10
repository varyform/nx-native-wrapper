import Foundation

/// The copies of games installed on a device that Apple's device service (CoreDevice) keeps on the Mac's own disk. For
/// every app that `devicectl device install app` installs it keeps a copy for each device, so that the next install
/// of the app sends only what changed. A game's app holds the whole game (`romfs.img`), so each copy is as big as the
/// game, wherever the games folder is. A copy also stays after the game is installed again from a new build: 10 of
/// this Mac's 37 GB were such older copies (issue #22). The layout is `<bundle ID>/<hash>/<device>/<bundle ID>/`
/// with `Stashed`, `Staged`, `ComputedDelta` and `StashedAppMetadata.plist` in it, a new hash for each new build.
/// The folder is in the service's own container, which macOS opens only to apps with Full Disk Access.
public enum DeviceInstallCopies {
    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(
            path:
                "Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches/AppInstallationBinaryDeltas",
            directoryHint: .isDirectory)
    }

    /// System Settings › Privacy & Security › Full Disk Access.
    public static let fullDiskAccessSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// One device's copy of one build of an app.
    struct Copy: Equatable {
        let url: URL
        let device: String
        let date: Date
    }

    /// Every app's folder; none when nothing was ever installed, nil when macOS doesn't let NX Play see them.
    static func apps(in folder: URL) -> [URL]? {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            return nil
        }
    }

    /// A game's apps: nxnative names them `org.nxnative.<team>.<title ID>`, one for each team that signed one.
    static func apps(of titleID: String, in apps: [URL]) -> [URL] {
        let suffix = "." + titleID.lowercased()
        return apps.filter {
            let name = $0.lastPathComponent.lowercased()
            return name.hasPrefix("org.nxnative.") && name.hasSuffix(suffix) && GameScanner.isDirectory($0)
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func copies(in app: URL) -> [Copy] {
        GameScanner.children(of: app).filter(GameScanner.isDirectory).flatMap { build in
            GameScanner.children(of: build).filter(GameScanner.isDirectory).map {
                Copy(url: $0, device: $0.lastPathComponent, date: date(of: $0))
            }
        }
    }

    /// When the install that made it ended: the service writes its record of the installed app last.
    static func date(of copy: URL) -> Date {
        let inside = GameScanner.children(of: copy).flatMap { [$0, $0.appending(path: "StashedAppMetadata.plist")] }
        return ([copy] + inside).compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        .max() ?? .distantPast
    }

    /// All but each device's newest: the service sends the next install as the changes to what that device has.
    static func older(_ copies: [Copy]) -> [Copy] {
        Dictionary(grouping: copies, by: \.device).values
            .flatMap { $0.sorted { $0.date > $1.date }.dropFirst() }
            .sorted { $0.url.path < $1.url.path }
    }

    /// After an install: the game's older copies go, each device's newest stays for its next install. Returns the
    /// space freed; nothing happens where macOS doesn't let NX Play in.
    @discardableResult
    static func removeOlder(of titleID: String, in folder: URL = folder) -> Int64 {
        guard let all = apps(in: folder) else { return 0 }
        var freed: Int64 = 0
        for app in apps(of: titleID, in: all) {
            for copy in older(copies(in: app)) {
                let size = CleanupScanner.size(of: copy.url)
                guard (try? FileManager.default.removeItem(at: copy.url)) != nil else { continue }
                freed += size
                removeIfEmpty(copy.url.deletingLastPathComponent())
            }
        }
        return freed
    }

    /// A build's folder without copies left (Finder's .DS_Store aside).
    private static func removeIfEmpty(_ folder: URL) {
        guard GameScanner.children(of: folder).isEmpty else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
