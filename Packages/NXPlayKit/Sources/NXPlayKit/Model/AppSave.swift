import Foundation

/// Which save Play uses when a game's Mac app keeps one of its own: NX Play's (the build's `run/save`), the app's, or
/// whichever was saved last.
public enum SaveChoice: String, CaseIterable, Sendable {
    case nxplay, app, newer
}

/// A Mac app's own save, in `~/Library/Application Support/nxnative/<title ID>/save`, beside NX Play's. An app opened
/// from Finder before NX Play pointed it at the game's save (nxplay's share_save) keeps playing on from its own, so the
/// two can hold different progress, and Play, which starts the app with NX Play's save, looked like it lost one.
public struct AppSave: Sendable {
    /// The app's own save (nxplay's NXPLAY_SAVE=app plays on from it).
    public let folder: URL
    /// NX Play's on one side (`mac`), the app's on the other (`device`).
    public let comparison: SaveComparison

    /// The line nxplay's share_save writes into the app's env.txt when it points the app at NX Play's save.
    static let mark = "# nxplay: the save NX Play plays this game with"

    /// Nil when there's nothing to choose: no Mac app or build, the app plays on from NX Play's save (or a folder the
    /// player set in its env.txt), or it hasn't saved yet.
    public init?(game: Game, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        guard game.macAppURL != nil, let id = game.titleID?.uppercased(),
            let build = game.buildFolder
        else { return nil }
        let support = home.appending(
            path: "Library/Application Support/nxnative/\(id)", directoryHint: .isDirectory)
        let env = (try? String(contentsOf: support.appending(path: "env.txt"), encoding: .utf8)) ?? ""
        if env.split(whereSeparator: \.isNewline).contains(where: {
            $0.contains(Self.mark) || $0.hasPrefix("DM_SAVE=")
        }) {
            return nil
        }
        folder = support.appending(path: "save", directoryHint: .isDirectory)
        let app = Self.files(folder)
        guard !app.isEmpty else { return nil }
        comparison = SaveComparison(
            mac: Self.files(build.appending(path: "run/save", directoryHint: .isDirectory)),
            device: app)
    }

    /// The save and the device save beside it (nxnative's `<DM_SAVE>_device`), one list.
    static func files(_ save: URL) -> [SaveFile] {
        let device = URL(filePath: save.path + "_device", directoryHint: .isDirectory)
        return SaveFile.list(save)
            + SaveFile.list(device).map {
                SaveFile(path: "_device/" + $0.path, size: $0.size, modified: $0.modified)
            }
    }

    public var differs: Bool { !comparison.isIdentical }
    public var nxplaySaved: Date? { comparison.latest(.mac) }
    public var appSaved: Date? { comparison.latest(.device) }
    public var appIsNewer: Bool { comparison.newer == .device }

    /// Whether Play uses the app's save with this choice.
    public func usesApp(_ choice: SaveChoice) -> Bool {
        switch choice {
        case .nxplay: false
        case .app: true
        case .newer: appIsNewer
        }
    }
}
