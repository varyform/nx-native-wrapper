import Foundation
import Network
import Observation

/// The Macs on the local network running NX Play with the iPhone & iPad App setting on. They advertise `_nxplay._tcp`
/// over Bonjour, with their .local name, port and pairing ID in the TXT record (NXPlayKit's RemoteServer).
///
/// Each one found is resolved to the address and port it actually answers at (a short connection to the service),
/// so pairing doesn't hang on a stale .local name; the TXT record's name comes second. The browser's state says when
/// iOS refuses the local network (Settings › Privacy & Security › Local Network), and a failed browser starts again
/// with growing pauses. Bonjour stays on the local network: it doesn't reach a Mac over Tailscale.
@MainActor @Observable
final class MacFinder {
    struct Found: Identifiable, Hashable {
        /// The Bonjour name: the Mac's name.
        let name: String
        /// The Mac's pairing ID from the TXT record; nil from a Mac before QR pairing.
        let macID: String?
        /// Where it answers (resolved), then its TXT record's .local name and port.
        var endpoints: [Endpoint]
        var id: String { macID ?? name }
    }

    enum Status: Equatable {
        case idle
        case searching
        /// iOS won't let NX Play use the local network.
        case denied
        /// Bonjour isn't working; NX Play keeps trying.
        case failed(String)
    }

    private(set) var found: [Found] = []
    private(set) var status = Status.idle
    /// When it started looking: after a while with nothing found, the pairing screen suggests the QR code.
    private(set) var searchingSince: Date?

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var restart: Task<Void, Never>?
    /// Where each service answered, with the TXT record it had then: a changed record (a new port) is resolved again.
    @ObservationIgnored private var resolved: [NWEndpoint: (endpoint: Endpoint, txt: [String: String])] = [:]
    @ObservationIgnored private var resolving: [NWEndpoint: NWConnection] = [:]
    @ObservationIgnored private var results: Set<NWBrowser.Result> = []
    /// Resolves the services again now and then while looking: a Mac can move to another address under the same name.
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    static let resolveAgainAfter: Duration = .seconds(60)

    /// Starts looking; each start needs its stop (the pairing screen and reconnecting both use it).
    func start() {
        users += 1
        guard browser == nil, restart == nil else { return }
        browse()
    }

    func stop() {
        users = max(users - 1, 0)
        guard users == 0 else { return }
        restart?.cancel()
        restart = nil
        browser?.cancel()
        browser = nil
        refreshing?.cancel()
        refreshing = nil
        resolving.values.forEach { $0.cancel() }
        resolving = [:]
        // what was found is as old as the last look: the next one starts afresh
        resolved = [:]
        results = []
        found = []
        status = .idle
        searchingSince = nil
    }

