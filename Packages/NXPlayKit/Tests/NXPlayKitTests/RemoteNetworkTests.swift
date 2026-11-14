import Foundation
import Testing

@testable import NXPlayKit

/// The Mac's addresses and Tailscale, for Settings › Devices and the pairing QR code.
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
