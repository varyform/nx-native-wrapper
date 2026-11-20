import Foundation
import Testing

@testable import NXPlayKit

struct FailureHelpTests {
    // issue #34: Ocarina of Time's profile behind nxnative's stricter shader check
    @Test func anOutdatedProfileIsNXNativesToFix() throws {
        let help = try #require(
            FailureHelp.read(
                [
                    "nxnative updated: 12 new commits, rebuilding",
                    "nxplay: the build is copied (an APFS clone) until this rebuild is done: if it fails, the game plays as before",
                    "[RED] the split shader tables differ from game profile 0400486024DEC000's:",
                    "Either these game files are another version, or the profile needs splitting again",
                    "nxplay: the rebuild did not finish: the build from before it is back, and the game plays as it did",
                    "nxplay: failed (exit 1)",
                ], status: .failed(1)))
        #expect(help.known == .shaderTables)
        #expect(help.source == .nxnativeBuild)
        #expect(help.restored)
        #expect(help.isNXNatives)
        #expect(!help.retries)
    }

    // issue #35: the Metal compiler dies while the started game prepares its shaders
    @Test func aCompilerCrashInTheGameIsWorthAnotherTry() throws {
        let help = try #require(
            FailureHelp.read(
                [
                    "nxplay: starting the game",
                    "[dm] [RED] pipeline compile: XPC_ERROR_CONNECTION_INTERRUPTED",
                    "-[MTLDebugDevice newRenderPipelineStateWithDescriptor:] failed assertion: vertexFunction must not be nil",
                    "[dm] CRASH sig=6",
                    "launcher: the host exited with 134",
                    "nxplay: failed (exit 134)",
                ], status: .failed(134)))
        #expect(help.known == .metalCompilerCrash)
        #expect(help.source == .game)
        #expect(help.retries)
        #expect(!help.restored)
    }

    @Test func anUnknownCrashInTheGameStillSaysWhose() throws {
        let help = try #require(
            FailureHelp.read(
                ["nxplay: starting the game", "[dm] CRASH sig=11", "nxplay: failed (exit 139)"], status: .failed(139)))
        #expect(help.known == nil)
        #expect(help.source == .game)
        #expect(help.title.contains("139"))
        #expect(help.isNXNatives)
    }

    @Test func nxplaysOwnStopIsNotNXNatives() throws {
        let help = try #require(
            FailureHelp.read(
                [
                    "nxplay: no game files (NSP, NSZ, XCI, XCZ, NUP) in /games/X to build from; put them back to rebuild",
                    "nxplay: failed (exit 1)",
                ], status: .failed(1)))
        #expect(help.source == .nxplay)
        #expect(!help.isNXNatives)
    }

    // a new game's output always says it has no profile: what stopped it is the plainer cause
    @Test func thePlainestCauseWins() throws {
        let help = try #require(
            FailureHelp.read(
                [
                    "no game profile for 0100000000001000: surveying first",
                    "OSError: [Errno 28] No space left on device",
                    "nxplay: failed (exit 1)",
                ], status: .failed(1)))
        #expect(help.known == .diskFull)
        #expect(!help.isNXNatives)
    }

    @Test func onlyAFailureHasHelp() {
        #expect(FailureHelp.read(["nxplay: done"], status: .succeeded) == nil)
        #expect(FailureHelp.read(["nxplay: cancelled"], status: .cancelled) == nil)
    }

    @Test func nxnativesNewerCommitsForAGame() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = root.appending(path: "upstream"), checkout = root.appending(path: "checkout")
        let id = "0400486024DEC000"
        try FileManager.default.createDirectory(
            at: upstream.appending(path: "dm/games/\(id)"), withIntermediateDirectories: true)
        func git(_ repo: URL, _ args: String...) {
            _ = ProfileNews.git(repo, ["-c", "user.name=t", "-c", "user.email=t@t"] + args)
        }
        func commit(_ file: String, _ message: String, at time: Int) throws {
            try UUID().uuidString.write(to: upstream.appending(path: file), atomically: true, encoding: .utf8)
            git(upstream, "add", "-A")
            _ = ProfileNews.git(
                upstream,
                ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message, "--date=\(time) +0000"])
        }
        git(upstream, "init", "-q", "-b", "main")
        try commit("dm/games/\(id)/game.tsv", "game: Ocarina of Time's profile", at: 1_700_000_000)
        _ = ProfileNews.git(root, ["clone", "-q", upstream.path, checkout.path])
        // no news before the upstream moves
        #expect(ProfileNews.newer(repo: checkout, titleID: id).isEmpty)

        try commit("dm/games/\(id)/shader_map.tsv", "game: Ocarina of Time refreshes its BAHS shader map", at: 1_700_000_100)
        try commit("other.txt", "host: something for another game", at: 1_700_000_200)
        try commit("host.txt", "nvn: the fix for 0400486024dec000's movie", at: 1_700_000_300)
        ProfileNews.fetch(repo: checkout)

        #expect(
            ProfileNews.newer(repo: checkout, titleID: id).map(\.subject) == [
                "nvn: the fix for 0400486024dec000's movie",
                "game: Ocarina of Time refreshes its BAHS shader map",
            ])
        #expect(ProfileNews.newer(repo: upstream, titleID: id).isEmpty)  // no upstream of its own
    }
}
