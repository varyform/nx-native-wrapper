import Foundation
import Testing

@testable import NXPlayKit

@MainActor @Suite struct SaveBackupTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-backup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func game(_ name: String, titleID: String? = "0100F2C0115B6000", folder: URL? = nil)
        -> Game
    {
        Game(
            folder: folder ?? root.appending(path: name), name: name, titleID: titleID,
            version: nil,
            languages: [], iconURL: nil, buildFolder: nil, ipaURL: nil, xcodeBuildFolder: nil,
            hasPackages: true, state: .ready)
    }

    @discardableResult
    private func git(_ arguments: String..., in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", dir.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// A bare repository standing in for the private remote, and a clone of it.
    private func clone(_ name: String = "clone") throws -> (remote: URL, clone: URL) {
        let remote = root.appending(path: "remote.git")
        if !FileManager.default.fileExists(atPath: remote.path) {
            try git("init", "-q", "--bare", "-b", "main", remote.path, in: root)
        }
        let clone = root.appending(path: name)
        try git("clone", "-q", remote.path, clone.path, in: root)
        try git("config", "user.name", "Test", in: clone)
        try git("config", "user.email", "test@example.com", in: clone)
        return (remote, clone)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func folderNames() {
        let name = { SaveBackup.folderName(for: game($0)) }
        #expect(
            name("The Legend of Zelda™: Tears of the Kingdom")
                == "the-legend-of-zelda-tears-of-the-kingdom-0100f2c0115b6000")
        #expect(name("Pokémon™ Scarlet") == "pokemon-scarlet-0100f2c0115b6000")
        #expect(
            name("Assassin’s Creed: The Rebel Collection")
                == "assassins-creed-the-rebel-collection-0100f2c0115b6000")
        #expect(name("ゼルダの伝説") == "0100f2c0115b6000")
        #expect(SaveBackup.folderName(for: game("Wonder", titleID: nil)) == nil)
    }

    @Test func aSaveIsBackedUpOnceItSettles() {
        var settle = SaveSettle()
        let looks: [[String: String]?] = [
            nil,  // no save yet
            ["a": "1"],  // first seen
            ["a": "1"],  // the same a look later: back it up
            ["a": "1"],  // backed up already
            ["a": "2"],  // being written
            ["a": "3"],
            ["a": "3"],
        ]
        let backups = looks.map { settle.changed($0) }
        #expect(backups == [false, false, true, false, false, false, true])
    }

    @Test func mirrorsCommitsAndPushesTheSave() async throws {
        let (remote, clone) = try clone()
        let save = root.appending(path: "save")
        try write("slot 1", to: save.appending(path: "0/slot1.sav"))
        try write("options", to: save.appending(path: "0/options.sav"))
        let repository = SaveRepository()
        let folder = "zelda-0100f2c0115b6000"

        let first = await repository.backUp(save, into: clone, folder: folder, game: "Zelda")
        #expect(first == "save backup: committed 2 files in \(folder), pushed")
        #expect(try git("log", "--format=%s", "main", in: remote).hasPrefix("Zelda: save of "))
        #expect(await repository.backUp(save, into: clone, folder: folder, game: "Zelda") == nil)

        // a removed file goes from the backup too
        try FileManager.default.removeItem(at: save.appending(path: "0/options.sav"))
        try write("slot 1, later", to: save.appending(path: "0/slot1.sav"))
        let second = await repository.backUp(save, into: clone, folder: folder, game: "Zelda")
        #expect(second == "save backup: committed 2 files in \(folder), pushed")
        #expect(
            try git("ls-tree", "-r", "--name-only", "main", in: remote) == "\(folder)/0/slot1.sav\n"
        )
    }

    /// The device save, the other local users' saves and their registry go beside the game's folder, under nxnative's
    /// names, and count for when the save changed.
    @Test func backsUpWhatNXNativeKeepsBesideTheSave() async throws {
        let (remote, clone) = try clone()
        let save = root.appending(path: "save")
        try write("slot 1", to: save.appending(path: "slot1.sav"))
        let before = SaveSettle.fingerprint(save)
        try write("device", to: root.appending(path: "save_device/d.sav"))
        try write("player 2", to: root.appending(path: "save_user2/slot1.sav"))
        try write("nxnative-users-1 6", to: root.appending(path: "save.users"))
        #expect(SaveSettle.fingerprint(save).count == before.count + 3)

        let note = await SaveRepository().backUp(save, into: clone, folder: "zelda-1", game: "Zelda")
        #expect(note == "save backup: committed 4 files in zelda-1, pushed")
        #expect(
            try git("ls-tree", "-r", "--name-only", "main", in: remote)
                == "zelda-1.users\nzelda-1/slot1.sav\nzelda-1_device/d.sav\nzelda-1_user2/slot1.sav\n")
    }

    @Test func anotherMacsPushIsReplayedUnder() async throws {
        let (remote, clone) = try clone()
        let save = root.appending(path: "save")
        try write("slot", to: save.appending(path: "slot.sav"))
        let repository = SaveRepository()
        _ = await repository.backUp(save, into: clone, folder: "zelda-1", game: "Zelda")

        // the other Mac pushes its game's save meanwhile
        let (_, other) = try self.clone("other")
        try write("wonder", to: other.appending(path: "wonder-2/slot.sav"))
        try git("add", "-A", in: other)
        try git("commit", "-q", "-m", "Wonder", in: other)
        try git("push", "-q", in: other)

        try write("slot, later", to: save.appending(path: "slot.sav"))
        let note = await repository.backUp(save, into: clone, folder: "zelda-1", game: "Zelda")
        #expect(note == "save backup: committed 1 file in zelda-1, pushed")
        #expect(try git("log", "--format=%s", "main", in: remote).split(separator: "\n").count == 3)
    }

    @Test func notARepository() async throws {
        let save = root.appending(path: "save")
        try write("slot", to: save.appending(path: "slot.sav"))
        let note = await SaveRepository().backUp(save, into: root, folder: "x", game: "X")
        #expect(note?.contains("is not a Git repository") == true)
    }

    @Test func aPlayIsWatchedUntilItEnds() async throws {
        let (remote, clone) = try clone()
        let folder = root.appending(path: "Zelda")
        let save = folder.appending(path: "0100F2C0115B6000_build/run/save")
        try write("slot", to: save.appending(path: "slot.sav"))
        let job = Job(
            kind: .play, game: game("Zelda", folder: folder),
            command: NXPlayCommand(
                script: URL(filePath: "/usr/bin/true"), arguments: [], environment: [:]))
        job.showScreenshot([], status: .running)

        let backup = SaveBackup()
        backup.watch(job, into: clone, interval: .milliseconds(50))
        let pushed = { job.log.lines.contains { $0.text.hasPrefix("save backup: committed") } }
        for _ in 0..<100 where !pushed() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(pushed())

        // the game saves once more as it quits: the backup after the play takes it
        try write("slot, at quit", to: save.appending(path: "slot.sav"))
        job.showScreenshot([], status: .succeeded)
        for _ in 0..<100 {
            if try git("log", "--format=%s", "main", in: remote).split(separator: "\n").count == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(
            try git("show", "main:zelda-0100f2c0115b6000/slot.sav", in: remote) == "slot, at quit")
    }
}
