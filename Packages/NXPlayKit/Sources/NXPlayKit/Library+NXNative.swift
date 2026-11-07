import Foundation

/// A game pinned to its own nxnative checkout: a `nxnative` symlink (or folder) in the game's folder,
/// used for every nxplay invocation of that game — extract, rebuild, play, IPA, Mac app and device
/// install — instead of the shared checkout. Forks and branches both come through the same path: a
/// fork is a checkout of it, a branch is a worktree on it (one folder each, no switching a shared
/// checkout under a queued build). nxplay pulls each game's own checkout when it updates, so a
/// branch with no upstream stays frozen while the shared one keeps following nxnative.
/// The link is made by hand — `ln -s <checkout> "<game folder>/nxnative"` — for the people testing
/// nxnative branches, not a thing every player needs in the Game menu.
extension Library {
    /// The item in a game's folder that pins its nxnative checkout.
    nonisolated static let ownNXNativeName = "nxnative"

    /// The checkout a game builds and plays with: its own when it names a valid one, else Settings'.
    func nxnativeRepo(for game: Game) -> String {
        Self.ownRepo(in: game.folder) ?? (nxnativePath as NSString).expandingTildeInPath
    }

    /// `<game folder>/nxnative` resolved to a checkout: a symlink's target or the folder itself,
    /// nil when it isn't there or names no nxnative checkout (the same test Settings makes).
    nonisolated static func ownRepo(in folder: URL) -> String? {
        let item = folder.appending(path: ownNXNativeName)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.path, isDirectory: &directory),
            directory.boolValue
        else { return nil }   // fileExists follows the link; a dangling one reads as absent
        let path =
            (try? FileManager.default.destinationOfSymbolicLink(atPath: item.path)).map {
                $0.hasPrefix("/")
                    ? $0
                    : folder.appending(path: $0).standardized.path
            } ?? item.path
        return FileManager.default.fileExists(atPath: path + "/scripts/build_ipa_from_nsp.py")
            ? path : nil
    }
}
