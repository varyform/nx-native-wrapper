import Foundation
import Testing

@testable import NXPlayKit

/// The device service's copies of installed games, laid out as CoreDevice keeps them:
/// `<bundle ID>/<hash of the build>/<device>/<bundle ID>/{Stashed, StashedAppMetadata.plist}`.
@MainActor @Suite final class DeviceInstallCopiesTests {
    private let root: URL
    private let copies: URL
    private let app = "org.nxnative.abcde12345.0100000000010000"

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-copies-\(UUID().uuidString)", directoryHint: .isDirectory)
        copies = root.appending(path: "AppInstallationBinaryDeltas", directoryHint: .isDirectory)
        try write("games/Ready/Ready [0100000000010000][v0].nsp")
        try write("games/Ready/0100000000010000_build/extract/v0/icon.jpg")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func write(_ path: String, size: Int = 1) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: size).write(to: url)
    }

    /// One device's copy of one build, installed `daysAgo`.
    @discardableResult
    private func copy(_ app: String, build: String, device: String, daysAgo: Double, size: Int = 1000) throws -> URL {
        let folder = "AppInstallationBinaryDeltas/\(app)/\(build)/\(device)"
        try write("\(folder)/\(app)/Stashed/DmIOS.app/romfs.img", size: size)
        try write("\(folder)/\(app)/StashedAppMetadata.plist")
        let date = Date.now.addingTimeInterval(-daysAgo * 86400)
        for path in [
            "\(folder)/\(app)/Stashed/DmIOS.app/romfs.img", "\(folder)/\(app)/Stashed/DmIOS.app",
            "\(folder)/\(app)/Stashed", "\(folder)/\(app)/StashedAppMetadata.plist", "\(folder)/\(app)", folder,
        ] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root.appending(path: path).path)
        }
        return root.appending(path: folder, directoryHint: .isDirectory)
    }

    @Test func findsAGamesAppsOnly() throws {
        try copy(app, build: "aa", device: "PHONE", daysAgo: 1)
        try copy("org.nxnative.otherteam.0100000000010000", build: "bb", device: "PHONE", daysAgo: 1)
        try copy("org.nxnative.abcde12345.0100000000020000", build: "cc", device: "PHONE", daysAgo: 1)
        try copy("org.nxplay.ios.ABCDE12345", build: "dd", device: "PHONE", daysAgo: 1)
        let all = try #require(DeviceInstallCopies.apps(in: copies))
        #expect(
            DeviceInstallCopies.apps(of: "0100000000010000", in: all).map(\.lastPathComponent) == [
                app, "org.nxnative.otherteam.0100000000010000",
            ])
        #expect(DeviceInstallCopies.apps(in: root.appending(path: "none")) == [])  // nothing installed yet
    }

    @Test func keepsEachDevicesNewestCopy() throws {
        let phoneOld = try copy(app, build: "aa", device: "PHONE", daysAgo: 9)
        let padOld = try copy(app, build: "aa", device: "PAD", daysAgo: 8)
        let phone = try copy(app, build: "bb", device: "PHONE", daysAgo: 2)
        let padOlder = try copy(app, build: "cc", device: "PAD", daysAgo: 20)
        let pad = try copy(app, build: "dd", device: "PAD", daysAgo: 1)
        let other = try copy("org.nxnative.abcde12345.0100000000020000", build: "aa", device: "PHONE", daysAgo: 30)

        let found = DeviceInstallCopies.copies(in: copies.appending(path: app))
        #expect(Set(DeviceInstallCopies.older(found).map(\.url.lastPathComponent)) == ["PHONE", "PAD"])
        #expect(DeviceInstallCopies.removeOlder(of: "0100000000010000", in: copies) >= 3000)

        for gone in [phoneOld, padOld, padOlder] { #expect(!FileManager.default.fileExists(atPath: gone.path)) }
        for kept in [phone, pad, other] { #expect(FileManager.default.fileExists(atPath: kept.path)) }
        // a build's folder goes with its last copy
        #expect(!FileManager.default.fileExists(atPath: copies.appending(path: "\(app)/aa").path))
        #expect(!FileManager.default.fileExists(atPath: copies.appending(path: "\(app)/cc").path))
        #expect(DeviceInstallCopies.removeOlder(of: "0100000000010000", in: copies) == 0)
    }

    @Test func freeUpSpaceListsThemPerGame() async throws {
        try copy(app, build: "aa", device: "PHONE", daysAgo: 1, size: 5000)
        let games = GameScanner.scan(roots: [root.appending(path: "games")])
        let cleanup = Cleanup(cache: nil, installCopies: copies)
        await cleanup.scan(games: games, busy: [])
        let file = try #require(cleanup.files(.installCopies).first)
        #expect(file.url.lastPathComponent == app && file.blocked == nil && !cleanup.installCopiesHidden)
        #expect(CleanupScanner.groups(games: games).first?.files.contains { $0.kind == .installCopies } == false)

        while cleanup.isMeasuring { await Task.yield() }
        #expect(cleanup.size(.installCopies) >= 5000)
        cleanup.toggle(.installCopies)
        cleanup.confirmation = Cleanup.phrase
        await cleanup.delete()
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func saysWhenMacOSKeepsThemHidden() async throws {
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: copies.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copies.path) }
        #expect(DeviceInstallCopies.apps(in: copies) == nil)
        #expect(DeviceInstallCopies.removeOlder(of: "0100000000010000", in: copies) == 0)
        let cleanup = Cleanup(cache: nil, installCopies: copies)
        await cleanup.scan(games: GameScanner.scan(roots: [root.appending(path: "games")]), busy: [])
        #expect(cleanup.installCopiesHidden)
    }
}
