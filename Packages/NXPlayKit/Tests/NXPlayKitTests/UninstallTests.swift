import Foundation
import Testing

@testable import NXPlayKit

@Suite struct UninstallTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-uninstall-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func make(_ path: String) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: url.appending(path: "file"))
        return url
    }

    @Test func listsOnlyWhatExists() throws {
        let home = root.appending(path: "home")
        let appHome = try make("home/Library/Application Support/NX Play")
        _ = try make("home/Library/Caches/com.example.nxplay")
        let bundle = try make("Applications/NX Play.app")
        let items = Uninstaller.items(
            home: home, appHome: appHome, bundle: bundle, domain: "com.example.nxplay")
        #expect(items.map(\.id) == ["home", "caches", "settings", "app"])  // no web storage or window state here
        #expect(Uninstaller.size(of: appHome) >= 4096)
    }

    @Test func readsTheBrewfile() throws {
        let brewfile = root.appending(path: "Brewfile")
        try Data(
            """
            # comment
            brew "uv"            # Python
            brew "zstd"
            cask "dotnet-sdk"    # nx_extract

            """.utf8
        ).write(to: brewfile)
        let tools = Uninstaller.brewfileTools(brewfile)
        #expect(tools.map(\.name) == ["uv", "zstd", "dotnet-sdk"])
        #expect(tools.map(\.cask) == [false, false, true])
    }

    @Test func unpinsOnlyThisAppFromTheDock() throws {
        // a stand-in for com.apple.dock: the real one is never written by a test
        let dock = testDefaultsName()
        defer { removeTestDefaults(dock) }
        func app(_ bundleID: String, _ path: String) -> [String: Any] {
            [
                "GUID": Int.random(in: 1...999_999), "tile-type": "file-tile",
                "tile-data": [
                    "bundle-identifier": bundleID, "file-label": path,
                    "file-data": ["_CFURLString": "file://\(path)/", "_CFURLStringType": 15],
                ],
            ]
        }
        let apps = [
            app("com.apple.Safari", "/Applications/Safari.app"),
            app("com.varyform.nxplay", "/Applications/NX Play.app"),
            app("dev.zed.Zed", "/Applications/Zed.app"),
            app("com.varyform.nxplay", "/Users/me/Apps/NX Play.app"),
        ]
        CFPreferencesSetAppValue("persistent-apps" as CFString, apps as CFArray, dock as CFString)
        CFPreferencesSetAppValue("orientation" as CFString, "left" as CFString, dock as CFString)
        CFPreferencesAppSynchronize(dock as CFString)

        #expect(Uninstaller.dockEntries(of: "com.varyform.nxplay", in: dock) == 2)
        #expect(Uninstaller.removeDockEntries(of: "com.varyform.nxplay", in: dock) == 2)
        let left = try #require(
            CFPreferencesCopyAppValue("persistent-apps" as CFString, dock as CFString)
                as? [[String: Any]])
        #expect(
            left.compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String }
                == ["com.apple.Safari", "dev.zed.Zed"])
        #expect(
            left.map { $0["GUID"] as? Int } == [apps[0]["GUID"] as? Int, apps[2]["GUID"] as? Int])
        #expect(
            CFPreferencesCopyAppValue("orientation" as CFString, dock as CFString) as? String
                == "left")
        #expect(Uninstaller.removeDockEntries(of: "com.varyform.nxplay", in: dock) == 0)  // nothing more
    }

    @Test func keepsOnlyNamesFromHomebrewsOutput() {
        let output = """
            Warning: Calling `postflight` is deprecated! Use `postflight_steps` instead.
            Please report this issue to the stared/homebrew-doom tap (not Homebrew/* repositories):
              /opt/homebrew/Library/Taps/stared/homebrew-doom/Casks/uzdoom.rb:14

            llvm
            llvm@22
            python@3.14
            """
        #expect(Uninstaller.lines(output) == ["llvm", "llvm@22", "python@3.14"])
        #expect(
            UninstallView.neededBy(["llvm", "node", "mysql", "rust"]) == "llvm, node and 2 more")
    }

    @Test func cleansUpOnceTheAppHasQuit() async throws {
        let appHome = try make("NX Play")
        let caches = try make("Caches/x")
        let domain = "nxplay-uninstall-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set("~/Games", forKey: "gamesRoot")
        defaults.synchronize()
        let app = Process()
        app.executableURL = URL(filePath: "/bin/sleep")
        app.arguments = ["60"]  // the test ends it, so a slow machine can't quit it before the check below
        try app.run()

        Uninstaller.cleanUp(
            afterPID: app.processIdentifier, folders: [appHome, caches], domain: domain)
        try await Task.sleep(for: .milliseconds(200))
        #expect(FileManager.default.fileExists(atPath: appHome.path))  // the app still runs
        app.terminate()
        // the shell removes one folder after the other: wait for both
        for _ in 0..<50
        where [appHome, caches].contains(where: { FileManager.default.fileExists(atPath: $0.path) })
        {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!FileManager.default.fileExists(atPath: appHome.path))
        #expect(!FileManager.default.fileExists(atPath: caches.path))
        let plist = FileManager.default.homeDirectoryForCurrentUser.appending(
            path: "Library/Preferences/\(domain).plist")
        // the settings go after the folders
        for _ in 0..<50 where FileManager.default.fileExists(atPath: plist.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!FileManager.default.fileExists(atPath: plist.path))
    }
}
