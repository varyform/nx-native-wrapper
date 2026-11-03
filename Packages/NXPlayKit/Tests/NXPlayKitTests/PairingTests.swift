import Foundation
import Testing

@testable import NXPlayKit

/// The pairing link and addresses (iOS/Shared/NXPlayPairing.swift, shared with the iOS app), the Mac's addresses and
/// Tailscale, Bonjour's retries, and the code-free `/v1/hello`.
@Suite struct PairingLinkTests {
    static let id = "5F0C1A2B-3C4D-4E5F-8A6B-7C8D9E0F1A2B"
    static let code = "abcd-efgh-jkmn"

    private func link(_ endpoints: [String], name: String = "Jess’s MacBook Pro") throws -> PairingLink {
        PairingLink(
            macID: Self.id, name: name, code: Self.code,
            endpoints: try endpoints.map { try Endpoint.parse($0, defaultPort: nil) })
    }

    @Test func aLinkReadsBackAsItWasMade() throws {
        let made = try link([
            "192.168.1.123:47475", "jesss-macbook-pro-7.local:47475", "[fd12:3456:789a:bcde::7161]:47475",
            "jesss-macbook-pro.tail1234.ts.net:47475", "100.101.12.34:47475", "[fd7a:115c:a1e0::1234:abcd]:47475",
        ])
        let url = try #require(made.url)
        #expect(url.scheme == "nxplay")
        #expect(url.absoluteString.count < NXPlayPairing.maxLinkLength)
        let read = try PairingLink.parse(url.absoluteString)
        #expect(read == made)
        #expect(read.endpoints.map(\.kind) == [.lan, .lan, .lan, .tailscale, .tailscale, .tailscale])
        #expect(read.endpoints[2].isIPv6 && read.endpoints[2].port == 47475)
    }

    @Test func aNameWithSymbolsSurvives() throws {
        let made = try link(["10.0.0.2:47474"], name: "Mac & Co + ? = #1")
        #expect(try PairingLink.parse(try #require(made.url).absoluteString).name == "Mac & Co + ? = #1")
    }

    @Test func theCodeIsReadCaseInsensitively() throws {
        let text = "nxplay://pair?v=1&id=\(Self.id)&n=Mac&c=ABCD-EFGH-JKMN&e=10.0.0.2:47474"
        #expect(try PairingLink.parse(text).code == Self.code)
        #expect(try PairingLink.parse("  NXPLAY://PAIR?v=1&id=\(Self.id)&n=Mac&c=\(Self.code)&e=10.0.0.2:1  ").name == "Mac")
    }

    @Test(arguments: [
        ("https://pair?v=1", PairingError.notAPairingLink),
        ("javascript:alert(1)", .notAPairingLink),
        ("nxplay://other?v=1", .notAPairingLink),
        ("nxplay://user@pair?v=1", .notAPairingLink),
        ("nxplay://pair:80?v=1", .notAPairingLink),
        ("nxplay://pair/x?v=1", .notAPairingLink),
        ("nxplay://pair?v=1#frag", .notAPairingLink),
        ("nxplay://pair?id=\(id)&n=M&c=\(code)&e=10.0.0.2:1", .malformed("no version")),
        ("nxplay://pair?v=2&id=\(id)&n=M&c=\(code)&e=10.0.0.2:1", .newerVersion),
        ("nxplay://pair?v=0&id=\(id)&n=M&c=\(code)&e=10.0.0.2:1", .malformed("no version")),
        ("nxplay://pair?v=1&v=1&id=\(id)&n=M&c=\(code)&e=10.0.0.2:1", .malformed("a repeated field")),
        ("nxplay://pair?v=1&id=\(id)&n=M&c=\(code)&e=10.0.0.2:1&x=1", .malformed("an unknown field")),
        ("nxplay://pair?v=1&id=nope&n=M&c=\(code)&e=10.0.0.2:1", .malformed("no Mac ID")),
        ("nxplay://pair?v=1&id=\(id)&n=&c=\(code)&e=10.0.0.2:1", .malformed("the Mac's name")),
        ("nxplay://pair?v=1&id=\(id)&n=a%0Ab&c=\(code)&e=10.0.0.2:1", .malformed("the Mac's name")),
        ("nxplay://pair?v=1&id=\(id)&n=a%E2%80%AEb&c=\(code)&e=10.0.0.2:1", .malformed("the Mac's name")),
        ("nxplay://pair?v=1&id=\(id)&n=M&c=abcd-efgh-jkm0&e=10.0.0.2:1", .malformed("the pairing code")),
        ("nxplay://pair?v=1&id=\(id)&n=M&c=abcdefghjkmn&e=10.0.0.2:1", .malformed("the pairing code")),
        ("nxplay://pair?v=1&id=\(id)&n=M&c=\(code)", .noAddresses),
        ("nxplay://pair?v=1&id=\(id)&n=M&c=\(code)&e=10.0.0.2", .badPort),
        ("nxplay://pair?v=1&id=\(id)&n=M&c=\(code)&e=10.0.0.2:0", .badPort),
        ("nxplay://pair?v=1&id=\(id)&n=M&c=\(code)&e=10.0.0.2:65536", .badPort),
    ])
    func aBadLinkIsRefused(text: String, error: PairingError) {
        #expect(throws: error) { try PairingLink.parse(text) }
    }

