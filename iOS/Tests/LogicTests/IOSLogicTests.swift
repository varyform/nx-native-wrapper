import Foundation
import Network
import Testing

@testable import NXPlayIOSLogic

/// A pairing kept in memory instead of the Keychain; `refuses` plays a Keychain that won't keep it.
final class MemoryVault: TokenVault, @unchecked Sendable {
    var token: String?
    var refuses = false

    func read() -> String? { token }
    func write(_ token: String) -> Bool {
        guard !refuses else { return false }
        self.token = token
        return true
    }
    func delete() { token = nil }
}

@Suite struct PairingStoreTests {
    private func defaults() -> UserDefaults {
        let name = "nxplay-ios-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func storedJSON(_ defaults: UserDefaults) throws -> [String: Any] {
        let data = try #require(defaults.data(forKey: PairingStore.macKey))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func aPairingFromBeforeIsKeptAndItsCodeMovesToTheKeychain() throws {
        let defaults = defaults()
        let old = #"{"name": "Jess’s MacBook Pro", "host": "Jesss-MacBook-Pro-7.local", "port": 47475, "token": "abcd-efgh-jkmn", "device": "00008160-000A1B2C3D4E5F60"}"#
        defaults.set(Data(old.utf8), forKey: PairingStore.macKey)
        let vault = MemoryVault()
        let mac = try #require(PairingStore.load(defaults, vault: vault))
        #expect(mac.name == "Jess’s MacBook Pro")
        #expect(mac.endpoints.map(\.display) == ["jesss-macbook-pro-7.local:47475"])
        #expect(mac.token == "abcd-efgh-jkmn")
        #expect(mac.device == "00008160-000A1B2C3D4E5F60")
        #expect(mac.macID == nil)
        #expect(vault.token == "abcd-efgh-jkmn")
        let stored = try storedJSON(defaults)
        #expect(stored["token"] == nil && stored["host"] == nil)
        // and it reads back the same from where it is now
        #expect(PairingStore.load(defaults, vault: vault) == mac)
    }

    @Test func oldAddressesOfEveryShapeSurvive() throws {
        for (host, port, expected) in [
            ("fd7a:115c:a1e0::1", 47474, "[fd7a:115c:a1e0::1]:47474"), ("192.168.1.123", 47475, "192.168.1.123:47475"),
            ("my mac", 47474, "my mac:47474"), ("mac.local", 0, "mac.local:47474"),
        ] {
            let defaults = defaults()
            let old = #"{"name": "M", "host": "\#(host)", "port": \#(port), "token": "abcd-efgh-jkmn"}"#
            defaults.set(Data(old.utf8), forKey: PairingStore.macKey)
            #expect(PairingStore.load(defaults, vault: MemoryVault())?.endpoint.display == expected)
        }
    }

    @Test func aRefusingKeychainKeepsTheCodeWhereItWas() throws {
        let defaults = defaults()
        let vault = MemoryVault()
        vault.refuses = true
        let endpoints = try ["[fd7a:115c:a1e0::1]:47475", "mac.local:47475"].map { try Endpoint.parse($0, defaultPort: nil) }
        let mac = PairedMac(name: "M", macID: UUID().uuidString, endpoints: endpoints, token: "abcd-efgh-jkmn", device: nil)
        PairingStore.save(mac, defaults, vault: vault)
        #expect(try storedJSON(defaults)["token"] as? String == "abcd-efgh-jkmn")
        #expect(PairingStore.load(defaults, vault: vault) == mac)
        // a stale Keychain code never wins over the newer one kept in UserDefaults
        vault.token = "zzzz-zzzz-zzzz"
        #expect(PairingStore.load(defaults, vault: vault)?.token == "abcd-efgh-jkmn")
    }

    @Test func unpairingForgetsBoth() throws {
        let defaults = defaults()
        let vault = MemoryVault()
        let mac = PairedMac(
            name: "M", macID: nil, endpoints: [try Endpoint.parse("10.0.0.2", defaultPort: 47474)],
            token: "abcd-efgh-jkmn", device: "x")
        PairingStore.save(mac, defaults, vault: vault)
        #expect(try storedJSON(defaults)["token"] == nil)
        PairingStore.save(nil, defaults, vault: vault)
        #expect(defaults.data(forKey: PairingStore.macKey) == nil && vault.token == nil)
        #expect(PairingStore.load(defaults, vault: vault) == nil)
    }
}

