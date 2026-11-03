import Foundation
import Network
import Testing

@testable import NXPlayIOSLogic

/// Where the saved code may go (PairingTrust), what a hostile answer can and can't do (redirects, proxies), a
/// cancelled pairing, links the Mac makes, and the scanner's hand-over of codes. Every server here is a loopback
/// responder that knows only what a stranger on the network could: the Mac's public ID.
@Suite(.serialized) struct TrustTests {
    static let macID = "5F0C1A2B-3C4D-4E5F-8A6B-7C8D9E0F1A2B"
    static let otherID = "9A8B7C6D-5E4F-4A3B-9C2D-1E0F2A3B4C5D"
    static let code = "abcd-efgh-jkmn"

    private func paired(_ endpoints: [Endpoint], id: String? = macID) -> PairedMac {
        PairedMac(name: "Mac", macID: id, endpoints: endpoints, token: Self.code, device: nil)
    }

    private func endpoint(_ text: String) throws -> Endpoint { try Endpoint.parse(text, defaultPort: nil) }

    // MARK: Where the saved code goes

    @Test func theSavedCodeGoesOnlyToConfirmedAddresses() throws {
        let mac = paired([try endpoint("192.168.1.20:47474"), try endpoint("mac.local:47474"), try endpoint("100.64.0.1:47474")])
        #expect(PairingTrust.reconnectCandidates(mac) == Array(mac.endpoints.dropFirst()))
        let impostor = try endpoint("192.168.1.66:47474")
        let found: [(macID: String?, endpoints: [Endpoint])] = [
            (Self.macID, [impostor, mac.endpoints[1]]), (Self.otherID, [try endpoint("192.168.1.77:47474")]),
            (nil, [try endpoint("192.168.1.88:47474")]),
        ]
        // Bonjour's same-ID address is shown to the player, never added to the addresses the code goes to
        #expect(PairingTrust.unconfirmedAddresses(of: mac, found: found) == [impostor])
        #expect(PairingTrust.reconnectCandidates(mac).contains(impostor) == false)
        // a Mac from before /v1/hello has no ID to match
        #expect(PairingTrust.unconfirmedAddresses(of: paired(mac.endpoints, id: nil), found: found).isEmpty)
        #expect(PairingTrust.unconfirmedAddresses(of: nil, found: found).isEmpty)
    }

    // MARK: Redirects and proxies

    @MainActor @Test func aHelloRedirectedToTheRealMacDoesNotVouchForTheAddress() async throws {
        let honest = try await ScriptedMac { scriptedAnswer($0) }
        defer { honest.stop() }
        let hello = try #require(honest.endpoint.url(path: "v1/hello")).absoluteString
        let impostor = try await ScriptedMac { request in
            request.path == "/v1/hello" ? .init(status: 302, location: hello) : scriptedAnswer(request)
        }
        defer { impostor.stop() }
        #expect(try await MacClient(endpoint: impostor.endpoint, token: "").hello() == .notNXPlay)
        let result = await PairingAttempt.run(endpoints: [impostor.endpoint], token: Self.code, expectedID: Self.macID) {
            e, _ in "\(e)"
        }
        #expect((try? result.get()) == nil)
        #expect(impostor.requests.allSatisfy { $0.authorization == nil })
        #expect(impostor.requests.map(\.path) == ["/v1/hello", "/v1/hello"])
        #expect(honest.requests.isEmpty, "the redirect isn't followed at all")
    }