    @Test func linksAreBounded() throws {
        let eight = (1...8).map { "e=10.0.0.\($0):47474" }.joined(separator: "&")
        #expect(try PairingLink.parse("nxplay://pair?v=1&id=\(Self.id)&n=M&c=\(Self.code)&\(eight)").endpoints.count == 8)
        #expect(throws: PairingError.malformed("too many fields")) {
            try PairingLink.parse("nxplay://pair?v=1&id=\(Self.id)&n=M&c=\(Self.code)&\(eight)&e=10.0.0.9:1")
        }
        let long = "nxplay://pair?v=1&id=\(Self.id)&n=M&c=\(Self.code)&e=" + String(repeating: "a", count: 1100) + ".local:1"
        #expect(throws: PairingError.tooLong) { try PairingLink.parse(long) }
        // the link's addresses go through the same checks as typed ones
        #expect(throws: PairingError.self) {
            try PairingLink.parse("nxplay://pair?v=1&id=\(Self.id)&n=M&c=\(Self.code)&e=%5Bfe80::1%5D:47474")
        }
        #expect(throws: PairingError.self) {
            try PairingLink.parse("nxplay://pair?v=1&id=\(Self.id)&n=M&c=\(Self.code)&e=evil.example/x:1")
        }
    }

    @Test func noMessageRepeatsTheCode() {
        let errors: [PairingError] = [
            .notAPairingLink, .tooLong, .newerVersion, .malformed("the pairing code"), .badAddress("x"), .badPort,
            .noAddresses,
        ]
        for error in errors { #expect(!(error.errorDescription ?? "").contains(Self.code)) }
        do {
            _ = try PairingLink.parse("nxplay://pair?v=1&id=\(Self.id)&n=M&c=\(Self.code)&e=10.0.0.2")
        } catch {
            #expect(!error.localizedDescription.contains(Self.code))
        }
    }

    @Test func onlyNXPlayLinksLookLikeLinks() {
        #expect(PairingLink.looksLikeLink(" nxplay://pair?v=1"))
        #expect(!PairingLink.looksLikeLink("https://example.com"))
        #expect(!PairingLink.looksLikeLink("nxplay-0100abc://"))
    }
}

@Suite struct EndpointTests {
    @Test(arguments: [
        ("192.168.1.123", "192.168.1.123", 47474, Endpoint.Kind.lan),
        ("192.168.1.123:47475", "192.168.1.123", 47475, .lan),
        (" http://Jesss-MacBook-Pro-7.local:47475/ ", "jesss-macbook-pro-7.local", 47475, .lan),
        ("jesss-macbook-pro.local.", "jesss-macbook-pro.local", 47474, .lan),
        ("macbook", "macbook", 47474, .lan),
        ("100.101.12.34", "100.101.12.34", 47474, .tailscale),
        ("100.64.0.1:8080", "100.64.0.1", 8080, .tailscale),
        ("jesss-mbp.tail1234.ts.net:47475", "jesss-mbp.tail1234.ts.net", 47475, .tailscale),
        ("[fd7a:115c:a1e0::1234:abcd]:47475", "fd7a:115c:a1e0::1234:abcd", 47475, .tailscale),
        ("FD7A:115C:A1E0:0:0:0:1234:ABCD", "fd7a:115c:a1e0::1234:abcd", 47474, .tailscale),
        ("[fd12:3456:789a:bcde::1]", "fd12:3456:789a:bcde::1", 47474, .lan),
        ("2001:db8::1", "2001:db8::1", 47474, .other),
        ("8.8.8.8:1", "8.8.8.8", 1, .other),
        ("nas.example.com:65535", "nas.example.com", 65535, .other),
    ])
    func addressesAsTyped(text: String, host: String, port: Int, kind: Endpoint.Kind) throws {
        let endpoint = try Endpoint.parse(text, defaultPort: 47474)
        #expect(endpoint.host == host)
        #expect(Int(endpoint.port) == port)
        #expect(endpoint.kind == kind)
    }