@Suite struct AdviceTests {
    private func advice(_ code: URLError.Code, _ address: String, denied: Bool = false) throws -> String {
        MacClient.describe(
            URLError(code), at: try Endpoint.parse(address, defaultPort: 47474), localNetworkDenied: denied,
            device: "iPhone")
    }

    @Test func eachFailureSaysWhatToCheck() throws {
        #expect(try advice(.cannotFindHost, "mac.tail1234.ts.net").contains("Tailscale"))
        #expect(try advice(.cannotFindHost, "mac.local").contains("IP address"))
        #expect(try advice(.timedOut, "100.101.12.34").contains("Tailscale is connected"))
        #expect(try advice(.timedOut, "192.168.1.123").contains("same Wi-Fi"))
        #expect(try advice(.timedOut, "192.168.1.123", denied: true).contains("Local Network"))
        #expect(try advice(.notConnectedToInternet, "192.168.1.123", denied: true).contains("Local Network"))
        #expect(try advice(.cannotConnectToHost, "192.168.1.123:47475").contains("port"))
        #expect(try advice(.appTransportSecurityRequiresSecureConnection, "nas.example.com").contains("plain HTTP"))
        let failure = MacClient.Failure(message: "Wrong pairing code: see NX Play › Settings › Devices on the Mac", status: 401)
        #expect(MacClient.describe(failure, at: try Endpoint.parse("10.0.0.2", defaultPort: 1), localNetworkDenied: false, device: "iPhone") == failure.message)
    }
}

@Suite struct ResolvedAddressTests {
    @Test func aResolvedServiceBecomesAnAddressToTry() throws {
        let port = try #require(NWEndpoint.Port(rawValue: 47475))
        #expect(MacFinder.endpoint(.ipv4(try #require(IPv4Address("192.168.1.123"))), port)?.display == "192.168.1.123:47475")
        #expect(
            MacFinder.endpoint(.ipv6(try #require(IPv6Address("fd12:3456:789a:bcde::7161"))), port)?.display
                == "[fd12:3456:789a:bcde::7161]:47475")
        #expect(MacFinder.endpoint(.ipv6(try #require(IPv6Address("fe80::1"))), port) == nil)
        #expect(MacFinder.endpoint(.name("Mac.local", nil), port)?.display == "mac.local:47475")
        #expect(MacFinder.isPolicyDenied(.dns(-65570)))
        #expect(!MacFinder.isPolicyDenied(.posix(.ECONNREFUSED)))
    }
}

/// Small HTTP servers standing in for Macs (and for things that aren't NX Play): the code must reach only the right one.
@Suite(.serialized) struct PairingAttemptTests {
    static let macID = "5F0C1A2B-3C4D-4E5F-8A6B-7C8D9E0F1A2B"
    static let code = "abcd-efgh-jkmn"

    @Test func theCodeGoesOnlyToTheRightMac() async throws {
        let other = try await FakeMac(id: UUID().uuidString)
        let stranger = try await FakeMac(kind: .notNXPlay)
        let right = try await FakeMac(id: Self.macID)
        defer { [other, stranger, right].forEach { $0.stop() } }
        let result = await PairingAttempt.run(
            endpoints: [other.endpoint, stranger.endpoint, right.endpoint], token: Self.code, expectedID: Self.macID
        ) { error, _ in "\(error)" }
        let success = try result.get()
        #expect(success.endpoint == right.endpoint)
        #expect(success.macID == Self.macID)
        #expect(success.info.name == "Right Mac")
        #expect(other.authorizations.allSatisfy { $0 == nil })
        #expect(stranger.authorizations.allSatisfy { $0 == nil })
        #expect(right.authorizations.first == .some(nil))  // /v1/hello: no code
        #expect(right.authorizations.dropFirst().allSatisfy { $0 == "Bearer \(Self.code)" })
    }

