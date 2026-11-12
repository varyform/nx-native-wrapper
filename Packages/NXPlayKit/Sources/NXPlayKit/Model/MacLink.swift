import Foundation
import Observation
import SystemConfiguration

/// Remote builds between Macs (Settings › Remote): this Mac letting paired Macs build its games (the host side), and
/// the Macs this one builds on (the client side), each polled for its library and builds while it's on the network.
@MainActor @Observable public final class MacLink {
    public enum Connection: Equatable, Sendable {
        case searching, connecting, connected
        case offline(String)
    }

    static let hostEnabledKey = "macHostEnabled"

    @ObservationIgnored let store: MacLinkStore
    @ObservationIgnored let instanceID: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored weak var library: Library?

    // MARK: This Mac as a host

    /// Allow Remote Builds: paired Macs may build this Mac's games.
    public var hostEnabled: Bool {
        didSet {
            defaults.set(hostEnabled, forKey: Self.hostEnabledKey)
            applyHost()
        }
    }
    public private(set) var pairingCode = ""
    /// The Macs allowed to build here.
    public private(set) var clients: [PairedMac] = []
    public private(set) var hostProblem: String?
    @ObservationIgnored private var host: MacLinkHost?

    // MARK: Macs this one builds on

    public internal(set) var hosts: [PairedMac]
    /// NX Play on other Macs of this network with remote builds allowed.
    public private(set) var discovered: [DiscoveredMac] = []
    public private(set) var connections: [String: Connection] = [:]
    /// Each host's library, as it last answered.
    public private(set) var snapshots: [String: MacSnapshot] = [:]
    /// Each host's builds, by its game ids, mirrored (Job+Mirror.swift).
    public private(set) var jobs: [String: [String: Job]] = [:]
    /// Artwork fetched from a host, by host and game.
    public private(set) var icons: [String: Data] = [:]
    /// What a build asked of a host said back, shown with its library.
    public var problem: String?
    /// The pairing sheet is open: the browser runs for it even with no Mac paired.
    public var isPairing = false {
        didSet { applyBrowser() }
    }
    /// The main window shows this host's library instead of this Mac's (nil).
    public var shownHost: String?

    @ObservationIgnored private var browser: MacBrowser?
    @ObservationIgnored private var clientsByHost: [String: MacClient] = [:]
    @ObservationIgnored private var pollers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var iconFetches: Set<String> = []

    init(defaults: UserDefaults, store: MacLinkStore = .standard, isScreenshot: Bool) {
        self.defaults = defaults
        self.store = store
        instanceID = store.instanceID()
        hostEnabled = !isScreenshot && defaults.bool(forKey: Self.hostEnabledKey)
        hosts = isScreenshot ? [] : store.hosts()
    }

