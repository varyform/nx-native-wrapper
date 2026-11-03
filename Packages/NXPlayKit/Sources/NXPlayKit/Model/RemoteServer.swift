import Foundation
import Network
import SystemConfiguration

/// How the iOS app reaches NX Play: a small HTTP server on the local network, advertised over Bonjour as
/// `_nxplay._tcp`, so the app finds the Mac without being given an address. Everything runs on the main queue,
/// where the library lives. Each connection carries one request and closes after the response.
///
/// Bonjour can take its time: macOS registers the service only once its local network privacy rules cover this copy
/// of the app, and a freshly built or replaced app can wait for that until the next network change (30 minutes once,
/// with the server listening all along). So the server watches for Bonjour to confirm the service, says so in
/// Settings, and registers the service again (on the same listener) with growing pauses until it does
/// (AdvertisementTracker). A failed listener is listened again the same way. Addresses and the QR code don't need
/// Bonjour at all.
@MainActor final class RemoteServer {
    static let serviceType = "_nxplay._tcp"
    /// A fixed port, so `curl` and an app given a host name can reach it without Bonjour.
    static let defaultPort: UInt16 = NXPlayPairing.defaultPort

    typealias Handler = @MainActor (RemoteRequest) async -> RemoteResponse

    /// Whether the phone can find this Mac over Bonjour.
    enum Advertisement: Equatable, Sendable {
        case off
        /// Registered with Bonjour, not confirmed yet: the `attempt`th registration since the last confirmation.
        case registering(attempt: Int)
        /// Bonjour confirmed it: phones on this network see it under `name`.
        case advertised(name: String)
    }

    private let handle: Handler
    private var listener: NWListener?
    private var port: UInt16 = defaultPort
    private var macID = ""
    private var advertises = true
    private var tracker = AdvertisementTracker()
    private var failures = 0
    /// A taken port is first tried again quietly after a moment: it's usually this app's own listener, still closing.
    private var retriedQuietly = false
    private var generation = 0
    /// Between withdrawing the service and registering it again: Bonjour's news about the old one is ignored.
    private var readvertising = false
    /// Listening again (after a failure, or once the old listener closed).
    private var listenTimer: Task<Void, Never>?
    /// Waiting for Bonjour to confirm, and registering again.
    private var advertiseTimer: Task<Void, Never>?
    /// Why the server isn't listening (the port taken, the network refused); nil while it's fine.
    var onProblem: ((String?) -> Void)?
    var onAdvertisement: ((Advertisement) -> Void)?

    init(handle: @escaping Handler) {
        self.handle = handle
    }