    @Test(arguments: [
        "", "   ", "https://mac.local", "ftp://mac.local", "mac.local/path", "mac local", "mac.local:", "mac.local:abc",
        "mac.local:0", "mac.local:65536", "mac.local:+80", "[fd7a::1", "[fd7a::1]x", "[10.0.0.1]:80", "fe80::1",
        "[fe80::1%en0]:47474", "fd7a::1%25en0", "999.1.1.1", "1.2.3", "0.0.0.0", "224.0.0.251", "ff02::fb", "::",
        "-mac.local", "mac-.local", "mac..local", "user@mac.local", "mac.local?x", "mac.local#x", "mac_1.local",
        "ma\u{0441}.local",
    ])
    func badAddressesAreRefused(text: String) {
        #expect(throws: PairingError.self) { try Endpoint.parse(text, defaultPort: 47474) }
    }

    @Test func urlsBracketIPv6AndKeepThePort() throws {
        let v6 = try Endpoint.parse("[fd7a:115c:a1e0::1234:abcd]:47475", defaultPort: nil)
        #expect(v6.display == "[fd7a:115c:a1e0::1234:abcd]:47475")
        let url = try #require(v6.url(path: "v1/info"))
        #expect(url.absoluteString == "http://[fd7a:115c:a1e0::1234:abcd]:47475/v1/info")
        #expect(url.host == "fd7a:115c:a1e0::1234:abcd")
        let v4 = try Endpoint.parse("100.101.12.34:47475", defaultPort: nil)
        let query = try #require(
            v4.url(path: "v1/games/Metroid%20Dread/install", query: [URLQueryItem(name: "device", value: "a b")]))
        #expect(query.absoluteString == "http://100.101.12.34:47475/v1/games/Metroid%20Dread/install?device=a%20b")
        #expect(throws: PairingError.badPort) { try Endpoint.parse("mac.local", defaultPort: nil) }
    }

    @Test func endpointsSurviveCoding() throws {
        let endpoints = try ["[fd7a:115c:a1e0::1]:2", "mac.local:47474"].map { try Endpoint.parse($0, defaultPort: nil) }
        let decoded = try JSONDecoder().decode([Endpoint].self, from: JSONEncoder().encode(endpoints))
        #expect(decoded == endpoints)
    }

    @MainActor @Test func codesAreChecked() {
        #expect(NXPlayPairing.isValidCode("abcd-efgh-jkmn"))
        #expect(NXPlayPairing.isValidCode(NXPlayPairing.normalizedCode("  ABCD-efgh-JKMN\n")))
        #expect(!NXPlayPairing.isValidCode("abcd-efgh-jkm"))
        #expect(!NXPlayPairing.isValidCode("abcd-efgh-jkmn-pqrs"))
        #expect(!NXPlayPairing.isValidCode("abcd-efgh-jkm1"))
        #expect(!NXPlayPairing.isValidCode("abcd efgh jkmn"))
        #expect(NXPlayPairing.isValidCode(Library.newRemoteToken()))
    }
}

@Suite struct MacAddressTests {
    typealias Address = MacAddresses.InterfaceAddress

