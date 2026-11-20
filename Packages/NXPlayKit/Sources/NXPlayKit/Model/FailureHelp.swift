import Foundation

/// Why a job failed, in words a player can act on, worked out from its output alone (no network, no AI): which part
/// stopped, what a known failure means, and what can help. Most failures are nxnative's (its build, its host running the
/// game), and NX Play can't fix those; saying so up front sends the player to what can help, and bug reports to
/// nxnative rather than here (issues #34 and #35).
public struct FailureHelp: Equatable, Sendable {
    /// The part that stopped.
    public enum Source: Equatable, Sendable {
        /// nxnative's build (build_ipa_from_nsp.py and its tools).
        case nxnativeBuild
        /// The game, running in nxnative's host, after it started.
        case game
        /// nxplay or NX Play: their own message says why.
        case nxplay
    }

    /// A failure seen before, by its message: each an explanation and what to do. The first that matches wins, so the
    /// plainest causes come first: a new game's output always says it has no profile, whatever then stops it.
    public enum Known: String, CaseIterable, Sendable {
        case diskFull, keys, otherMetal, shaderTables, metalCompilerCrash, newGame
    }

    public let source: Source
    public let known: Known?
    /// nxplay put back the build from before the failed rebuild (its APFS clone): it plays as it did.
    public let restored: Bool
    /// The process's exit code, as the log's last line has it.
    public let exitCode: Int32

    /// What stopped, in one line.
    public var title: String {
        switch (known, source) {
        case (.shaderTables?, _): "nxnative's profile for this game is out of date"
        case (.metalCompilerCrash?, _): "macOS's Metal shader compiler crashed"
        case (.otherMetal?, _): "This Mac's Metal compiler is newer than nxnative's"
        case (.keys?, _): "The keys can't open these game files"
        case (.newGame?, _): "nxnative doesn't know this game yet"
        case (.diskFull?, _): "The drive is full"
        case (nil, .nxnativeBuild): "nxnative's build stopped"
        case (nil, .game): "The game stopped in nxnative (exit \(exitCode))"
        case (nil, .nxplay): "nxplay stopped"
        }
    }

    /// What it means, and whose it is to fix.
    public var explanation: String {
        switch known {
        case .shaderTables?:
            """
            nxnative checks the game's shaders against the list in its profile for this game, and they no longer \
            match: a change in nxnative needs the profile updated too. It's fixed in nxnative, not in NX Play: once an \
            nxnative update brings the fix, rebuilding works.
            """
        case .metalCompilerCrash?:
            """
            While nxnative prepared the game's shaders, macOS's Metal compiler (MTLCompilerService) crashed on one of \
            them. It happens on some Macs and not others, and trying again often gets through. It's nxnative's to work \
            around, not NX Play's.
            """
        case .otherMetal?:
            """
            nxnative tested its shaders with another version of Xcode's Metal compiler, so it stopped the build. \
            Install the Xcode version it names, or turn on “Allow a Metal compiler nxnative didn't test” in Settings.
            """
        case .keys?:
            """
            nxnative couldn't decrypt the game files with this prod.keys: it's missing keys for this game or its \
            update. Dump the keys again from a console with the newest system update, and set the file in Settings.
            """
        case .newGame?:
            """
            nxnative has no profile for this game, so it tried to work one out itself, and that didn't get far enough \
            to play. Support for a game is added in nxnative; look for it in nxnative's issues, or ask for it there.
            """
        case .diskFull?:
            "The build ran out of space on the games drive. Free Up Space removes what nxnative and NX Play can make again."
        case nil:
            switch source {
            case .nxnativeBuild:
                """
                NX Play builds games with nxnative, and nxnative's build stopped: its last lines above say where. \
                NX Play can't fix that, but a newer nxnative often has, so look below.
                """
            case .game:
                """
                The game started and then ended with an error in nxnative's host, which runs it. Its last lines above \
                say where. NX Play can't fix that, but a newer nxnative may have.
                """
            case .nxplay:
                "nxplay's last message above says why."
            }
        }
    }

    /// Worth trying again as it is: a failure that comes and goes.
    public var retries: Bool { known == .metalCompilerCrash }

    /// Something nxnative can fix: worth a look at its newer commits and its issues.
    public var isNXNatives: Bool {
        switch known {
        case .keys?, .diskFull?, .otherMetal?: false
        default: source != .nxplay
        }
    }

    /// The help for a failed job's output, newest lines last; nil when it didn't fail. `allowsOtherMetal`: nxnative
    /// was told to build with this Mac's Metal compiler, so its line about another one didn't stop the build.
    static func read(_ lines: [String], status: Job.Status, allowsOtherMetal: Bool = false) -> FailureHelp? {
        guard case .failed(let code) = status else { return nil }
        // the end of a long run is where its failure is; a whole game session can be 100,000 lines
        let tail = lines.suffix(1500)
        let started = tail.contains { $0.contains(gameStartedLine) }
        let restored = tail.contains { $0.contains(restoredLine) }
        let known = Known.allCases.first { kind in
            !(kind == .otherMetal && allowsOtherMetal) && kind.markers.contains { marker in tail.contains { $0.contains(marker) } }
        }
        let source: Source
        if started {
            source = .game
        } else if let last = tail.last(where: { !$0.hasPrefix("nxplay: failed") && !$0.isEmpty }),
            last.hasPrefix("nxplay: "), !last.contains(restoredLine)
        {
            source = .nxplay
        } else {
            source = .nxnativeBuild
        }
        return FailureHelp(source: source, known: known, restored: restored, exitCode: code)
    }

    /// nxplay's line when it hands over to the game.
    static let gameStartedLine = "nxplay: starting the game"
    /// nxplay's line when it put the build back after a rebuild that didn't finish (nxplay's restore_build).
    static let restoredLine = "the build from before it is back"
}

extension FailureHelp.Known {
    /// The lines that give it away, as nxnative and macOS print them.
    var markers: [String] {
        switch self {
        // build_ipa_from_nsp.py's BuildError
        case .shaderTables: ["split shader tables differ from game profile"]
        // nvn_mtl.m's compiler-death test, and Metal's abort on the pipeline it then has no function for (nxnative #2825)
        case .metalCompilerCrash:
            ["XPC_ERROR_CONNECTION_INTERRUPTED", "MTLCompilerService", "Function must not be nil", "function must not be nil"]
        case .otherMetal: [Library.otherMetalMarker]
        // build_ipa_from_nsp.py's KEYS_RED, nx_extract's lines for keys that can't open the files
        case .keys: ["prod.keys has no", "no title key for rights ID"]
        case .newGame: ["no game profile for"]
        case .diskFull: ["No space left on device", "ENOSPC"]
        }
    }
}