    /// Listens on `port` and advertises it with the Mac's ID (`id`) in the TXT record. `advertises` false (tests)
    /// listens without Bonjour; port 0 takes any free one (`listeningPort`).
    func start(port: UInt16 = defaultPort, id: String = "", advertises: Bool = true) {
        let previous = listener
        stop()
        self.port = port
        macID = id
        self.advertises = advertises
        retriedQuietly = false
        guard let previous else { return listen() }
        // the port is free once the old listener has closed: listen then (or after a second at most)
        generation += 1
        let generation = generation
        previous.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard case .cancelled = state, let self, self.generation == generation, self.listener == nil else {
                    return
                }
                self.listen()
            }
        }
        schedule(.listen, after: .seconds(1)) { server in
            if server.generation == generation, server.listener == nil { server.listen() }
        }
    }

    /// The port it listens on once ready.
    var listeningPort: UInt16? { listener?.state == .ready ? listener?.port?.rawValue : nil }

    /// Stops listening and advertising. A restart still waiting for the old listener to close is called off too: its
    /// callbacks belong to an older generation and do nothing.
    func stop() {
        generation += 1
        listenTimer?.cancel()
        listenTimer = nil
        advertiseTimer?.cancel()
        advertiseTimer = nil
        readvertising = false
        listener?.cancel()
        listener = nil
        tracker.stopped()
        failures = 0
        onAdvertisement?(.off)
    }

    private func listen() {
        listener?.cancel()
        listener = nil
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        // a restart takes the port straight back
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            fail("Can't listen on port \(port): \(error.localizedDescription)")
            return
        }
        if advertises { listener.service = service() }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, listener === self.listener else { return }
                switch state {
                case .ready:
                    self.failures = 0
                    self.retriedQuietly = false
                    self.onProblem?(nil)
                case .waiting(let error):
                    self.onProblem?("Waiting for the network on port \(self.port): \(error.localizedDescription)")
                case .failed(let error):
                    self.fail(Self.problem(error, port: self.port), addressInUse: error == .posix(.EADDRINUSE))
                default: break
                }
            }
        }
        listener.serviceRegistrationUpdateHandler = { [weak self, weak listener] change in
            MainActor.assumeIsolated {
                guard let self, let listener, listener === self.listener, !self.readvertising else { return }
                switch change {
                case .add(let endpoint):
                    var name = "this Mac"
                    if case .service(let service, _, _, _) = endpoint { name = service }
                    self.apply(self.tracker.added(name: name))
                case .remove:
                    self.apply(self.tracker.removed())
                @unknown default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
        if advertises { apply(tracker.started()) }
    }

    /// The service with its TXT record: the .local host name (the iOS app may talk HTTP to it; it also resolves the
    /// service itself), the port, and the Mac's ID. Read afresh each time: the host name can change.
    private func service() -> NWListener.Service {
        let host = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
        var txt: [String: String] = ["v": "1", "host": host ?? "", "port": "\(port)"]
        if !macID.isEmpty { txt["id"] = macID }
        return NWListener.Service(type: Self.serviceType, txtRecord: NWTXTRecord(txt).data)
    }

    /// Bonjour hasn't confirmed the service: withdraws it and registers it again on the same listener (connections
    /// and the port stay as they are), the second half a moment later so the withdrawal goes through first.
    private func readvertise() {
        guard let listener, advertises else { return }
        readvertising = true
        listener.service = nil
        schedule(.advertise, after: .milliseconds(500)) { server in
            guard let current = server.listener, current === listener else { return }
            server.readvertising = false
            current.service = server.service()
            server.apply(server.tracker.started())
        }
    }

    /// The listener failed: says why, and listens again after a pause that grows with each failure in a row.
    private func fail(_ problem: String, addressInUse: Bool = false) {
        listener?.cancel()
        listener = nil
        advertiseTimer?.cancel()
        readvertising = false
        if addressInUse, !retriedQuietly {
            retriedQuietly = true
            schedule(.listen, after: .milliseconds(600)) { $0.listen() }
            return
        }
        onProblem?(problem)
        failures += 1
        schedule(.listen, after: AdvertisementTracker.pause(afterFailures: failures)) { $0.listen() }
    }

    private func apply(_ action: AdvertisementTracker.Action) {
        onAdvertisement?(tracker.state)
        switch action {
        case .unchanged: break
        case .confirmed: advertiseTimer?.cancel()
        case .wait(let pause):
            schedule(.advertise, after: pause) { server in
                if server.tracker.timedOut() == .restart { server.readvertise() }
            }
        }
    }

    private enum Slot { case listen, advertise }

    private func schedule(_ slot: Slot, after pause: Duration, _ then: @escaping @MainActor (RemoteServer) -> Void) {
        let task = Task { [weak self] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled, let self else { return }
            then(self)
        }
        switch slot {
        case .listen:
            listenTimer?.cancel()
            listenTimer = task
        case .advertise:
            advertiseTimer?.cancel()
            advertiseTimer = task
        }
    }

    static func problem(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is in use by another app: choose another port below. NX Play tries again meanwhile."
        }
        return "Can't listen on port \(port): \(error.localizedDescription). NX Play tries again shortly."
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    /// Reads until the headers are complete, then answers. A client that sends more than a header's worth without
    /// finishing it, or goes away, is dropped.
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                let buffer = buffer + (data ?? Data())
                if let request = RemoteRequest.parse(buffer) {
                    self.respond(to: request, on: connection)
                } else if error != nil || isComplete || buffer.count > RemoteRequest.maxHeader {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(to request: RemoteRequest, on connection: NWConnection) {
        Task { @MainActor in
            let response = await handle(request)
            connection.send(
                content: response.data,
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// When to give up waiting for Bonjour to confirm the service and register it again: 10 s after the first
/// registration, then 20, 40, 80, 160, and every 5 minutes after. A confirmation resets it; a service Bonjour
/// withdraws (the network went away) is waited for again from where it was.
struct AdvertisementTracker: Equatable {
    enum Action: Equatable {
        /// Nothing changes: a withdrawal of a service that wasn't confirmed.
        case unchanged
        /// Bonjour confirmed: stop waiting.
        case confirmed
        /// Give Bonjour this long, then call `timedOut`.
        case wait(Duration)
    }

    enum Timeout: Equatable {
        case restart
        case ignore
    }

    private(set) var state = RemoteServer.Advertisement.off
    private(set) var attempt = 0

    static func pause(attempt: Int) -> Duration {
        .seconds(min(10 << min(max(attempt - 1, 0), 5), 300))
    }

    /// Listening again after failures in a row: 5 s, 10, 20, 40, then every minute.
    static func pause(afterFailures failures: Int) -> Duration {
        .seconds(min(5 << min(max(failures - 1, 0), 4), 60))
    }

    mutating func started() -> Action {
        attempt += 1
        state = .registering(attempt: attempt)
        return .wait(Self.pause(attempt: attempt))
    }

    mutating func added(name: String) -> Action {
        state = .advertised(name: name)
        attempt = 0
        return .confirmed
    }

    mutating func removed() -> Action {
        guard case .advertised = state else { return .unchanged }
        attempt = max(attempt, 1)
        state = .registering(attempt: attempt)
        return .wait(Self.pause(attempt: attempt))
    }

    /// The wait ran out: register again while Bonjour still hasn't confirmed.
    func timedOut() -> Timeout {
        if case .registering = state { return .restart }
        return .ignore
    }

    mutating func stopped() {
        state = .off
        attempt = 0
    }
}
