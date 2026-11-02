import Foundation

/// Settings › Devices › Install NX Play: NX Play for iPhone and iPad, built from the source in NX Play's bundle
/// (Resources/iOSApp, bin/install-ios with the iOS project) and signed with the team that signs the games.
public struct IOSAppInstall: Sendable {
    public enum State: Sendable { case running, succeeded, failed }

    public let device: Device
    public var state = State.running
    /// What the script is doing, or how it ended.
    public var status = "Starting…"
    /// A failure's last lines (xcodebuild's error, devicectl's refusal).
    public var lastLines: [String] = []
}

extension Library {
    /// The bundled script, or the checkout's for a build run from it without the bundle's copy.
    static var iosAppScript: URL? {
        Bundle.main.url(forResource: "install-ios", withExtension: nil, subdirectory: "iOSApp/bin")
            ?? AppHome.sourceRoot?.appending(path: "bin/install-ios")
    }

    public var canInstallIOSApp: Bool { Self.iosAppScript != nil }

    public func installIOSApp(on device: Device) {
        guard iosAppInstall?.state != .running, let script = Self.iosAppScript else { return }
        iosAppInstall = IOSAppInstall(device: device)
        var environment = NXPlayCommand.environment(nxnative: nxnativePath, keys: keysPath)
        // the project is generated and built there, never in the bundle
        environment["NXPLAY_IOS_WORK"] = AppHome.folder.appending(path: "iOS").path
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [script.path, device.id] + (team.map { ["--team", $0.id] } ?? [])
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let splitter = LockedLineSplitter()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            let lines = (data.isEmpty ? splitter.finish() : splitter.feed(data)).filter {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.iosAppOutput(lines) }
            }
        }
        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            // after the output: the pipe's last lines are queued on main before this
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.iosAppEnded(code) }
            }
        }
        do {
            try process.run()
        } catch {
            iosAppInstall?.state = .failed
            iosAppInstall?.status = "Couldn't start the install: \(error.localizedDescription)"
        }
    }

    private func iosAppOutput(_ lines: [String]) {
        guard var install = iosAppInstall else { return }
        install.lastLines = Array((install.lastLines + lines).suffix(12))
        // xcodebuild's noise stays in lastLines; the status is the script's own steps
        if install.state == .running,
            let step = lines.last(where: { !$0.contains("xcodebuild[") && !$0.hasPrefix("•") }) {
            install.status = step
        }
        iosAppInstall = install
    }

    private func iosAppEnded(_ code: Int32) {
        guard var install = iosAppInstall else { return }
        install.state = code == 0 ? .succeeded : .failed
        if code != 0 { install.status = "Failed (exit \(code)): the last lines say why" }
        iosAppInstall = install
    }
}
