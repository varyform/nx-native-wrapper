import Foundation
import Testing

@testable import NXPlayKit

/// Bonjour's retries, the code-free `/v1/hello`, and the server's port.
@Suite struct AdvertisementTrackerTests {
    @Test func bonjourIsAskedAgainUntilItConfirms() {
        var tracker = AdvertisementTracker()
        #expect(tracker.state == .off)
        #expect(tracker.started() == .wait(.seconds(10)))
        #expect(tracker.state == .registering(attempt: 1))
        #expect(tracker.timedOut() == .restart)
        #expect(tracker.started() == .wait(.seconds(20)))
        #expect(tracker.started() == .wait(.seconds(40)))
        #expect(tracker.added(name: "Mac") == .confirmed)
        #expect(tracker.state == .advertised(name: "Mac"))
        #expect(tracker.timedOut() == .ignore)
        // the network went away: waited for again, from the first pause
        #expect(tracker.removed() == .wait(.seconds(10)))
        #expect(tracker.state == .registering(attempt: 1))
        #expect(tracker.removed() == .unchanged)
        tracker.stopped()
        #expect(tracker.state == .off)
        #expect(tracker.timedOut() == .ignore)
    }

    @Test func pausesGrowAndStop() {
        #expect((1...8).map(AdvertisementTracker.pause(attempt:)) == [10, 20, 40, 80, 160, 300, 300, 300].map { .seconds($0) })
        #expect((1...7).map(AdvertisementTracker.pause(afterFailures:)) == [5, 10, 20, 40, 60, 60, 60].map { .seconds($0) })
    }
}

@MainActor @Suite final class PairingServerTests {
    private var suites: [String] = []

    deinit {
        suites.forEach(removeTestDefaults)
    }

    private func library() -> (Library, UserDefaults) {
        let suite = testDefaultsName()
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        return (Library(defaults: defaults, isScreenshot: true), defaults)
    }

    @Test func helloNeedsNoCodeAndTellsNothingElse() async throws {
        let (library, _) = library()
        let hello = try #require(RemoteRequest.parse(Data("GET /v1/hello HTTP/1.1\r\n\r\n".utf8)))
        let response = await library.respond(to: hello)
        #expect(response.status == 200)
        let decoded = try JSONDecoder().decode(PairingHello.self, from: response.body)
        #expect(decoded == PairingHello(app: "nxplay", api: 1, id: library.remoteID))
        let body = String(decoding: response.body, as: UTF8.self)
        #expect(!body.contains(library.remoteToken))
        #expect(try JSONSerialization.jsonObject(with: response.body) as? [String: Any] != nil)
        #expect((try JSONSerialization.jsonObject(with: response.body) as? [String: Any])?.count == 3)
        // everything else still takes the code
        for path in ["v1/info", "v1/games", "v1/devices", "v1/hello/x"] {
            let request = try #require(RemoteRequest.parse(Data("GET /\(path) HTTP/1.1\r\n\r\n".utf8)))
            #expect(await library.respond(to: request).status == 401)
        }
        let post = try #require(RemoteRequest.parse(Data("POST /v1/hello HTTP/1.1\r\n\r\n".utf8)))
        #expect(await library.respond(to: post).status == 401)
    }

    @Test func theMacKeepsItsIDAndPort() {
        let (library, defaults) = library()
        let id = library.remoteID
        #expect(UUID(uuidString: id) != nil)
        #expect(library.remoteID == id)
        #expect(Library(defaults: defaults, isScreenshot: true).remoteID == id)

        #expect(library.remotePort == 47474)
        library.setRemotePort(47475)
        #expect(library.remotePort == 47475)
        #expect(defaults.integer(forKey: "remotePort") == 47475)
        #expect(Library(defaults: defaults, isScreenshot: true).remotePort == 47475)
        library.setRemotePort(80)
        #expect(library.remotePort == 47474)
        #expect(defaults.object(forKey: "remotePort") == nil)
    }