    @Test func reachableAddressesComeInTheOrderToTry() {
        let addresses: [Address] = [
            .init(interface: "en0", host: "fd12:3456:789a:bcde:87e:1234:5678:9abc"),
            .init(interface: "en0", host: "fe80::1234:5678:9abc:def0"),
            .init(interface: "en0", host: "192.168.1.123"),
            .init(interface: "en0", host: "2001:db8::10"),
            .init(interface: "en0", host: "2001:db8::11"),
            .init(interface: "utun5", host: "100.101.12.34"),
            .init(interface: "utun5", host: "fd7a:115c:a1e0::1234:abcd"),
            .init(interface: "utun2", host: "10.8.0.5"),
            .init(interface: "awdl0", host: "fe80::99"),
            .init(interface: "ap1", host: "192.168.2.1"),
            .init(interface: "bridge0", host: "169.254.10.10"),
            .init(interface: "en7", host: "10.0.0.20"),
        ]
        let tailscale = TailscaleStatus(
            state: .running, dnsName: "jesss-macbook-pro.tail1234.ts.net",
            addresses: ["100.101.12.34", "fd7a:115c:a1e0::1234:abcd"])
        let endpoints = MacAddresses.endpoints(
            from: addresses, localHostName: "Jesss-MacBook-Pro-7", tailscale: tailscale, port: 47475)
        #expect(endpoints.map(\.display) == [
            "192.168.1.123:47475", "10.0.0.20:47475", "jesss-macbook-pro-7.local:47475",
            "[fd12:3456:789a:bcde:87e:1234:5678:9abc]:47475", "[2001:db8::10]:47475",
            "jesss-macbook-pro.tail1234.ts.net:47475", "100.101.12.34:47475", "[fd7a:115c:a1e0::1234:abcd]:47475",
        ])
    }

    @Test func aStoppedTailscaleAddsNoName() {
        let endpoints = MacAddresses.endpoints(
            from: [.init(interface: "en0", host: "192.168.1.5")], localHostName: nil,
            tailscale: TailscaleStatus(state: .installed("Stopped"), dnsName: "mac.tail1.ts.net"), port: 47474)
        #expect(endpoints.map(\.display) == ["192.168.1.5:47474"])
    }

    @Test func theRealInterfacesGiveUsableAddresses() {
        // whatever this Mac has: every one parses back, none is loopback or link-local
        let endpoints = MacAddresses.endpoints(
            from: MacAddresses.interfaceAddresses(), localHostName: nil, tailscale: .notInstalled, port: 47474)
        for endpoint in endpoints {
            #expect((try? Endpoint.parse(endpoint.display, defaultPort: nil)) == endpoint)
            #expect(!endpoint.host.hasPrefix("127.") && endpoint.host != "::1" && !endpoint.host.hasPrefix("fe80"))
        }
    }
}

@Suite struct TailscaleStatusTests {
    @Test func aRunningTailscaleGivesItsNameAndAddresses() throws {
        let json = Data(
            """
            {"Version": "1.102.4", "BackendState": "Running", "MagicDNSSuffix": "tail1234.ts.net",
             "CurrentTailnet": {"Name": "someone@example.com", "MagicDNSSuffix": "tail1234.ts.net", "MagicDNSEnabled": true},
             "Self": {"DNSName": "Jesss-MacBook-Pro.tail1234.ts.net.", "HostName": "Jess’s MacBook Pro",
                      "TailscaleIPs": ["100.101.12.34", "fd7a:115c:a1e0::1234:abcd", "8.8.8.8"]},
             "Peer": {"x": {"DNSName": "phone.tail1234.ts.net.", "TailscaleIPs": ["100.1.1.1"]}}}
            """.utf8)
        let status = try #require(TailscaleStatus.parse(json))
        #expect(status.state == .running)
        #expect(status.dnsName == "jesss-macbook-pro.tail1234.ts.net")
        #expect(status.addresses == ["100.101.12.34", "fd7a:115c:a1e0::1234:abcd"])
    }

