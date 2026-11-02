import Foundation
import Network
import SystemConfiguration

/// How the iOS app reaches NX Play: a small HTTP server on the local network, advertised over Bonjour as
/// `_nxplay._tcp`, so the app finds the Mac without being given an address. Everything runs on the main queue,
/// where the library lives. Each connection carries one request and closes after the response.
@MainActor final class RemoteServer {
    static let serviceType = "_nxplay._tcp"
    /// A fixed port, so `curl` and an app given a host name can reach it without Bonjour.
    static let defaultPort: UInt16 = 47_474

    typealias Handler = @MainActor (RemoteRequest) async -> RemoteResponse

    private let handle: Handler
    private var listener: NWListener?
    /// Why the server isn't listening (the port taken, the network refused); nil while it's fine.
    var onProblem: ((String?) -> Void)?

    init(handle: @escaping Handler) {
        self.handle = handle
    }

    func start(port: UInt16 = defaultPort) {
        stop()
        guard let port = NWEndpoint.Port(rawValue: port) else { return }
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: port)
        } catch {
            onProblem?("Can't listen on port \(port): \(error.localizedDescription)")
            return
        }
        // the host name in the TXT record: the iOS app talks HTTP to <name>.local, not to the Bonjour service
        let host = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
        listener.service = NWListener.Service(
            type: Self.serviceType,
            txtRecord: NWTXTRecord(["v": "1", "host": host ?? "", "port": "\(port)"]).data)
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.onProblem?(nil)
                case .failed(let error):
                    self?.onProblem?("Can't listen on port \(port): \(error.localizedDescription)")
                    self?.stop()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
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
