import Foundation
import Network

/// The control API's listener: 127.0.0.1 only, a port of its own (any free one unless NXPLAY_CONTROL_PORT names one),
/// one request per connection. Everything runs on the main queue, where the library lives. Bounded: 16 KiB of head,
/// 1 MiB of body, 10 seconds to send a request, 16 connections at once.
@MainActor final class ControlServer {
    typealias Handler = @MainActor (ControlRequest) async -> ControlResponse

    static let maxConnections = 16
    static let requestTimeout: Duration = .seconds(10)

    private let handle: Handler
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    var onReady: ((UInt16) -> Void)?
    var onFailure: ((String) -> Void)?

    init(handle: @escaping Handler) {
        self.handle = handle
    }

    var port: UInt16? { listener?.state == .ready ? listener?.port?.rawValue : nil }

    func start(port: UInt16) {
        let parameters = NWParameters.tcp
        // bound to the loopback address: nothing on the network can connect, whatever the firewall says
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = false
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            onFailure?("Can't listen on 127.0.0.1:\(port): \(error.localizedDescription)")
            return
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, listener === self.listener else { return }
                switch state {
                case .ready: self.onReady?(listener.port?.rawValue ?? 0)
                case .failed(let error):
                    self.onFailure?("The control API stopped listening: \(error.localizedDescription)")
                    self.stop()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    /// Whether the other end is this Mac's loopback: the listener is bound there, and this checks it again.
    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || address == .loopback
        default: return false
        }
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint), connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .cancelled, .failed: self?.connections[key] = nil
                default: break
                }
            }
        }
        connection.start(queue: .main)
        // a client that doesn't finish its request in time is dropped
        Task { [weak self, weak connection] in
            try? await Task.sleep(for: Self.requestTimeout)
            guard let self, let connection, self.connections[key] != nil, self.waiting.contains(key) else { return }
            connection.cancel()
        }
        waiting.insert(key)
        receive(connection, buffer: Data())
    }

    /// Connections still sending their request (the timeout applies to them, not to an answer being worked out).
    private var waiting: Set<ObjectIdentifier> = []

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                let buffer = buffer + (data ?? Data())
                switch ControlHTTP.parse(buffer) {
                case .request(let box):
                    self.waiting.remove(ObjectIdentifier(connection))
                    self.respond(to: box.request, on: connection)
                case .refused(let status, let code, let message):
                    self.waiting.remove(ObjectIdentifier(connection))
                    self.send(.error(ControlError(code: code, status: status, message: message)), on: connection)
                case .incomplete:
                    if error != nil || isComplete {
                        connection.cancel()
                    } else {
                        self.receive(connection, buffer: buffer)
                    }
                }
            }
        }
    }

    private func respond(to request: ControlRequest, on connection: NWConnection) {
        Task { @MainActor in
            send(await handle(request), on: connection)
        }
    }

    private func send(_ response: ControlResponse, on connection: NWConnection) {
        connection.send(content: response.data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
