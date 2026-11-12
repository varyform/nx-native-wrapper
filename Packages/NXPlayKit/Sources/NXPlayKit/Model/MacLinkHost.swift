import CryptoKit
import Foundation
import Network

/// Lets paired Macs build here (Settings › Remote › Allow Remote Builds): a TLS listener advertised over Bonjour as
/// `_nxplay-mac._tcp`, taking the pairing code and the paired clients' keys. The library answers the calls; this
/// only pairs, checks who's calling and carries the frames.
@MainActor final class MacLinkHost {
    /// What a paired client asked for, answered by the library (Library+MacHost.swift).
    typealias Handler = @MainActor (MacCall, PairedMac) async -> MacReply

    /// One accepted connection. A connection that hasn't said who it is may only pair.
    private final class Session {
        let connection: FrameConnection
        var clientID: String?
        init(connection: FrameConnection) { self.connection = connection }
    }

    private static let maxConnections = 32
    /// A fixed port, one past the iOS app's (RemoteServer), so a firewall rule or another app's port picked at random
    /// can't move it.
    static let defaultPort: UInt16 = 47_475
    private static let maxClients = 32
    private static let maxNameLength = 64

    private let store: MacLinkStore
    let hostID: String
    private let name: String
    private let handle: Handler
    /// Pairing code, clients or a problem changed.
    var onChange: (() -> Void)?

    private(set) var clients: [PairedMac]
    private(set) var pairingCode = ""
    private(set) var problem: String?
    private var pairingKey = Data()
    private var listener: NWListener?
    /// Listening is wanted: from start() to stop(), whatever the listener's state.
    private var isStarted = false
    /// Counts the listeners made, so a retry for one that has been replaced does nothing.
    private var generation = 0
    /// The port it listens on, once it does.
    private(set) var port: NWEndpoint.Port?
    /// The port asked for: any free one in tests, which run beside NX Play.
    private let requestedPort: NWEndpoint.Port
    /// Off in tests, which connect to the port.
    private let advertises: Bool
    private var sessions: [ObjectIdentifier: Session] = [:]

    init(
        store: MacLinkStore, hostID: String, name: String, port: UInt16? = defaultPort, advertises: Bool = true,
        handle: @escaping Handler
    ) {
        self.store = store
        requestedPort = port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        self.advertises = advertises
        self.hostID = hostID
        self.name = name
        self.handle = handle
        clients = store.clients()
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        await makeNewCode()
        guard isStarted else { return }
        restartListener()
    }

    func stop() {
        isStarted = false
        generation += 1
        listener?.cancel()
        listener = nil
        port = nil
        for session in sessions.values { session.connection.close() }
        sessions = [:]
        onChange?()
    }

    /// Replaces the code showing, for when it might have been seen by the wrong person.
    func regenerateCode() async {
        guard isStarted else { return }
        await makeNewCode()
        restartListener()
    }

    func removeClient(id: String) {
        clients.removeAll { $0.id == id }
        store.saveClients(clients)
        for session in sessions.values where session.clientID == id { session.connection.close() }
        if isStarted { restartListener() }
        onChange?()
    }

    private func makeNewCode() async {
        let code = MacLinkSecurity.makePairingCode()
        let hostID = hostID
        pairingKey = await Task.detached(priority: .userInitiated) {
            MacLinkSecurity.pairingKey(code: code, hostID: hostID)
        }.value
        pairingCode = code
        onChange?()
    }

    /// A listener's keys are fixed when it's made, so a change of code or clients replaces it. Connections it
    /// already took aren't affected. The port is kept, so the advertised address stays good.
    private func restartListener() {
        listener?.cancel()
        listener = nil
        generation += 1
        var keys = clients.map { (identity: $0.id, key: $0.key) }
        keys.append((identity: MacLinkSecurity.pairingIdentity, key: pairingKey))
        startListener(parameters: MacLinkSecurity.parameters(keys: keys), generation: generation, attempt: 0)
    }

