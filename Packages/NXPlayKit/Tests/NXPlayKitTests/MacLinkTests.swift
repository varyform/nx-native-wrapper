import Foundation
import Network
import Testing

@testable import NXPlayKit

/// Remote builds between Macs (Settings › Remote): pairing and calls over TLS, the mirrored builds, and a game in a
/// games folder both Macs have.
@MainActor @Suite(.serialized) final class MacLinkTests {
    private var suites: [String] = []
    private let folder = FileManager.default.temporaryDirectory.appending(
        path: "nxplay-maclink-\(UUID().uuidString)", directoryHint: .isDirectory)

    deinit {
        suites.forEach(removeTestDefaults)
        try? FileManager.default.removeItem(at: folder)
    }

    private func library() -> Library {
        let suite = testDefaultsName()
        suites.append(suite)
        return Library(defaults: UserDefaults(suiteName: suite)!, isScreenshot: true)
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(30)) }
    }

    @Test func aCodeForgivesMisreadingsAndPairsOnce() async throws {
        #expect(MacLinkSecurity.normalizedCode("ab1o-il2z") == "AB10112Z")
        let snapshot = MacSnapshot(name: "Studio", version: "1.9.1", games: [])
        let host = MacLinkHost(
            store: MacLinkStore(directory: folder.appending(path: "host")), hostID: "host-id", name: "Studio", port: nil,
            advertises: false
        ) { call, client in
            if case .poll = call { return .snapshot(snapshot) }
            return .failure("no")
        }
        await host.start()
        try await until { host.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try #require(host.port))

        await #expect(throws: MacLinkError.self) {
            _ = try await MacClient.pair(
                endpoint: endpoint, hostID: "host-id", code: "0000-0000", clientID: "c", clientName: "Air")
        }
        let code = host.pairingCode
        let paired = try await MacClient.pair(
            endpoint: endpoint, hostID: "host-id", code: code.lowercased(), clientID: "c", clientName: "Air")
        #expect(paired.name == "Studio" && host.clients.map(\.name) == ["Air"])
        #expect(host.clients.first?.key == paired.key)  // both ends worked out the same key
        // a new code means a new listener, which refuses connections until it's ready (on a busy CI runner, long
        // enough for the connect below)
        try await until { host.pairingCode != code && host.isListening }
        #expect(host.pairingCode != code)  // one use only

        let client = MacClient(host: paired, clientID: "c")
        try await client.connect(to: endpoint)
        #expect(try await client.poll(logs: [:]) == snapshot)

        // removed there: its key no longer opens a connection
        await client.disconnect()
        host.removeClient(id: "c")
        await #expect(throws: MacLinkError.self) { try await client.connect(to: endpoint) }
        host.stop()
    }

    @Test func aMirrorTakesTheHostsLogFromWhereItIs() {
        let line = { (n: Int) in LogLine("line \(n)") }
        var remote = RemoteJob(
            id: UUID(), kind: .rebuild, status: .running, progress: nil, note: nil, warnings: [],
            gameStarted: false, logTotal: 5_000, logFrom: 5_000, log: [])
        let build = RemoteBuild(macName: "Studio", jobID: remote.id) {}
        let game = MacLink.game(
            RemoteGame(
                id: "/g/A", name: "A", titleID: nil, version: nil, isExtracted: true, isReady: true, isKept: false,
                canBuild: false, canRebuild: true, hasIcon: false, shared: nil, job: nil))
        let job = Job.mirror(remote, of: game, on: build)
        #expect(build.logTotal == 3_000 && job.log.lines.map(\.text) == ["nxplay: building on Studio", "…"])

        remote.logFrom = 3_000
        remote.log = (3_000..<5_000).map(line)
        job.apply(remote)
        remote.logTotal = 5_005
        remote.logFrom = 4_990  // a poll that crossed another: only what's new is added
        remote.log = (4_990..<5_005).map(line)
        job.apply(remote)
        #expect(job.log.lines.count == 2 + 2_005 && job.log.lines.last?.text == "line 5004")
        #expect(build.logTotal == 5_005 && job.status == .running && build.wasActive)
    }

    @Test func aSharedFolderIsKnownWhateverItsPath() throws {
        let root = folder.appending(path: "Switch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Zelda"), withIntermediateDirectories: true)
        // the other Mac reaches it under another path: here a link to it
        let elsewhere = folder.appending(path: "Volumes-Switch")
        try FileManager.default.createSymbolicLink(at: elsewhere, withDestinationURL: root)
        var here: [URL: String] = [:], there: [URL: String] = [:]
        let key = SharedFolders.key(of: root.appending(path: "Zelda"), roots: [root], ids: &here)
        #expect(key != nil)
        #expect(SharedFolders.key(of: elsewhere.appending(path: "zelda"), roots: [elsewhere], ids: &there) == key)
        #expect(SharedFolders.key(of: root, roots: [root], ids: &here) == here[root]! + "/")
        #expect(SharedFolders.key(of: folder.appending(path: "Other"), roots: [root], ids: &here) == nil)
    }

    @Test func anotherMacsBuildOfASharedGameStopsOneHere() throws {
        let root = folder.appending(path: "Games", directoryHint: .isDirectory)
        let folderA = root.appending(path: "Alpha")
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try Data([1]).write(to: folderA.appending(path: "Alpha.nsp"))
        let library = library()
        library.roots = [root]
        let game = try #require(library.games.first)
        #expect(library.macLink.hosts.isEmpty && library.sharedGames().isEmpty)  // no id file without a paired Mac

        // the host lists the game under the folder's id, as it's the same folder there
        library.macLink.hosts = [PairedMac(id: "studio", name: "Studio", key: Data())]
        let listed = try #require(library.macSnapshot(logs: [:]).games.first)
        #expect(listed.shared != nil && library.sharedGames()[listed.shared!]?.id == game.id)

        var remote = RemoteJob(
            id: UUID(), kind: .extract, status: .running, progress: nil, note: nil, warnings: [],
            gameStarted: false, logTotal: 0, logFrom: 0, log: [])
        var hosted = listed
        hosted.id = "/Volumes/Games/Alpha"
        hosted.job = remote
        library.macLink.apply(MacSnapshot(name: "Studio", version: "", games: [hosted]), from: "studio")
        #expect(library.isBusy(game) && library.job(for: game)?.remote?.macName == "Studio")
        #expect(library.buildingJobs.count == 1)
        library.extract(game)
        #expect(library.jobs[game.id] == nil)  // not started here

        remote.status = .succeeded
        hosted.job = remote
        library.macLink.apply(MacSnapshot(name: "Studio", version: "", games: [hosted]), from: "studio")
        #expect(!library.isBusy(game) && library.buildingJobs.isEmpty)
    }
}
