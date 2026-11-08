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

    /// The job's line about the game's link, in bug reports too. A link that can't be used says so: a mistyped path
    /// would otherwise look like a test of the branch while the game builds with the shared checkout.
    nonisolated static func ownRepoNote(in folder: URL) -> String? {
        if let own = ownRepo(in: folder) { return "nxnative: using \(own)" }
        let item = folder.appending(path: ownNXNativeName)
        // attributesOfItem looks at the link itself, so a dangling one counts as there
        guard (try? FileManager.default.attributesOfItem(atPath: item.path)) != nil else { return nil }
        return "nxnative: ignoring \(item.path): it isn't an nxnative checkout, so this uses the shared one"
    }

    /// The games pinned to their own checkout, by game: another folder of the same game may not be.
    var ownRepos: [Game.ID: URL] {
        var own: [Game.ID: URL] = [:]
        for game in games {
            guard let repo = Self.ownRepo(in: game.folder) else { continue }
            own[game.id] = URL(filePath: repo, directoryHint: .isDirectory)
        }
        return own
    }

    /// What nxnative says about each game, by game, from the checkout it builds with: a pinned game's from its own.
    static func gameProfiles(of games: [Game], repo: URL, own: [Game.ID: URL]) -> [Game.ID: GameProfile] {
        var wanted: [URL: Set<String>] = [:]
        for game in games {
            guard let id = game.titleID?.uppercased() else { continue }
            wanted[own[game.id] ?? repo, default: []].insert(id)
        }
        var found: [URL: [String: GameProfile]] = [:]
        for (checkout, ids) in wanted {
            found[checkout] = GameProfile.read(
                repo: checkout, titleIDs: ids.intersection(Self.profiles(repo: checkout.path)))
        }
        var byGame: [Game.ID: GameProfile] = [:]
        for game in games {
            guard let id = game.titleID?.uppercased() else { continue }
            byGame[game.id] = found[own[game.id] ?? repo]?[id]
        }
        return byGame
    }
}