    private func browse() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_nxplay._tcp", domain: "local."), using: parameters)
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self, let browser, browser === self.browser else { return }
                self.changed(state)
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, let browser, browser === self.browser else { return }
                self.update(results)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        if searchingSince == nil { searchingSince = Date() }
        status = .searching
        if refreshing == nil {
            refreshing = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.resolveAgainAfter)
                    guard !Task.isCancelled, let self else { return }
                    for result in self.results where self.resolving[result.endpoint] == nil {
                        self.resolve(result.endpoint)
                    }
                }
            }
        }
    }

    private func changed(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            failures = 0
            status = .searching
        case .waiting(let error):
            // the browser keeps waiting by itself: for the network, or for permission
            status = Self.isPolicyDenied(error) ? .denied : .failed(error.localizedDescription)
        case .failed(let error):
            status = Self.isPolicyDenied(error) ? .denied : .failed(error.localizedDescription)
            browser?.cancel()
            browser = nil
            failures += 1
            let pause = min(2 << min(failures - 1, 4), 30)
            restart = Task { [weak self] in
                try? await Task.sleep(for: .seconds(pause))
                guard !Task.isCancelled, let self else { return }
                self.restart = nil
                if self.users > 0 { self.browse() }
            }
        default: break
        }
    }

    /// kDNSServiceErr_PolicyDenied: the local network is off for NX Play.
    nonisolated static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == -65570 { return true }
        return false
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        self.results = results
        for result in results {
            // a service whose record changed (the Mac's port, its name) answers somewhere else now
            if let cached = resolved[result.endpoint], cached.txt != Self.txt(result) {
                resolved[result.endpoint] = nil
            }
            if resolved[result.endpoint] == nil && resolving[result.endpoint] == nil { resolve(result.endpoint) }
        }
        let current = Set(results.map(\.endpoint))
        for (endpoint, connection) in resolving where !current.contains(endpoint) {
            connection.cancel()
            resolving[endpoint] = nil
        }
        resolved = resolved.filter { current.contains($0.key) }
        rebuild()
    }

    /// One Mac per ID (or name), with every address found for it: a Mac on Wi-Fi and Ethernet shows once.
    private func rebuild() {
        var macs: [String: Found] = [:]
        var order: [String] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            let txt = Self.txt(result)
            let port = UInt16(txt["port"] ?? "")
            var endpoints: [Endpoint] = []
            let address = resolved[result.endpoint].flatMap { $0.txt == txt ? $0.endpoint : nil }
            if let address { endpoints.append(address) }
            if let host = txt["host"], !host.isEmpty, let port = port ?? address?.port,
                let endpoint = try? Endpoint.parse(host, defaultPort: port)
            {
                endpoints.append(endpoint)
            }
            let macID = txt["id"].flatMap(UUID.init(uuidString:))?.uuidString
            let key = macID ?? name
            if macs[key] == nil {
                macs[key] = Found(name: name, macID: macID, endpoints: [])
                order.append(key)
            }
            for endpoint in endpoints where !(macs[key]?.endpoints.contains(endpoint) ?? true) {
                macs[key]?.endpoints.append(endpoint)
            }
        }
        // resolved addresses (IPv4 first) before .local names
        var list: [Found] = []
        for key in order {
            guard var mac = macs[key], !mac.endpoints.isEmpty else { continue }
            mac.endpoints.sort { Self.rank($0) < Self.rank($1) }
            list.append(mac)
        }
        found = list.sorted { $0.name < $1.name }
    }

    nonisolated private static func rank(_ endpoint: Endpoint) -> Int {
        if endpoint.host.hasSuffix(".local") { return 2 }
        return endpoint.isIPv6 ? 1 : 0
    }

    /// Connects to the service just long enough to learn the address and port it answers at.
    private func resolve(_ service: NWEndpoint) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let connection = NWConnection(to: service, using: parameters)
        resolving[service] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection, self.resolving[service] === connection else { return }
                switch state {
                case .ready:
                    if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint,
                        let endpoint = Self.endpoint(host, port),
                        let result = self.results.first(where: { $0.endpoint == service })
                    {
                        self.resolved[service] = (endpoint, Self.txt(result))
                    }
                    self.finishResolving(service)
                case .failed:
                    // where it answered before, it doesn't now
                    self.resolved[service] = nil
                    self.finishResolving(service)
                case .cancelled:
                    self.finishResolving(service)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        Task { [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, let connection, self.resolving[service] === connection else { return }
            self.finishResolving(service)
        }
    }

    private func finishResolving(_ service: NWEndpoint) {
        resolving.removeValue(forKey: service)?.cancel()
        rebuild()
    }

    nonisolated private static func txt(_ result: NWBrowser.Result) -> [String: String] {
        if case .bonjour(let record) = result.metadata { return record.dictionary }
        return [:]
    }

    /// The address a connection reached, as an Endpoint; nil for a link-local IPv6 one (it needs its interface).
    nonisolated static func endpoint(_ host: NWEndpoint.Host, _ port: NWEndpoint.Port) -> Endpoint? {
        let text: String
        switch host {
        case .ipv4(let address): text = address.rawValue.map(String.init).joined(separator: ".")
        case .ipv6(let address): text = Endpoint.ipv6String(Array(address.rawValue))
        case .name(let name, _): text = name
        @unknown default: return nil
        }
        return try? Endpoint.parse(text.contains(":") ? "[\(text)]:\(port.rawValue)" : "\(text):\(port.rawValue)", defaultPort: nil)
    }
}