    /// This Mac's name in Sharing settings (Host.current() can wait on DNS).
    static var computerName: String { SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac" }

    func start() {
        applyHost()
        applyBrowser()
        for host in hosts { startPolling(host) }
    }

    // MARK: - Hosting

    private func applyHost() {
        guard hostEnabled else {
            host?.stop()
            host = nil
            pairingCode = ""
            hostProblem = nil
            return
        }
        guard host == nil else { return }
        let host = MacLinkHost(store: store, hostID: instanceID, name: Self.computerName) {
            [weak self] call, client in
            await self?.library?.answerMac(call, from: client) ?? .failure("NX Play is quitting.")
        }
        host.onChange = { [weak self, weak host] in
            guard let self, let host else { return }
            self.pairingCode = host.pairingCode
            self.clients = host.clients
            self.hostProblem = host.problem
        }
        self.host = host
        clients = host.clients
        Task { await host.start() }
    }

    public func newPairingCode() {
        Task { await host?.regenerateCode() }
    }

    public func removeClient(_ client: PairedMac) {
        host?.removeClient(id: client.id)
    }

    // MARK: - Pairing

    private func applyBrowser() {
        let wanted = isPairing || !hosts.isEmpty
        if wanted, browser == nil {
            let browser = MacBrowser(excluding: instanceID) { [weak self] macs in
                Task { @MainActor in self?.discovered = macs }
            }
            browser.start()
            self.browser = browser
        } else if !wanted, let browser {
            browser.stop()
            self.browser = nil
            discovered = []
        }
    }

    public func pair(with mac: DiscoveredMac, code: String) async throws {
        let paired = try await MacClient.pair(
            endpoint: mac.endpoint, hostID: mac.id, code: code, clientID: instanceID, clientName: Self.computerName)
        stopPolling(paired.id)
        hosts.removeAll { $0.id == paired.id }
        hosts.append(paired)
        store.saveHosts(hosts)
        applyBrowser()
        startPolling(paired)
    }

    public func unpair(_ host: PairedMac) {
        let client = clientsByHost[host.id]
        stopPolling(host.id)
        hosts.removeAll { $0.id == host.id }
        store.saveHosts(hosts)
        if shownHost == host.id { shownHost = nil }
        applyBrowser()
        Task { await client?.unpair() }
    }

    // MARK: - Polling

    private func startPolling(_ host: PairedMac) {
        let client = MacClient(host: host, clientID: instanceID)
        clientsByHost[host.id] = client
        connections[host.id] = .searching
        pollers[host.id] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.pollOnce(host.id, client)
                try? await Task.sleep(for: wait)
            }
        }
    }

    private func stopPolling(_ id: String) {
        pollers.removeValue(forKey: id)?.cancel()
        if let client = clientsByHost.removeValue(forKey: id) { Task { await client.disconnect() } }
        connections[id] = nil
        lost(id)
    }

    /// One poll of a host, connecting first when needed; how long to wait before the next one.
    private func pollOnce(_ id: String, _ client: MacClient) async -> Duration {
        guard let endpoint = discovered.first(where: { $0.id == id })?.endpoint else {
            connections[id] = .offline("Not on this network, or remote builds are off there")
            lost(id)
            return .seconds(2)
        }
        do {
            if !(await client.isConnected) {
                connections[id] = .connecting
                try await client.connect(to: endpoint)
            }
            let snapshot = try await client.poll(logs: logRequests(id))
            guard pollers[id] != nil else { return .seconds(1) }  // unpaired while it answered
            connections[id] = .connected
            apply(snapshot, from: id)
            let busy = jobs[id]?.values.contains { $0.status.isActive } == true
            return busy ? .seconds(1) : .seconds(2)
        } catch {
            await client.disconnect()
            connections[id] = .offline(error.localizedDescription)
            lost(id)
            return .seconds(3)
        }
    }

    /// The log lines to ask for: of each build mirrored, from the line it has.
    private func logRequests(_ id: String) -> [String: Int] {
        (jobs[id] ?? [:]).compactMapValues { $0.remote?.logTotal }
    }

    func apply(_ snapshot: MacSnapshot, from id: String) {
        if let index = hosts.firstIndex(where: { $0.id == id }), hosts[index].name != snapshot.name {
            hosts[index].name = snapshot.name
            store.saveHosts(hosts)
        }
        snapshots[id] = snapshot
        let shared = library?.sharedGames() ?? [:]
        // only the games the host lists now: one removed there takes its build with it
        let old = jobs[id] ?? [:]
        var mirrors: [String: Job] = [:]
        var finished: [Game] = []
        for game in snapshot.games {
            guard let remote = game.job else { continue }
            if let job = old[game.id], job.remote?.jobID == remote.id {
                mirrors[game.id] = job
                let wasActive = job.status.isActive
                job.apply(remote)
                if wasActive, !job.status.isActive { finished.append(job.game) }
            } else {
                let local = game.shared.flatMap { shared[$0] }
                let build = RemoteBuild(macName: snapshot.name, jobID: remote.id) { [weak self] in
                    self?.cancel(game.id, on: id)
                }
                mirrors[game.id] = Job.mirror(remote, of: local ?? Self.game(game), on: build)
            }
        }
        jobs[id] = mirrors
        library?.remoteBuildsChanged(finished: finished)
    }

    /// The host went away: its builds stop covering this Mac's games.
    private func lost(_ id: String) {
        guard snapshots[id] != nil || jobs[id] != nil else { return }
        snapshots[id] = nil
        jobs[id] = nil
        library?.remoteBuildsChanged(finished: [])
    }

    /// A host's game as a Game, for a mirror of a game this Mac doesn't have.
    static func game(_ remote: RemoteGame) -> Game {
        Game(
            folder: URL(filePath: remote.id, directoryHint: .isDirectory), name: remote.name,
            titleID: remote.titleID, version: remote.version, languages: [], iconURL: nil, buildFolder: nil,
            ipaURL: nil, xcodeBuildFolder: nil, hasPackages: remote.canBuild || remote.canRebuild,
            state: remote.isReady ? .ready : remote.isExtracted ? .extracted : .notExtracted)
    }

    // MARK: - Builds

    public func build(_ game: RemoteGame, rebuild: Bool, on id: String) {
        guard let client = clientsByHost[id] else { return }
        problem = nil
        Task {
            do {
                try await client.build(game.id, rebuild: rebuild)
            } catch {
                problem = "\(game.name): \(error.localizedDescription)"
            }
        }
    }

    func cancel(_ game: String, on id: String) {
        guard let client = clientsByHost[id] else { return }
        Task {
            do {
                try await client.cancel(game)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    public func icon(_ game: String, on id: String) -> Data? { icons[id + "\n" + game] }

    /// The game's artwork from the host, once, as its row first shows.
    func fetchIcon(_ game: String, on id: String) {
        let key = id + "\n" + game
        guard icons[key] == nil, let client = clientsByHost[id], iconFetches.insert(key).inserted else { return }
        Task {
            if let data = try? await client.icon(game) { icons[key] = data }
        }
    }
}
