import CryptoKit
import Foundation
import Testing

@testable import NXPlayKit

/// The control API (Control/) against a real loopback server: auth and the browser guards, request limits, the
/// commands on a synthetic games folder, settings, jobs following the library's own work (a throwaway script stands in
/// for nxplay; a synthetic HTTP server for a catalog), events, MCP, and the stdio adapter. No real game, key, device,
/// network setting or NX Play setting is touched: each test has its own defaults domain and folders.
@MainActor @Suite(.serialized) final class ControlTests {
    private var suites: [String] = []
    private var folders: [URL] = []
    private var libraries: [Library] = []

    isolated deinit {
        libraries.forEach { $0.stopControl() }
        suites.forEach(removeTestDefaults)
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    // MARK: - Fixtures

    private func folder(_ name: String = "") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-control-tests/\(UUID().uuidString)\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url.resolvingSymlinksInPath()
    }

    private func defaults() -> (UserDefaults, String) {
        let suite = testDefaultsName()
        suites.append(suite)
        return (UserDefaults(suiteName: suite)!, suite)
    }

    /// A games folder with synthetic games: folder name → files (made-up bytes).
    private func gamesFolder(_ games: [String: [String]]) throws -> URL {
        let root = try folder("-games")
        for (name, files) in games {
            let game = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
            for file in files {
                let url = game.appending(path: file)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("synthetic \(file)".utf8).write(to: url)
            }
        }
        return root
    }

    private struct Running {
        let library: Library
        let api: ControlAPI
        let port: UInt16
        let token: String
        let folder: URL
        let defaults: UserDefaults
    }

    private func start(root: URL? = nil, defaults given: UserDefaults? = nil) async throws -> Running {
        let defaults = given ?? self.defaults().0
        let library = Library(defaults: defaults, isScreenshot: true)
        libraries.append(library)
        if let root { library.root = root }
        let dir = try folder("-control").appending(path: "control-api", directoryHint: .isDirectory)
        let api = library.startControl(endpoint: ControlEndpointFile(folder: dir))
        try await wait("the control API to listen") { api.port != nil }
        return Running(library: library, api: api, port: api.port ?? 0, token: api.tokenForTests, folder: dir, defaults: defaults)
    }

