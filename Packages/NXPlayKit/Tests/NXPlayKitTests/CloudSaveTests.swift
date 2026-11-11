import Darwin
import Foundation
import Testing

@testable import NXPlayKit

/// The cloud save comparison before a play, against nxnative's save sync (dm/host/save_sync.c): the hashes here are
/// what its ss_scan gives for the same folders.
@Suite final class CloudSaveTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-cloud-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func write(_ text: String, _ path: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A save with a folder, an empty folder, Finder's .DS_Store, a guest name and a device save.
    private func save() throws -> URL {
        try write("hello", "f/save/a.bin")
        try write("x", "f/save/dir/b")
        try write("yz", "f/save_device/c")
        try write("junk", "f/save/.DS_Store")
        try FileManager.default.createDirectory(
            at: root.appending(path: "f/save/empty"), withIntermediateDirectories: true)
        let guest = Array("Case.bin".utf8)
        #expect(setxattr(root.appending(path: "f/save/dir/b").path, "org.d2rmobile.guest-name", guest, guest.count, 0, 0) == 0)
        return root.appending(path: "f/save", directoryHint: .isDirectory)
    }

    /// A packed save's header as ss_pack writes it.
    private func packed(hash: String, saved: Int64, title: String, device: String) -> Data {
        var data = Data("DMSYNC1\n".utf8)
        withUnsafeBytes(of: UInt32(1).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(3).littleEndian) { data.append(contentsOf: $0) }
        func field(_ text: String, _ size: Int) {
            data.append(contentsOf: Array(text.utf8) + [UInt8](repeating: 0, count: size - text.utf8.count))
        }
        field(hash, 32)
        withUnsafeBytes(of: saved.littleEndian) { data.append(contentsOf: $0) }
        field(title, 24)
        field(device, 64)
        return data + Data("the entries".utf8)
    }

    @Test func theHashIsTheHosts() throws {
        let save = try save()
        let snapshot = try #require(CloudSave.scan(save))
        #expect(snapshot.hash == "1c791240199a08357ee2e6e6a2ee1f0f")

        try write("", "h/save/zero")
        #expect(CloudSave.scan(root.appending(path: "h/save"))?.hash == "3f4fe5831323a9dd9bc84a00c9107b42")
        try FileManager.default.createDirectory(
            at: root.appending(path: "g/save"), withIntermediateDirectories: true)
        #expect(CloudSave.scan(root.appending(path: "g/save"))?.hash == "")  // no save
    }

    @Test func readsTheCloudsHeaderAndTheBase() throws {
        let file = root.appending(path: "save.dmsync")
        try packed(hash: String(repeating: "ab", count: 16), saved: 1_794_000_000, title: "0100C6F01C4F8000", device: "iPhone17,1")
            .write(to: file)
        let header = try #require(CloudSave.header(of: file, titleID: "0100c6f01c4f8000"))
        #expect(header.hash == String(repeating: "ab", count: 16))
        #expect(header.saved == Date(timeIntervalSince1970: 1_794_000_000) && header.device == "iPhone17,1")
        #expect(CloudSave.header(of: file, titleID: "0100000000010000") == nil)  // another game's

        try write("base\t\(String(repeating: "cd", count: 16))\nother\t1\n", "s/save.sync")
        #expect(CloudSave.base(of: root.appending(path: "s/save")) == String(repeating: "cd", count: 16))
        #expect(CloudSave.base(of: root.appending(path: "none/save")) == "")
    }

    @Test func asksOnlyWhenBothChanged() throws {
        let save = try save()
        let here = "1c791240199a08357ee2e6e6a2ee1f0f", other = String(repeating: "ef", count: 16)
        let cloud = root.appending(path: "save.dmsync")
        let id = "0100C6F01C4F8000"
        try packed(hash: other, saved: 1, title: id, device: "iPhone17,1").write(to: cloud)

        // this Mac's first sync with a save of its own
        guard case .bothChanged(let mine, let theirs) = CloudSave.check(save: save, cloud: cloud, titleID: id)
        else { Issue.record("expected a question"); return }
        #expect(mine.hash == here && theirs.hash == other)

        let sync = URL(filePath: save.path + ".sync")
        try Data("base\t\(here)\n".utf8).write(to: sync)  // only the cloud's changed
        #expect(CloudSave.check(save: save, cloud: cloud, titleID: id) == .nothingToChoose)
        try Data("base\t\(other)\n".utf8).write(to: sync)  // only this one changed
        #expect(CloudSave.check(save: save, cloud: cloud, titleID: id) == .nothingToChoose)
        try Data("base\t\(String(repeating: "00", count: 16))\n".utf8).write(to: sync)
        #expect(CloudSave.check(save: save, cloud: cloud, titleID: id) != .nothingToChoose)

        try packed(hash: here, saved: 1, title: id, device: "").write(to: cloud)  // the same save
        #expect(CloudSave.check(save: save, cloud: cloud, titleID: id) == .nothingToChoose)
        try FileManager.default.removeItem(at: cloud)  // nothing in the cloud
        #expect(CloudSave.check(save: save, cloud: cloud, titleID: id) == .nothingToChoose)
        // there, and not readable (as one iCloud can't download): the play says offline, not ask
        try packed(hash: other, saved: 1, title: id, device: "").write(to: cloud)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: cloud.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cloud.path) }
        #expect(CloudSave.check(save: save, cloud: cloud, titleID: id) == .cloudUnread)
    }

    @Test func aCloudThatDoesntAnswerIsUnread() async throws {
        let save = try save()
        let fifo = root.appending(path: "slow.dmsync")  // a read that never ends
        #expect(mkfifo(fifo.path, 0o644) == 0)
        let check = await Library.checkCloud(save: save, cloud: fifo, titleID: "0100C6F01C4F8000", timeout: 0.2)
        #expect(check == .cloudUnread)
        // unblock the reader left waiting on the pipe
        let writer = open(fifo.path, O_WRONLY | O_NONBLOCK)
        if writer >= 0 { close(writer) }
    }

    @Test func theCloudFileAndTheChoiceAsTheHostReadsThem() {
        let home = URL(filePath: "/Users/p", directoryHint: .isDirectory)
        #expect(CloudSave.file(target: "0", titleID: "01ab", home: home) == nil)
        #expect(
            CloudSave.file(target: "icloud", titleID: "01ab", home: home)?.path
                == "/Users/p/Library/Mobile Documents/com~apple~CloudDocs/nxnative Saves/01AB/save.dmsync")
        #expect(CloudSave.file(target: "/s/", titleID: "01ab", home: home)?.path == "/s/01AB/save.dmsync")
        #expect(CloudSave.file(target: "/s/01ab", titleID: "01AB", home: home)?.path == "/s/01ab/save.dmsync")

        #expect(CloudSave.Choice.none.environment == "ask")
        #expect(CloudSave.Choice.offline.environment == "offline")
        #expect(CloudSave.Choice.cloud("ab").environment == "cloud:ab")
        #expect(CloudSave.Choice.here("ab").environment == "local:ab")
        #expect(CloudSave.Choice.here("").environment == "local:none")
    }
}
