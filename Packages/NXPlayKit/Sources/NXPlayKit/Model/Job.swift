import Foundation
import Observation

/// One nxplay run for a game: an extraction (build without starting) or a play, with its live output.
@MainActor @Observable
public final class Job: Identifiable {
    public enum Kind: Hashable, Sendable {
        case extract, rebuild, play, ipa
        /// nxnative's --platform mac-app: a standalone app of the game in its folder.
        case macApp
        /// Through Xcode: prepare the project, build it signed, install and start it.
        case install(Device)

        /// Builds in the Mac build's work folder with the current nxnative, rewriting the patched game code and the
        /// shader tables its launcher runs: not for a kept build.
        public var rewritesTheMacBuild: Bool {
            switch self {
            case .ipa, .macApp, .install: true
            case .extract, .rebuild, .play: false
            }
        }
    }

    public enum Status: Equatable, Sendable {
        case queued, running, succeeded
        case failed(Int32)
        case cancelled

        public var isActive: Bool { self == .queued || self == .running }
    }

    public let id = UUID()
    public let kind: Kind
    public let game: Game
    public private(set) var status: Status = .queued
    public private(set) var progress: BuildProgress?
    public private(set) var log = LogBuffer()

    @ObservationIgnored let command: NXPlayCommand
    @ObservationIgnored var onFinish: ((Job) -> Void)?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var exitCode: Int32?
    @ObservationIgnored private var outputClosed = false
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var ansi = ANSIParser()
    @ObservationIgnored private var output = BuildOutputReader()
    /// Seconds between the escalating stop signals.
    @ObservationIgnored var stopGrace: TimeInterval = 5

    init(kind: Kind, game: Game, command: NXPlayCommand) {
        self.kind = kind
        self.game = game
        self.command = command
    }

    /// A build that is still going: a play job builds first when the game is not ready or nxnative changed.
    public var isBuilding: Bool {
        status == .running && progress.map { !$0.isLastStageDone } == true
    }

    /// nxplay has handed over to the game (its "nxplay: starting the game" line).
    public private(set) var gameStarted = false
    /// What nxplay last said about getting ready ("nxnative updated: 3 new commits, rebuilding").
    public private(set) var note: String?

    /// A play still getting ready: nxplay updating nxnative and working out whether the game needs a rebuild,
    /// before any build stage or the game itself. A few seconds that otherwise looked like nothing happening.
    public var isPreparing: Bool {
        kind == .play && status == .running && progress == nil && !gameStarted
    }

    /// Build work to show progress for: an extraction, rebuild, IPA, app or install, queued or running, or a play
    /// while it gets ready and builds (not the game itself).
    public var showsProgress: Bool {
        status.isActive && (kind != .play || status == .queued || isPreparing || isBuilding)
    }

    /// The whole build done so far, 0 while it waits its turn.
    public var progressFraction: Double { status == .queued ? 0 : progress?.fraction ?? 0 }

    /// "4/6 shader split · splitting · 69% · 0:04 left"
    public var progressText: String {
        if status == .queued { return "Waiting for the current build" }
        if isPreparing { return note ?? "Checking for nxnative updates…" }
        return progress?.summary ?? "Starting…"
    }

    /// A line from NX Play itself in the run's log (the save backup's).
    func note(_ line: String) {
        log.append([line])
    }

    func start() {
        guard status == .queued else { return }
        status = .running
        log.append(["$ " + command.displayLine])

        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [command.script.path] + command.arguments
        process.environment = command.environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let job = self
        let splitter = LockedLineSplitter()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            let closed = data.isEmpty
            if closed { handle.readabilityHandler = nil }
            let lines = closed ? splitter.finish() : splitter.feed(data)
            guard closed || !lines.isEmpty else { return }
            // the main queue keeps the chunks in order
            DispatchQueue.main.async {
                MainActor.assumeIsolated { job.received(lines, closed: closed) }
            }
        }
        process.terminationHandler = { process in
            let code = process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { job.exited(code) } }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            log.append([
                "nxplay: cannot start \(command.script.path): \(error.localizedDescription)"
            ])
            finish(.failed(-1))
        }
    }

    /// Stops the whole process tree: Process puts the child in a process group of its own, so the
    /// signals reach bash, the python build and its tools, or the game. SIGINT first (the build stops
    /// cleanly on it), then SIGTERM and SIGKILL for what ignores it or outlives bash: a script's
    /// background jobs ignore SIGINT.
    public func cancel() {
        switch status {
        case .queued:
            finish(.cancelled)
        case .running:
            guard let process, process.isRunning, !cancelRequested else { return }
            cancelRequested = true
            log.append(["nxplay: stopping…"])
            let group = process.processIdentifier
            if kill(-group, SIGINT) != 0 { process.interrupt() }
            for (step, signal) in [SIGTERM, SIGKILL].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + stopGrace * Double(step + 1)) {
                    _ = kill(-group, signal)
                }
            }
        default:
            break
        }
    }

    /// The app is quitting: no grace period.
    func terminate() {
        if status == .queued { finish(.cancelled) }
        guard let process, process.isRunning else { return }
        cancelRequested = true
        if kill(-process.processIdentifier, SIGTERM) != 0 { process.terminate() }
    }

    #if DEBUG
        /// Screenshot mode: output as if nxplay had printed it, in the given state, without a process.
        func showScreenshot(_ lines: [String], status: Status) {
            self.status = .running
            log.append(["$ " + command.displayLine])
            received(lines, closed: false)
            self.status = status
        }
    #endif

    private func received(_ lines: [String], closed: Bool) {
        if !lines.isEmpty {
            let shown = lines.flatMap { output.read($0) }
            if !shown.isEmpty {
                let parsed = shown.map { ansi.parse($0) }
                log.append(parsed)
                for line in parsed.map(\.text) {
                    if line.hasPrefix("nxplay: starting the game") {
                        gameStarted = true
                    } else if line.hasPrefix("nxnative") || line.hasPrefix("nxplay:") {
                        note = line
                    }
                }
            }
            if output.progress != progress { progress = output.progress }
        }
        if closed {
            outputClosed = true
            finishIfDone()
        }
    }

    private func exited(_ code: Int32) {
        exitCode = code
        finishIfDone()
        // something the game left running may hold the output open: stop waiting for it
        let job = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                job.outputClosed = true
                job.finishIfDone()
            }
        }
    }

    private func finishIfDone() {
        guard status == .running, outputClosed, let exitCode else { return }
        process?.terminationHandler = nil
        process = nil
        finish(cancelRequested ? .cancelled : exitCode == 0 ? .succeeded : .failed(exitCode))
    }

    private func finish(_ status: Status) {
        self.status = status
        switch status {
        case .succeeded: log.append(["nxplay: done"])
        case .failed(let code): log.append(["nxplay: failed (exit \(code))"])
        case .cancelled: log.append(["nxplay: cancelled"])
        default: break
        }
        onFinish?(self)
    }
}
