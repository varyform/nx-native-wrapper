import Foundation
import Network
import Observation
import SystemConfiguration

/// The Mac's side of the network for Settings › Devices: its addresses, its .local name and Tailscale, looked at again
/// whenever the network changes (Wi-Fi joined, Tailscale connected) while the iPhone & iPad App setting is on.
@MainActor @Observable final class RemoteNetwork {
    private(set) var addresses: [MacAddresses.InterfaceAddress] = []
    private(set) var localHostName: String?
    private(set) var tailscale = TailscaleStatus.notInstalled
    /// Whether it has looked yet.
    private(set) var isLoaded = false

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private let sample: Bool

    /// `sample`: screenshot mode's made-up addresses, with no looking.
    init(sample: Bool = false) {
        self.sample = sample
        if sample {
            addresses = [.init(interface: "en0", host: "192.168.1.20")]
            localHostName = "Mac"
            tailscale = TailscaleStatus(state: .running, dnsName: "mac.example.ts.net", addresses: ["100.101.102.103"])
            isLoaded = true
        }
    }

    /// The endpoints in the order to try them (MacAddresses.endpoints).
    func endpoints(port: UInt16) -> [Endpoint] {
        MacAddresses.endpoints(from: addresses, localHostName: localHostName, tailscale: tailscale, port: port)
    }

    /// Watches the network and looks now.
    func start() {
        guard !sample, monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
        refresh()
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        refreshing?.cancel()
        refreshing = nil
    }

    /// Looks again: the interfaces now, Tailscale in the background (a second or so). A refresh asked for while one
    /// runs replaces it.
    func refresh() {
        guard !sample else { return }
        let interfaces = MacAddresses.interfaceAddresses()
        addresses = interfaces
        localHostName = SCDynamicStoreCopyLocalHostName(nil) as String?
        isLoaded = true
        refreshing?.cancel()
        refreshing = Task { [weak self] in
            // a burst of path changes (joining Wi-Fi) settles first
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let status = await TailscaleStatus.detect(interfaceAddresses: interfaces)
            guard !Task.isCancelled, let self else { return }
            self.tailscale = status
        }
    }
}
