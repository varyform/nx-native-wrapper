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

    static func game(in folder: URL, titleID: String? = nil) -> Game {
        Game(
            folder: folder, name: "G", titleID: titleID, version: nil, languages: [], iconURL: nil,
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

    @Test func theLibraryShowsTheCheckoutsBranchOrABrokenLink() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appending(path: "game")
        let link = game.appending(path: "nxnative")
        #expect(Library.nxnativeLink(in: game) == nil)

        // a worktree: its .git is a file naming its git folder, relative here
        let repo = try Self.checkout("worktree", in: root)
        let gitDir = root.appending(path: "main/.git/worktrees/worktree")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "gitdir: ../main/.git/worktrees/worktree\n".write(
            to: repo.appending(path: ".git"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/update-only-program\n".write(
            to: gitDir.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)
        #expect(
            Library.nxnativeLink(in: game)
                == .checkout(path: repo.path, branch: "update-only-program"))

        // detached: no branch to name
        try "1c482396b3b4e0f1a2c3d4e5f60718293a4b5c6d\n".write(
            to: gitDir.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        #expect(Library.nxnativeLink(in: game) == .checkout(path: repo.path, branch: nil))

        // a clone: .git is the folder itself
        let clone = try Self.checkout("clone", in: root)
        try FileManager.default.createDirectory(
            at: clone.appending(path: ".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(
            to: clone.appending(path: ".git/HEAD"), atomically: true, encoding: .utf8)
        #expect(Library.branch(of: clone.path) == "main")

        // a link to what isn't a checkout: the game builds with the shared one, and the library says so
        try FileManager.default.removeItem(at: link)
        let mistyped = root.appending(path: "mistyped")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: mistyped.path)
        #expect(Library.nxnativeLink(in: game) == .broken(path: mistyped.path))
    }

    @Test func aScannedGameCarriesItsLink() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appending(path: "game")
        try Data([0]).write(to: game.appending(path: "game.nsp"))
        try FileManager.default.createSymbolicLink(
            at: game.appending(path: "nxnative"), withDestinationURL: try Self.checkout("own", in: root))
        #expect(GameScanner.game(at: game)?.nxnativeLink != nil)
    }

    /// A profile in a checkout, its name telling which checkout it came from.
    static func profile(_ id: String, named name: String, in repo: URL) throws {
        let folder = repo.appending(path: "dm/games/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "name\t\(name)\n".write(
            to: folder.appending(path: "game.tsv"), atomically: true, encoding: .utf8)
    }

    @MainActor @Test func eachFoldersProfileComesFromTheCheckoutItBuildsWith() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = try Self.checkout("shared", in: root)
        let own = try Self.checkout("own", in: root)
        try Self.profile("A000", named: "shared A", in: shared)
        try Self.profile("A000", named: "own A", in: own)
        try Self.profile("D000", named: "own D", in: own)  // only the branch has a profile
        // two folders of one game, one of them pinned
        let plain = Self.game(in: root.appending(path: "plain"), titleID: "a000")
        let pinned = Self.game(in: root.appending(path: "pinned"), titleID: "A000")
        let onlyOwn = Self.game(in: root.appending(path: "only own"), titleID: "D000")
        let none = Self.game(in: root.appending(path: "none"), titleID: "D000")

        let profiles = Library.gameProfiles(
            of: [plain, pinned, onlyOwn, none], repo: shared,
            own: [pinned.id: own, onlyOwn.id: own])
        #expect(profiles[plain.id]?.name == "shared A")
        #expect(profiles[pinned.id]?.name == "own A")
        #expect(profiles[onlyOwn.id]?.name == "own D")
        #expect(profiles[none.id] == nil)
    }

    @Test func eachFoldersNewsComeFromTheCheckoutItBuildsWith() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        /// A checkout where the game's profile changed once since `built`, its tree.
        func checkout(_ name: String, subject: String) throws -> (repo: URL, built: String) {
            let repo = root.appending(path: name)
            func git(_ args: String...) {
                _ = ProfileNews.git(repo, ["-c", "user.name=t", "-c", "user.email=t@t"] + args)
            }
            try Self.profile("A000", named: name, in: repo)
            git("init", "-q")
            git("add", "-A")
            git("commit", "-q", "-m", "first")
            let built = try #require(ProfileNews.git(repo, ["rev-parse", "HEAD^{tree}"]))
            try Self.profile("A000", named: "\(name) again", in: repo)
            git("add", "-A")
            git("commit", "-q", "-m", subject)
            return (repo, built)
        }
        let shared = try checkout("shared", subject: "from shared")
        let own = try checkout("own", subject: "from own")

        // two folders of one game, one of them pinned
        let news = ProfileNews.read(
            repo: shared.repo,
            builds: [
                "plain": .init(titleID: "A000", tree: shared.built),
                "pinned": .init(titleID: "A000", tree: own.built),
            ],
            own: ["pinned": own.repo])
        #expect(news["plain"]?.map(\.subject) == ["from shared"])
        #expect(news["pinned"]?.map(\.subject) == ["from own"])
    }
}
