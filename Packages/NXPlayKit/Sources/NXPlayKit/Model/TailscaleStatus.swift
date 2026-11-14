import Foundation

/// Whether Tailscale runs on this Mac, and this Mac's name and addresses on the tailnet, for Settings › Devices and the
/// pairing QR code. Best effort and read-only: NX Play asks `tailscale status --json --peers=false` and reads only
/// this Mac's own entry. It never changes Tailscale's settings, ACLs, Serve or Funnel.
struct TailscaleStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// No Tailscale app or command found.
        case notInstalled
        /// Installed; its state as Tailscale says it (Stopped, NeedsLogin, …), or nil when it couldn't be asked.
        case installed(String?)
        case running
    }

    var state: State
    /// This Mac's MagicDNS name (mac.tailnet-name.ts.net), without the final dot; nil without MagicDNS.
    var dnsName: String?
    /// This Mac's tailnet addresses: 100.x.y.z and fd7a:115c:a1e0::….
    var addresses: [String] = []

    static let notInstalled = TailscaleStatus(state: .notInstalled)
    var isRunning: Bool { state == .running }

    /// The Tailscale commands NX Play asks, in order: the Mac app's own, then Homebrew's and the open-source package's.
    static let commands = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    /// The commands' whole environment. The Mac app's binary acts as the CLI only when told so (`TAILSCALE_BE_CLI`) or
    /// run from a terminal (`TERM`); otherwise it starts a second Tailscale app that never answers, and the name was
    /// lost. The other commands ignore it.
    static let environment = ["PATH": "/usr/bin:/bin", "TAILSCALE_BE_CLI": "1"]

    /// Reads `tailscale status --json`: only BackendState, CurrentTailnet.MagicDNSEnabled and Self's DNSName and
    /// TailscaleIPs. Nil when it isn't Tailscale's JSON.
    static func parse(_ data: Data) -> TailscaleStatus? {
        guard data.count <= 4 << 20,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let backend = root["BackendState"] as? String
        else { return nil }
        guard backend == "Running" else { return TailscaleStatus(state: .installed(backend)) }
        let me = root["Self"] as? [String: Any] ?? [:]
        let magicDNS = (root["CurrentTailnet"] as? [String: Any])?["MagicDNSEnabled"] as? Bool ?? true
        var name = (me["DNSName"] as? String) ?? ""
        if name.hasSuffix(".") { name.removeLast() }
        let addresses = (me["TailscaleIPs"] as? [String] ?? []).prefix(4).filter {
            (try? Endpoint.validatedHost($0)).map { Endpoint.kind(of: $0) == .tailscale } ?? false
        }
        return TailscaleStatus(
            state: .running,
            dnsName: magicDNS && !name.isEmpty && name.hasSuffix(".ts.net") ? name.lowercased() : nil,
            addresses: Array(addresses))
    }

    /// Asks the first Tailscale command found, for at most `timeout`. Without one, Tailscale's addresses on this Mac's
    /// interfaces still say it runs (the name is unknown then).
    static func detect(
        interfaceAddresses: [MacAddresses.InterfaceAddress], commands: [String] = Self.commands,
        timeout: Duration = .seconds(4)
    ) async -> TailscaleStatus {
        let fromInterfaces = interfaceAddresses.map(\.host).filter {
            Endpoint.kind(of: $0) == .tailscale && ((try? Endpoint.validatedHost($0)) != nil)
        }
        let fileManager = FileManager.default
        guard let command = commands.first(where: fileManager.isExecutableFile(atPath:)) else {
            return fromInterfaces.isEmpty ? .notInstalled : TailscaleStatus(state: .running, addresses: fromInterfaces)
        }
        if let data = await run(command, ["status", "--json", "--peers=false"], timeout: timeout),
            var status = parse(data)
        {
            if status.isRunning, status.addresses.isEmpty { status.addresses = fromInterfaces }
            return status
        }
        return fromInterfaces.isEmpty
            ? TailscaleStatus(state: .installed(nil)) : TailscaleStatus(state: .running, addresses: fromInterfaces)
    }

    /// The command's standard output, or nil when it fails or outlasts `timeout` (it's stopped then).
    private static func run(_ path: String, _ arguments: [String], timeout: Duration) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(filePath: path)
                process.arguments = arguments
                process.environment = environment
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { return continuation.resume(returning: nil) }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: deadline)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }
}
