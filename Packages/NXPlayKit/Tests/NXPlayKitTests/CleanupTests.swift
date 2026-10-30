import Foundation
import Testing

@testable import NXPlayKit

@MainActor @Suite struct CleanupTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
        // ready: built for the Mac; its NSZ was converted into the build's nsp/; installed on a device once
        try write("Ready/Ready [0100000000010000][v0].nsz", size: 3000)
        try write("Ready/Ready.ipa", size: 500)
        try write("Ready/0100000000010000_build/extract/v0/icon.jpg")
        try write("Ready/0100000000010000_build/start_mac.sh")
        try write("Ready/0100000000010000_build/tools/dmhost", executable: true)
        try write("Ready/0100000000010000_build/nsp/Ready [0100000000010000][v0].nsp", size: 4000)
        try write("Ready/0100000000010000_build/patched_v0/main", size: 7000)
        try write("Ready/0100000000010000_build/run/save/progress.bin", size: 50)
        try write("Ready/0100000000010000_build/run/save_device/system.bin", size: 50)
        try write("Ready/0100000000010000_build/run/temp/cache.bin", size: 900)
        try write("Ready/0100000000010000_build/run/pso_user.tsv", size: 10)
        try write(
            "Ready/0100000000010000_build/xcode-derived-data/Build/Products/DmIOS.app/romfs/a.bin",
            size: 6000)
        try write(
            "Ready/0100000000010000_build/xcode-derived-data/Build/Products/DmIOS.app/romfs/b.bin",
            size: 2000)
        // extracted, never built for the Mac
        try write("Extracted/Extracted.XCI", size: 2000)
        try write("Extracted/0100000000020000_build/extract/v0/icon.jpg")
        // only the packages
        try write("Fresh/Fresh.nsp", size: 1000)
        try write("Fresh/Fresh.ipa", size: 100)
    }

    private var games: [Game] { GameScanner.scan(root: root) }
    private func game(_ name: String) -> Game {
        games.first { $0.folder.lastPathComponent == name }!
    }

    @Test func listsEveryKindPerGameWithItsOwnRules() throws {
        let groups = CleanupScanner.groups(games: games)
        #expect(groups.map(\.game.folder.lastPathComponent) == ["Extracted", "Fresh", "Ready"])

        let ready = try #require(groups.last)
        #expect(ready.files.map(\.role) == [.original, .converted, .build, .ipa, .xcodeBuild])
        #expect(ready.files.allSatisfy { $0.blocked == nil })
        #expect(try #require(ready.files.last).size >= 8000)  // the whole Xcode build folder
        // the build without the saves, the converted NSPs and the Xcode build: listed on their own or kept
        let build = ready.files[2]
        #expect(build.size >= 7000 + 900 + 10)
        #expect(
            Set(
                CleanupScanner.buildContents(build.url).map { $0.path(percentEncoded: false) }.map {
                    String($0.dropFirst(build.url.path(percentEncoded: false).count))
                        .trimmingCharacters(
                            in: CharacterSet(charactersIn: "/"))
                }) == [
                    "extract", "start_mac.sh", "tools", "patched_v0", "run/temp",
                    "run/pso_user.tsv",
                ])

        // a game that isn't built for the Mac keeps its game files, but its IPA can go
        let fresh = groups[1]
        #expect(fresh.files.map(\.role) == [.original, .ipa])
        #expect(fresh.files.map { $0.blocked == nil } == [false, true])
        // any case of the extension; an extracted game's build can go, since its files can make it again
        #expect(
            groups[0].files.map(\.url.lastPathComponent) == [
                "Extracted.XCI", "0100000000020000_build",
            ])
        #expect(groups[0].files.last?.blocked == nil)
    }

    @Test func aBusyGameKeepsEverything() {
        let groups = CleanupScanner.groups(games: games, busy: [game("Ready").id])
        #expect(groups.last?.files.allSatisfy { $0.blocked != nil } == true)
    }

    @Test func selectsByKindByGameAndByFile() {
        let cleanup = Cleanup()
        cleanup.apply(CleanupScanner.groups(games: games))

        cleanup.toggle(.ipas)
        #expect(cleanup.selectedFiles.map(\.url.lastPathComponent) == ["Fresh.ipa", "Ready.ipa"])
        #expect(cleanup.isSelected(.ipas) == true)

        cleanup.toggle(.gameFiles)  // only the ready game's: the others are blocked
        #expect(
            cleanup.selectedFiles.filter { $0.kind == .gameFiles }.map(\.role) == [
                .original, .converted,
            ])
        #expect(cleanup.isSelected(.gameFiles) == true)

        let ready = cleanup.groups.last!
        #expect(cleanup.isSelected(ready) == nil)  // its Xcode build isn't picked
        cleanup.toggle(ready)
        #expect(cleanup.isSelected(ready) == true && cleanup.isSelected(.xcodeBuilds) == true)
        cleanup.toggle(.ipas)
        #expect(cleanup.isSelected(ready) == nil && cleanup.isSelected(.ipas) == false)
    }

    @Test func deletesOnlyTheConfirmedSelection() async throws {
        let cleanup = Cleanup()
        await cleanup.scan(games: games, busy: [])
        let ready = try #require(cleanup.groups.last)
        let xcode = try #require(ready.files.last)
        let original = ready.files[0]
        cleanup.toggle(xcode)
        cleanup.toggle(original)

        #expect(!cleanup.canDelete)  // not confirmed
        cleanup.confirmation = "Yes, I’m  sure!"
        #expect(cleanup.canDelete)
        await cleanup.delete()

        #expect(cleanup.phase == .done(count: 2, size: xcode.size + original.size))
        #expect(!FileManager.default.fileExists(atPath: xcode.url.path))  // a whole folder
        #expect(!FileManager.default.fileExists(atPath: original.url.path))
        #expect(FileManager.default.fileExists(atPath: ready.files[1].url.path))
        #expect(cleanup.selection.isEmpty && cleanup.confirmation.isEmpty)

        // the game keeps playing its build without its packages
        let after = GameScanner.game(at: ready.game.folder)
        #expect(after?.state == .ready)
        #expect(after?.hasPackages == false)
        // and the rescanned game differs from the old one, so its card redraws without the Xcode badge
        #expect(ready.game.xcodeBuildFolder != nil)
        #expect(after?.xcodeBuildFolder == nil)
        #expect(after != ready.game)
    }

    /// Make Mac App's app: clones of the build's files (nxnative packs it so), its own launcher, the .app.key beside it.
    @Test func aMacAppCountsWhatOnlyItTakesAndGoesWithItsKey() async throws {
        let app = root.appending(path: "Ready/Ready.app")
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(
            at: app.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try write("Ready/Ready.app/Contents/MacOS/dmhost", size: 300, executable: true)
        try write("Ready/Ready.app/Contents/MacOS/nxnative", size: 300, executable: true)
        try write("Ready/Ready.app.key", size: 10)
        let big = root.appending(path: "Ready/0100000000010000_build/patched_v0/big")
        try Data(repeating: 7, count: 4_000_000).write(to: big)
        let clone = app.appending(path: "Contents/Resources/big")
        // the temporary folder is on the startup disk, APFS: a clone shares the blocks
        #expect(clonefile(big.path, clone.path, 0) == 0)
        // not one of nxnative's: no Mac host inside
        try write("Ready/Other.app/Contents/Info.plist")
        #expect(
            CleanupScanner.macApps(in: app.deletingLastPathComponent()).map(\.lastPathComponent)
                == [
                    "Ready.app"
                ])

        let cleanup = Cleanup()
        await cleanup.scan(games: games, busy: [])
        while cleanup.isMeasuring { try await Task.sleep(for: .milliseconds(20)) }
        let listed = try #require(cleanup.files(.macApps).first)
        #expect(listed.url.lastPathComponent == "Ready.app" && cleanup.files(.macApps).count == 1)
        #expect(listed.size < 1_000_000)  // its own launcher and key, not the shared 4 MB
        #expect(CleanupScanner.size(of: app) > 4_000_000)  // as du counts it

        cleanup.toggle(listed)
        cleanup.confirmation = Cleanup.phrase
        await cleanup.delete()
        #expect(cleanup.phase == .done(count: 1, size: listed.size))
        #expect(!FileManager.default.fileExists(atPath: app.path))
        #expect(!FileManager.default.fileExists(atPath: CleanupScanner.appKey(app).path))
        #expect(FileManager.default.fileExists(atPath: big.path))  // the build's file stays
    }

    @Test func removingABuildKeepsItsSaves() async throws {
        let cleanup = Cleanup()
        await cleanup.scan(games: games, busy: [])
        let ready = try #require(cleanup.groups.last)
        let build = try #require(ready.files.first { $0.role == .build })
        cleanup.toggle(build)
        cleanup.confirmation = Cleanup.phrase
        await cleanup.delete()

        let folder = build.url
        #expect(cleanup.phase == .done(count: 1, size: build.size))
        for kept in [
            "run/save/progress.bin", "run/save_device/system.bin", "nsp", "xcode-derived-data",
        ] {
            #expect(
                FileManager.default.fileExists(atPath: folder.appending(path: kept).path), "\(kept)"
            )
        }
        for gone in [
            "patched_v0", "start_mac.sh", "extract", "tools", "run/temp", "run/pso_user.tsv",
        ] {
            #expect(
                !FileManager.default.fileExists(atPath: folder.appending(path: gone).path),
                "\(gone)")
        }
        // the game is back to its game files, to be built again at its next play
        let after = try #require(GameScanner.game(at: ready.game.folder))
        #expect(after.state == .notExtracted && after.hasPackages)
    }

    @Test func aGamesBuildAndItsFilesNeverGoTogether() throws {
        let cleanup = Cleanup()
        cleanup.apply(CleanupScanner.groups(games: games))
        let ready = cleanup.groups.last!
        let original = ready.files[0]
        let build = ready.files[2]

        cleanup.toggle(original)
        #expect(cleanup.conflict(build) != nil)
        cleanup.toggle(build)
        #expect(!cleanup.selection.contains(build.url))
        cleanup.toggle(original)

        // picked whole, a game keeps its game files: the build goes first, then they can't
        cleanup.toggle(ready)
        #expect(cleanup.selection.contains(build.url) && !cleanup.selection.contains(original.url))
        #expect(cleanup.selection.contains(ready.files[1].url))  // the converted NSP: the NSZ makes it again
        #expect(cleanup.isSelected(ready) == true)
        cleanup.toggle(.gameFiles)
        #expect(!cleanup.selection.contains(original.url))

        // a game whose files are gone keeps its build: it's how it plays
        try FileManager.default.removeItem(at: original.url)
        let alone = CleanupScanner.groups(games: games).last!
        #expect(alone.files.first { $0.role == .build }?.blocked != nil)
    }

    @Test func measuresAFolderOnceAndRemembersIt() throws {
        let xcode = root.appending(path: "Ready/0100000000010000_build/xcode-derived-data")
        // a hard link counts once, as du counts it
        let a = xcode.appending(path: "Build/Products/DmIOS.app/romfs/a.bin")
        let walked = CleanupScanner.size(of: xcode)
        try FileManager.default.linkItem(at: a, to: xcode.appending(path: "link.bin"))
        #expect(CleanupScanner.size(of: xcode) == walked)
        #expect(walked >= 8000)

        let cache = SizeCache(file: root.appending(path: "sizes.json"))
        let file = CleanupFile(
            url: xcode, size: 0, measuring: true, role: .xcodeBuild, blocked: nil)
        #expect(CleanupScanner.measure(file, cache: cache).size == walked)
        // deep inside changes without the stamp moving: the cached size, not a walk
        try Data(repeating: 1, count: 50_000).write(
            to: xcode.appending(path: "Build/Products/DmIOS.app/romfs/c.bin"))
        let reread = SizeCache(file: root.appending(path: "sizes.json"))  // kept on disk
        #expect(CleanupScanner.measure(file, cache: reread).size == walked)
        // a change at the first level (a rebuild rewrites it) measures again
        try Data(repeating: 1, count: 10).write(to: xcode.appending(path: "info.plist"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(5)],
            ofItemAtPath: xcode.appending(path: "info.plist").path)
        #expect(CleanupScanner.measure(file, cache: reread).size > walked + 50_000)
    }

    @Test func aRescanDropsSelectionsThatBecameBlocked() async {
        let cleanup = Cleanup()
        await cleanup.scan(games: games, busy: [])
        cleanup.toggle(.ipas)
        #expect(cleanup.selection.count == 2)

        await cleanup.scan(games: games, busy: [game("Fresh").id])
        #expect(cleanup.selection.map(\.lastPathComponent) == ["Ready.ipa"])
    }

    @Test func confirmationIgnoresCasePunctuationAndSpacing() {
        for text in ["yes, I'm sure", "YES IM SURE", " yes  i’m sure. "] {
            #expect(Cleanup.normalized(text) == Cleanup.normalized(Cleanup.phrase), "\(text)")
        }
        for text in ["", "yes", "I'm sure", "yes I am sure"] {
            #expect(Cleanup.normalized(text) != Cleanup.normalized(Cleanup.phrase), "\(text)")
        }
    }

    private func write(_ path: String, size: Int = 1, executable: Bool = false) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: size).write(to: url)
        if executable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
}