    private func wait(_ what: String, seconds: Double = 15, until condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !condition() {
            guard Date.now < deadline else {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - A raw HTTP client (so tests can send what a browser or an attacker would)

    struct Reply {
        let status: Int
        let head: String
        let body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        var result: Any? { json["result"] }
        var errorCode: String? { (json["error"] as? [String: Any])?["code"] as? String }
    }

    nonisolated static func send(_ host: String, _ port: UInt16, _ bytes: Data) async -> Reply? {
        await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var timeout = timeval(tv_sec: 20, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            inet_pton(AF_INET, host, &address.sin_addr)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { return nil }
            _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
            let status = Int(head.split(separator: " ").dropFirst().first ?? "") ?? 0
            return Reply(status: status, head: head, body: Data(data[end.upperBound...]))
        }.value
    }

    private func call(
        _ running: Running, _ method: String, _ path: String, json: Any? = nil, headers: [String: String] = [:],
        token: String? = nil, host: String? = nil
    ) async -> Reply {
        var body = Data()
        if let json { body = try! JSONSerialization.data(withJSONObject: json) }
        var lines = ["\(method) \(path) HTTP/1.1", "Host: \(host ?? "127.0.0.1:\(running.port)")"]
        if let token = token ?? Optional(running.token), !token.isEmpty { lines.append("Authorization: Bearer \(token)") }
        if json != nil { lines.append("Content-Type: application/json") }
        lines.append("Content-Length: \(body.count)")
        for (name, value) in headers { lines.append("\(name): \(value)") }
        let request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
        return await Self.send("127.0.0.1", running.port, request) ?? Reply(status: 0, head: "", body: Data())
    }

    private func invoke(_ running: Running, _ command: String, _ args: [String: Any] = [:], wait: String? = nil) async -> Reply {
        var body: [String: Any] = ["command": command, "args": args]
        if let wait { body["wait"] = wait }
        return await call(running, "POST", "/v1/invoke", json: body)
    }

    // MARK: - Credential, descriptor, switch

    @Test func theDescriptorIsPrivateAndGoesWithTheAPI() async throws {
        let running = try await start()
        let file = running.folder.appending(path: "endpoint.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: running.folder.path)
        #expect((folderAttributes[.posixPermissions] as? Int) == 0o700)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["schema"] as? String == "nxplay-control-api/1")
        #expect(json["url"] as? String == "http://127.0.0.1:\(running.port)")
        let token = try #require(json["token"] as? String)
        #expect(token.count == 64 && token.allSatisfy(\.isHexDigit))
        #expect(token == running.token)
        #expect(token != running.library.remoteToken)
        running.library.stopControl()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func tokensAreFreshAndComparedWhole() {
        let a = ControlCredential.newToken()
        let b = ControlCredential.newToken()
        #expect(a != b && a.count == 64)
        #expect(ControlCredential.matches(a, a))
        #expect(!ControlCredential.matches(String(a.dropLast()) + "0", a) || a.last == "0")
        #expect(!ControlCredential.matches(String(a.prefix(63)), a))
        #expect(!ControlCredential.matches(nil, a))
        #expect(!ControlCredential.matches("", ""))
    }

    @Test func theAPIIsOffUnlessAskedForAndZeroWins() throws {
        let missing = try folder().appending(path: "enabled")
        #expect(!ControlEndpointFile.isEnabled(environment: [:], arguments: [], enabledFile: missing))
        #expect(ControlEndpointFile.isEnabled(environment: ["NXPLAY_CONTROL_API": "1"], arguments: [], enabledFile: missing))
        #expect(ControlEndpointFile.isEnabled(environment: [:], arguments: ["--control-api"], enabledFile: missing))
        let present = try folder().appending(path: "enabled")
        try Data().write(to: present)
        #expect(ControlEndpointFile.isEnabled(environment: [:], arguments: [], enabledFile: present))
        #expect(!ControlEndpointFile.isEnabled(environment: ["NXPLAY_CONTROL_API": "0"], arguments: ["--control-api"], enabledFile: present))
        #expect(!ControlEndpointFile.isEnabled(environment: ["NXPLAY_CONTROL_API": "off"], arguments: [], enabledFile: present))
        #expect(ControlEndpointFile.port(environment: ["NXPLAY_CONTROL_PORT": "47900"]) == 47900)
        #expect(ControlEndpointFile.port(environment: ["NXPLAY_CONTROL_PORT": "80"]) == 0)
        // screenshot mode never starts it, whatever asks
        let library = Library(defaults: defaults().0, isScreenshot: true)
        library.applyControl(environment: ["NXPLAY_CONTROL_API": "1"], arguments: ["--control-api"])
        #expect(library.controlAPI == nil)
    }

    @Test func aFolderOthersCanEnterIsMadePrivateAndALinkIsRefused() throws {
        let base = try folder()
        let open = base.appending(path: "open", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try ControlEndpointFile(folder: open).prepareFolder()
        #expect((try FileManager.default.attributesOfItem(atPath: open.path)[.posixPermissions] as? Int) == 0o700)
        let link = base.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: open)
        #expect(throws: ControlEndpointFile.Failure.self) { try ControlEndpointFile(folder: link).prepareFolder() }
    }

    // MARK: - Guards

    @Test func everyRequestNeedsTheControlTokenNotThePairingCode() async throws {
        let running = try await start()
        #expect(await call(running, "GET", "/v1/status").status == 200)
        let none = await call(running, "GET", "/v1/status", token: "")
        #expect(none.status == 401 && none.errorCode == "unauthorized")
        #expect(await call(running, "GET", "/v1/status", token: String(repeating: "0", count: 64)).status == 401)
        // the iOS app's pairing code opens nothing here
        #expect(await call(running, "GET", "/v1/status", token: running.library.remoteToken).status == 401)
        #expect(await call(running, "POST", "/mcp", json: ["jsonrpc": "2.0", "id": 1, "method": "ping"], token: running.library.remoteToken).status == 401)
        // and the control token opens nothing in the iOS app's API
        let remote = await running.library.respond(
            to: RemoteRequest(method: "GET", path: ["v1", "games"], query: [:], headers: ["authorization": "Bearer \(running.token)"]))
        #expect(remote.status == 401)
        // no answer echoes the token
        let status = await call(running, "GET", "/v1/status")
        #expect(!String(decoding: status.body, as: UTF8.self).contains(running.token))
    }

    @Test func browsersAndRebindingAreRefused() async throws {
        let running = try await start()
        let rebound = await call(running, "GET", "/v1/status", host: "evil.example:\(running.port)")
        #expect(rebound.status == 403 && rebound.errorCode == "bad_host")
        #expect(await call(running, "GET", "/v1/status", host: "127.0.0.1:1").status == 403)
        #expect(await call(running, "GET", "/v1/status", host: "localhost:\(running.port)").status == 200)
        let origin = await call(running, "GET", "/v1/status", headers: ["Origin": "http://127.0.0.1:\(running.port)"])
        #expect(origin.status == 403 && origin.errorCode == "browser_request_forbidden")
        #expect(await call(running, "GET", "/v1/status", headers: ["Sec-Fetch-Site": "same-origin"]).status == 403)
        #expect(await call(running, "OPTIONS", "/v1/status").status == 405)
        let text = await call(running, "POST", "/v1/invoke", headers: ["Content-Type": "text/plain"])
        #expect(text.status == 415 || text.status == 400)
        // no CORS header, never cached, never a redirect
        let ok = await call(running, "GET", "/v1/status")
        #expect(!ok.head.lowercased().contains("access-control"))
        #expect(ok.head.contains("Cache-Control: no-store"))
        #expect(!ok.head.lowercased().contains("location:"))
    }

    @Test func requestsAreBounded() async throws {
        let running = try await start()
        let auth = "Authorization: Bearer \(running.token)\r\nHost: 127.0.0.1:\(running.port)\r\n"
        let chunked = Data("POST /v1/invoke HTTP/1.1\r\n\(auth)Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8)
        #expect(await Self.send("127.0.0.1", running.port, chunked)?.status == 400)
        let twice = Data("POST /v1/invoke HTTP/1.1\r\n\(auth)Content-Type: application/json\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}".utf8)
        #expect(await Self.send("127.0.0.1", running.port, twice)?.status == 400)
        let big = Data("POST /v1/invoke HTTP/1.1\r\n\(auth)Content-Type: application/json\r\nContent-Length: \(2 * 1024 * 1024)\r\n\r\n".utf8)
        #expect(await Self.send("127.0.0.1", running.port, big)?.status == 413)
        let head = Data(("GET /v1/status HTTP/1.1\r\n\(auth)X-Pad: " + String(repeating: "a", count: 20_000) + "\r\n\r\n").utf8)
        #expect(await Self.send("127.0.0.1", running.port, head)?.status == 431)
        let proxy = Data("GET http://127.0.0.1:\(running.port)/v1/status HTTP/1.1\r\n\(auth)\r\n".utf8)
        #expect(await Self.send("127.0.0.1", running.port, proxy)?.status == 400)
        let badJSON = Data("POST /v1/invoke HTTP/1.1\r\n\(auth)Content-Type: application/json\r\nContent-Length: 3\r\n\r\n{x}".utf8)
        let reply = await Self.send("127.0.0.1", running.port, badJSON)
        #expect(reply?.status == 400 && reply?.errorCode == "invalid_json")
    }

    @Test func itListensOnLoopbackOnly() async throws {
        let running = try await start()
        let others = MacAddresses.interfaceAddresses().map(\.host).filter { !$0.contains(":") && !$0.hasPrefix("127.") }
        for address in others {
            let reply = await Self.send(address, running.port, Data("GET /v1/status HTTP/1.1\r\n\r\n".utf8))
            #expect(reply == nil, "answered on \(address)")
        }
    }

    @Test func parsingWaitsForTheWholeBody() {
        let partial = Data("POST /v1/invoke HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\"".utf8)
        #expect(ControlHTTP.parse(partial) == .incomplete)
        let whole = Data("POST /v1/invoke?x=1 HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8)
        guard case .request(let box) = ControlHTTP.parse(whole) else {
            Issue.record("not parsed")
            return
        }
        #expect(box.request.path == ["v1", "invoke"] && box.request.query["x"] == "1" && box.request.body == Data("{}".utf8))
    }

    // MARK: - Commands on the library

    @Test func gamesAreTheLibrarysGames() async throws {
        let root = try gamesFolder([
            "Alpha [0100000000010000]": ["Alpha [0100000000010000][v0].nsp"],
            "Beta": ["Beta.xci"],
        ])
        let running = try await start(root: root)
        let list = await invoke(running, "games.list")
        #expect(list.status == 200)
        let games = try #require(list.result as? [[String: Any]])
        #expect(Set(games.compactMap { $0["id"] as? String }) == ["Alpha [0100000000010000]", "Beta"])
        #expect(games.allSatisfy { ($0["actions"] as? [String])?.contains("extract") == true })
        let one = await invoke(running, "games.get", ["game": "Beta"])
        #expect((one.result as? [String: Any])?["state"] as? String == "notExtracted")
        let missing = await invoke(running, "games.get", ["game": "Nope"])
        #expect(missing.status == 404)
        let typo = await invoke(running, "games.get", ["gmae": "Beta"])
        #expect(typo.status == 400 && typo.errorCode == "invalid_args")
        let wrongType = await invoke(running, "games.get", ["game": 3])
        #expect(wrongType.status == 400)
    }

    @Test func aFolderIsCheckedBeforeItIsChosen() async throws {
        let root = try gamesFolder(["Gamma": ["Gamma.nsp"]])
        let running = try await start()
        let inspected = await invoke(running, "library.inspect_folder", ["path": root.path])
        #expect(((inspected.result as? [String: Any])?["games"] as? [Any])?.count == 1)
        #expect(running.library.root == nil)  // looking doesn't choose
        #expect(await invoke(running, "library.inspect_folder", ["path": "relative/path"]).status == 400)
        #expect(await invoke(running, "library.inspect_folder", ["path": root.appending(path: "Gamma/Gamma.nsp").path]).status == 400)
        let chosen = await invoke(running, "library.set_folder", ["path": root.path])
        #expect(chosen.status == 200)
        #expect(running.library.root?.standardizedFileURL.path == root.standardizedFileURL.path)
        #expect(running.library.games.count == 1)
        // saved, as Choose Games Folder… saves it
        #expect(running.defaults.string(forKey: "gamesRoot") == root.standardizedFileURL.path)
    }

    @Test func aRefusedBuildLeavesNoAlertInTheWindow() async throws {
        let root = try gamesFolder(["Delta": ["Delta.nsp"]])
        let running = try await start(root: root)
        running.library.nxnativePath = try folder("-no-nxnative").path
        let reply = await invoke(running, "games.extract", ["game": "Delta"])
        #expect(reply.status == 422 && reply.errorCode == "command_failed")
        #expect(running.library.problem == nil)
        #expect(running.library.jobs.isEmpty)
        // a game that can't be extracted is refused before nxplay is asked
        #expect(await invoke(running, "games.rebuild", ["game": "Delta"]).status == 409)
    }

    // MARK: - Settings

    @Test func settingsChangeTogetherOrNotAtAllAndAreSaved() async throws {
        let (defaults, _) = defaults()
        let running = try await start(defaults: defaults)
        let changed = await invoke(running, "settings.update", ["patch": ["viewStyle": "list", "allowOtherMetal": true, "controllerPlayers": "merged"]])
        #expect(changed.status == 200)
        #expect(running.library.viewStyle == .list && running.library.allowOtherMetal && running.library.controllerPlayers == .merged)
        // one bad key refuses the whole patch
        let refused = await invoke(running, "settings.update", ["patch": ["viewStyle": "grid", "updateBeforePlay": "sometimes"]])
        #expect(refused.status == 400)
        #expect(running.library.viewStyle == .list)
        // a patch every key of which has the right type, one of which can't be applied: still nothing changes
        let semantic = await invoke(running, "settings.update", ["patch": ["viewStyle": "grid", "cloudSaves": "/no/such/folder"]])
        #expect(semantic.status == 400)
        #expect(running.library.viewStyle == .list)
        // the library's own check, for a caller that skips the API's schema
        #expect(throws: ControlError.self) { try running.library.controlPatchSettings(["viewStyle": "grid", "updateBeforePlay": "x"]) }
        #expect(throws: ControlError.self) { try running.library.controlPatchSettings(["viewStyle": "grid", "remoteEnabled": true]) }
        #expect(running.library.viewStyle == .list && !running.library.remoteEnabled)
        // keys the API doesn't change
        for patch: [String: Any] in [["nxnativePath": "/tmp"], ["keysPath": "/tmp/k"], ["remoteEnabled": true], ["remoteToken": "x"]] {
            #expect(await invoke(running, "settings.update", ["patch": patch]).status == 400)
        }
        #expect(await invoke(running, "settings.update", ["patch": ["globalChoices": ["DM_NOT_A_SETTING": "1"]]]).status == 400)
        #expect(await invoke(running, "settings.update", ["patch": ["globalChoices": ["DM_FULLSCREEN": "7"]]]).status == 400)
        #expect(await invoke(running, "settings.update", ["patch": ["cloudSaves": "/no/such/folder"]]).status == 400)
        #expect(await invoke(running, "settings.update", ["patch": ["teamID": "NOTATEAM"]]).status == 400)
        // saved where the Settings window saves them
        let next = Library(defaults: defaults, isScreenshot: true)
        #expect(next.viewStyle == .list && next.allowOtherMetal && next.controllerPlayers == .merged)
    }

    @Test func concurrentPatchesAndTheWindowsChangesAreAllKept() async throws {
        let running = try await start()
        // the window changes one value while calls change others at the same time
        running.library.showsLog = true
        let tasks = [
            Task { await self.invoke(running, "settings.update", ["patch": ["globalChoices": ["DM_FULLSCREEN": "1"]]]) },
            Task { await self.invoke(running, "settings.update", ["patch": ["globalChoices": ["DM_METAL_HUD": "1"]]]) },
            Task { await self.invoke(running, "settings.update", ["patch": ["viewStyle": "list"]]) },
            Task { await self.call(running, "POST", "/v1/settings", json: ["patch": ["updateBeforePlay": "current"]]) },
        ]
        var replies: [Reply] = []
        for task in tasks { replies.append(await task.value) }
        #expect(replies.allSatisfy { $0.status == 200 })
        let library = running.library
        #expect(library.globalChoices["DM_FULLSCREEN"] == "1" && library.globalChoices["DM_METAL_HUD"] == "1")
        #expect(library.viewStyle == .list && library.updateBeforePlay == .current && library.showsLog)
        // null takes one back to the games' default, leaving the other
        #expect(await invoke(running, "settings.update", ["patch": ["globalChoices": ["DM_FULLSCREEN": NSNull()]]]).status == 200)
        #expect(library.globalChoices["DM_FULLSCREEN"] == nil && library.globalChoices["DM_METAL_HUD"] == "1")
    }

    @Test func noSecretIsAnsweredWith() async throws {
        let running = try await start()
        let code = running.library.remoteToken
        for command in ["settings.get", "companion.status", "library.status", "ui.state"] {
            let reply = await invoke(running, command)
            #expect(reply.status == 200)
            let text = String(decoding: reply.body, as: UTF8.self)
            #expect(!text.contains(code), "\(command) shows the pairing code")
            #expect(!text.contains(running.token), "\(command) shows the token")
        }
        let jobs = await call(running, "GET", "/v1/jobs")
        #expect(!String(decoding: jobs.body, as: UTF8.self).contains(code))
        #expect(ControlRedaction.redact(["token": "s3cret", "nested": ["password": "p"], "game": "x"]) as? NSDictionary
            == ["token": "***", "nested": ["password": "***"], "game": "x"] as NSDictionary)
    }

    @Test func settingsChangesReachTheWindowsStateAndTheEvents() async throws {
        let running = try await start()
        let before = running.api.hub.lastSeq
        #expect(await invoke(running, "settings.update", ["patch": ["viewStyle": "list"]]).status == 200)
        let events = await call(running, "GET", "/v1/events?after=\(before)&names=settings&wait_ms=3000")
        let list = try #require((events.result as? [String: Any])?["events"] as? [[String: Any]])
        #expect(list.contains { (($0["data"] as? [String: Any])?["changed"] as? [String])?.contains("viewStyle") == true })
        // a change the window makes is an event too
        let mark = running.api.hub.lastSeq
        running.library.showsLog.toggle()
        let window = await call(running, "GET", "/v1/events?after=\(mark)&names=settings&wait_ms=3000")
        #expect(((window.result as? [String: Any])?["events"] as? [Any])?.isEmpty == false)
    }

    // MARK: - Jobs following the library's own work

    /// A stand-in for nxplay: a script that sleeps (or exits) and ignores nothing.
    private func script(_ body: String) throws -> URL {
        let url = try folder("-script").appending(path: "fake-nxplay")
        try Data("#!/bin/bash\n\(body)\n".utf8).write(to: url)
        return url
    }

    private func fakeRun(_ library: Library, game: Game, body: String, kind: Job.Kind = .extract) throws -> Job {
        let job = Job(kind: kind, game: game, command: NXPlayCommand(script: try script(body), arguments: [], environment: [:]))
        job.stopGrace = 0.2
        job.onFinish = { [weak library] in library?.finished($0) }
        library.jobs[game.id] = job
        job.start()
        return job
    }

    @Test func aJobFollowsTheBuildAndItsCancelIsHonest() async throws {
        let root = try gamesFolder(["Echo": ["Echo.nsp"]])
        let running = try await start(root: root)
        let game = try #require(running.library.games.first)
        let run = try fakeRun(running.library, game: game, body: "echo working; sleep 30")
        let hub = running.api.hub
        let job = hub.newJob(command: "games.extract", args: ["game": "Echo"])
        hub.answered(job, .build(run, [:]))
        #expect(hub.state(job) == .running)
        let cancel = await call(running, "POST", "/v1/jobs/\(job.id)/cancel", json: [String: Any]())
        #expect(cancel.status == 200)
        // cancelling until the process has really ended, then cancelled: never reported early
        #expect(hub.state(job) == .cancelling || hub.state(job) == .cancelled)
        let waited = await call(running, "GET", "/v1/jobs/\(job.id)?wait_ms=10000")
        #expect((waited.result as? [String: Any])?["state"] as? String == "cancelled")
        #expect(run.status == .cancelled)
        // an ended job can't be cancelled again, and stays as it ended
        let again = await call(running, "POST", "/v1/jobs/\(job.id)/cancel", json: [String: Any]())
        #expect(again.status == 409 && again.errorCode == "already_finished")
    }

    @Test func aCancelIsNeverReportedBeforeTheProcessHasEnded() async throws {
        let root = try gamesFolder(["Echo2": ["Echo2.nsp"]])
        let running = try await start(root: root)
        let game = try #require(running.library.games.first)
        // ignores SIGINT and SIGTERM: only the SIGKILL that follows stops it, a while later
        let run = try fakeRun(running.library, game: game, body: "trap '' INT TERM; echo ready; while true; do sleep 0.1; done")
        run.stopGrace = 0.6
        // the trap is set before anything is sent
        try await wait("the script to be ready") { run.log.lines.contains { $0.text == "ready" } }
        let hub = running.api.hub
        let job = hub.newJob(command: "games.extract", args: [:])
        hub.answered(job, .build(run, [:]))
        let reply = await call(running, "POST", "/v1/jobs/\(job.id)/cancel", json: [String: Any]())
        #expect(reply.json["pending"] as? Bool == true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(run.status == .running)
        let during = await call(running, "GET", "/v1/jobs/\(job.id)")
        #expect((during.result as? [String: Any])?["state"] as? String == "cancelling")
        let after = await call(running, "GET", "/v1/jobs/\(job.id)?wait_ms=10000")
        #expect((after.result as? [String: Any])?["state"] as? String == "cancelled")
        #expect(run.status == .cancelled)
    }

    @Test func aWorkThatFinishesDespiteACancelSaysSo() async throws {
        let root = try gamesFolder(["Foxtrot": ["Foxtrot.nsp"]])
        let running = try await start(root: root)
        let game = try #require(running.library.games.first)
        // traps the stop signals and finishes its work anyway
        let run = try fakeRun(running.library, game: game, body: "trap '' INT TERM; sleep 0.5; exit 0")
        let hub = running.api.hub
        let job = hub.newJob(command: "games.rebuild", args: [:])
        hub.answered(job, .build(run, [:]))
        _ = try? hub.cancel(job)
        try await wait("the run to end") { !run.status.isActive }
        hub.updateAll()
        // Job reports a cancel it asked for as cancelled; the API reports what the library says, nothing more
        #expect(hub.state(job).rawValue == "\(run.status)")
    }

    @Test func aQueuedBuildCancelsAtOnceAndTheQueueMovesOn() async throws {
        let root = try gamesFolder(["Golf": ["Golf.nsp"]])
        let running = try await start(root: root)
        let game = try #require(running.library.games.first)
        let queued = Job(kind: .extract, game: game, command: NXPlayCommand(script: try script("exit 0"), arguments: [], environment: [:]))
        queued.onFinish = { [weak library = running.library] in library?.finished($0) }
        running.library.jobs[game.id] = queued
        let hub = running.api.hub
        let job = hub.newJob(command: "games.extract", args: [:])
        hub.answered(job, .build(queued, [:]))
        #expect(hub.state(job) == .queued)
        let stop = await invoke(running, "games.stop", ["game": game.folder.lastPathComponent])
        #expect(stop.status == 200)
        #expect(queued.status == .cancelled)
        hub.updateAll()
        #expect(hub.state(job) == .cancelled)
        #expect(await invoke(running, "games.stop", ["game": game.folder.lastPathComponent]).status == 409)
    }

    @Test func buildProgressIsAnEvent() async throws {
        let root = try gamesFolder(["Hotel": ["Hotel.nsp"]])
        let running = try await start(root: root)
        let game = try #require(running.library.games.first)
        let mark = running.api.hub.lastSeq
        let run = try fakeRun(running.library, game: game, body: "exit 3")
        try await wait("the run to fail") { !run.status.isActive }
        let events = await call(running, "GET", "/v1/events?after=\(mark)&names=build&wait_ms=3000")
        let list = try #require((events.result as? [String: Any])?["events"] as? [[String: Any]])
        let data = list.compactMap { $0["data"] as? [String: Any] }
        #expect(data.contains { $0["game"] as? String == "Hotel" && $0["status"] as? String == "failed" && $0["exitCode"] as? Int == 3 })
    }

    // MARK: - Downloads through a synthetic catalog

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func aDownloadIsAJobItsCancelStopsItAndARetryIsANewJob() async throws {
        let server = try TestHTTPServer()
        let body = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        server.route("/files/Slow.nsp", .init(body: body, chunk: 16 * 1024, delay: 0.05))
        let catalog: [String: Any] = [
            "nxplayCatalog": 1, "name": "Synthetic",
            "entries": [[
                "id": "slow", "name": "Slow Game", "titleID": "0100000000010000", "version": "1.0",
                "packages": [["kind": "base", "filename": "Slow.nsp", "url": "files/Slow.nsp", "bytes": body.count, "sha256": Self.sha(body)]],
            ]],
        ]
        server.route("/catalog.json", .init(body: try JSONSerialization.data(withJSONObject: catalog)))
        let root = try gamesFolder([:])
        let running = try await start(root: root)
        running.library.repositories.freeSpace = { _ in 1 << 50 }
        let added = await invoke(running, "sources.add", ["url": server.url("/catalog.json").absoluteString, "name": "Synthetic"])
        #expect(added.status == 200)
        let source = try #require((added.result as? [String: Any])?["id"] as? String)
        #expect(await invoke(running, "sources.add", ["url": server.url("/catalog.json").absoluteString]).status == 409)
        #expect(await invoke(running, "sources.refresh", ["source": source]).status == 200)
        let entries = await invoke(running, "sources.entries", ["source": source])
        #expect((entries.result as? [[String: Any]])?.first?["id"] as? String == "slow")
        let sources = await invoke(running, "sources.list")
        #expect((sources.result as? [[String: Any]])?.first?["token"] as? String == "none")

        let started = await invoke(running, "downloads.start", ["source": source, "entry": "slow"])
        #expect(started.status == 202)
        let jobID = try #require(started.json["job_id"] as? String)
        try await wait("the download to run") { running.library.repositories.downloads.first?.state == .running }
        let cancel = await call(running, "POST", "/v1/jobs/\(jobID)/cancel", json: [String: Any]())
        #expect(cancel.status == 200)
        let ended = await call(running, "GET", "/v1/jobs/\(jobID)?wait_ms=10000")
        #expect((ended.result as? [String: Any])?["state"] as? String == "cancelled")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Slow Game [0100000000010000]/Slow.nsp").path))

        // the same download id runs again: a new job, and the old one stays cancelled
        server.route("/files/Slow.nsp", .init(body: body, chunk: 256 * 1024))
        let retried = await invoke(running, "downloads.retry", ["download": try #require(running.library.repositories.downloads.first?.id)], wait: "done")
        #expect(retried.status == 200 && retried.json["state"] as? String == "succeeded")
        #expect(retried.json["job_id"] as? String != jobID)
        let old = await call(running, "GET", "/v1/jobs/\(jobID)")
        #expect((old.result as? [String: Any])?["state"] as? String == "cancelled")
        try await wait("the library to see the game") { running.library.games.count == 1 }
        // events said what happened
        let events = await call(running, "GET", "/v1/events?names=download,job,library&limit=1000")
        let names = Set(((events.result as? [String: Any])?["events"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        #expect(names.isSuperset(of: ["download", "job", "library"]))
        #expect(await invoke(running, "sources.remove", ["source": source]).status == 200)
        #expect(running.library.repositories.sources.isEmpty)
    }

    // MARK: - Free Up Space

    @Test func cleanupDeletesOnlyWhatItListsWithTheConfirmation() async throws {
        let root = try gamesFolder(["India": ["India.nsp", "India.ipa"]])
        let running = try await start(root: root)
        let scan = await invoke(running, "cleanup.scan")
        let groups = try #require((scan.result as? [String: Any])?["groups"] as? [[String: Any]])
        let files = groups.flatMap { $0["files"] as? [[String: Any]] ?? [] }
        let ipa = try #require(files.first { ($0["kind"] as? String) == "ipas" }?["path"] as? String)
        #expect(await invoke(running, "cleanup.delete", ["paths": [ipa], "confirm": "yes"]).status == 400)
        let outside = try folder().appending(path: "precious.txt")
        try Data("keep".utf8).write(to: outside)
        #expect(await invoke(running, "cleanup.delete", ["paths": [outside.path], "confirm": "yes, I'm sure"]).status == 404)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        let deleted = await invoke(running, "cleanup.delete", ["paths": [ipa], "confirm": "Yes, I'm sure"])
        #expect(deleted.status == 200)
        #expect(!FileManager.default.fileExists(atPath: ipa))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "India/India.nsp").path))
    }

    @Test func removingAGameNeedsItsNameAgain() async throws {
        let root = try gamesFolder(["Juliet": ["Juliet.nsp"]])
        let running = try await start(root: root)
        #expect(await invoke(running, "games.remove", ["game": "Juliet", "confirm": "juliet"]).status == 400)
        #expect(await invoke(running, "games.remove", ["game": "Juliet"]).status == 400)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Juliet/Juliet.nsp").path))
        #expect(await invoke(running, "games.remove", ["game": "Juliet", "confirm": "Juliet"]).status == 200)
        #expect(running.library.games.isEmpty)
    }

    // MARK: - The window

    @Test func theWindowFollowsTheCalls() async throws {
        let root = try gamesFolder(["Kilo": ["Kilo.nsp"], "Lima": ["Lima.nsp"]])
        let running = try await start(root: root)
        #expect(await invoke(running, "ui.select", ["game": "Lima"]).status == 200)
        #expect(running.library.selectedGame?.folder.lastPathComponent == "Lima")
        #expect(await invoke(running, "ui.search", ["text": "kil"]).status == 200)
        #expect(running.library.shownGames.map(\.folder.lastPathComponent) == ["Kilo"])
        #expect(await invoke(running, "ui.select", ["game": NSNull()]).status == 200)
        #expect(running.library.selection == nil)
        // no RootView in a test: the request is made, nobody claims it opened, and it's withdrawn
        running.library.windowOpenTimeout = .milliseconds(300)
        let opened = await invoke(running, "ui.open", ["window": "sources"])
        #expect((opened.result as? [String: Any])?["opened"] as? Bool == false)
        #expect(running.library.windowRequests.isEmpty)
        // RootView answering: it opens what's queued and says so for each request
        final class Opened { var windows: [ControlWindow] = [] }
        let shown = Opened()
        running.library.windowOpenTimeout = .seconds(5)
        let rootView = Task { @MainActor in
            while !Task.isCancelled {
                running.library.openRequestedWindows { shown.windows.append($0) }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let tab = await invoke(running, "ui.open", ["window": "settings", "tab": "devices"])
        rootView.cancel()
        #expect(tab.status == 200 && running.library.settingsTab == .devices)
        #expect((tab.result as? [String: Any])?["opened"] as? Bool == true)
        #expect(shown.windows == [.settings])
        #expect(await invoke(running, "ui.open", ["window": "terminal"]).status == 400)
    }

    @Test func questionsAreAnsweredOnlyWhenAsked() async throws {
        let running = try await start()
        #expect(await invoke(running, "games.answer_update", ["answer": "update"]).status == 409)
        #expect(await invoke(running, "games.answer_save", ["choice": "newer"]).status == 409)
    }

    // MARK: - Events

    @Test func aLongPollWakesOnTheNextEvent() async throws {
        let running = try await start()
        let mark = running.api.hub.lastSeq
        let reply = Task { await self.call(running, "GET", "/v1/events?after=\(mark)&names=ui&wait_ms=10000") }
        try await Task.sleep(for: .milliseconds(200))
        running.library.consoleMode = true
        let started = Date.now
        let events = await reply.value
        #expect(Date.now.timeIntervalSince(started) < 5)
        let result = try #require(events.result as? [String: Any])
        #expect((result["events"] as? [Any])?.isEmpty == false)
        #expect((result["next_after"] as? Int ?? 0) > mark)
        running.library.consoleMode = false
    }

    // MARK: - Registry

    @Test func theRegistryIsConsistent() async throws {
        let running = try await start()
        let commands = running.api.commands
        #expect(Set(commands.map(\.name)).count == commands.count)
        for command in commands {
            #expect(command.toolName.range(of: #"^[a-zA-Z0-9_-]{1,64}$"#, options: .regularExpression) != nil)
            #expect(Set(command.params.map(\.name)).count == command.params.count)
            if command.effect == .destructive, command.name != "sources.remove" {
                #expect(command.params.contains { $0.name == "confirm" }, "\(command.name) deletes without a confirmation")
            }
            // nothing takes a secret
            #expect(!command.params.contains { ControlRedaction.isSecret($0.name) }, "\(command.name) takes a secret")
        }
        // the coverage inventory (docs/control-api.md) lists exactly these
        #expect(commands.map(\.name) == Self.inventory)
    }

    static let inventory = [
        "library.status", "library.refresh", "library.inspect_folder", "library.set_folder", "setup.status",
        "games.list", "games.get", "games.log", "games.extract", "games.rebuild", "games.build_ipa", "games.make_mac_app",
        "games.install", "games.play", "games.stop", "games.answer_update", "games.answer_save", "games.set_kept",
        "games.settings", "games.set_setting", "games.clear_settings", "games.forget_save_choice", "games.extract_all",
        "games.update_all", "games.remove",
        "settings.get", "settings.update", "companion.status",
        "sources.list", "sources.add", "sources.remove", "sources.set_enabled", "sources.refresh", "sources.entries",
        "downloads.list", "downloads.start", "downloads.cancel", "downloads.retry",
        "devices.list", "ios_app.install",
        "cleanup.scan", "cleanup.delete",
        "ui.state", "ui.select", "ui.search", "ui.console_mode", "ui.open",
    ]

    // MARK: - MCP

    private func mcp(_ running: Running, _ message: [String: Any], headers: [String: String] = [:]) async -> Reply {
        await call(running, "POST", "/mcp", json: message, headers: headers)
    }

    @Test func mcpSpeaksTheProtocol() async throws {
        let running = try await start()
        let initialize = await mcp(running, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "t", "version": "1"]]])
        let result = try #require(initialize.json["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        let future = await mcp(running, ["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "2099-01-01"]])
        #expect((future.json["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
        let note = await mcp(running, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(note.status == 202 && note.body.isEmpty)
        #expect((await mcp(running, ["jsonrpc": "2.0", "id": "p", "method": "ping"])).json["result"] != nil)
        let unknown = await mcp(running, ["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
        #expect((unknown.json["error"] as? [String: Any])?["code"] as? Int == -32601)
        let batch = await call(running, "POST", "/mcp", json: [["jsonrpc": "2.0", "id": 4, "method": "ping"]])
        #expect((batch.json["error"] as? [String: Any])?["code"] as? Int == -32600)
        let badVersion = await mcp(running, ["jsonrpc": "2.0", "id": 5, "method": "ping"], headers: ["MCP-Protocol-Version": "1999-01-01"])
        #expect(badVersion.status == 400)
        let parse = await call(running, "POST", "/mcp", headers: ["Content-Type": "application/json"])
        #expect((parse.json["error"] as? [String: Any])?["code"] as? Int == -32700)
    }

    @Test func mcpToolsCarryTheirEffects() async throws {
        let running = try await start()
        let list = await mcp(running, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let tools = try #require((list.json["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        func annotations(_ name: String) -> [String: Any]? {
            tools.first { $0["name"] as? String == name }?["annotations"] as? [String: Any]
        }
        #expect(tools.count == running.api.commands.count + ControlMCP.metaTools.count)
        #expect(annotations("nx_games_list")?["readOnlyHint"] as? Bool == true)
        #expect(annotations("nx_cleanup_delete")?["destructiveHint"] as? Bool == true)
        #expect(annotations("nx_games_remove")?["readOnlyHint"] as? Bool == false)
        #expect(annotations("nx_settings_update")?["destructiveHint"] as? Bool == false)
        #expect(annotations("nx_settings_update")?["idempotentHint"] as? Bool == true)
        #expect(annotations("nx_downloads_start")?["openWorldHint"] as? Bool == true)
        #expect(annotations("nxapi_status")?["readOnlyHint"] as? Bool == true)
        for tool in tools {
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
        }
    }

    @Test func mcpCallsAnswerWithResultsAndErrorsAsResults() async throws {
        let root = try gamesFolder(["Mike": ["Mike.nsp"]])
        let running = try await start(root: root)
        let ok = await mcp(running, ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "nx_games_list", "arguments": [String: Any]()]])
        let result = try #require(ok.json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        #expect(((result["structuredContent"] as? [String: Any])?["result"] as? [Any])?.count == 1)
        #expect(((result["content"] as? [[String: Any]])?.first?["type"] as? String) == "text")
        let invalid = await mcp(running, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "nx_games_get", "arguments": ["nope": 1]]])
        #expect((invalid.json["result"] as? [String: Any])?["isError"] as? Bool == true)
        let unknown = await mcp(running, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "nx_rm_rf"]])
        #expect((unknown.json["error"] as? [String: Any])?["code"] as? Int == -32602)
        let meta = await mcp(running, ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "nxapi_invoke", "arguments": ["command": "games.get", "args": ["game": "Mike"]]]])
        #expect((meta.json["result"] as? [String: Any])?["isError"] as? Bool == false)
        let describe = await mcp(running, ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "nxapi_describe_command", "arguments": ["name": "cleanup.delete"]]])
        let described = ((describe.json["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["result"] as? [String: Any]
        #expect(described?["destructive"] as? Bool == true)
    }

    // MARK: - The stdio adapter, end to end

    @Test func theStdioAdapterForwardsToTheRunningAPI() async throws {
        let adapter = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../Control/nxplay_control.py").standardizedFileURL
        guard FileManager.default.fileExists(atPath: adapter.path),
            FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")
        else { return }
        let root = try gamesFolder(["November": ["November.nsp"]])
        let running = try await start(root: root)
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nx_games_list","arguments":{}}}"#,
            "not json",
        ].joined(separator: "\n") + "\n"
        let endpoint = running.folder.appending(path: "endpoint.json").path
        let output = await Task.detached { () -> (String, String, Int32) in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/python3")
            process.arguments = ["-I", adapter.path, "--endpoint", endpoint, "mcp"]
            process.environment = ["HTTP_PROXY": "http://127.0.0.1:9", "http_proxy": "http://127.0.0.1:9", "PATH": "/usr/bin:/bin"]
            let input = Pipe()
            let out = Pipe()
            let err = Pipe()
            process.standardInput = input
            process.standardOutput = out
            process.standardError = err
            try? process.run()
            input.fileHandleForWriting.write(Data(lines.utf8))
            try? input.fileHandleForWriting.close()
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self), process.terminationStatus)
        }.value
        #expect(output.2 == 0, "stderr: \(output.1)")
        let answers = output.0.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        // initialize, tools/list, tools/call, the parse error: nothing for the notification, nothing but JSON-RPC
        #expect(answers.count == 4)
        #expect(output.0.split(separator: "\n").count == 4)
        #expect((answers.first?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
        #expect((((answers[safe: 1]?["result"] as? [String: Any])?["tools"]) as? [Any])?.isEmpty == false)
        #expect(((answers[safe: 2]?["result"] as? [String: Any])?["isError"]) as? Bool == false)
        #expect((answers[safe: 3]?["error"] as? [String: Any])?["code"] as? Int == -32700)
        #expect(!output.0.contains(running.token) && !output.1.contains(running.token))
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
