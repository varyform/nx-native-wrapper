import Foundation
import Testing

/// The nxplay script itself, run against a fake nxnative whose build script only records its arguments and writes a
/// build: nxplay runs with set -e and pipefail, so a helper that fails where nothing checks it ends a rebuild with
/// exit 1 and no word of why (issue #36).
@Suite struct NXPlayScriptTests {
    let root: URL
    var game: URL { root.appending(path: "Game", directoryHint: .isDirectory) }
    var build: URL { game.appending(path: "0100000000001000_build", directoryHint: .isDirectory) }
    var repo: URL { root.appending(path: "nxnative", directoryHint: .isDirectory) }

    static let script = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "nxplay")

    /// Writes a launcher and a host to `build` and says the run command, as nxnative's build does; it takes the
    /// options nxplay looks for (--glslc-play, --aoc-dir).
    static let fakeBuild = """
        # takes --glslc-play and --aoc-dir, as nxplay checks before passing them
        import os, sys
        game = sys.argv[1]
        b = os.path.join(game, '0100000000001000_build')
        for d in ('run', 'tools', 'patched_v0'): os.makedirs(os.path.join(b, d), exist_ok=True)
        host = os.path.join(b, 'tools/dmhost')
        open(host, 'w').write('#!/bin/sh\\necho "host ran album=$DM_ALBUM_DIR"\\n'); os.chmod(host, 0o755)
        open(os.path.join(os.path.dirname(game), 'built'), 'a').write(' '.join(sys.argv[2:]) + '\\n')
        print('done: the game runs on the Mac with this command')
        print(f"cd '{b}/run' && '{host}' '{b}/patched_v0'")
        """

    /// Records the mod it prepares and writes its exefs/nxnative, as nxnative's prepare_mod.py does.
    static let fakePrepare = """
        import os, sys
        mod = sys.argv[1]
        os.makedirs(os.path.join(mod, 'exefs/nxnative'), exist_ok=True)
        open(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(mod))), 'prepared'), 'a').write(mod + '\\n')
        """

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-script-\(UUID().uuidString)", directoryHint: .isDirectory)
        try write(repo.appending(path: "scripts/build_ipa_from_nsp.py"), Self.fakeBuild)
        try write(repo.appending(path: "dm/gfx/nvn/dmsh_chain.h"), "#define DMSH_CHAIN \"c1\"\n")
        try write(repo.appending(path: "dm/gfx/tools/dmsh_live.py"), "")
        try write(repo.appending(path: "dm/tools/patch_nso.py"), "# the rewriter\n")
        try write(repo.appending(path: "scripts/prepare_mod.py"), Self.fakePrepare)
        try git("init", "-q")
        try git("add", "-A")
        try git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "fake")
        try write(game.appending(path: "Game.nsp"), "game files")
        try write(root.appending(path: "prod.keys"), "")
    }

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + arguments
        try process.run()
        process.waitUntilExit()
    }

    /// nxplay's exit status and output
    private func nxplay(_ arguments: [String], environment extra: [String: String] = [:]) throws -> (
        Int32, String
    ) {
        let process = Process()
        process.executableURL = Self.script
        process.arguments = arguments + [game.path]
        process.environment = ProcessInfo.processInfo.environment.merging(
            [
                "NXNATIVE": repo.path, "NX_KEYS": root.appending(path: "prod.keys").path,
                "NXPLAY_VENV": root.appending(path: "no-venv").path, "NO_COLOR": "1",
                "NXPLAY_UPDATE": "update",
            ].merging(extra) { $1 }
        ) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }

    /// A build from before 2.3.0, never played since: no glslc_play folder. Its rebuild stopped at once (issue #36).
    @Test func aBuildNeverPlayedSinceRebuilds() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (first, firstOutput) = try nxplay(["--build-only"])
        #expect(first == 0, "\(firstOutput)")
        #expect(!FileManager.default.fileExists(atPath: build.appending(path: "glslc_play").path))

        let (status, output) = try nxplay(["--rebuild", "--build-only"])
        #expect(status == 0, "\(output)")
        let built = try String(contentsOf: root.appending(path: "built"), encoding: .utf8)
        #expect(built.split(separator: "\n").count == 2, "\(built)")
    }

    /// A play with the translator on, of a build whose nxnative tree the checkout no longer has (a rewritten
    /// upstream): its shader chain can't be read, and it plays all the same.
    @Test func aPlayOfABuildFromAForgottenTreeStarts() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try nxplay(["--build-only"]).0 == 0)
        let launcher = build.appending(path: "start_mac.sh")
        let text = try String(contentsOf: launcher, encoding: .utf8)
        try text.replacingOccurrences(
            of: #"# nxnative tree \w+"#, with: "# nxnative tree 0123456789abcdef0123456789abcdef01234567",
            options: .regularExpression
        ).write(to: launcher, atomically: true, encoding: .utf8)

        let (status, output) = try nxplay(
            [], environment: ["NXPLAY_NVN_RUNTIME": "1", "NXPLAY_UPDATE": "current"])
        #expect(status == 0, "\(output)")
        #expect(output.contains("host ran"), "\(output)")
    }

    /// The pictures a game saves to its album go where nxnative's Mac app puts them, not into the build, which Free
    /// Up Space deletes; a player's own folder wins.
    @Test func aPlaySavesAlbumPicturesOutsideTheBuild() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try nxplay(["--build-only"]).0 == 0)
        let pictures = FileManager.default.homeDirectoryForCurrentUser.path + "/Pictures/nxnative/0100000000001000"
        let (status, output) = try nxplay([], environment: ["NXPLAY_UPDATE": "current"])
        #expect(status == 0, "\(output)")
        #expect(output.contains("host ran album=\(pictures)\n"), "\(output)")
        let own = try nxplay([], environment: ["NXPLAY_UPDATE": "current", "DM_ALBUM_DIR": "/elsewhere"])
        #expect(own.1.contains("host ran album=/elsewhere\n"), "\(own.1)")
    }

    /// A mod's code plugins are rewritten for nxnative before the play that first loads them, and again only once
    /// nxnative's rewriter changed.
    @Test func aModsCodeIsPreparedOnceForEachRewriter() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try nxplay(["--build-only"]).0 == 0)
        let mod = game.appending(path: "Mods/Compass", directoryHint: .isDirectory)
        try write(mod.appending(path: "exefs/subsdk9"), "NSO0")
        try write(game.appending(path: "Mods/Files/romfs/a"), "a")
        let env = [
            "NXPLAY_UPDATE": "current",
            "DM_ROMFS_OVERLAY": "\(game.path)/Mods/Files/romfs:\(mod.path)/romfs",
        ]
        func prepared() -> [String] {
            ((try? String(contentsOf: root.appending(path: "prepared"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        let (status, output) = try nxplay([], environment: env)
        #expect(status == 0, "\(output)")
        #expect(output.contains("preparing Compass's code"), "\(output)")
        #expect(prepared() == [mod.path])
        #expect(try nxplay([], environment: env).0 == 0)
        #expect(prepared().count == 1)

        try write(repo.appending(path: "dm/tools/patch_nso.py"), "# the rewriter, changed\n")
        try git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", "rewriter")
        #expect(try nxplay([], environment: env).0 == 0)
        #expect(prepared().count == 2)
    }
}