    @Test func aWrongCodeStopsAtTheFirstMac() async throws {
        let first = try await FakeMac(id: Self.macID, code: "zzzz-zzzz-zzzz")
        let second = try await FakeMac(id: Self.macID)
        defer { first.stop(); second.stop() }
        let result = await PairingAttempt.run(
            endpoints: [first.endpoint, second.endpoint], token: Self.code, expectedID: Self.macID
        ) { error, _ in "\(error)" }
        guard case .failure(let failures) = result else { Issue.record("paired with a wrong code"); return }
        #expect(failures.messages.count == 1 && failures.messages[0].contains("Wrong pairing code"))
        #expect(second.authorizations.isEmpty)
    }

    @Test func anOlderMacPairsByAddressButNotByLink() async throws {
        let older = try await FakeMac(kind: .older)
        defer { older.stop() }
        let typed = await PairingAttempt.run(endpoints: [older.endpoint], token: Self.code, expectedID: nil) { e, _ in "\(e)" }
        #expect((try? typed.get())?.macID == nil)
        #expect((try? typed.get()) != nil)
        let linked = await PairingAttempt.run(endpoints: [older.endpoint], token: Self.code, expectedID: Self.macID) { e, _ in "\(e)" }
        #expect((try? linked.get()) == nil)
    }

    @Test func nothingListeningSaysSo() async throws {
        let gone = try await FakeMac(id: Self.macID)
        let endpoint = gone.endpoint
        gone.stop()
        try await Task.sleep(for: .milliseconds(100))
        let result = await PairingAttempt.run(endpoints: [endpoint], token: Self.code, expectedID: Self.macID) { error, at in
            MacClient.describe(error, at: at, localNetworkDenied: false, device: "iPhone")
        }
        guard case .failure(let failures) = result else { Issue.record("paired with nothing"); return }
        #expect(failures.text.contains("turned the connection down") || failures.text.contains("127.0.0.1"))
    }
}

/// A one-request-per-connection HTTP server on 127.0.0.1 answering as NX Play (`.current`), as NX Play before
/// /v1/hello (`.older`), or as something else (`.notNXPlay`). It records each request's Authorization header.
final class FakeMac: @unchecked Sendable {
    enum Kind { case current, older, notNXPlay }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-mac")
    private let lock = NSLock()
    private var seen: [String?] = []
    private(set) var endpoint = Endpoint(validHost: "127.0.0.1", port: 1)

    var authorizations: [String?] { lock.withLock { seen } }

    init(id: String = UUID().uuidString, code: String = "abcd-efgh-jkmn", kind: Kind = .current) async throws {
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
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection, id: id, code: code, kind: kind) }
            listener.start(queue: queue)
        }
        endpoint = try Endpoint.parse("127.0.0.1:\(port)", defaultPort: nil)
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection, id: String, code: String, kind: Kind) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let head = String(data: data, encoding: .utf8) else { return connection.cancel() }
            let lines = head.components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }
                .map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) }
            self.lock.withLock { self.seen.append(authorization) }
            let (status, body) = self.answer(path: path, authorization: authorization, id: id, code: code, kind: kind)
            let response = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func answer(path: String, authorization: String?, id: String, code: String, kind: Kind) -> (Int, String) {
        switch kind {
        case .notNXPlay: return (404, "<html>router</html>")
        case .current where path == "/v1/hello": return (200, #"{"app":"nxplay","api":1,"id":"\#(id)"}"#)
        case .current, .older:
            guard authorization == "Bearer \(code)" else {
                return (401, #"{"error":"Wrong pairing code: see NX Play › Settings › Devices on the Mac"}"#)
            }
            if path == "/v1/info" {
                return (200, kind == .older ? #"{"name":"Old Mac","version":"1.8.0","team":null}"# : #"{"name":"Right Mac","version":"1.9.0","team":null,"id":"\#(id)"}"#)
            }
            if path == "/v1/devices" { return (200, "[]") }
            return (404, #"{"error":"No such API"}"#)
        }
    }
}

/// Runs its block the first time only.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ block: () -> Void) {
        lock.withLock {
            guard !done else { return }
            done = true
            block()
        }
    }
}
