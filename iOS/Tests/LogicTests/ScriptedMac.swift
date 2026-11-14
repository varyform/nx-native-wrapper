import Foundation
import Network

@testable import NXPlayIOSLogic

/// An HTTP responder on 127.0.0.1 that records each request (path, Authorization) and answers as told: forged
/// identity, redirects, and answers held until `release`.
final class ScriptedMac: @unchecked Sendable {
    struct Request: Sendable {
        let path: String
        let authorization: String?
    }

    struct Reply: Sendable {
        var status = 200
        var body = "{}"
        var location: String?
        var hold = false
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "nxplay-test-scripted-mac")
    private let lock = NSLock()
    private var seen: [Request] = []
    private var held: [@Sendable () -> Void] = []
    private(set) var endpoint = Endpoint(validHost: "127.0.0.1", port: 1)

    var requests: [Request] { lock.withLock { seen } }

    init(answer: @escaping @Sendable (Request) -> Reply) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection, answer: answer) }
            listener.start(queue: queue)
        }
        endpoint = Endpoint(validHost: "127.0.0.1", port: port)
    }

    func stop() {
        release()
        listener.cancel()
    }

    /// Sends the answers held so far.
    func release() {
        let pending = lock.withLock {
            let pending = held
            held = []
            return pending
        }
        pending.forEach { $0() }
    }

    func waitFor(_ path: String) async throws {
        for _ in 0..<300 {
            if requests.contains(where: { $0.path == path }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MacClient.Failure(message: "no request for \(path)")
    }

    private func serve(_ connection: NWConnection, answer: @escaping @Sendable (Request) -> Reply) {
        connection.start(queue: queue)
        read(connection, buffer: Data(), answer: answer)
    }

    private func read(_ connection: NWConnection, buffer: Data, answer: @escaping @Sendable (Request) -> Reply) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            let buffer = buffer + (data ?? Data())
            guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete || error != nil || buffer.count > 65536 { return connection.cancel() }
                return self.read(connection, buffer: buffer, answer: answer)
            }
            let lines = String(decoding: buffer, as: UTF8.self).components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }
                .map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) }
            let request = Request(path: path, authorization: authorization)
            self.lock.withLock { self.seen.append(request) }
            let reply = answer(request)
            let send: @Sendable () -> Void = {
                let location = reply.location.map { "Location: \($0)\r\n" } ?? ""
                let head =
                    "HTTP/1.1 \(reply.status) Scripted\r\nContent-Type: application/json\r\n\(location)Content-Length: \(reply.body.utf8.count)\r\nConnection: close\r\n\r\n"
                connection.send(
                    content: Data((head + reply.body).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
            if reply.hold { self.lock.withLock { self.held.append(send) } } else { send() }
        }
    }
}

/// NX Play's answers, as an impostor that copied the public ID would give them: it never checks the code.
func scriptedAnswer(_ request: ScriptedMac.Request, id: String = TrustTests.macID) -> ScriptedMac.Reply {
    switch request.path {
    case "/v1/hello": .init(body: #"{"app":"nxplay","api":1,"id":"\#(id)"}"#)
    case "/v1/info": .init(body: #"{"name":"Scripted Mac","version":"1","team":null,"id":"\#(id)"}"#)
    case "/v1/devices", "/v1/games": .init(body: "[]")
    default: .init(status: 404, body: #"{"error":"no"}"#)
    }
}
