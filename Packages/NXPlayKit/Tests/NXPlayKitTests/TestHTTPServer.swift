import Foundation
import Network

/// A tiny HTTP/1.1 server on 127.0.0.1 for Sources' tests: fixed answers by path, a body sent in chunks (slowly, for
/// cancelling), redirects, and a record of each request's headers. Synthetic data only.
final class TestHTTPServer: @unchecked Sendable {
    struct Route {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// Content-Length when it should lie about the body.
        var length: Int?
        var chunk = 64 * 1024
        var delay: TimeInterval = 0
    }

    struct Seen {
        let path: String
        let headers: [String: String]
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-http")
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var seen: [Seen] = []
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    deinit { listener.cancel() }

    func route(_ path: String, _ route: Route) { lock.withLock { routes[path] = route } }

    func requests(_ path: String) -> [Seen] { lock.withLock { seen.filter { $0.path == path } } }

    func url(_ path: String, host: String = "127.0.0.1") -> URL {
        URL(string: "http://\(host):\(port)\(path)")!
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, Data())
    }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.answer(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), connection)
            } else if error == nil, !done {
                self.receive(connection, buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func answer(_ head: String, _ connection: NWConnection) {
        var lines = head.components(separatedBy: "\r\n")
        let path = lines.removeFirst().split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let route = lock.withLock {
            seen.append(Seen(path: path, headers: headers))
            return routes[path] ?? Route(status: 404, body: Data("missing".utf8))
        }
        var text = "HTTP/1.1 \(route.status) Test\r\nContent-Length: \(route.length ?? route.body.count)\r\n"
        for (name, value) in route.headers { text += "\(name): \(value)\r\n" }
        text += "Connection: close\r\n\r\n"
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
        send(route, from: 0, connection)
    }

    private func send(_ route: Route, from offset: Int, _ connection: NWConnection) {
        guard offset < route.body.count else {
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let end = min(route.body.count, offset + route.chunk)
        connection.send(
            content: route.body.subdata(in: offset..<end),
            completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else { return connection.cancel() }
                if route.delay > 0 {
                    self.queue.asyncAfter(deadline: .now() + route.delay) { self.send(route, from: end, connection) }
                } else {
                    self.send(route, from: end, connection)
                }
            })
    }
}
