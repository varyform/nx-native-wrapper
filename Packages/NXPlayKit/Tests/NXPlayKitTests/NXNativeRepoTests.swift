import Foundation
import Testing

@testable import NXPlayKit

@Suite struct NXNativeRepoTests {
    /// A folder that passes for an nxnative checkout (the marker Settings and command() check).
    static func checkout(_ name: String, in parent: URL) throws -> URL {
        let repo = parent.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: repo.appending(path: "scripts"), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: repo.appending(path: "scripts/build_ipa_from_nsp.py").path, contents: Data())
        return repo
    }

    /// A temporary root: the game folder in `game/`, checkouts beside it.
    static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "nxnative-repo-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root.appending(path: "game"), withIntermediateDirectories: true)
        return root
    }

    static func game(in folder: URL) -> Game {
        Game(
            folder: folder, name: "G", titleID: nil, version: nil, languages: [], iconURL: nil,
            buildFolder: nil, ipaURL: nil, xcodeBuildFolder: nil, hasPackages: true, state: .ready)
    }

    @Test func aLinkedCheckoutIsTheGames() throws {
        let root = try Self.root()
        let repo = try Self.checkout("fork-checkout", in: root)
        let game = root.appending(path: "game")
        try FileManager.default.createSymbolicLink(
            at: game.appending(path: "nxnative"), withDestinationURL: repo)
        #expect(Library.ownRepo(in: game) == repo.path)
    }

    @Test func aRelativeLinkResolvesBesideTheGame() throws {
        let root = try Self.root()
        let repo = try Self.checkout("beside", in: root)
        let game = root.appending(path: "game")
        try FileManager.default.createSymbolicLink(
            atPath: game.appending(path: "nxnative").path,
            withDestinationPath: "../\(repo.lastPathComponent)")
        #expect(Library.ownRepo(in: game) == repo.path)
    }

    @Test func aCheckoutCopiedIntoTheFolderCountsToo() throws {
        let root = try Self.root()
        let repo = try Self.checkout("nxnative", in: root.appending(path: "game"))
        #expect(Library.ownRepo(in: root.appending(path: "game")) == repo.path)
    }

    @Test func aFolderThatIsNoCheckoutIsIgnored() throws {
        let root = try Self.root()
        try FileManager.default.createDirectory(
            at: root.appending(path: "game/nxnative"), withIntermediateDirectories: true)
        #expect(Library.ownRepo(in: root.appending(path: "game")) == nil)
    }

    @Test func aDanglingLinkIsIgnored() throws {
        let root = try Self.root()
        let game = root.appending(path: "game")
        try FileManager.default.createSymbolicLink(
            atPath: game.appending(path: "nxnative").path,
            withDestinationPath: root.appending(path: "gone").path)
        #expect(Library.ownRepo(in: game) == nil)
    }

    @MainActor @Test func theSharedCheckoutIsTheFallback() throws {
        let suite = testDefaultsName()
        defer { removeTestDefaults(suite) }
        let library = Library(defaults: UserDefaults(suiteName: suite)!, isScreenshot: true)
        library.nxnativePath = "/shared"
        let root = try Self.root()
        let game = Self.game(in: root.appending(path: "game"))
        #expect(library.nxnativeRepo(for: game) == "/shared")
        let repo = try Self.checkout("own", in: root)
        try FileManager.default.createSymbolicLink(
            at: game.folder.appending(path: "nxnative"), withDestinationURL: repo)
        #expect(library.nxnativeRepo(for: game) == repo.path)
        try FileManager.default.removeItem(at: game.folder.appending(path: "nxnative"))
        #expect(library.nxnativeRepo(for: game) == "/shared")
    }

    @Test func theLogSaysWhichCheckoutOrWhyNot() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appending(path: "game")
        let link = game.appending(path: "nxnative")
        #expect(Library.ownRepoNote(in: game) == nil)  // most games: nothing to say

        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: root.appending(path: "mistyped").path)
        #expect(Library.ownRepoNote(in: game)?.hasPrefix("nxnative: ignoring \(link.path)") == true)
        try FileManager.default.removeItem(at: link)

        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        #expect(Library.ownRepoNote(in: game)?.hasPrefix("nxnative: ignoring \(link.path)") == true)
        try FileManager.default.removeItem(at: link)

        let repo = try Self.checkout("own", in: root)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)
        #expect(Library.ownRepoNote(in: game) == "nxnative: using \(repo.path)")
    }

    /// A profile in a checkout, its name telling which checkout it came from.
    static func profile(_ id: String, named name: String, in repo: URL) throws {
        let folder = repo.appending(path: "dm/games/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "name\t\(name)\n".write(
            to: folder.appending(path: "game.tsv"), atomically: true, encoding: .utf8)
    }

    @MainActor @Test func aPinnedGamesProfileComesFromItsOwnCheckout() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = try Self.checkout("shared", in: root)
        let own = try Self.checkout("own", in: root)
        try Self.profile("A000", named: "shared A", in: shared)  // not pinned
        try Self.profile("B000", named: "shared B", in: shared)  // pinned, in both
        try Self.profile("B000", named: "own B", in: own)
        try Self.profile("C000", named: "shared C", in: shared)  // pinned, its branch has no profile
        try Self.profile("D000", named: "own D", in: own)  // pinned, only its branch has a profile
        let pinned = ["B000": own, "C000": own, "D000": own]

        let known = Library.profiles(repo: shared.path, own: pinned)
        #expect(known == ["A000", "B000", "D000"])
        let profiles = Library.gameProfiles(repo: shared, titleIDs: known, own: pinned)
        #expect(profiles["A000"]?.name == "shared A")
        #expect(profiles["B000"]?.name == "own B")
        #expect(profiles["C000"] == nil)
        #expect(profiles["D000"]?.name == "own D")
    }

    @Test func aPinnedGamesNewsComeFromItsOwnCheckout() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        /// A checkout where the game's profile changed once since `built`, its tree.
        func checkout(_ name: String, subject: String) throws -> (repo: URL, built: String) {
            let repo = root.appending(path: name)
            func git(_ args: String...) {
                _ = ProfileNews.git(repo, ["-c", "user.name=t", "-c", "user.email=t@t"] + args)
            }
            try Self.profile("A000", named: name, in: repo)
            try Self.profile("B000", named: name, in: repo)
            git("init", "-q")
            git("add", "-A")
            git("commit", "-q", "-m", "first")
            let built = try #require(ProfileNews.git(repo, ["rev-parse", "HEAD^{tree}"]))
            try Self.profile("A000", named: "\(name) again", in: repo)
            try Self.profile("B000", named: "\(name) again", in: repo)
            git("add", "-A")
            git("commit", "-q", "-m", subject)
            return (repo, built)
        }
        let shared = try checkout("shared", subject: "from shared")
        let own = try checkout("own", subject: "from own")

        let news = ProfileNews.read(
            repo: shared.repo, builds: ["A000": shared.built, "B000": own.built],
            own: ["B000": own.repo])
        #expect(news["A000"]?.map(\.subject) == ["from shared"])
        #expect(news["B000"]?.map(\.subject) == ["from own"])
    }
}
