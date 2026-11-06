import CryptoKit
import Foundation
import Testing

@testable import NXPlayKit

@Suite struct AppUpdateTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: String...) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// An ad-hoc signed "NX Play.app" of a version, in a DMG.
    private func dmg(version: String) throws -> URL {
        let app = root.appending(path: "src/NX Play.app/Contents")
        try FileManager.default.createDirectory(
            at: app.appending(path: "MacOS"), withIntermediateDirectories: true)
        let info: NSDictionary = [
            "CFBundleIdentifier": "com.varyform.nxplay", "CFBundleShortVersionString": version,
            "CFBundleExecutable": "NX Play",
        ]
        info.write(to: app.appending(path: "Info.plist"), atomically: true)
        try FileManager.default.copyItem(
            atPath: "/usr/bin/true", toPath: app.appending(path: "MacOS/NX Play").path)
        try run(
            "/usr/bin/codesign", "--force", "--sign", "-",
            root.appending(path: "src/NX Play.app").path)
        let dmg = root.appending(path: "NX-Play-\(version).dmg")
        #expect(
            try run(
                "/usr/bin/hdiutil", "create", "-quiet", "-volname", "NX Play", "-srcfolder",
                root.appending(path: "src").path, "-format", "UDZO", dmg.path) == 0)
        return dmg
    }

    @Test func readsTheLatestRelease() throws {
        let json = """
            {"tag_name": "v1.7", "body": "notes", "assets": [
              {"name": "NX-Play-1.7.dmg.sha256", "browser_download_url": "https://github.com/x/1.sha256"},
              {"name": "NX-Play-1.7.dmg", "browser_download_url": "https://github.com/x/NX-Play-1.7.dmg",
               "digest": "sha256:ABCDEF"}]}
            """
        let release = try #require(AppUpdater.Release(json: Data(json.utf8)))
        #expect(release.version == "1.7" && release.notes == "notes" && release.sha256 == "ABCDEF")
        #expect(release.dmg.lastPathComponent == "NX-Play-1.7.dmg")
        // no digest, no update: a download that can't be checked isn't installed
        #expect(
            AppUpdater.Release(
                json: Data(json.replacing(#""digest": "sha256:ABCDEF""#, with: #""x": 1"#).utf8))
                == nil)
    }

    @Test func comparesVersions() {
        #expect(AppUpdater.isNewer("1.7", than: "1.6"))
        #expect(AppUpdater.isNewer("1.10", than: "1.9"))
        #expect(AppUpdater.isNewer("1.6.1", than: "1.6"))
        #expect(!AppUpdater.isNewer("1.6", than: "1.6.0"))
        #expect(!AppUpdater.isNewer("1.5", than: "1.6"))
    }

    @Test func checksTheDigest() throws {
        let file = root.appending(path: "f")
        try Data("dmg".utf8).write(to: file)
        let digest = SHA256.hash(data: Data("dmg".utf8)).map { String(format: "%02x", $0) }.joined()
        try AppUpdater.verifyDigest(of: file, expected: digest.uppercased())
        #expect(throws: UpdateError.self) {
            try AppUpdater.verifyDigest(of: file, expected: String(repeating: "0", count: 64))
        }
    }

    @Test func stagesTheAppFromTheDMG() throws {
        let dmg = try dmg(version: "1.7")
        let staged = root.appending(path: "staged/NX Play.app")
        // ad hoc: no team (a release has its Developer ID team), not notarized
        try AppUpdater.stage(
            dmg: dmg, to: staged, bundleID: "com.varyform.nxplay", teamID: "not set",
            version: "1.7", assess: false)
        #expect(
            FileManager.default.fileExists(
                atPath: staged.appending(path: "Contents/MacOS/NX Play").path))

        #expect(throws: UpdateError.self) {
            try AppUpdater.stage(
                dmg: dmg, to: staged, bundleID: "com.varyform.nxplay", teamID: "not set",
                version: "1.8",
                assess: false)
        }
        #expect(throws: UpdateError.self) {
            try AppUpdater.stage(
                dmg: dmg, to: staged, bundleID: "com.varyform.nxplay", teamID: "535S292559",
                version: "1.7",
                assess: false)
        }
    }

    @Test func swapsTheAppOnceTheOldOneHasQuit() async throws {
        let bundle = root.appending(path: "Applications/NX Play.app")
        let staged = root.appending(path: "staged/NX Play.app")
        for (url, text) in [(bundle, "old"), (staged, "new")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url.appending(path: "version"))
        }
        let quitter = Process()
        quitter.executableURL = URL(filePath: "/bin/sleep")
        quitter.arguments = ["60"]  // the test ends it, so a slow machine can't quit it before the check below
        try quitter.run()

        AppUpdater.swap(
            staged: staged, into: bundle, afterPID: quitter.processIdentifier, relaunch: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try String(contentsOf: bundle.appending(path: "version"), encoding: .utf8) == "old")  // still running
        quitter.terminate()
        for _ in 0..<50 {
            if (try? String(contentsOf: bundle.appending(path: "version"), encoding: .utf8))
                == "new"
            {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try String(contentsOf: bundle.appending(path: "version"), encoding: .utf8) == "new")
        // the shell removes the old copy after moving the new one in: wait for that too
        let folder = bundle.deletingLastPathComponent().path
        for _ in 0..<50
        where (try? FileManager.default.contentsOfDirectory(atPath: folder))?.count != 1 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder) == ["NX Play.app"])  // the old one is gone
    }
}
