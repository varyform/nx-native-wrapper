import CryptoKit
import Foundation
import Network

/// A request/reply connection to a host. Replies are matched by id, so calls can overlap.
actor MacChannel {
    private var connection: FrameConnection?
    private var pending: [UInt64: CheckedContinuation<MacReply, any Error>] = [:]
    private var nextID: UInt64 = 1
    private var openCount = 0

    var isOpen: Bool { connection != nil }

    func open(endpoint: NWEndpoint, parameters: NWParameters) async throws {
        close()
        openCount += 1
        let opening = openCount
        let nwConnection = NWConnection(to: endpoint, using: parameters)
        let error = await withCheckedContinuation { (continuation: CheckedContinuation<MacLinkError?, Never>) in
            let once = ResumeOnce(continuation)
            let frames = FrameConnection(
                nwConnection,
                onFrame: { [weak self] payload in Task { await self?.receive(payload) } },
                onClose: { [weak self] reason in
                    once.resume(reason)
                    Task { await self?.closed(reason, opening: opening) }
                })
            connection = frames
            frames.start(onReady: { once.resume(nil) })
            // a host that has gone quiet never fails by itself, so this can't wait forever
            Task {
                try? await Task.sleep(for: .seconds(10))
                once.resume(.unreachable)
            }
        }
        if let error {
            close()
            throw error
        }
    }

    func call(_ call: MacCall, timeout: Duration = .seconds(15)) async throws -> MacReply {
        guard let connection else { throw MacLinkError.disconnected }
        let id = nextID
        nextID += 1
        let payload = try JSONEncoder().encode(MacRequestFrame(id: id, call: call))
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.timedOut(id)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            connection.send(payload)
        }
    }

    func close() {
        connection?.close()
        connection = nil
        failPending(.disconnected)
    }

    private func receive(_ payload: Data) {
        guard let frame = try? JSONDecoder().decode(MacReplyFrame.self, from: payload) else { return }
        pending.removeValue(forKey: frame.id)?.resume(returning: frame.reply)
    }

    private func timedOut(_ id: UInt64) {
        pending.removeValue(forKey: id)?.resume(throwing: MacLinkError.timedOut)
    }

    private func closed(_ reason: MacLinkError, opening: Int) {
        // a close arrives a little after it happens, and mustn't take a newer connection down with it
        guard opening == openCount else { return }
        connection = nil
        failPending(reason)
    }

    private func failPending(_ error: MacLinkError) {
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}

/// Builds on a paired host: its library, and the calls that build there.
actor MacClient {
    let host: PairedMac
    private let clientID: String
    private let channel = MacChannel()

    init(host: PairedMac, clientID: String) {
        self.host = host
        self.clientID = clientID
    }

    /// Pairs with a host using the code it shows. Throws `.authenticationFailed` for a wrong code.
    static func pair(
        endpoint: NWEndpoint, hostID: String, code: String, clientID: String, clientName: String
    ) async throws -> PairedMac {
        let pairingKey = await Task.detached(priority: .userInitiated) {
            MacLinkSecurity.pairingKey(code: code, hostID: hostID)
        }.value
        let channel = MacChannel()
        defer { Task { await channel.close() } }
        let keys = [(identity: MacLinkSecurity.pairingIdentity, key: pairingKey)]
        try await channel.open(endpoint: endpoint, parameters: MacLinkSecurity.parameters(keys: keys))

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let reply = try await channel.call(
            .pair(clientID: clientID, clientName: clientName, publicKey: privateKey.publicKey.rawRepresentation))
        switch reply {
        case .paired(let answeredID, let hostName, let publicKey):
            guard answeredID == hostID else { throw MacLinkError.unexpectedHost }
            let key = try MacLinkSecurity.longTermKey(
                privateKey: privateKey, peerPublicKey: publicKey, pairingKey: pairingKey, clientID: clientID,
                hostID: hostID)
            return PairedMac(id: hostID, name: hostName, key: key)
        case .failure(let message): throw MacLinkError.rejected(message)
        default: throw MacLinkError.disconnected
        }
    }

    var isConnected: Bool {
        get async { await channel.isOpen }
    }

    func connect(to endpoint: NWEndpoint) async throws {
        guard !(await channel.isOpen) else { return }
        let keys = [(identity: clientID, key: host.key)]
        try await channel.open(endpoint: endpoint, parameters: MacLinkSecurity.parameters(keys: keys))
        let proof = MacLinkSecurity.clientProof(key: host.key, clientID: clientID)
        let reply = try await channel.call(
            .hello(clientID: clientID, proof: proof, protocolVersion: MacWire.protocolVersion))
        switch reply {
        case .hello(let hostID) where hostID == host.id: return
        case .hello:
            await channel.close()
            throw MacLinkError.unexpectedHost
        case .failure(let message):
            await channel.close()
            throw MacLinkError.rejected(message)
        default:
            await channel.close()
            throw MacLinkError.disconnected
        }
    }

    func disconnect() async { await channel.close() }

    /// Asks the host to forget this Mac. Best effort: the host may be off, and the user is leaving anyway.
    func unpair() async {
        _ = try? await channel.call(.unpair, timeout: .seconds(3))
        await channel.close()
    }

    func poll(logs: [String: Int]) async throws -> MacSnapshot {
        let reply = try await channel.call(.poll(logs: logs))
        guard case .snapshot(let snapshot) = reply else { throw unexpected(reply) }
        return snapshot
    }

    func build(_ game: String, rebuild: Bool) async throws {
        try expectOK(try await channel.call(.build(game: game, rebuild: rebuild)))
    }

    func cancel(_ game: String) async throws {
        try expectOK(try await channel.call(.cancel(game: game)))
    }

    func icon(_ game: String) async throws -> Data? {
        let reply = try await channel.call(.icon(game: game), timeout: .seconds(30))
        guard case .icon(let data) = reply else { throw unexpected(reply) }
        return data
    }

    private func expectOK(_ reply: MacReply) throws {
        guard case .ok = reply else { throw unexpected(reply) }
    }

    private func unexpected(_ reply: MacReply) -> MacLinkError {
        if case .failure(let message) = reply { return .rejected(message) }
        return .disconnected
    }
}
