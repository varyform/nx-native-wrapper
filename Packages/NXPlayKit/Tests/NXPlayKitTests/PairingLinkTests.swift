import Foundation
import Testing

@testable import NXPlayKit

/// The pairing link and addresses (iOS/Shared, shared with the iOS app).
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
