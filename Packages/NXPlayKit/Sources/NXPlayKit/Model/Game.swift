import Foundation

/// One subfolder of the games folder: the NSPs of a game (or its NUP, or a dump of its files) and, once built, its
/// `<title ID>_build` folder.
public struct Game: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// Only the packages: nothing extracted yet.
        case notExtracted
        /// The game files are extracted but nxplay has not saved a Mac launcher.
        case extracted
        /// `start_mac.sh` and the Mac host are there: the game starts without a build.
        case ready
    }

    public let folder: URL
    public let name: String
    public let titleID: String?
    public let version: String?
    /// Language codes the game supports (control.nacp); empty before extraction.
    public let languages: [String]
    public let iconURL: URL?
    public let buildFolder: URL?
    /// The IPA build_ipa_from_nsp.py left in the game folder (the newest, when there are several).
    public let ipaURL: URL?
    /// Install on Device's Xcode build (`<id>_build/xcode-derived-data`), kept to make the next install fast.
    /// Stored, not looked up when asked: a card redraws only when its Game changes, so a value read from disk
    /// on the fly kept showing a removed build.
    public let xcodeBuildFolder: URL?
    /// The standalone Mac app Make Mac App packed into the game folder (nxnative's --platform mac-app).
    public var macAppURL: URL? = nil
    /// The game files are there to build from: NSPs, NSZs, XCIs, XCZs or a NUP, or a dump.
    public let hasPackages: Bool
    /// nxnative builds the game from one NUP file, as it can a Switch 2 game (GameNUP).
    public var isNUP = false
    /// nxnative builds the game from a dump of it (`base/`, `updates/`, `dlc/`), as it can a Switch 2 game: no icon or
    /// name of its own (GameDump).
    public var isDump = false
    /// What nxnative builds from isn't encrypted (a NUP or a dump): it needs no prod.keys, and nxnative builds it only
    /// for a game it has a profile for.
    public var isUnencrypted: Bool { isNUP || isDump }
    /// A game file Finder is still copying into the folder: nothing may build from it until it's complete.
    public var isCopying = false
    /// When nxplay last started or ended the game (`run/last_played`); Console Mode puts the latest first.
    public var lastPlayed: Date? = nil
    /// Keep This Build: a `keep` file in the build folder, so nxplay plays the build as it is after an nxnative
    /// update instead of rebuilding it; only Rebuild replaces it.
    public var isKept = false
    /// The Mac app runs older nxnative code than the build, so Play starts the build instead (nxplay's app_is_current):
    /// a rebuild packs it again, or Make Mac App when that couldn't (no game files, a failed pack).
    public var macAppOutdated = false
    public let state: State

    public var id: String { folder.path }
    /// Switch 2 title IDs start with 04 (Switch 1 ones with 01).
    public var isSwitch2: Bool { titleID?.hasPrefix("04") == true }
    public var isExtracted: Bool { state != .notExtracted }
    public var canExtract: Bool { state == .notExtracted && hasPackages && !isCopying }
    /// Builds read the game files: a rebuild, the IPA and Install on Device (which also starts from the NSPs).
    public var canBuildFromFiles: Bool { hasPackages && !isCopying }
    /// The IPA build starts from the NSPs, whatever the Mac build left.
    public var canBuildIPA: Bool { canBuildFromFiles }

    /// A game that works can be kept from automatic rebuilds: it needs a build that plays.
    public var canKeep: Bool { state == .ready || isKept }

    public var keepFile: URL? { buildFolder?.appending(path: GameScanner.keepName) }

    public var logsFolder: URL? { existingFolder("logs") }

    /// The Mac host's save (DM_SAVE in the launcher), kept from run to run.
    public var saveFolder: URL? { existingFolder("run/save") }

    private func existingFolder(_ path: String) -> URL? {
        guard let folder = buildFolder?.appending(path: path, directoryHint: .isDirectory),
            FileManager.default.fileExists(atPath: folder.path)
        else { return nil }
        return folder
    }
}