    private func startListener(parameters: NWParameters, generation: Int, attempt: Int) {
        // a port asked for any is kept from the first listener, so the advertised address stays good
        let requested = requestedPort == .any ? port ?? .any : requestedPort
        guard let listener = try? NWListener(using: parameters, on: requested) else {
            problem = "Remote builds can\u{2019}t listen on the network."
            onChange?()
            return
        }
        if advertises {
            listener.service = NWListener.Service(
                name: name, type: MacWire.serviceType, domain: nil,
                txtRecord: NWTXTRecord([MacWire.instanceIDKey: hostID]).data)
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.port = listener.port
                    self.problem = nil
                case .failed(let error):
                    listener.cancel()
                    self.listener = nil
                    // the listener this one replaces can hold the port for a moment after it's cancelled; the
                    // error only comes once it starts, so the retry is here
                    if case .posix(.EADDRINUSE) = error, attempt < 20 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            MainActor.assumeIsolated {
                                guard self.isStarted, self.generation == generation else { return }
                                self.startListener(parameters: parameters, generation: generation, attempt: attempt + 1)
                            }
                        }
                        return
                    }
                    self.problem =
                        if case .posix(.EADDRINUSE) = error {
                            "Another app uses port \(requested), so remote builds can\u{2019}t listen on it."
                        } else {
                            "Remote builds can\u{2019}t listen on the network: \(error.localizedDescription)"
                        }
                default: return
                }
                self.onChange?()
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        guard sessions.count < Self.maxConnections else { return connection.cancel() }
        // the session is needed by its own callbacks, so they reach it by this key instead
        let box = SessionKey()
        let frames = FrameConnection(
            connection,
            onFrame: { [weak self] payload in
                Task { @MainActor in await self?.receive(payload, from: box.value) }
            },
            onClose: { [weak self] _ in
                Task { @MainActor in self?.closed(box.value) }
            })
        let session = Session(connection: frames)
        let key = ObjectIdentifier(session)
        box.value = key
        sessions[key] = session
        frames.start(onReady: {})
    }

    private func closed(_ key: ObjectIdentifier?) {
        guard let key else { return }
        sessions[key] = nil
    }

    private func receive(_ payload: Data, from key: ObjectIdentifier?) async {
        guard let key, let session = sessions[key],
            let request = try? JSONDecoder().decode(MacRequestFrame.self, from: payload)
        else { return }
        let reply = await answer(request.call, from: session)
        guard let data = try? JSONEncoder().encode(MacReplyFrame(id: request.id, reply: reply)) else { return }
        session.connection.send(data)
    }

    private func answer(_ call: MacCall, from session: Session) async -> MacReply {
        switch call {
        case .pair(let clientID, let clientName, let publicKey):
            return pair(clientID: clientID, clientName: clientName, publicKey: publicKey)
        case .hello(let clientID, let proof, let version):
            return hello(clientID: clientID, proof: proof, version: version, session: session)
        default:
            break
        }
        guard let id = session.clientID, let client = clients.first(where: { $0.id == id }) else {
            return .failure("This connection hasn\u{2019}t said which Mac it is.")
        }
        if case .unpair = call {
            // answered before the connection closes, as the client waits for it
            Task { @MainActor in self.removeClient(id: id) }
            return .ok
        }
        return await handle(call, client)
    }

    private func hello(clientID: String, proof: Data, version: Int, session: Session) -> MacReply {
        guard version == MacWire.protocolVersion else {
            return .failure("That Mac runs another version of NX Play. Update both to the same version.")
        }
        guard let client = clients.first(where: { $0.id == clientID }),
            MacLinkSecurity.isValidClientProof(proof, key: client.key, clientID: clientID)
        else { return .failure("This Mac isn\u{2019}t paired.") }
        session.clientID = clientID
        return .hello(hostID: hostID)
    }

    private func pair(clientID: String, clientName: String, publicKey: Data) -> MacReply {
        guard !clientID.isEmpty, clientID != MacLinkSecurity.pairingIdentity,
            clients.count < Self.maxClients || clients.contains(where: { $0.id == clientID })
        else { return .failure("This Mac can\u{2019}t take any more paired Macs.") }
        do {
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let key = try MacLinkSecurity.longTermKey(
                privateKey: privateKey, peerPublicKey: publicKey, pairingKey: pairingKey, clientID: clientID,
                hostID: hostID)
            clients.removeAll { $0.id == clientID }
            clients.append(PairedMac(id: clientID, name: String(clientName.prefix(Self.maxNameLength)), key: key))
            store.saveClients(clients)
            // one use only
            Task { @MainActor in
                await self.makeNewCode()
                self.restartListener()
            }
            return .paired(hostID: hostID, hostName: name, publicKey: privateKey.publicKey.rawRepresentation)
        } catch {
            return .failure("Pairing failed: \(error.localizedDescription)")
        }
    }
}

/// Lets a session's callbacks find it without keeping it alive.
private final class SessionKey: @unchecked Sendable {
    var value: ObjectIdentifier?
}
