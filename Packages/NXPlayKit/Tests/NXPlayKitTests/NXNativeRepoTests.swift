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
        library.setOwnRepo(repo, for: game)
        #expect(library.nxnativeRepo(for: game) == repo.path)
        library.clearOwnRepo(for: game)
        #expect(library.nxnativeRepo(for: game) == "/shared")
    }

    @MainActor @Test func clearingKeepsACheckoutCopiedIntoTheFolder() throws {
        let suite = testDefaultsName()
        defer { removeTestDefaults(suite) }
        let library = Library(defaults: UserDefaults(suiteName: suite)!, isScreenshot: true)
        let root = try Self.root()
        try Self.checkout("nxnative", in: root.appending(path: "game"))
        let game = Self.game(in: root.appending(path: "game"))
        library.clearOwnRepo(for: game)
        #expect(Library.ownRepo(in: game.folder) != nil)
    }
}
