import Foundation
import Testing

@testable import NXPlayKit

/// Tools › Update All Builds….
@MainActor @Suite final class UpdateAllTests {
    private var suites: [String] = []
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-updateall-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        suites.forEach(removeTestDefaults)
        try? FileManager.default.removeItem(at: root)
    }

    /// A built game: its launcher and Mac host, its game files unless said otherwise, kept if asked, played at `played`.
    private func game(
        _ name: String, id: String, files: Bool = true, kept: Bool = false, played: Date? = nil
    ) throws {
        let folder = root.appending(path: name, directoryHint: .isDirectory)
        let build = folder.appending(path: "\(id)_build", directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(
            at: build.appending(path: "tools"), withIntermediateDirectories: true)
        try fm.createDirectory(at: build.appending(path: "run"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: build.appending(path: GameScanner.launcherName))
        fm.createFile(
            atPath: build.appending(path: "tools/dmhost").path, contents: Data(),
            attributes: [.posixPermissions: 0o755])
        if files { try Data([1]).write(to: folder.appending(path: "\(name).nsp")) }
        if kept {
            fm.createFile(
                atPath: build.appending(path: GameScanner.keepName).path, contents: Data())
        }
        if let played {
            let mark = build.appending(path: "run/last_played")
            fm.createFile(atPath: mark.path, contents: Data())
            try fm.setAttributes([.modificationDate: played], ofItemAtPath: mark.path)
        }
    }

    private func library() -> Library {
        let suite = testDefaultsName()
        suites.append(suite)
        let library = Library(defaults: UserDefaults(suiteName: suite)!, isScreenshot: true)
        library.root = root
        return library
    }

    @Test func buildsTheGamesItCanThePlayedLastFirst() throws {
        try game("Old", id: "0100000000010000", played: .now.addingTimeInterval(-86_400))
        try game("New", id: "0100000000020000", played: .now)
        try game("Never", id: "0100000000030000")
        try game("Kept", id: "0100000000040000", kept: true)
        try game("Trimmed", id: "0100000000050000", files: false)
        let library = library()
        #expect(library.updatableGames.map(\.name) == ["New", "Old", "Never"])
        #expect(library.updateSkips.kept == 1 && library.updateSkips.noFiles == 1)
        #expect(
            UpdateAllView.skipped(library.updateSkips)
                == "Skipped: 1 kept build, 1 game without its game files.")
        #expect(UpdateAllView.skipped((0, 0)) == nil)
    }

    @Test func onBatteryTheQueueWaitsForTheAdapter() {
        let library = library()
        var battery = true
        library.isOnBattery = { battery }
        library.buildsWaitForPower = true
        // nothing queued: nothing to wait for, and the wish ends with the queue
        library.startNextExtraction()
        #expect(!library.waitingForPower && !library.buildsWaitForPower)
        battery = false
        library.startNextExtraction()
        #expect(!library.waitingForPower)
    }
}