    @MainActor @Test func anAuthenticatedRequestIsNeverRedirected() async throws {
        let sink = try await ScriptedMac { scriptedAnswer($0) }
        defer { sink.stop() }
        let elsewhere = try #require(sink.endpoint.url(path: "v1/info")).absoluteString
        let source = try await ScriptedMac { request in
            request.path == "/v1/info" ? .init(status: 307, location: elsewhere) : scriptedAnswer(request)
        }
        defer { source.stop() }
        await #expect(throws: MacClient.Failure.self) {
            try await MacClient(endpoint: source.endpoint, token: Self.code).info()
        }
        #expect(sink.requests.isEmpty)
    }

    @Test func requestsUseNoProxy() async throws {
        #expect(MacClient.configuration.connectionProxyDictionary != nil)
        #expect(MacClient.configuration.connectionProxyDictionary?.isEmpty == true)
        // control: a session given a proxy does send to it (the dictionary is honoured per session)
        let proxy = try await ScriptedMac { _ in .init(body: #"{"app":"nxplay","api":1,"id":"\#(Self.macID)"}"#) }
        defer { proxy.stop() }
        let unreachable = Endpoint(validHost: "nxplay-proxy-check.invalid", port: 47474)
        let proxied = URLSessionConfiguration.ephemeral
        proxied.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": Int(proxy.endpoint.port),
        ]
        let url = try #require(unreachable.url(path: "v1/hello"))
        _ = try? await URLSession(configuration: proxied).data(from: url)
        #expect(proxy.requests.count == 1)
        // the app's own client: straight to the host (which doesn't exist), the proxy never sees it
        await #expect(throws: (any Error).self) { try await MacClient(endpoint: unreachable, token: "").hello() }
        #expect(proxy.requests.count == 1)
    }

    // MARK: A cancelled pairing

    @MainActor @Test func aCancelledPairingSendsNoCode() async throws {
        let mac = try await ScriptedMac { request in
            var reply = scriptedAnswer(request)
            reply.hold = request.path == "/v1/hello"
            return reply
        }
        defer { mac.stop() }
        let attempt = Task {
            await PairingAttempt.run(endpoints: [mac.endpoint, mac.endpoint], token: Self.code, expectedID: Self.macID) {
                e, _ in "\(e)"
            }
        }
        try await mac.waitFor("/v1/hello")
        attempt.cancel()
        mac.release()
        #expect((try? await attempt.value.get()) == nil)
        try await Task.sleep(for: .milliseconds(200))
        mac.release()
        #expect(mac.requests.allSatisfy { $0.authorization == nil })
    }

    // MARK: Links the Mac makes

    static let longAddresses = [
        "192.168.1.20:47474", "10.0.0.20:47474", "macbook-pro.local:47474",
        "[fd12:3456:789a:bcde:1234:5678:9abc:def0]:47474", "[2001:db8:1234:5678:1234:5678:9abc:def0]:47474",
        "macbook-pro.tail1234.ts.net:47474", "100.100.100.100:47474", "[fd7a:115c:a1e0::1234:5678]:47474",
    ]

    @Test(arguments: [
        String(repeating: "🖥", count: 60), String(repeating: "👨‍👩‍👧‍👦", count: 64), "Jess’s MacBook Pro",
        "Mac & Co + ? = #1 / % ;", "  spaced  ", "\u{202E}gnp.exe", "a\u{0000}b\nc", "\u{200B}\u{200D}",
        String(repeating: "e\u{301}", count: 80), "مرحبا Mac", String(repeating: "x", count: 300),
    ])
    func everyLinkTheMacMakesReadsBack(name: String) throws {
        for count in 1...Self.longAddresses.count {
            let endpoints = try Self.longAddresses.prefix(count).map(endpoint)
            let link = try #require(
                PairingLink.fitting(macID: Self.macID, name: name, code: Self.code, endpoints: endpoints))
            let text = try #require(link.url).absoluteString
            #expect(text.utf8.count <= NXPlayPairing.maxLinkLength)
            #expect(try PairingLink.parse(text) == link)
            // the name is what gives way: every address the Mac has still fits
            #expect(link.endpoints == endpoints)
            #expect(!link.name.isEmpty)
        }
    }

    @Test func theReviewersLinkNowFitsAndReadsBack() throws {
        let name = String(repeating: "🖥", count: 60)
        let endpoints = try Self.longAddresses.map(endpoint)
        // as before: made without fitting, it would be too long, so `url` refuses to make it
        #expect(PairingLink(macID: Self.macID, name: name, code: Self.code, endpoints: endpoints).url == nil)
        let link = try #require(PairingLink.fitting(macID: Self.macID, name: name, code: Self.code, endpoints: endpoints))
        #expect(try PairingLink.parse(try #require(link.url).absoluteString) == link)
        #expect(link.endpoints.count == 8 && link.name.count < 60)
    }

    @Test func longNamesForAddressesLeaveOutTheLastOnes() throws {
        let label = String(repeating: "a", count: 60)
        let long = (1...8).map { Endpoint(validHost: "\(label).\(label).\(label).h\($0).ts.net", port: 47474) }
        let link = try #require(PairingLink.fitting(macID: Self.macID, name: "Mac", code: Self.code, endpoints: long))
        #expect(link.endpoints == Array(long.prefix(link.endpoints.count)))
        #expect(link.endpoints.count < 8 && link.endpoints.count >= 1)
        #expect(try PairingLink.parse(try #require(link.url).absoluteString) == link)
        #expect(PairingLink.fitting(macID: Self.macID, name: "Mac", code: Self.code, endpoints: []) == nil)
    }

    // MARK: IPv4 written as IPv6

    @Test func mappedIPv4IsCheckedAsIPv4() throws {
        for text in ["[::ffff:224.0.0.251]:47474", "[::ffff:0.0.0.0]:47474", "[::ffff:255.255.255.255]:47474", "[::ffff:e000:fb]:1"] {
            #expect(throws: PairingError.self, "\(text)") { try Endpoint.parse(text, defaultPort: nil) }
        }
        let mapped = try endpoint("[::ffff:192.168.1.20]:47474")
        #expect(mapped == (try endpoint("192.168.1.20:47474")))
        #expect(mapped.kind == .lan && !mapped.isIPv6)
        #expect(try endpoint("[::ffff:100.64.0.1]:1").kind == .tailscale)
    }

    // MARK: The scanner's codes

    @MainActor @Test func codesStillOnTheirWayWhenTheScannerClosesAreDropped() async throws {
        let sink = QRCodeSink()
        var received: [String] = []
        sink.open { received.append($0) }
        let capture = DispatchQueue(label: "nxplay-test-capture")
        // delivered from the capture queue, still waiting for the main actor, when the scanner closes
        capture.sync { for i in 0..<100 { sink.deliver("code \(i)") } }
        sink.close()
        try await Task.sleep(for: .milliseconds(100))
        #expect(received.isEmpty)
        sink.open { received.append($0) }
        capture.sync { sink.deliver("late") }
        try await Task.sleep(for: .milliseconds(50))
        #expect(received.isEmpty, "a closed scanner stays closed")
    }

    @MainActor @Test func anOpenScannerGetsItsCodes() async throws {
        let sink = QRCodeSink()
        var received: [String] = []
        sink.open { received.append($0) }
        let capture = DispatchQueue(label: "nxplay-test-capture")
        capture.sync { for i in 0..<100 { sink.deliver("code \(i)") } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(received.count == 100)
    }

    /// Run with --sanitize=thread: the capture queue delivers while the main actor opens and closes scanners.
    @MainActor @Test func closingWhileTheCameraDeliversIsSafe() async throws {
        let capture = DispatchQueue(label: "nxplay-test-capture")
        var received = 0
        for round in 0..<400 {
            let sink = QRCodeSink()
            sink.open { _ in received += 1 }
            capture.async {
                for _ in 0..<50 { sink.deliver("code \(round)") }
            }
            if round % 2 == 0 { sink.close() }
            await Task.yield()
            sink.close()
            // the serial queue has delivered them all once this runs
            await withCheckedContinuation { done in capture.async { done.resume() } }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(received >= 0)
    }
}

// MARK: - A scripted responder on loopback

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
