import Foundation
import Observation

/// Settings › Setup: runs the bundled bin/setup (AppHome.setupProject), the same script a developer runs from the
/// checkout, to check what the builds need and install what's missing. Homebrew is the one prerequisite the player
/// installs; Homebrew's tools, Python with nxnative's packages and nxnative itself come from here, all
/// but Homebrew's into AppHome.folder. The script's ✓ ! ✗ lines become the rows; the rest is the log.
@MainActor @Observable
public final class Setup {
    public struct Item: Identifiable, Equatable, Sendable {
        public enum State: Sendable { case ok, warning, missing }
        public let id: Int
        public let section: String
        public let state: State
        public let text: String
    }

    public enum Phase: Equatable, Sendable { case idle, checking, installing }

    public private(set) var items: [Item] = []
    public private(set) var phase: Phase = .idle
    public private(set) var log = LogBuffer()
    /// The last run's exit status: nil before the first.
    public private(set) var succeeded: Bool?

    public var missing: [Item] { items.filter { $0.state == .missing } }
    public var homebrewMissing: Bool {
        missing.contains { $0.text.hasPrefix("Homebrew is not installed") }
    }

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var ansi = ANSIParser()
    @ObservationIgnored private var parser = SetupParser()
    private let environment: () -> [String: String]
    private let script: URL?

    public init(library: Library) {
        script =
            AppHome.setupProject?.appending(path: "setup")
            ?? AppHome.sourceRoot?.appending(path: "bin/setup")
        environment = { [weak library] in library?.setupEnvironment() ?? [:] }
    }

    init(script: URL?, environment: @escaping () -> [String: String]) {
        self.script = script
        self.environment = environment
    }

    public func check() { run(install: false) }
    public func install() { run(install: true) }

    public func stop() {
        guard let process, process.isRunning else { return }
        kill(-process.processIdentifier, SIGINT)
    }

    private func run(install: Bool) {
        guard phase == .idle else { return }
        guard let script else {
            log.append(["setup: the setup script is missing from the app bundle"])
            succeeded = false
            return
        }
        phase = install ? .installing : .checking
        if install { log = LogBuffer() }
        parser = SetupParser()
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        let developer = AppHome.sourceRoot != nil
        process.arguments =
            [script.path] + (install ? [] : ["--check"]) + (developer ? ["--no-app"] : [])
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let splitter = LockedLineSplitter()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            let closed = data.isEmpty
            if closed { handle.readabilityHandler = nil }
            let lines = closed ? splitter.finish() : splitter.feed(data)
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for line in lines { self.parser.read(line) }
                    self.log.append(lines.map { self.ansi.parse($0) })
                    self.items = self.parser.items
                }
            }
        }
        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            // after the output's last lines, which the main queue delivers first
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.succeeded = code == 0
                    self.phase = .idle
                    self.process = nil
                    self.onFinish?()
                }
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            log.append(["setup: cannot run \(script.path): \(error.localizedDescription)"])
            phase = .idle
            succeeded = false
        }
    }

    /// Called when a run ends: the library looks at nxnative and the Python environment again.
    @ObservationIgnored public var onFinish: (() -> Void)?

}

/// bin/setup's report, line by line: a section title on a line of its own, then items, "  ✓ text", "  ! text" or
/// "  ✗ text". Other lines (Homebrew's and uv's output) are left for the log.
struct SetupParser {
    private(set) var items: [Setup.Item] = []
    private var section = ""

    static let sections: Set<String> = [
        "Mac", "Xcode", "Tools", "Python (.venv)", "nxnative", "Keys", "NX Play",
    ]

    mutating func read(_ line: String) {
        let plain = line.replacing(/\e\[[0-9;]*m/, with: "")
        let trimmed = plain.trimmingCharacters(in: .whitespaces)
        let states: [Character: Setup.Item.State] = ["✓": .ok, "!": .warning, "✗": .missing]
        if plain.hasPrefix("  "), let mark = trimmed.first, let state = states[mark],
            trimmed.dropFirst().first == " "
        {
            items.append(
                Setup.Item(
                    id: items.count, section: section == "Python (.venv)" ? "Python" : section,
                    state: state, text: String(trimmed.dropFirst(2))))
        } else if !plain.hasPrefix(" "), Self.sections.contains(trimmed) {
            section = trimmed
        }
    }
}
