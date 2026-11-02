import Foundation
import Testing

@testable import NXPlayKit

@MainActor @Suite final class RemoteTests {
    private var suites: [String] = []

    deinit {
        suites.forEach(removeTestDefaults)
    }

    private func library() -> Library {
        let suite = testDefaultsName()
        suites.append(suite)
        return Library(defaults: UserDefaults(suiteName: suite)!, isScreenshot: true)
    }

    private func request(_ text: String) -> RemoteRequest? {
        RemoteRequest.parse(Data(text.utf8))
    }

    @Test func aRequestIsReadOnceItsHeadersEnd() throws {
        #expect(request("GET /v1/games HTTP/1.1\r\nHost: mac\r\n") == nil)
        let full = try #require(
            request(
                "POST /v1/games/Metroid%20Dread/install?device=0000-1 HTTP/1.1\r\nAuthorization: Bearer abc\r\n\r\n"
            ))
        #expect(full.method == "POST")
        #expect(full.path == ["v1", "games", "Metroid Dread", "install"])
        #expect(full.query == ["device": "0000-1"])
        #expect(full.bearer == "abc")
        #expect(request("nonsense\r\n\r\n") == nil)
    }

    @Test func theResponseSaysItsLengthAndCloses() {
        let wire = String(decoding: RemoteResponse.error(404, "gone").data, as: UTF8.self)
        #expect(wire.hasPrefix("HTTP/1.1 404 "))
        #expect(wire.contains("Content-Length: 16\r\n"))
        #expect(wire.contains("Connection: close\r\n"))
        #expect(wire.hasSuffix("\r\n\r\n{\"error\":\"gone\"}"))
    }

    @Test func onlyThePairingCodeGetsIn() async throws {
        let library = library()
        let token = library.remoteToken
        #expect(token.wholeMatch(of: /[a-z2-9]{4}-[a-z2-9]{4}-[a-z2-9]{4}/) != nil)

        let wrong = try #require(request("GET /v1/games HTTP/1.1\r\nAuthorization: Bearer nope\r\n\r\n"))
        #expect(await library.respond(to: wrong).status == 401)
        let none = try #require(request("GET /v1/games HTTP/1.1\r\n\r\n"))
        #expect(await library.respond(to: none).status == 401)

        let games = try #require(
            request("GET /v1/games HTTP/1.1\r\nAuthorization: Bearer \(token)\r\n\r\n"))
        #expect(await library.respond(to: games).status == 200)

        library.renewRemoteToken()
        #expect(await library.respond(to: games).status == 401)
    }

    @Test func anInstallNeedsAKnownGame() async throws {
        let library = library()
        let install = try #require(
            request(
                "POST /v1/games/Nothing/install?device=x HTTP/1.1\r\nAuthorization: Bearer \(library.remoteToken)\r\n\r\n"
            ))
        let response = await library.respond(to: install)
        #expect(response.status == 404)
        #expect(String(decoding: response.body, as: UTF8.self).contains("No game Nothing"))
    }

    @Test func theDeviceListsOnlyNXNativeGames() {
        let json = Data(
            """
            {"result": {"apps": [
              {"bundleIdentifier": "org.nxnative.010093801237C000", "name": "Metroid Dread", "version": "2.1"},
              {"bundleIdentifier": "org.nxnative.TEAM1234.0100646009FBE000", "name": "Dead Cells"},
              {"bundleIdentifier": "com.apple.mobilesafari", "name": "Safari"},
              {"bundleIdentifier": "com.example.0123456789abcdef0", "name": "Not one"}
            ]}}
            """.utf8)
        let apps = DeviceCtl.parseApps(json, titleID: nil)
        #expect(apps.map(\.titleID) == ["010093801237C000", "0100646009FBE000"])
    }

    @Test func readsWhenAProfileExpires() throws {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>ExpirationDate</key><date>2027-10-25T15:06:36Z</date></dict></plist>
            """
        // the list sits between the CMS signature's bytes
        let profile = Data([0x30, 0x80, 0x06]) + Data(plist.utf8) + Data([0xA0, 0x00])
        let date = try #require(Provisioning.expiration(ofProfile: profile))
        #expect(date == ISO8601DateFormatter().date(from: "2027-10-25T15:06:36Z"))
        #expect(Provisioning.expiration(ofProfile: Data([0x30, 0x80])) == nil)
    }
}
