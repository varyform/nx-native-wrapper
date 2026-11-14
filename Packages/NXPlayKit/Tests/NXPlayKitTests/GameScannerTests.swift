import Foundation
import Testing

@testable import NXPlayKit

@Suite struct GameScannerTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @Test func findsGamesByStateAndSkipsOtherFolders() throws {
        // ready: launcher + executable Mac host, base and update extracted
        let ready = try build(game: "Metroid", titleID: "010093801237C000", versions: [0, 327680])
        try touch(ready.appending(path: "start_mac.sh"))
        try touch(ready.appending(path: "tools/dmhost"), executable: true)
        // extracted, no launcher
        _ = try build(
            game: "Zelda (NSP)", titleID: "01007EF00011E000", versions: [786432], title: nil)
        // only packages, and an IPA built earlier
        try touch(root.appending(path: "Wonder/game.NSZ"))
        try touch(root.appending(path: "Wonder/SMBWMobile.ipa"))
        // nothing of a game
        try touch(root.appending(path: "Music/01. Track.mp3"))
        try touch(root.appending(path: "Music/0100000000000000_notabuild/x"))

        let games = GameScanner.scan(roots: [root])

        #expect(games.map(\.name) == ["Metroid Dread", "Wonder", "Zelda (NSP)"])
        let metroid = try #require(games.first)
        #expect(metroid.state == .ready)
        #expect(metroid.titleID == "010093801237C000")
        #expect(metroid.version == "2.1.0")
        #expect(metroid.iconURL?.path.hasSuffix("extract/v327680/icon.jpg") == true)
        #expect(metroid.ipaURL == nil)
        #expect(games[1].state == .notExtracted)
        #expect(games[1].canExtract)
        #expect(games[1].ipaURL?.lastPathComponent == "SMBWMobile.ipa")
        #expect(games[2].state == .extracted)
        #expect(games[2].hasPackages == false)
    }

    @Test func aFileFinderIsStillCopyingHoldsTheGameBack() throws {
        let nsp = root.appending(path: "Wonder/Wonder [0100000000010000][v0].nsp")
        try touch(nsp)
        // what Finder sets while copying (seen: 1984-01-24 11:00 local), then the source's date once complete
        let copying = ISO8601DateFormatter().date(from: "1984-01-24T08:00:00Z")!
        try FileManager.default.setAttributes([.creationDate: copying], ofItemAtPath: nsp.path)

        let game = try #require(GameScanner.scan(roots: [root]).first)
        #expect(game.isCopying)
        #expect(!game.canExtract && !game.canBuildIPA)
        #expect(CleanupScanner.groups(games: [game]).first?.files.first?.blocked != nil)

        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: 1_692_051_683)], ofItemAtPath: nsp.path)
        let done = try #require(GameScanner.scan(roots: [root]).first)
        #expect(!done.isCopying && done.canExtract)
    }

    @Test func aFolderFinderIsStillCopyingHoldsTheGameBack() throws {
        // a dragged game folder: Finder marks the folder, while the file inside has today's date (seen with
        // Streets of Rage 4)
        let folder = root.appending(path: "Streets of Rage 4 [NSP]")
        try touch(folder.appending(path: "Streets of Rage 4 [0100EC9010258000][v0].nsp"))
        let copying = ISO8601DateFormatter().date(from: "1984-01-24T08:00:00Z")!
        try FileManager.default.setAttributes([.creationDate: copying], ofItemAtPath: folder.path)

        #expect(GameScanner.scan(roots: [root]).first?.isCopying == true)

        try FileManager.default.setAttributes([.creationDate: Date.now], ofItemAtPath: folder.path)
        #expect(GameScanner.scan(roots: [root]).first?.isCopying == false)
    }

    @Test func findsTheMacAppNxnativePacked() throws {
        try touch(root.appending(path: "Metroid/Metroid Dread [010093801237C000][v0].nsp"))
        try touch(
            root.appending(path: "Metroid/Metroid Dread.app/Contents/MacOS/dmhost"),
            executable: true)
        try touch(
            root.appending(path: "Metroid/Some Other.app/Contents/MacOS/Some Other"),
            executable: true)

        #expect(
            GameScanner.scan(roots: [root]).first?.macAppURL?.lastPathComponent == "Metroid Dread.app")
    }

    /// Build IPA › Without the Game Files: nxplay names the RomFS image in the build folder, shown beside the IPA.
    @Test func anIPAWithoutTheGameFilesShowsItsImage() throws {
        let game = root.appending(path: "Zelda")
        try touch(game.appending(path: "Zelda [01007EF00011E000][v0].nsp"))
        try touch(game.appending(path: "Zelda.ipa"))
        let image = game.appending(path: "01007EF00011E000_build/extract/v786432/RomFS.img")
        try touch(image)
        let note = game.appending(path: "01007EF00011E000_build/ipa-game-files")
        try Data("\(image.path)\n".utf8).write(to: note)

        var found = try #require(GameScanner.scan(roots: [root]).first)
        #expect(found.ipaGameFiles?.lastPathComponent == "RomFS.img")
        #expect(found.ipaFiles.map(\.lastPathComponent) == ["Zelda.ipa", "RomFS.img"])

        // the image went (a new extraction, Free Up Space): the IPA alone
        try FileManager.default.removeItem(at: image)
        found = try #require(GameScanner.scan(roots: [root]).first)
        #expect(found.ipaGameFiles == nil && found.ipaFiles.map(\.lastPathComponent) == ["Zelda.ipa"])
    }

    /// nxplay's app_is_current, as the library shows it: the code app.tree records against the launcher's, else dates.
    @Test func aMacAppPackedWithOlderCodeIsOutdated() throws {
        let build = try build(game: "Metroid", titleID: "010093801237C000", versions: [0])
        let launcher = build.appending(path: "start_mac.sh")
        try Data("#!/bin/sh\n# nxnative tree aaa\ncd x\n".utf8).write(to: launcher)
        let app = root.appending(path: "Metroid/Metroid Dread.app")
        try touch(app.appending(path: "Contents/MacOS/dmhost"), executable: true)
        try touch(app.appending(path: "Contents/Info.plist"))
        func outdated() -> Bool { GameScanner.scan(roots: [root]).first?.macAppOutdated == true }

        try Data("aaa\n".utf8).write(to: build.appending(path: "app.tree"))
        #expect(!outdated())
        // other code, packed before the build: the build is newer
        let tree = build.appending(path: "app.tree")
        try Data("bbb\n".utf8).write(to: tree)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-3600)], ofItemAtPath: tree.path)
        #expect(outdated())
        // packed after the build (Make Mac App after an nxnative update, before the rebuild): the app is newer
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(3600)], ofItemAtPath: tree.path)
        #expect(!outdated())
        // from before app.tree: older than the launcher
        try FileManager.default.removeItem(at: build.appending(path: "app.tree"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-3600)],
            ofItemAtPath: app.appending(path: "Contents/Info.plist").path)
        #expect(outdated())
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(3600)],
            ofItemAtPath: app.appending(path: "Contents/Info.plist").path)
        #expect(!outdated())
    }

    @Test func aLauncherWithoutTheMacHostIsNotReady() throws {
        let folder = try build(game: "Metroid", titleID: "010093801237C000", versions: [0])
        try touch(folder.appending(path: "start_mac.sh"))
        #expect(GameScanner.scan(roots: [root]).first?.state == .extracted)
    }

    @Test func iconFallsBackToAnOlderVersion() throws {
        let folder = try build(game: "Metroid", titleID: "010093801237C000", versions: [0])
        try FileManager.default.createDirectory(
            at: folder.appending(path: "extract/v65536/RomFS"), withIntermediateDirectories: true)
        #expect(GameScanner.scan(roots: [root]).first?.iconURL?.path.hasSuffix("v0/icon.jpg") == true)
    }

    @Test func readsTheLastPlayFromTheMarkNxplayLeaves() throws {
        let folder = try build(game: "Metroid", titleID: "010093801237C000", versions: [0])
        #expect(GameScanner.scan(roots: [root]).first?.lastPlayed == nil)

        let mark = folder.appending(path: "run/last_played")
        try touch(mark)
        let played = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: played], ofItemAtPath: mark.path)
        #expect(GameScanner.scan(roots: [root]).first?.lastPlayed == played)
    }

    @Test func keepThisBuildMarksTheBuildFolder() throws {
        let folder = try build(game: "Metroid", titleID: "010093801237C000", versions: [0])
        let extracted = try #require(GameScanner.scan(roots: [root]).first)
        #expect(!extracted.isKept && !extracted.canKeep)  // nothing that plays to keep yet

        try touch(folder.appending(path: "start_mac.sh"))
        try touch(folder.appending(path: "tools/dmhost"), executable: true)
        let ready = try #require(GameScanner.scan(roots: [root]).first)
        #expect(!ready.isKept && ready.canKeep)
        #expect(ready.keepFile?.pathComponents.suffix(2) == [folder.lastPathComponent, "keep"])

        try touch(folder.appending(path: "keep"))
        #expect(GameScanner.scan(roots: [root]).first?.isKept == true)
    }

    // MARK: - Fixtures

    private func build(
        game: String, titleID: String, versions: [Int], title: String? = "Metroid Dread"
    ) throws -> URL {
        let folder = root.appending(path: "\(game)/\(titleID)_build", directoryHint: .isDirectory)
        for version in versions {
            let extract = folder.appending(path: "extract/v\(version)")
            try FileManager.default.createDirectory(
                at: extract.appending(path: "RomFS"), withIntermediateDirectories: true)
            try touch(extract.appending(path: "icon.jpg"))
            if let title {
                try NACPTests.nacp(title: title, version: "2.1.0").write(
                    to: extract.appending(path: "control.nacp"))
            }
        }
        return folder
    }

    /// Several folders make one library: a folder of games, a game's own folder, and one that isn't there.
    @Test func gamesFromSeveralFoldersAndAGamesOwnFolder() throws {
        try touch(root.appending(path: "Library/Celeste/Celeste.nsp"))
        try touch(root.appending(path: "Library/stray.nsp"))  // a library with a loose file is still a library
        try touch(root.appending(path: "Library/Hades/Hades.nsz"))
        try touch(root.appending(path: "Elsewhere/Balatro/Balatro.nsp"))
        let own = root.appending(path: "Elsewhere/Balatro", directoryHint: .isDirectory)
        let library = root.appending(path: "Library", directoryHint: .isDirectory)
        let missing = root.appending(path: "Unplugged", directoryHint: .isDirectory)

        let games = GameScanner.scan(roots: [library, own, missing, library])
        #expect(games.map(\.name) == ["Balatro", "Celeste", "Hades"])  // by name, each once
        #expect(games.first?.folder.lastPathComponent == "Balatro")
    }

    private func touch(_ url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        if executable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
}