    @Test func otherStatesAndMagicDNSOff() throws {
        #expect(TailscaleStatus.parse(Data(#"{"BackendState": "Stopped"}"#.utf8))?.state == .installed("Stopped"))
        #expect(TailscaleStatus.parse(Data(#"{"BackendState": "NeedsLogin", "Self": {}}"#.utf8))?.isRunning == false)
        let off = try #require(
            TailscaleStatus.parse(
                Data(
                    #"{"BackendState": "Running", "CurrentTailnet": {"MagicDNSEnabled": false}, "Self": {"DNSName": "mac.tail1.ts.net.", "TailscaleIPs": ["100.90.1.2"]}}"#
                        .utf8)))
        #expect(off.dnsName == nil)
        #expect(off.addresses == ["100.90.1.2"])
        #expect(TailscaleStatus.parse(Data("not json".utf8)) == nil)
        #expect(TailscaleStatus.parse(Data("[]".utf8)) == nil)
        // a name outside ts.net isn't taken as MagicDNS's
        let odd = TailscaleStatus.parse(
            Data(#"{"BackendState": "Running", "Self": {"DNSName": "evil.example.com.", "TailscaleIPs": []}}"#.utf8))
        #expect(odd?.dnsName == nil)
    }

    /// `status --json --peers=false` as the Tailscale Mac app's binary (1.102.4) printed it on the Mac where Settings ›
    /// Devices said "no MagicDNS name", with its names, addresses, keys and IDs replaced.
    static let macAppStatus = #"""
        {
          "Version": "1.102.4-t3caf7d9e7-g084ee3b64",
          "TUN": true,
          "BackendState": "Running",
          "HaveNodeKey": true,
          "AuthURL": "",
          "TailscaleIPs": [
            "100.64.0.10",
            "fd7a:115c:a1e0::a"
          ],
          "Self": {
            "ID": "nTESTNODE1CNTRL",
            "NodeID": 1,
            "PublicKey": "nodekey:0000000000000000000000000000000000000000000000000000000000000000",
            "HostName": "NX Play Mac",
            "DNSName": "nxplay-mac.tail0000.ts.net.",
            "OS": "macOS",
            "UserID": 1,
            "TailscaleIPs": [
              "100.64.0.10",
              "fd7a:115c:a1e0::a"
            ],
            "AllowedIPs": [
              "100.64.0.10/32",
              "fd7a:115c:a1e0::a/128"
            ],
            "Addrs": [
              "203.0.113.10:41641"
            ],
            "CurAddr": "",
            "Relay": "syd",
            "PeerRelay": "",
            "RxBytes": 0,
            "TxBytes": 0,
            "Created": "0001-01-01T00:00:00Z",
            "LastWrite": "0001-01-01T00:00:00Z",
            "LastSeen": "0001-01-01T00:00:00Z",
            "LastHandshake": "0001-01-01T00:00:00Z",
            "Online": true,
            "ExitNode": false,
            "ExitNodeOption": false,
            "Active": false,
            "PeerAPIURL": [
              "http://100.64.0.10:12345",
              "http://[fd7a:115c:a1e0::a]:12345"
            ],
            "TaildropTarget": 0,
            "NoFileSharingReason": "",
            "Capabilities": [],
            "CapMap": {},
            "InNetworkMap": true,
            "InMagicSock": false,
            "InEngine": false
          },
          "Health": [
            "(redacted health message)"
          ],
          "MagicDNSSuffix": "tail0000.ts.net",
          "CurrentTailnet": {
            "Name": "user@example.com",
            "MagicDNSSuffix": "tail0000.ts.net",
            "MagicDNSEnabled": true
          },
          "CertDomains": [
            "nxplay-mac.tail0000.ts.net"
          ],
          "ExtraRecords": null,
          "Peer": null,
          "User": {
            "1": {
              "ID": 1,
              "LoginName": "user@example.com",
              "DisplayName": "User",
              "ProfilePicURL": ""
            }
          },
          "ClientVersion": null
        }
        """#

    @Test func theMacAppsStatusGivesItsMagicDNSName() throws {
        let status = try #require(TailscaleStatus.parse(Data(Self.macAppStatus.utf8)))
        #expect(status.state == .running)
        #expect(status.dnsName == "nxplay-mac.tail0000.ts.net")
        #expect(status.addresses == ["100.64.0.10", "fd7a:115c:a1e0::a"])
    }

    /// Like the Mac app's binary: the CLI only when told so, otherwise an app that never answers. (The real one also
    /// takes a TERM, but /bin/sh sets one itself, so the stand-in can't check it.)
    @Test func theMacAppsBinaryIsAskedAsTheCLI() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tailscale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let status = folder.appending(path: "status.json")
        try Data(Self.macAppStatus.utf8).write(to: status)
        let command = folder.appending(path: "Tailscale")
        try """
            #!/bin/sh
            [ "$TAILSCALE_BE_CLI" = 1 ] || exec /bin/sleep 30
            [ "$*" = "status --json --peers=false" ] || exit 2
            exec /bin/cat '\(status.path)'

            """.write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)

        let detected = await TailscaleStatus.detect(
            interfaceAddresses: [], commands: [command.path], timeout: .seconds(5))
        #expect(detected.state == .running)
        #expect(detected.dnsName == "nxplay-mac.tail0000.ts.net")
        #expect(detected.addresses == ["100.64.0.10", "fd7a:115c:a1e0::a"])
    }
}

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
        for path in ["v1/info", "v1/games", "v1/devices", "v1/sources", "v1/downloads", "v1/hello/x"] {
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