    @Test func theScreenshotQRCodeHasNoRealCode() throws {
        let (library, _) = library()
        library.remoteEnabled = true
        let link = try #require(library.pairingLink(endpoints: library.remoteEndpoints))
        #expect(link.code == "abcd-efgh-jkmn" && link.code != library.remoteToken)
        #expect(link.macID == library.remoteID)
        #expect(link.endpoints.map(\.display) == [
            "192.168.1.20:47474", "mac.local:47474", "mac.example.ts.net:47474", "100.101.102.103:47474",
        ])
        #expect(try PairingLink.parse(try #require(link.url).absoluteString) == link)
        #expect(library.pairingLink(endpoints: []) == nil)
    }

    /// A restart waits for the old listener to close; a stop right after calls that restart off, so nothing listens
    /// again later.
    @Test func aStopRightAfterARestartStaysStopped() async throws {
        let server = RemoteServer { _ in .json(["app": "nxplay"]) }
        defer { server.stop() }
        server.start(port: 0, advertises: false)
        let port = try #require(await waitForPort(server))
        server.start(port: port, advertises: false)
        server.stop()
        #expect(server.listeningPort == nil)
        // past the old listener's close and the one-second fallback
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(server.listeningPort == nil)
        await #expect(throws: (any Error).self) { try await self.get(port: port) }
    }

    /// A long Unicode computer name with every kind of address still makes a link the app reads back whole.
    @Test func aLongUnicodeNameStillMakesALinkTheAppReads() throws {
        let name = String(repeating: "🖥", count: 60)
        let endpoints = try [
            "192.168.1.20:47474", "10.0.0.20:47474", "macbook-pro.local:47474",
            "[fd12:3456:789a:bcde:1234:5678:9abc:def0]:47474", "[2001:db8:1234:5678:1234:5678:9abc:def0]:47474",
            "macbook-pro.tail1234.ts.net:47474", "100.100.100.100:47474", "[fd7a:115c:a1e0::1234:5678]:47474",
        ].map { try Endpoint.parse($0, defaultPort: nil) }
        let link = try #require(
            PairingLink.fitting(macID: PairingLinkTests.id, name: name, code: PairingLinkTests.code, endpoints: endpoints))
        let text = try #require(link.url).absoluteString
        #expect(text.utf8.count <= NXPlayPairing.maxLinkLength)
        #expect(try PairingLink.parse(text) == link)
        #expect(link.endpoints == endpoints)
    }

    /// A real listener on a free port, without Bonjour: answers, restarts on the same port, and stops.
    @Test func theServerListensRestartsAndStops() async throws {
        let server = RemoteServer { request in
            request.route("GET", "v1/hello") != nil ? .json(["app": "nxplay"]) : .error(404, "no")
        }
        var problems: [String?] = []
        server.onProblem = { problems.append($0) }
        server.start(port: 0, advertises: false)
        let port = try #require(await waitForPort(server))
        #expect(try await get(port: port) == 200)

        server.start(port: port, advertises: false)
        let again = await waitForPort(server)
        #expect(again == port, "problems: \(problems)")
        #expect(try await get(port: port) == 200)

        server.stop()
        #expect(server.listeningPort == nil)
        await #expect(throws: (any Error).self) { try await self.get(port: port) }
        #expect(!problems.contains { $0 != nil })
    }

    /// The setting turned off and straight on again: a new server takes the port back without calling it taken.
    @Test func aQuickOffAndOnTakesThePortBack() async throws {
        let first = RemoteServer { _ in .json(["app": "nxplay"]) }
        first.start(port: 0, advertises: false)
        let port = try #require(await waitForPort(first))
        #expect(try await get(port: port) == 200)
        first.stop()
        let second = RemoteServer { _ in .json(["app": "nxplay"]) }
        var problems: [String?] = []
        second.onProblem = { problems.append($0) }
        second.start(port: port, advertises: false)
        #expect(await waitForPort(second) == port)
        #expect(try await get(port: port) == 200)
        second.stop()
        #expect(!problems.contains { $0 != nil }, "problems: \(problems)")
    }

    @Test func aTakenPortSaysSo() async throws {
        let first = RemoteServer { _ in .error(404, "no") }
        first.start(port: 0, advertises: false)
        let port = try #require(await waitForPort(first))
        defer { first.stop() }
        let second = RemoteServer { _ in .error(404, "no") }
        var problem: String?
        second.onProblem = { problem = $0 ?? problem }
        second.start(port: port, advertises: false)
        for _ in 0..<40 where problem == nil { try await Task.sleep(for: .milliseconds(50)) }
        second.stop()
        // the listener may take the port too (address reuse) or fail: when it fails, it says which port
        if let problem { #expect(problem.contains("\(port)")) }
    }

    private func waitForPort(_ server: RemoteServer) async -> UInt16? {
        for _ in 0..<60 {
            if let port = server.listeningPort, port != 0 { return port }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    nonisolated private func get(port: UInt16) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/hello")!)
        request.timeoutInterval = 3
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
