import CryptoKit
import Foundation
import Testing

@testable import NXPlayKit

/// Sources against a synthetic local HTTP server: made-up bytes, never a real game.
@MainActor @Suite(.serialized) final class RepositoryTests {
    private var suites: [String] = []
    private var folders: [URL] = []
    private let server: TestHTTPServer

    init() throws {
        server = try TestHTTPServer()
    }

    deinit {
        suites.forEach(removeTestDefaults)
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func defaults() -> UserDefaults {
        let suite = testDefaultsName()
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-repo-tests/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        // the real path: /var is a link to /private/var, and DownloadFiles compares nothing through it anyway
        return url.resolvingSymlinksInPath()
    }

    private func repositories(root: URL? = nil, stateFile: URL? = nil) throws -> (Repositories, URL, MemoryCredentials) {
        let root = try root ?? folder()
        let credentials = MemoryCredentials()
        let repositories = Repositories(defaults: defaults(), credentials: credentials, stateFile: stateFile)
        repositories.root = { root }
        repositories.freeSpace = { _ in 1 << 50 }
        return (repositories, root, credentials)
    }

    private static func bytes(_ count: Int, seed: UInt8 = 7) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let titleID = "0100000000010000"

    private static func encoded(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))!
    }

    private func catalog(_ packages: [[String: Any]], id: String = "example", name: String = "Example Game") -> Data {
        let object: [String: Any] = [
            "nxplayCatalog": 1, "name": "Test shelf",
            "entries": [["id": id, "name": name, "titleID": Self.titleID, "version": "1.0.1", "packages": packages]],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func package(
        _ filename: String, _ data: Data, kind: String = "base", url: String? = nil, sha: String? = nil,
        bytes: Int? = nil
    ) -> [String: Any] {
        [
            "kind": kind, "filename": filename, "url": url ?? "files/\(Self.encoded(filename))",
            "bytes": bytes ?? data.count, "sha256": sha ?? Self.sha(data),
        ]
    }

    /// Serves a catalog of `packages` (with their bodies at /files/<name>) and adds it as a source, loaded.
    private func serve(
        _ repositories: Repositories, files: [String: Data], packages: [[String: Any]], token: String = "",
        path: String = "/catalog.json"
    ) async throws -> RepositorySource {
        for (name, body) in files { server.route("/files/\(Self.encoded(name))", .init(body: body)) }
        server.route(path, .init(body: catalog(packages)))
        let source = try repositories.addSource(name: "Shelf", address: server.url(path).absoluteString, token: token)
        await repositories.refresh(source.id)
        return source
    }

    private func wait(_ what: String = "", until condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(15)
        while !condition() {
            guard Date.now < deadline else {
                Issue.record("timed out waiting \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func staging(_ root: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: ".nxplay-downloads").path)) ?? []
    }

    // MARK: - Catalog

    @Test func aCatalogKeepsGoodEntriesAndSaysWhyOthersWereLeftOut() throws {
        let good = Self.bytes(10)
        let object: [String: Any] = [
            "nxplayCatalog": 1, "name": "Shelf",
            "entries": [
                ["name": "Good", "titleID": "0100000000010000", "packages": [package("Good.nsp", good)]],
                ["name": "Twice", "titleID": "0100000000010000", "packages": [package("Other.nsp", good)]],
                ["name": "No title", "packages": [package("X.nsp", good)]],
                [
                    "id": "mixed", "name": "Mixed", "titleID": "0100000000020000",
                    "packages": [
                        package("Mixed.nsp", Self.bytes(3)),
                        package("Mixed.zip", Self.bytes(4)),
                        package("../escape.nsp", Self.bytes(5)),
                        package(".hidden.nsp", Self.bytes(6)),
                        package("Bad.nsp", Self.bytes(7), sha: "xyz"),
                    ],
                ],
                ["id": "only-archive", "name": "Archive", "titleID": "0100000000030000",
                 "packages": [package("Game.7z", Self.bytes(8))]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let parsed = try Catalog.parse(data, base: URL(string: "https://nas.example/shelf/catalog.json")!)
        #expect(parsed.entries.map(\.id) == ["0100000000010000", "mixed"])
        #expect(parsed.entries[0].packages[0].url.absoluteString == "https://nas.example/shelf/files/Good.nsp")
        let mixed = parsed.entries[1]
        #expect(mixed.packages.map(\.filename) == ["Mixed.nsp"])
        #expect(mixed.issues.count == 4)
        #expect(mixed.issues[0].contains("archive"))
        #expect(mixed.issues[1].contains("folder"))
        #expect(mixed.issues[2].contains("hidden"))
        #expect(mixed.issues[3].contains("sha256"))
        #expect(parsed.issues.count == 3)
        #expect(parsed.issues.contains { $0.contains("second entry") })
        #expect(parsed.issues.contains { $0.contains("archive") })
    }

    @Test func aCatalogOfAnotherKindIsRefusedWhole() {
        let base = URL(string: "https://nas.example/catalog.json")!
        #expect(throws: Catalog.ParseError.self) { try Catalog.parse(Data("[]".utf8), base: base) }
        #expect(throws: Catalog.ParseError.self) { try Catalog.parse(Data("{\"entries\": []}".utf8), base: base) }
        #expect(throws: Catalog.ParseError.self) {
            try Catalog.parse(Data("{\"nxplayCatalog\": 2, \"entries\": []}".utf8), base: base)
        }
        #expect(throws: Catalog.ParseError.self) {
            try Catalog.parse(Data(count: Catalog.maxBytes + 1), base: base)
        }
    }

    @Test func theDocumentedExampleCatalogReads() throws {
        let file = URL(filePath: #filePath).deletingLastPathComponent().appending(
            path: "../../../../Catalog/example-catalog.json"
        ).standardized
        let parsed = try Catalog.parse(
            try Data(contentsOf: file), base: URL(string: "https://nas.example/games/catalog.json")!)
        #expect(parsed.issues.isEmpty)
        #expect(!parsed.entries.isEmpty)
        #expect(parsed.entries.allSatisfy { $0.issues.isEmpty })
        #expect(Set(parsed.entries.flatMap(\.packages).map(\.kind)) == [.base, .update, .dlc])
    }

    @Test func addressesAreHTTPSOrTheLocalNetworkWithoutSecretsInThem() throws {
        func problem(_ text: String) -> String? { RepositoryAddress.problem(with: URL(string: text)!) }
        #expect(problem("https://games.example.com/c.json") == nil)
        #expect(problem("http://nas.local:8080/c.json") == nil)
        #expect(problem("http://192.168.1.4/c.json") == nil)
        #expect(problem("http://[fd00::4]/c.json") == nil)
        #expect(problem("http://nas/c.json") == nil)
        #expect(problem("http://games.example.com/c.json") != nil)
        // IP addresses: only loopback, private and link-local ones over plain http
        for local in [
            "127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.0.10", "169.254.1.1", "[::1]",
            "[fc00::1]", "[fd12:3456::1]", "[fe80::1]", "[fe80::1%25en0]", "[::ffff:192.168.1.2]", "localhost", "nas.local.",
        ] {
            #expect(problem("http://\(local)/c.json") == nil, "\(local)")
        }
        for remote in [
            "8.8.8.8", "1.1.1.1", "172.32.0.1", "100.64.0.1", "0.0.0.0", "[2606:4700:4700::1111]", "[::ffff:8.8.8.8]",
            "[64:ff9b::808:808]", "[fec0::1]", "[::]", "16843009", "0x7f000001", "010.0.0.1", "127.1",
        ] {
            #expect(problem("http://\(remote)/c.json") != nil, "\(remote)")
            #expect(problem("https://\(remote)/c.json") == nil, "\(remote)")
        }
        #expect(problem("ftp://nas.local/c.json") != nil)
        #expect(problem("file:///etc/passwd") != nil)
        #expect(problem("https://me:pw@nas.example/c.json") != nil)

        let (repositories, _, _) = try repositories()
        #expect(throws: Repositories.Failure.self) {
            try repositories.addSource(name: "", address: "https://nas.example/c.json?token=abc")
        }
        #expect(throws: Repositories.Failure.self) {
            try repositories.addSource(name: "", address: "http://games.example.com/c.json")
        }
        // a token for a public address would go over plain http
        for address in ["http://8.8.8.8/c.json", "http://[2606:4700:4700::1111]/c.json"] {
            #expect(throws: Repositories.Failure.self) {
                try repositories.addSource(name: "", address: address, token: "tok")
            }
        }
        #expect(repositories.sources.isEmpty)
        // and a catalog's files on one are left out
        let data = try JSONSerialization.data(withJSONObject: [
            "nxplayCatalog": 1,
            "entries": [["name": "A", "titleID": Self.titleID, "packages": [
                package("A.nsp", Self.bytes(4), url: "http://8.8.8.8/A.nsp"),
                package("B.nsp", Self.bytes(5), url: "http://[2606:4700:4700::1111]/B.nsp"),
                package("C.nsp", Self.bytes(6), url: "http://192.168.1.9/C.nsp"),
            ]]],
        ] as [String: Any])
        let parsed = try Catalog.parse(data, base: URL(string: "http://192.168.1.9/catalog.json")!)
        #expect(parsed.entries.first?.packages.map(\.filename) == ["C.nsp"])
        #expect(parsed.entries.first?.issues.count == 2)
    }

    @Test func aTokenGoesToTheKeychainNeverToTheSettings() throws {
        let defaults = defaults()
        let credentials = MemoryCredentials()
        let repositories = Repositories(defaults: defaults, credentials: credentials, stateFile: nil)
        let source = try repositories.addSource(name: "NAS", address: "https://nas.example/c.json", token: "s3cret-token")
        #expect(try credentials.token(for: source.id) == "s3cret-token")
        let saved = try JSONSerialization.data(
            withJSONObject: defaults.array(forKey: Repositories.sourcesKey) ?? [])
        #expect(!String(decoding: saved, as: UTF8.self).contains("s3cret"))
        // read back from the settings
        let again = Repositories(defaults: defaults, credentials: credentials, stateFile: nil)
        #expect(again.sources == [source])
        try again.removeSource(source.id)
        #expect(try credentials.token(for: source.id) == nil)
    }

    // MARK: - Sources

    @Test func eachSourceLoadsOnItsOwn() async throws {
        let (repositories, _, _) = try repositories()
        let data = Self.bytes(100)
        let good = try await serve(repositories, files: ["Good.nsp": data], packages: [package("Good.nsp", data)])
        server.route("/down.json", .init(status: 500))
        server.route("/garbage.json", .init(body: Data("<html>".utf8)))
        let down = try repositories.addSource(name: "Down", address: server.url("/down.json").absoluteString)
        let garbage = try repositories.addSource(name: "Garbage", address: server.url("/garbage.json").absoluteString)
        await repositories.refreshAll()
        #expect(repositories.catalog(good.id)?.entries.count == 1)
        #expect(repositories.states[down.id] == .failed("The server answered 500"))
        guard case .failed(let message) = repositories.states[garbage.id] else {
            Issue.record("garbage loaded")
            return
        }
        #expect(message.contains("JSON"))
        #expect(repositories.entries(source: nil).map(\.entry.name) == ["Example Game"])
        #expect(repositories.entries(source: nil, search: "nothing").isEmpty)

        repositories.setEnabled(false, good.id)
        #expect(repositories.entries(source: nil).isEmpty)
    }

    @Test func theTokenNeverFollowsARedirectToAnotherOrigin() async throws {
        let (repositories, _, _) = try repositories()
        let data = Self.bytes(10)
        server.route("/moved.json", .init(status: 302, headers: ["Location": server.url("/same.json").absoluteString]))
        server.route("/same.json", .init(status: 302, headers: [
            "Location": server.url("/elsewhere.json", host: "localhost").absoluteString,
        ]))
        server.route("/elsewhere.json", .init(body: catalog([package("A.nsp", data, url: server.url("/files/A.nsp").absoluteString)])))
        server.route("/files/A.nsp", .init(body: data))
        let source = try repositories.addSource(
            name: "", address: server.url("/moved.json").absoluteString, token: "tok-123")
        await repositories.refresh(source.id)
        #expect(repositories.catalog(source.id) != nil)
        #expect(server.requests("/moved.json").last?.headers["authorization"] == "Bearer tok-123")
        #expect(server.requests("/same.json").last?.headers["authorization"] == "Bearer tok-123")
        #expect(server.requests("/elsewhere.json").last?.headers["authorization"] == nil)

        // the file is on the catalog's own origin (127.0.0.1): it gets the token
        let job = try repositories.download(source: source.id, entry: "example")
        try await wait("for the download") { repositories.job(job.id)?.state.isActive == false }
        #expect(repositories.job(job.id)?.state == .succeeded)
        #expect(server.requests("/files/A.nsp").last?.headers["authorization"] == "Bearer tok-123")
    }

    @Test func aFileHostedOnAnotherOriginGetsNoToken() async throws {
        let (repositories, root, _) = try repositories()
        let data = Self.bytes(4000)
        server.route("/cross.json", .init(body: catalog([
            package("X.nsp", data, url: server.url("/files/X.nsp", host: "localhost").absoluteString)
        ])))
        server.route("/files/X.nsp", .init(body: data))
        let source = try repositories.addSource(name: "", address: server.url("/cross.json").absoluteString, token: "tok")
        await repositories.refresh(source.id)
        #expect(server.requests("/cross.json").last?.headers["authorization"] == "Bearer tok")
        let job = try repositories.download(source: source.id, entry: "example")
        try await wait { repositories.job(job.id)?.state.isActive == false }
        #expect(repositories.job(job.id)?.state == .succeeded)
        #expect(server.requests("/files/X.nsp").last?.headers["authorization"] == nil)
        #expect(try Data(contentsOf: root.appending(path: job.folder).appending(path: "X.nsp")) == data)
    }

    @Test func aWaitingDownloadCancelsWithoutStarting() async throws {
        let (repositories, _, _) = try repositories()
        let slow = Self.bytes(400_000)
        let other = Self.bytes(1000, seed: 3)
        server.route("/two.json", .init(body: try JSONSerialization.data(withJSONObject: [
            "nxplayCatalog": 1,
            "entries": [
                ["id": "slow", "name": "Slow", "titleID": "0100000000010000", "packages": [package("S.nsp", slow)]],
                ["id": "next", "name": "Next", "titleID": "0100000000020000", "packages": [package("N.nsp", other)]],
            ],
        ] as [String: Any])))
        server.route("/files/S.nsp", .init(body: slow, chunk: 16 * 1024, delay: 0.02))
        server.route("/files/N.nsp", .init(body: other))
        let source = try repositories.addSource(name: "", address: server.url("/two.json").absoluteString)
        await repositories.refresh(source.id)
        let first = try repositories.download(source: source.id, entry: "slow")
        let second = try repositories.download(source: source.id, entry: "next")
        #expect(repositories.job(second.id)?.state == .queued)
        repositories.cancel(second.id)
        #expect(repositories.job(second.id)?.state == .cancelled)
        repositories.cancel(first.id)
        try await wait { !repositories.isActive }
        #expect(server.requests("/files/N.nsp").isEmpty)
    }

    @Test func aRedirectToPlainHTTPElsewhereIsRefused() async throws {
        let (repositories, _, _) = try repositories()
        server.route("/off.json", .init(status: 302, headers: ["Location": "http://games.example.com/c.json"]))
        let source = try repositories.addSource(name: "", address: server.url("/off.json").absoluteString, token: "t")
        await repositories.refresh(source.id)
        guard case .failed(let message) = repositories.states[source.id] else {
            Issue.record("followed the redirect")
            return
        }
        #expect(message.contains("redirect"))
    }

    // MARK: - Downloads

    @Test func aDownloadIsCheckedThenPublishedInTheGameFolder() async throws {
        let (repositories, root, _) = try repositories()
        var published: [String] = []
        repositories.onPublished = { published.append($0.id) }
        let base = Self.bytes(300_000, seed: 1)
        let update = Self.bytes(70_000, seed: 2)
        let source = try await serve(
            repositories, files: ["Example.nsp": base, "Example Update.nsp": update],
            packages: [package("Example.nsp", base), package("Example Update.nsp", update, kind: "update")])
        let job = try repositories.download(source: source.id, entry: "example")
        #expect(job.folder == "Example Game [0100000000010000]")
        #expect(job.totalBytes == 370_000)
        try await wait("for the download") { repositories.job(job.id)?.state.isActive == false }
        let done = try #require(repositories.job(job.id))
        #expect(done.state == .succeeded, "\(done.message ?? "")")
        #expect(done.bytesDone == 370_000)
        #expect(published == [job.id])
        let folder = root.appending(path: job.folder)
        #expect(try Data(contentsOf: folder.appending(path: "Example.nsp")) == base)
        #expect(try Data(contentsOf: folder.appending(path: "Example Update.nsp")) == update)
        #expect(staging(root).isEmpty)
        // the library sees it as a game to build
        #expect(GameScanner.game(at: folder)?.canExtract == true)
        // both files are there now: nothing more to download
        #expect(throws: Repositories.Failure.self) { try repositories.download(source: source.id, entry: "example") }
    }

    @Test func anUpdateGoesBesideTheBaseGameTheLibraryHas() async throws {
        let (repositories, root, _) = try repositories()
        try FileManager.default.createDirectory(at: root.appending(path: "My Game"), withIntermediateDirectories: true)
        repositories.existingFolder = { $0 == Self.titleID ? "My Game" : nil }
        let update = Self.bytes(5000)
        let source = try await serve(
            repositories, files: ["U.nsp": update], packages: [package("U.nsp", update, kind: "update")])
        let job = try repositories.download(source: source.id, entry: "example")
        try await wait { repositories.job(job.id)?.state.isActive == false }
        #expect(try Data(contentsOf: root.appending(path: "My Game/U.nsp")) == update)
    }

    @Test func aChecksumMismatchPutsNothingInTheLibrary() async throws {
        let (repositories, root, _) = try repositories()
        let data = Self.bytes(50_000)
        let source = try await serve(
            repositories, files: ["Bad.nsp": data],
            packages: [package("Bad.nsp", data, sha: String(repeating: "ab", count: 32))])
        let job = try repositories.download(source: source.id, entry: "example")
        try await wait { repositories.job(job.id)?.state.isActive == false }
        let done = try #require(repositories.job(job.id))
        #expect(done.state == .failed)
        #expect(done.message?.contains("SHA-256") == true)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: job.folder).appending(path: "Bad.nsp").path))
        #expect(staging(root).isEmpty)
    }

    @Test func aFileOfTheWrongSizeStopsEarly() async throws {
        let (repositories, root, _) = try repositories()
        let data = Self.bytes(1000)
        let source = try await serve(
            repositories, files: ["Short.nsp": data], packages: [package("Short.nsp", data, bytes: 5000)])
        let job = try repositories.download(source: source.id, entry: "example")
        try await wait { repositories.job(job.id)?.state.isActive == false }
        #expect(repositories.job(job.id)?.state == .failed)
        #expect(repositories.job(job.id)?.message?.contains("out of date") == true)
        #expect(staging(root).isEmpty)
    }

    @Test func aDownloadCancelsCleanlyAndRetriesFromTheStart() async throws {
        let (repositories, root, _) = try repositories()
        let data = Self.bytes(2_000_000, seed: 9)
        let source = try await serve(repositories, files: [:], packages: [package("Slow.nsp", data)])
        server.route("/files/Slow.nsp", .init(body: data, chunk: 32 * 1024, delay: 0.05))
        let job = try repositories.download(source: source.id, entry: "example")
        try await wait("for bytes") { (repositories.job(job.id)?.bytesDone ?? 0) > 0 }
        #expect(!staging(root).isEmpty)
        repositories.cancel(job.id)
        try await wait("for the cancel") { repositories.job(job.id)?.state == .cancelled }
        #expect(!repositories.isActive)
        #expect(staging(root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: job.folder).appending(path: "Slow.nsp").path))

        server.route("/files/Slow.nsp", .init(body: data))
        let again = try repositories.retry(job.id)
        #expect(again.id == job.id)
        #expect(again.bytesDone == 0)
        try await wait("for the retry") { repositories.job(job.id)?.state.isActive == false }
        #expect(repositories.job(job.id)?.state == .succeeded)
        #expect(try Data(contentsOf: root.appending(path: job.folder).appending(path: "Slow.nsp")) == data)
    }

    @Test func theSameFileIsNeverDownloadedTwiceAtOnce() async throws {
        let (repositories, _, _) = try repositories()
        let data = Self.bytes(400_000)
        let source = try await serve(repositories, files: [:], packages: [package("Once.nsp", data)])
        server.route("/files/Once.nsp", .init(body: data, chunk: 16 * 1024, delay: 0.02))
        let job = try repositories.download(source: source.id, entry: "example")
        #expect {
            try repositories.download(source: source.id, entry: "example")
        } throws: { ($0 as? Repositories.Failure)?.status == 409 }
        repositories.cancel(job.id)
        try await wait { !repositories.isActive }
    }

    @Test func aFileAlreadyThereIsNeverReplaced() async throws {
        let (repositories, root, _) = try repositories()
        let data = Self.bytes(300_000)
        let source = try await serve(repositories, files: [:], packages: [package("Mine.nsp", data)])
        server.route("/files/Mine.nsp", .init(body: data, chunk: 16 * 1024, delay: 0.01))
        let job = try repositories.download(source: source.id, entry: "example")
        // the player copies their own file in while the download runs
        let folder = root.appending(path: job.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("the player's own".utf8).write(to: folder.appending(path: "Mine.nsp"))
        try await wait { repositories.job(job.id)?.state.isActive == false }
        #expect(repositories.job(job.id)?.state == .failed)
        #expect(repositories.job(job.id)?.message?.contains("doesn't replace") == true)
        #expect(try Data(contentsOf: folder.appending(path: "Mine.nsp")) == Data("the player's own".utf8))
        #expect(staging(root).isEmpty)
    }

    @Test func aLinkWhereTheGameFolderGoesIsRefused() async throws {
        let (repositories, root, _) = try repositories()
        let outside = try folder()
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "Example Game [0100000000010000]"), withDestinationURL: outside)
        let data = Self.bytes(1000)
        let source = try await serve(repositories, files: ["E.nsp": data], packages: [package("E.nsp", data)])
        let job = try repositories.download(source: source.id, entry: "example")
        try await wait { repositories.job(job.id)?.state.isActive == false }
        #expect(repositories.job(job.id)?.state == .failed)
        #expect(repositories.job(job.id)?.message?.contains("link") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func aStagingLinkCantSendFilesElsewhere() throws {
        let root = try folder()
        let outside = try folder()
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: DownloadFiles.stagingName), withDestinationURL: outside)
        #expect(throws: DownloadFiles.Failure.self) { try DownloadFiles.Staging(root: root, id: "job") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func folderNamesStayInsideTheGamesFolder() {
        #expect(DownloadFiles.folderName(name: "../../etc", titleID: "0100000000010000") == "etc [0100000000010000]")
        #expect(DownloadFiles.folderName(name: "A/B: C", titleID: "0100000000010000") == "A B C [0100000000010000]")
        #expect(DownloadFiles.folderName(name: "...", titleID: "0100000000010000") == "0100000000010000")
        #expect(!DownloadFiles.isPlainName(".."))
        #expect(!DownloadFiles.isPlainName("a/b"))
        #expect(!DownloadFiles.isPlainName(".nxplay-downloads"))
    }

    @Test func tooLittleRoomRefusesBeforeDownloading() async throws {
        let (repositories, _, _) = try repositories()
        repositories.freeSpace = { _ in 3 * 1024 * 1024 * 1024 }
        let data = Self.bytes(1000)
        let source = try await serve(
            repositories, files: [:],
            packages: [package("Big.nsp", data, bytes: 2 * 1024 * 1024 * 1024)])
        #expect {
            try repositories.download(source: source.id, entry: "example")
        } throws: { ($0 as? Repositories.Failure)?.status == 507 }
        #expect(server.requests("/files/Big.nsp").isEmpty)
    }

    @Test func aDownloadStoppedByQuittingShowsAsFailedNextLaunch() async throws {
        let state = try folder().appending(path: "downloads.json")
        let (repositories, root, _) = try repositories(stateFile: state)
        let data = Self.bytes(400_000)
        let source = try await serve(repositories, files: [:], packages: [package("Q.nsp", data)])
        server.route("/files/Q.nsp", .init(body: data, chunk: 16 * 1024, delay: 0.05))
        let job = try repositories.download(source: source.id, entry: "example")
        try await wait { repositories.job(job.id)?.state == .running && !staging(root).isEmpty }
        let saved = try String(contentsOf: state, encoding: .utf8)
        #expect(saved.contains(job.id))
        #expect(!saved.contains("http"))  // no addresses kept: a retry takes them from the catalog

        // the next launch, without the first one cleaning up
        let next = Repositories(defaults: defaults(), credentials: MemoryCredentials(), stateFile: state)
        #expect(next.job(job.id)?.state == .failed)
        #expect(next.job(job.id)?.message?.contains("quit") == true)
        #expect(staging(root).isEmpty)
        repositories.cancel(job.id)
        try await wait { !repositories.isActive }
    }

    // MARK: - The Mac's API

    @Test func theAPINeedsThePairingCodeAndSaysWhatsGoingOn() async throws {
        let library = Library(defaults: defaults(), isScreenshot: true)
        let root = try folder()
        library.root = root
        func ask(_ method: String, _ path: String, token: String? = nil) async -> (Int, Any?) {
            let auth = "Authorization: Bearer \(token ?? library.remoteToken)\r\n"
            let request = RemoteRequest.parse(Data("\(method) \(path) HTTP/1.1\r\n\(auth)\r\n".utf8))!
            let response = await library.respond(to: request)
            return (response.status, try? JSONSerialization.jsonObject(with: response.body))
        }
        #expect(await ask("GET", "/v1/sources", token: "wrong").0 == 401)
        #expect(await ask("GET", "/v1/downloads", token: "wrong").0 == 401)
        #expect(await ask("POST", "/v1/downloads?source=x&entry=y", token: "wrong").0 == 401)

        let data = Self.bytes(20_000)
        let source = try await serve(
            library.repositories, files: ["A.nsp": data], packages: [package("A.nsp", data)], token: "tok")
        let (status, sources) = await ask("GET", "/v1/sources")
        #expect(status == 200)
        let first = try #require((sources as? [[String: Any]])?.first)
        #expect(first["id"] as? String == source.id)
        #expect(first["state"] as? String == "loaded")
        #expect(first["entries"] as? Int == 1)
        #expect(first["origin"] as? String == "http://127.0.0.1:\(server.port)")
        #expect(!String(describing: sources).contains("tok"))

        let (_, entries) = await ask("GET", "/v1/sources/\(source.id)/entries?q=example")
        let entry = try #require((entries as? [[String: Any]])?.first)
        #expect(entry["id"] as? String == "example")
        #expect(entry["libraryGame"] is NSNull)
        let packageJSON = try #require((entry["packages"] as? [[String: Any]])?.first)
        #expect(packageJSON["present"] as? Bool == false)
        #expect(packageJSON["id"] as? String == Self.sha(data))

        #expect(await ask("POST", "/v1/downloads?source=\(source.id)&entry=nope").0 == 404)
        #expect(await ask("POST", "/v1/downloads?source=\(source.id)&entry=example&packages=\(String(repeating: "0", count: 64))").0 == 404)
        let (accepted, job) = await ask("POST", "/v1/downloads?source=\(source.id)&entry=example&packages=\(Self.sha(data))")
        #expect(accepted == 202)
        let jobJSON = try #require(job as? [String: Any])
        let id = try #require(jobJSON["id"] as? String)
        #expect(Set(jobJSON.keys).isSuperset(of: ["state", "bytesDone", "totalBytes", "fraction", "files", "libraryGame", "message"]))
        try await wait { library.repositories.job(id)?.state.isActive == false }

        let (_, list) = await ask("GET", "/v1/downloads")
        let finished = try #require((list as? [[String: Any]])?.first)
        #expect(finished["state"] as? String == "succeeded")
        // the library has the game now, by the id Install takes
        #expect(finished["libraryGame"] as? String == "Example Game [0100000000010000]")
        let (_, games) = await ask("GET", "/v1/games")
        #expect((games as? [[String: Any]])?.first?["id"] as? String == "Example Game [0100000000010000]")
        #expect((games as? [[String: Any]])?.first?["canInstall"] as? Bool == true)

        #expect(await ask("POST", "/v1/downloads?source=\(source.id)&entry=example").0 == 409)
        #expect(await ask("POST", "/v1/downloads/\(id)/retry").0 == 409)
        #expect(await ask("POST", "/v1/downloads/nope/cancel").0 == 404)
        #expect(await ask("POST", "/v1/downloads/nope/retry").0 == 404)
        #expect(await ask("GET", "/v1/sources/nope/entries").0 == 404)
        #expect(await ask("POST", "/v1/sources/refresh").0 == 200)
    }

    // MARK: - Review fixes

    /// A catalog of `entries` entries with `each` packages, made-up hashes.
    private static func bigCatalog(entries: Int, each: Int) -> Data {
        var text = "{\"nxplayCatalog\":1,\"entries\":["
        for entry in 0..<entries {
            if entry > 0 { text += "," }
            text += "{\"id\":\"e\(entry)\",\"name\":\"Game \(entry)\",\"titleID\":\"0100000000010000\",\"packages\":["
            for index in 0..<each {
                if index > 0 { text += "," }
                let sha = String(format: "%064x", entry * 1_000_000 + index)
                text += "{\"kind\":\"dlc\",\"filename\":\"P\(index).nsp\",\"url\":\"f/\(index)\",\"bytes\":1,\"sha256\":\"\(sha)\"}"
            }
            text += "]}"
        }
        return Data((text + "]}").utf8)
    }

    @Test func aCatalogIsBoundedAndReadsInLinearTime() throws {
        let base = URL(string: "https://nas.example/catalog.json")!
        // the review's case: 40,000 files in one entry is refused at once, not compared pair by pair
        let one = Self.bigCatalog(entries: 1, each: 40_000)
        var started = Date.now
        let refused = try Catalog.parse(one, base: base)
        #expect(refused.entries.isEmpty)
        #expect(refused.issues.first?.contains("more than \(Catalog.maxPackagesPerEntry) packages") == true)
        #expect(Date.now.timeIntervalSince(started) < 2)

        // 40,000 files spread over entries at the per-entry limit: every one checked, quickly
        let spread = Self.bigCatalog(entries: 20, each: Catalog.maxPackagesPerEntry)
        #expect(spread.count < Catalog.maxBytes)
        started = .now
        let parsed = try Catalog.parse(spread, base: base)
        let seconds = Date.now.timeIntervalSince(started)
        #expect(parsed.entries.count == 20)
        #expect(parsed.entries.allSatisfy { $0.packages.count == Catalog.maxPackagesPerEntry })
        #expect(seconds < 10, "\(seconds) s")

        // duplicates are still caught, whatever the case of the name
        let twice = try JSONSerialization.data(withJSONObject: [
            "nxplayCatalog": 1,
            "entries": [["name": "A", "titleID": Self.titleID, "packages": [
                package("A.nsp", Self.bytes(4)), package("a.NSP", Self.bytes(5)), package("B.nsp", Self.bytes(4)),
            ]]],
        ] as [String: Any])
        let dupes = try Catalog.parse(twice, base: base).entries[0]
        #expect(dupes.packages.map(\.filename) == ["A.nsp"])
        #expect(dupes.issues.count == 2)
    }

    @Test func aCatalogWithTooManyFilesIsRefusedWhole() {
        let base = URL(string: "https://nas.example/catalog.json")!
        let entries = (0...(Catalog.maxPackages / Catalog.maxPackagesPerEntry)).map { index -> [String: Any] in
            ["id": "e\(index)", "name": "G", "titleID": Self.titleID,
             "packages": Array(repeating: 0, count: Catalog.maxPackagesPerEntry) as [Any]]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["nxplayCatalog": 1, "entries": entries] as [String: Any])
        #expect(throws: Catalog.ParseError(message: "The catalog lists more than \(Catalog.maxPackages) files")) {
            try Catalog.parse(data, base: base)
        }
    }

    @Test func readingABigCatalogLeavesTheMainActorFree() async throws {
        let (repositories, _, _) = try repositories()
        let data = Self.bigCatalog(entries: 30, each: Catalog.maxPackagesPerEntry)
        // how long the parse alone takes here: on the main actor, the longest wait would be about that
        let base = URL(string: "https://nas.example/catalog.json")!
        let started = Date.now
        _ = try await Task.detached { try Catalog.parse(data, base: base) }.value
        let parse = Date.now.timeIntervalSince(started)
        server.route("/big.json", .init(body: data))
        let source = try repositories.addSource(name: "", address: server.url("/big.json").absoluteString)
        let refresh = Task { await repositories.refresh(source.id) }
        var longest: TimeInterval = 0
        var turns = 0
        let loading = Date.now
        while repositories.catalog(source.id) == nil, Date.now.timeIntervalSince(loading) < 60 {
            let before = Date.now
            try await Task.sleep(for: .milliseconds(2))
            longest = max(longest, Date.now.timeIntervalSince(before))
            turns += 1
        }
        await refresh.value
        #expect(repositories.catalog(source.id)?.entries.count == 30)
        // the main actor kept getting turns while the catalog was read
        #expect(parse > 0.08, "the parse took \(parse) s: too quick to tell")
        #expect(longest < parse / 2, "longest main-actor wait \(longest) s, parse \(parse) s, \(turns) turns")
    }

    @Test func aRetryLeavesAConflictingFileAndStaysFailed() async throws {
        for kind in ["file", "folder", "link"] {
            let (repositories, root, _) = try repositories()
            let data = Self.bytes(300_000)
            let source = try await serve(repositories, files: [:], packages: [package("Mine.nsp", data)])
            server.route("/files/Mine.nsp", .init(body: data, chunk: 16 * 1024, delay: 0.01))
            let job = try repositories.download(source: source.id, entry: "example")
            let folder = root.appending(path: job.folder)
            let target = folder.appending(path: "Mine.nsp")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            switch kind {
            case "file": try Data("the player's own file, 25b".utf8.prefix(25)).write(to: target)
            case "folder": try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            default: try FileManager.default.createSymbolicLink(at: target, withDestinationURL: try self.folder())
            }
            try await wait { repositories.job(job.id)?.state.isActive == false }
            #expect(repositories.job(job.id)?.state == .failed, "\(kind)")
            server.route("/files/Mine.nsp", .init(body: data))
            #expect {
                try repositories.retry(job.id)
            } throws: { ($0 as? Repositories.Failure)?.status == 409 }
            #expect(repositories.job(job.id)?.state == .failed, "\(kind)")
            if kind == "file" {
                #expect(try Data(contentsOf: target) == Data("the player's own file, 25b".utf8.prefix(25)))
            }
            #expect(staging(root).isEmpty)
        }
    }

    @Test func aRetryKeepsWhatThisDownloadPublishedAcrossLaunches() async throws {
        let state = try folder().appending(path: "downloads.json")
        let (repositories, root, _) = try repositories(stateFile: state)
        let first = Self.bytes(2000, seed: 1)
        let second = Self.bytes(300_000, seed: 2)
        let source = try await serve(
            repositories, files: ["A.nsp": first], packages: [package("A.nsp", first), package("B.nsp", second)])
        server.route("/files/B.nsp", .init(body: second, chunk: 16 * 1024, delay: 0.01))
        let job = try repositories.download(source: source.id, entry: "example")
        let folder = root.appending(path: job.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("player's B".utf8).write(to: folder.appending(path: "B.nsp"))
        try await wait { repositories.job(job.id)?.state.isActive == false }
        // A went in, B didn't
        #expect(repositories.job(job.id)?.state == .failed)
        #expect(try Data(contentsOf: folder.appending(path: "A.nsp")) == first)
        #expect(repositories.job(job.id)?.files.first?.published != nil)

        // the next launch knows A is this download's; B is still a conflict
        let next = Repositories(defaults: defaults(), credentials: MemoryCredentials(), stateFile: state)
        next.root = { root }
        next.freeSpace = { _ in 1 << 50 }
        #expect(next.job(job.id)?.files.first?.published == repositories.job(job.id)?.files.first?.published)
        next.sources = repositories.sources
        await next.refresh(source.id)
        #expect(throws: Repositories.Failure.self) { try next.retry(job.id) }
        #expect(next.job(job.id)?.state == .failed)

        // the player moves their B away: only B downloads, and A is kept as it is
        try FileManager.default.removeItem(at: folder.appending(path: "B.nsp"))
        server.route("/files/B.nsp", .init(body: second))
        let fetchedA = server.requests("/files/A.nsp").count
        let again = try next.retry(job.id)
        #expect(again.bytesDone == 2000)
        try await wait { next.job(job.id)?.state.isActive == false }
        #expect(next.job(job.id)?.state == .succeeded, "\(next.job(job.id)?.message ?? "")")
        #expect(server.requests("/files/A.nsp").count == fetchedA)
        #expect(try Data(contentsOf: folder.appending(path: "A.nsp")) == first)
        #expect(try Data(contentsOf: folder.appending(path: "B.nsp")) == second)
    }

    @Test func aFileReplacedSinceItWasPublishedIsAConflict() async throws {
        let (repositories, root, _) = try repositories()
        let first = Self.bytes(2000, seed: 1)
        let second = Self.bytes(300_000, seed: 2)
        let source = try await serve(
            repositories, files: ["A.nsp": first], packages: [package("A.nsp", first), package("B.nsp", second)])
        server.route("/files/B.nsp", .init(body: second, chunk: 16 * 1024, delay: 0.01))
        let job = try repositories.download(source: source.id, entry: "example")
        let folder = root.appending(path: job.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("player's B".utf8).write(to: folder.appending(path: "B.nsp"))
        try await wait { repositories.job(job.id)?.state.isActive == false }
        // A is replaced by another file (of the same size) and B is moved away
        try FileManager.default.removeItem(at: folder.appending(path: "A.nsp"))
        try Self.bytes(2000, seed: 5).write(to: folder.appending(path: "A.nsp"))
        try FileManager.default.removeItem(at: folder.appending(path: "B.nsp"))
        #expect {
            try repositories.retry(job.id)
        } throws: { ($0 as? Repositories.Failure)?.status == 409 }
        #expect(repositories.job(job.id)?.state == .failed)
        #expect(try Data(contentsOf: folder.appending(path: "A.nsp")) == Self.bytes(2000, seed: 5))
    }

    @Test func anUpdateFromAnotherCatalogGoesBesideAnUnbuiltBaseGame() async throws {
        let library = Library(defaults: defaults(), isScreenshot: true)
        let root = try folder()
        library.root = root
        let repositories = library.repositories
        repositories.freeSpace = { _ in 1 << 50 }
        let base = Self.bytes(3000, seed: 1)
        let update = Self.bytes(2000, seed: 2)
        let dlc = Self.bytes(1000, seed: 3)
        server.route("/files/Base.nsp", .init(body: base))
        server.route("/files/Update.nsp", .init(body: update))
        server.route("/files/Extra.nsp", .init(body: dlc))
        server.route("/one.json", .init(body: catalog([package("Base.nsp", base)], name: "Example Game")))
        server.route("/two.json", .init(body: catalog(
            [package("Update.nsp", update, kind: "update")], name: "Same Game Different Catalog Name")))
        let one = try repositories.addSource(name: "One", address: server.url("/one.json").absoluteString)
        let two = try repositories.addSource(name: "Two", address: server.url("/two.json").absoluteString)
        await repositories.refreshAll()

        let job = try repositories.download(source: one.id, entry: "example")
        try await wait { repositories.job(job.id)?.state.isActive == false }
        #expect(repositories.job(job.id)?.state == .succeeded)
        // the real scanner: a game of files only, no build, so no title ID from it
        let game = try #require(library.games.first { $0.folder.lastPathComponent == job.folder })
        #expect(game.titleID == nil)
        // the download history is gone (another Mac, or trimmed): the folder's name still says which game it is
        let fresh = Library(defaults: defaults(), isScreenshot: true)
        fresh.root = root
        let entry = try #require(repositories.catalog(two.id)?.entries.first)
        #expect(fresh.repositories.folder(for: entry) == "Example Game [0100000000010000]")

        let second = try repositories.download(source: two.id, entry: "example")
        #expect(second.folder == "Example Game [0100000000010000]")
        try await wait { repositories.job(second.id)?.state.isActive == false }
        #expect(try Data(contentsOf: root.appending(path: job.folder).appending(path: "Update.nsp")) == update)
        #expect(library.games.count == 1)

        // a folder the player copied in, named their way, found by its game file's name
        let copied = try folder()
        let mine = copied.appending(path: "My Copy")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try Data("dump".utf8).write(to: mine.appending(path: "Example [0100000000010000][v0].nsp"))
        let other = Library(defaults: defaults(), isScreenshot: true)
        other.root = copied
        server.route("/three.json", .init(body: catalog([package("Extra.nsp", dlc, kind: "dlc")], name: "Extra Name")))
        let three = try other.repositories.addSource(name: "", address: server.url("/three.json").absoluteString)
        await other.repositories.refresh(three.id)
        let extra = try #require(other.repositories.catalog(three.id)?.entries.first)
        #expect(other.repositories.folder(for: extra) == "My Copy")
        // a DLC's or update's own title ID counts for its base game
        #expect(Library.titleFolderIndex(other.games)["0100000000010000"] == "My Copy")
        try FileManager.default.moveItem(
            at: mine.appending(path: "Example [0100000000010000][v0].nsp"),
            to: mine.appending(path: "Example Update [0100000000010800][v65536].nsp"))
        other.refresh()
        #expect(other.repositories.folder(for: extra) == "My Copy")
    }

    @Test func anUpdateQueuedWhileItsBaseDownloadsGoesToTheSameFolder() async throws {
        let (repositories, _, _) = try repositories()
        let base = Self.bytes(400_000, seed: 1)
        let update = Self.bytes(1000, seed: 2)
        server.route("/files/Base.nsp", .init(body: base, chunk: 16 * 1024, delay: 0.02))
        server.route("/files/Update.nsp", .init(body: update))
        server.route("/a.json", .init(body: catalog([package("Base.nsp", base)], name: "Example Game")))
        server.route("/b.json", .init(body: catalog([package("Update.nsp", update, kind: "update")], name: "Renamed")))
        let a = try repositories.addSource(name: "A", address: server.url("/a.json").absoluteString)
        let b = try repositories.addSource(name: "B", address: server.url("/b.json").absoluteString)
        await repositories.refreshAll()
        let first = try repositories.download(source: a.id, entry: "example")
        let second = try repositories.download(source: b.id, entry: "example")
        #expect(second.folder == first.folder)
        try await wait { !repositories.isActive }
        #expect(repositories.job(second.id)?.state == .succeeded)
    }

    // MARK: - Switch 2 dumps

    /// Lays out a synthetic Switch 2 dump (GameDump: base/exefs/main.npdm naming the title, base/romfs) in `folder`.
    private static func makeDump(_ folder: URL, titleID: UInt64 = 0x0100_0000_0001_0000) throws {
        let exefs = folder.appending(path: "base/exefs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: exefs, withIntermediateDirectories: true)
        try GameDumpTests.npdm(programID: titleID).write(to: exefs.appending(path: "main.npdm"))
        try FileManager.default.createDirectory(
            at: folder.appending(path: "base/romfs", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appending(path: "base/romfs/a.bin"))
    }

    /// nxnative's choice between a dump and packages (build_ipa_from_nsp.py's dump_folder): the folder is a dump
    /// (pack_dump.is_dump) and has no NSP, XCI, NSZ or XCZ of its own.
    private static func nxnativeBuildsAsDump(_ folder: URL) -> Bool {
        GameDump.isDump(folder)
            && !GameScanner.children(of: folder).contains {
                GameScanner.packageExtensions.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("._")
            }
    }

    private func packageFiles(_ folder: URL) -> [String] {
        GameScanner.children(of: folder).map(\.lastPathComponent).filter {
            GameScanner.packageExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }
    }

    @Test func anUpdateForASwitch2DumpIsRefusedAndTheDumpStaysADump() async throws {
        // the real scanner names the unbuilt dump by its NPDM, so the library's index finds it for the title
        let library = Library(defaults: defaults(), isScreenshot: true)
        let root = try folder()
        let dump = root.appending(path: "Fast Game", directoryHint: .isDirectory)
        try Self.makeDump(dump)
        library.root = root
        let repositories = library.repositories
        repositories.freeSpace = { _ in 1 << 50 }
        let game = try #require(library.games.first { $0.folder.lastPathComponent == "Fast Game" })
        #expect(game.isDump && game.titleID == Self.titleID)
        #expect(Library.titleFolderIndex(library.games)[Self.titleID] == "Fast Game")
        #expect(Self.nxnativeBuildsAsDump(dump))

        let update = Self.bytes(4000, seed: 4)
        server.route("/files/Update.nsp", .init(body: update))
        server.route("/dump.json", .init(body: catalog([package("Update.nsp", update, kind: "update")], name: "Other Name")))
        let source = try repositories.addSource(name: "Shelf", address: server.url("/dump.json").absoluteString)
        await repositories.refresh(source.id)
        let entry = try #require(repositories.catalog(source.id)?.entries.first)
        // the dump is where the title's files would go…
        #expect(repositories.folder(for: entry) == "Fast Game")
        // …so the download is refused, saying why, before anything is fetched or queued
        #expect {
            try repositories.download(source: source.id, entry: "example")
        } throws: { error in
            let failure = error as? Repositories.Failure
            return failure?.status == 409 && failure?.message.contains("Switch 2 dump") == true
        }
        #expect(repositories.downloads.isEmpty)
        #expect(server.requests("/files/Update.nsp").isEmpty)
        #expect(packageFiles(dump).isEmpty)
        #expect(staging(root).isEmpty)
        // what NX Play shows and what nxnative builds still agree: a dump
        library.refresh()
        #expect(library.games.first { $0.folder.lastPathComponent == "Fast Game" }?.isDump == true)
        #expect(Self.nxnativeBuildsAsDump(dump))
        #expect(library.games.count == 1)
    }

    @Test func aFolderThatBecomesADumpWhileTheDownloadWaitsGetsNothing() async throws {
        let (repositories, root, _) = try repositories()
        let data = Self.bytes(400_000, seed: 6)
        let source = try await serve(repositories, files: [:], packages: [package("Late.nsp", data, kind: "update")])
        server.route("/files/Late.nsp", .init(body: data, chunk: 16 * 1024, delay: 0.05))
        let job = try repositories.download(source: source.id, entry: "example")
        try await wait("for it to start") { repositories.job(job.id)?.state == .running && !staging(root).isEmpty }
        #expect(repositories.job(job.id)?.state == .running)
        // the player copies a dump of the game in where the download is going
        let folder = root.appending(path: job.folder, directoryHint: .isDirectory)
        try Self.makeDump(folder)
        try await wait("for the download to stop") { repositories.job(job.id)?.state.isActive == false }
        let stopped = try #require(repositories.job(job.id))
        #expect(stopped.state == .failed)
        #expect(stopped.message?.contains("Switch 2 dump") == true)
        #expect(stopped.files.allSatisfy { $0.published == nil })
        #expect(packageFiles(folder).isEmpty)
        #expect(staging(root).isEmpty)
        #expect(Self.nxnativeBuildsAsDump(folder))

        // Retry is refused the same way, and the dump stays as it is
        server.route("/files/Late.nsp", .init(body: data))
        #expect {
            try repositories.retry(job.id)
        } throws: { ($0 as? Repositories.Failure)?.status == 409 }
        #expect(repositories.job(job.id)?.state == .failed)
        #expect(packageFiles(folder).isEmpty)
        #expect(Self.nxnativeBuildsAsDump(folder))
    }

    @Test func aWaitingDownloadWhoseFolderBecameADumpNeverStarts() async throws {
        let (repositories, root, _) = try repositories()
        let first = Self.bytes(400_000, seed: 1)
        let second = Self.bytes(2000, seed: 2)
        server.route("/files/First.nsp", .init(body: first, chunk: 16 * 1024, delay: 0.02))
        server.route("/files/Second.nsp", .init(body: second))
        server.route("/first.json", .init(body: catalog([package("First.nsp", first)], id: "first", name: "First")))
        server.route("/second.json", .init(body: catalog(
            [package("Second.nsp", second, kind: "update")], id: "second", name: "Second")))
        let a = try repositories.addSource(name: "A", address: server.url("/first.json").absoluteString)
        let b = try repositories.addSource(name: "B", address: server.url("/second.json").absoluteString)
        await repositories.refreshAll()
        let running = try repositories.download(source: a.id, entry: "first")
        let waiting = try repositories.download(source: b.id, entry: "second")
        // the same title: the update waits to go into the folder the base game is going to
        #expect(waiting.folder == running.folder)
        #expect(repositories.job(waiting.id)?.state == .queued)
        try await wait("for the first to start") { !staging(root).isEmpty }
        // while it waits, the player copies a dump of the game in there and stops the base game's download
        let folder = root.appending(path: waiting.folder, directoryHint: .isDirectory)
        try Self.makeDump(folder)
        repositories.cancel(running.id)
        try await wait("for the cancel") { repositories.job(running.id)?.state == .cancelled }
        try await wait("for the waiting one") { repositories.job(waiting.id)?.state.isActive == false }
        #expect(repositories.job(waiting.id)?.state == .failed)
        #expect(repositories.job(waiting.id)?.message?.contains("Switch 2 dump") == true)
        #expect(server.requests("/files/Second.nsp").isEmpty)
        #expect(packageFiles(folder).isEmpty)
        #expect(Self.nxnativeBuildsAsDump(folder))
    }

    @Test func aFinishedDownloadsFolderReplacedByADumpIsntReused() async throws {
        let (repositories, root, _) = try repositories()
        let base = Self.bytes(3000, seed: 1)
        let update = Self.bytes(1000, seed: 2)
        server.route("/files/Base.nsp", .init(body: base))
        server.route("/files/Update.nsp", .init(body: update))
        server.route("/base.json", .init(body: catalog([package("Base.nsp", base)], name: "Example Game")))
        server.route("/update.json", .init(body: catalog([package("Update.nsp", update, kind: "update")], name: "Renamed")))
        let a = try repositories.addSource(name: "A", address: server.url("/base.json").absoluteString)
        let b = try repositories.addSource(name: "B", address: server.url("/update.json").absoluteString)
        await repositories.refreshAll()
        let job = try repositories.download(source: a.id, entry: "example")
        try await wait { repositories.job(job.id)?.state.isActive == false }
        #expect(repositories.job(job.id)?.state == .succeeded)
        // the player swaps the package for a dump of the game, in the same folder; no library knows of it here
        let folder = root.appending(path: job.folder, directoryHint: .isDirectory)
        try FileManager.default.removeItem(at: folder.appending(path: "Base.nsp"))
        try Self.makeDump(folder)
        let entry = try #require(repositories.catalog(b.id)?.entries.first)
        #expect(repositories.folder(for: entry) == job.folder)  // the download history still points there
        #expect {
            try repositories.download(source: b.id, entry: "example")
        } throws: { ($0 as? Repositories.Failure)?.status == 409 }
        #expect(server.requests("/files/Update.nsp").isEmpty)
        #expect(Self.nxnativeBuildsAsDump(folder))
    }

    @Test func aRetryWithEveryFileInAlreadyNeedsNoRoom() async throws {
        let (repositories, root, _) = try repositories()
        let data = Self.bytes(5000, seed: 3)
        let source = try await serve(repositories, files: ["Done.nsp": data], packages: [package("Done.nsp", data)])
        let job = try repositories.download(source: source.id, entry: "example")
        try await wait { repositories.job(job.id)?.state.isActive == false }
        var stopped = try #require(repositories.job(job.id))
        #expect(stopped.state == .succeeded)
        #expect(stopped.files.allSatisfy { $0.published != nil })
        // stopped after its files went in (cancelled while it checked them), with the disk nearly full since
        stopped.state = .cancelled
        stopped.finished = .now
        repositories.downloads = [stopped]
        repositories.freeSpace = { _ in 1_000_000 }
        let fetched = server.requests("/files/Done.nsp").count
        let again = try repositories.retry(job.id)
        #expect(again.remainingBytes == 0)
        try await wait { repositories.job(job.id)?.state.isActive == false }
        #expect(repositories.job(job.id)?.state == .succeeded, "\(repositories.job(job.id)?.message ?? "")")
        #expect(server.requests("/files/Done.nsp").count == fetched)
        #expect(try Data(contentsOf: root.appending(path: job.folder).appending(path: "Done.nsp")) == data)

        // a file still to fetch needs its room as before
        stopped.files[0].published = nil
        stopped.bytesDone = 0
        repositories.downloads = [stopped]
        try FileManager.default.removeItem(at: root.appending(path: job.folder).appending(path: "Done.nsp"))
        #expect {
            try repositories.retry(job.id)
        } throws: { ($0 as? Repositories.Failure)?.status == 507 }
    }

    @Test func aRedirectedCatalogsFilesResolveWhereItWent() async throws {
        let (repositories, root, _) = try repositories()
        let data = Self.bytes(3000)
        // the same server, another folder: the token still goes
        server.route("/old/catalog.json", .init(status: 301, headers: ["Location": server.url("/v2/catalog.json").absoluteString]))
        server.route("/v2/catalog.json", .init(body: catalog([package("R.nsp", data, url: "files/R.nsp")])))
        server.route("/v2/files/R.nsp", .init(body: data))
        let source = try repositories.addSource(name: "", address: server.url("/old/catalog.json").absoluteString, token: "tok")
        await repositories.refresh(source.id)
        let listed = try #require(repositories.catalog(source.id)?.entries.first?.packages.first)
        #expect(listed.url == server.url("/v2/files/R.nsp"))
        let job = try repositories.download(source: source.id, entry: "example")
        try await wait { repositories.job(job.id)?.state.isActive == false }
        #expect(repositories.job(job.id)?.state == .succeeded, "\(repositories.job(job.id)?.message ?? "")")
        #expect(server.requests("/v2/files/R.nsp").last?.headers["authorization"] == "Bearer tok")
        #expect(server.requests("/files/R.nsp").isEmpty)
        #expect(try Data(contentsOf: root.appending(path: job.folder).appending(path: "R.nsp")) == data)

        // another server: the files are there too, and the token stays with the source's own origin
        let (others, _, _) = try self.repositories()
        server.route("/x/catalog.json", .init(status: 302, headers: [
            "Location": server.url("/v3/catalog.json", host: "localhost").absoluteString,
        ]))
        server.route("/v3/catalog.json", .init(body: catalog([package("C.nsp", data, url: "files/C.nsp")])))
        server.route("/v3/files/C.nsp", .init(body: data))
        let moved = try others.addSource(name: "", address: server.url("/x/catalog.json").absoluteString, token: "tok2")
        await others.refresh(moved.id)
        let elsewhere = try #require(others.catalog(moved.id)?.entries.first?.packages.first)
        #expect(elsewhere.url == server.url("/v3/files/C.nsp", host: "localhost"))
        let second = try others.download(source: moved.id, entry: "example")
        try await wait { others.job(second.id)?.state.isActive == false }
        #expect(others.job(second.id)?.state == .succeeded)
        #expect(server.requests("/x/catalog.json").last?.headers["authorization"] == "Bearer tok2")
        #expect(server.requests("/v3/catalog.json").last?.headers["authorization"] == nil)
        #expect(server.requests("/v3/files/C.nsp").last?.headers["authorization"] == nil)
        #expect(others.source(moved.id)?.url == server.url("/x/catalog.json"))
    }

    @Test func allSourcesTellsTheSameEntryInTwoSourcesApart() async throws {
        let (repositories, _, _) = try repositories()
        let data = Self.bytes(100)
        server.route("/first.json", .init(body: catalog([package("A.nsp", data)])))
        server.route("/second.json", .init(body: catalog([package("A.nsp", data)])))
        let first = try repositories.addSource(name: "First", address: server.url("/first.json").absoluteString)
        let second = try repositories.addSource(name: "Second", address: server.url("/second.json").absoluteString)
        await repositories.refreshAll()
        let rows = repositories.entries(source: nil)
        #expect(rows.map(\.entry.id) == ["example", "example"])
        #expect(Set(rows.map(\.id)) == [
            EntryKey(source: first.id, entry: "example"), EntryKey(source: second.id, entry: "example"),
        ])
    }

    // MARK: - Keychain failures

    /// A Keychain with set statuses, in memory: never the real one.
    final class FakeKeychain: @unchecked Sendable {
        var items: [String: Data] = [:]
        var statuses: [String: OSStatus] = [:]
        var calls: [String] = []
        let lock = NSLock()

        var api: KeychainCredentials.API {
            KeychainCredentials.API(
                copyMatching: { query in
                    self.lock.withLock {
                        self.calls.append("copy")
                        if let status = self.statuses["copy"] { return (status, nil) }
                        let data = self.items[query[kSecAttrAccount as String] as! String]
                        return (data == nil ? errSecItemNotFound : errSecSuccess, data)
                    }
                },
                add: { item in
                    self.lock.withLock {
                        self.calls.append("add")
                        if let status = self.statuses["add"] { return status }
                        let account = item[kSecAttrAccount as String] as! String
                        guard self.items[account] == nil else { return errSecDuplicateItem }
                        self.items[account] = item[kSecValueData as String] as? Data
                        return errSecSuccess
                    }
                },
                update: { query, change in
                    self.lock.withLock {
                        self.calls.append("update")
                        if let status = self.statuses["update"] { return status }
                        let account = query[kSecAttrAccount as String] as! String
                        guard self.items[account] != nil else { return errSecItemNotFound }
                        self.items[account] = change[kSecValueData as String] as? Data
                        return errSecSuccess
                    }
                },
                delete: { query in
                    self.lock.withLock {
                        self.calls.append("delete")
                        if let status = self.statuses["delete"] { return status }
                        let account = query[kSecAttrAccount as String] as! String
                        return self.items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
                    }
                })
        }
    }

    @Test func theKeychainReplacesATokenInPlaceAndSaysWhenItCant() throws {
        let fake = FakeKeychain()
        let keychain = KeychainCredentials(api: fake.api)
        #expect(try keychain.token(for: "s") == nil)
        try keychain.setToken("one", for: "s")
        #expect(fake.calls == ["copy", "update", "add"])
        #expect(try keychain.token(for: "s") == "one")

        // a replacement updates the item: never deleted first
        fake.calls = []
        try keychain.setToken("two", for: "s")
        #expect(fake.calls == ["update"])
        #expect(try keychain.token(for: "s") == "two")

        // a refused update throws, and the old token stays
        fake.calls = []
        fake.statuses["update"] = errSecAuthFailed
        #expect(throws: KeychainFailure(status: errSecAuthFailed, action: "save")) {
            try keychain.setToken("three", for: "s")
        }
        #expect(!fake.calls.contains("delete") && !fake.calls.contains("add"))
        fake.statuses = [:]
        #expect(try keychain.token(for: "s") == "two")

        // a refused add throws
        fake.statuses["add"] = errSecNotAvailable
        #expect(throws: KeychainFailure.self) { try keychain.setToken("new", for: "other") }
        fake.statuses = [:]
        #expect(try keychain.token(for: "other") == nil)

        // a token added in between: replaced
        fake.calls = []
        fake.items["race"] = Data("theirs".utf8)
        try KeychainCredentials(api: KeychainCredentials.API(
            copyMatching: fake.api.copyMatching, add: fake.api.add,
            update: { query, change in
                // the first update sees nothing yet
                fake.lock.withLock { fake.calls.append("update") }
                return fake.calls.filter { $0 == "update" }.count == 1 ? errSecItemNotFound : fake.api.update(query, change)
            }, delete: fake.api.delete)
        ).setToken("mine", for: "race")
        #expect(try keychain.token(for: "race") == "mine")

        // a read that fails isn't "no token"
        fake.statuses["copy"] = errSecInteractionNotAllowed
        #expect(throws: KeychainFailure(status: errSecInteractionNotAllowed, action: "read")) {
            try keychain.token(for: "s")
        }
        fake.statuses = [:]

        // deleting: a missing token is fine, a refusal isn't
        try keychain.setToken(nil, for: "nothing")
        try keychain.setToken("", for: "s")
        #expect(try keychain.token(for: "s") == nil)
        fake.statuses["delete"] = errSecAuthFailed
        #expect(throws: KeychainFailure.self) { try keychain.setToken(nil, for: "other") }
        #expect(KeychainFailure(status: errSecAuthFailed, action: "save").localizedDescription.contains("-25293"))
    }

    @Test func aKeychainFailureIsShownNeverTakenForSuccessOrNoToken() async throws {
        let (repositories, _, credentials) = try repositories()
        credentials.failure = KeychainFailure(status: errSecInteractionNotAllowed, action: "save")
        #expect {
            try repositories.addSource(name: "", address: server.url("/kc.json").absoluteString, token: "tok")
        } throws: { ($0 as? Repositories.Failure)?.message.contains("Keychain") == true }
        #expect(repositories.sources.isEmpty)

        credentials.failure = nil
        server.route("/kc.json", .init(body: catalog([package("K.nsp", Self.bytes(10))])))
        let source = try repositories.addSource(name: "", address: server.url("/kc.json").absoluteString, token: "old")
        credentials.failure = KeychainFailure(status: errSecAuthFailed, action: "save")
        #expect(throws: Repositories.Failure.self) { try repositories.setToken("new", for: source.id) }
        #expect(repositories.tokenState(source.id) == .unreadable(credentials.failure!.localizedDescription))

        // a token that can't be read: the catalog isn't asked for without it
        await repositories.refresh(source.id)
        guard case .failed(let message) = repositories.states[source.id] else {
            Issue.record("loaded without its token")
            return
        }
        #expect(message.contains("Access Token"))
        #expect(server.requests("/kc.json").isEmpty)

        credentials.failure = nil
        #expect(try credentials.token(for: source.id) == "old")
        #expect(repositories.tokenState(source.id) == .saved)
        await repositories.refresh(source.id)
        #expect(server.requests("/kc.json").last?.headers["authorization"] == "Bearer old")

        credentials.failure = KeychainFailure(status: errSecAuthFailed, action: "delete")
        #expect(throws: Repositories.Failure.self) { try repositories.removeSource(source.id) }
        #expect(repositories.sources.isEmpty)
    }
    /// A source saved before the address rules (plain http to a public address) never sends its token: the rule
    /// stops it before any request, with the rule's own words. TEST-NET-3, which no network routes: even a
    /// regression can't reach anyone.
    @Test func savedPublicHTTPSourceFailsBeforeTransfer() async throws {
        let saved = defaults()
        let url = URL(string: "http://203.0.113.5/catalog.json")!
        let policy = try #require(RepositoryAddress.problem(with: url))
        let source = RepositorySource(name: "Old", url: url)
        saved.set([source.plist], forKey: Repositories.sourcesKey)
        let credentials = MemoryCredentials()
        try credentials.setToken("synthetic-token", for: source.id)
        let repositories = Repositories(defaults: saved, credentials: credentials, stateFile: nil)
        let started = Date.now
        await repositories.refresh(source.id)
        #expect(repositories.states[source.id] == .failed(policy))
        #expect(Date.now.timeIntervalSince(started) < 1)  // no connection was tried
        await #expect {
            try await RepositoryTransfer.data(
                from: url, auth: SourceAuth(origin: try #require(RepositoryOrigin(url)), token: "synthetic-token"),
                limit: 100)
        } throws: { ($0 as? RepositoryTransfer.Failure)?.message == policy }
    }

    @Test func publishedContentMustMatchEvenWithUnchangedIdentity() async throws {
        for algorithm in Checksum.Algorithm.allCases {
            let root = try folder()
            let gameFolder = "Synthetic"
            let dir = root.appending(path: gameFolder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: "A.nsp")
            let original = Data("good".utf8)
            try original.write(to: url)
            guard case .file(let identity) = DownloadFiles.find(root: root, folder: gameFolder, filename: "A.nsp") else {
                Issue.record("missing fixture"); return
            }
            let checksum = Self.checksum(original, algorithm)
            try await DownloadFiles.verifyPublished(root: root, folder: gameFolder, filename: "A.nsp", identity: identity, bytes: 4, checksum: checksum)
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: Data("evil".utf8))
            try handle.close()
            #expect(DownloadFiles.find(root: root, folder: gameFolder, filename: "A.nsp") == .file(identity))
            await #expect {
                try await DownloadFiles.verifyPublished(root: root, folder: gameFolder, filename: "A.nsp", identity: identity, bytes: 4, checksum: checksum)
            } throws: { ($0 as? DownloadFiles.Failure)?.message.contains(algorithm.label) == true }
        }
    }

    // MARK: - SHA-1 checksums

    private static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func checksum(_ data: Data, _ algorithm: Checksum.Algorithm) -> Checksum {
        Checksum(algorithm, hex: algorithm == .sha256 ? sha(data) : sha1(data))!
    }

    /// A package with only the SHA-1 an archive publishes.
    private func sha1Package(_ filename: String, _ data: Data, kind: String = "base", sha1: String? = nil) -> [String: Any] {
        var object = package(filename, data, kind: kind)
        object["sha256"] = nil
        object["sha1"] = sha1 ?? Self.sha1(data)
        return object
    }

    private func parsePackages(_ packages: [[String: Any]]) throws -> CatalogEntry? {
        let data = try JSONSerialization.data(withJSONObject: [
            "nxplayCatalog": 1, "entries": [["name": "A", "titleID": Self.titleID, "packages": packages]],
        ] as [String: Any])
        return try Catalog.parse(data, base: URL(string: "https://archive.example/catalog.json")!).entries.first
    }

    @Test func checksumsHashWithTheAlgorithmTheyName() {
        var sha256 = Checksum.Hasher(.sha256)
        var sha1 = Checksum.Hasher(.sha1)
        for part in ["a", "bc"] {
            sha256.update(data: Data(part.utf8))
            sha1.update(data: Data(part.utf8))
        }
        #expect(sha256.finalize() == Checksum(.sha256, hex: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        #expect(sha1.finalize() == Checksum(.sha1, hex: "A9993E364706816ABA3E25717850C26C9CD0D89D"))
        #expect(sha1.finalize().id == "sha1:a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(sha256.finalize().id == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Checksum.Algorithm.sha1.label == "SHA-1")
        #expect(Checksum.Algorithm.sha256.label == "SHA-256")
    }

    @Test func aCatalogNamesEachFilesChecksumAndRefusesBadOnes() throws {
        let data = Self.bytes(10)
        let sha1Only = try #require(try parsePackages([sha1Package("A.nsp", data)]))
        #expect(sha1Only.packages.first?.checksum == Checksum(.sha1, hex: Self.sha1(data)))
        #expect(sha1Only.packages.first?.id == "sha1:\(Self.sha1(data))")
        // both: the SHA-256 is the one checked, and the package keeps the id it always had
        var both = package("B.nsp", data)
        both["sha1"] = Self.sha1(data)
        let withBoth = try #require(try parsePackages([both]))
        #expect(withBoth.packages.first?.checksum.algorithm == .sha256)
        #expect(withBoth.packages.first?.id == Self.sha(data))

        func refused(_ change: (inout [String: Any]) -> Void) throws -> String? {
            var object = package("C.nsp", data)
            change(&object)
            let entry = try parsePackages([object, package("Fine.nsp", Self.bytes(3))])
            #expect(entry?.packages.map(\.filename) == ["Fine.nsp"])
            return entry?.issues.first
        }
        // no checksum at all, or only one NX Play doesn't check
        #expect(try refused { $0["sha256"] = nil }?.contains("no \"sha256\" or \"sha1\"") == true)
        #expect(try refused { $0["sha256"] = nil; $0["md5"] = String(repeating: "a", count: 32) }?.contains("no \"sha256\" or \"sha1\"") == true)
        // malformed SHA-1s
        for bad: Any in [String(repeating: "a", count: 39), String(repeating: "a", count: 41), String(repeating: "g", count: 40),
                         String(repeating: "１", count: 40), " " + String(repeating: "a", count: 39), 1234, NSNull()] {
            #expect(try refused { $0["sha256"] = nil; $0["sha1"] = bad }?.contains("\"sha1\" isn't 40 hex digits") == true, "\(bad)")
        }
        // a SHA-256's length isn't a SHA-1, nor the other way round
        #expect(try refused { $0["sha256"] = nil; $0["sha1"] = Self.sha(data) }?.contains("\"sha1\"") == true)
        #expect(try refused { $0["sha256"] = Self.sha1(data) }?.contains("\"sha256\" isn't 64 hex digits") == true)
        // a bad SHA-256 isn't passed over for a good SHA-1, nor a bad SHA-1 beside a good SHA-256
        #expect(try refused { $0["sha256"] = "xyz"; $0["sha1"] = Self.sha1(data) }?.contains("\"sha256\"") == true)
        #expect(try refused { $0["sha1"] = "xyz" }?.contains("\"sha1\"") == true)
    }

    @Test func aSHA1FileIsCheckedThenPublished() async throws {
        let (repositories, root, _) = try repositories()
        let data = Self.bytes(300_000, seed: 3)
        let source = try await serve(repositories, files: ["Archive.nsp": data], packages: [sha1Package("Archive.nsp", data)])
        let job = try repositories.download(source: source.id, entry: "example")
        #expect(job.files.first?.checksum.algorithm == .sha1)
        try await wait("for the download") { repositories.job(job.id)?.state.isActive == false }
        let done = try #require(repositories.job(job.id))
        #expect(done.state == .succeeded, "\(done.message ?? "")")
        #expect(try Data(contentsOf: root.appending(path: job.folder).appending(path: "Archive.nsp")) == data)
        #expect(staging(root).isEmpty)
    }

    @Test func aSHA1MismatchPutsNothingInTheLibrary() async throws {
        let (repositories, root, _) = try repositories()
        let data = Self.bytes(50_000)
        // the file's SHA-256 written as if it were its SHA-1 can't pass either: the lengths differ, and a SHA-1 of
        // other bytes must not match
        let source = try await serve(
            repositories, files: ["Bad.nsp": data], packages: [sha1Package("Bad.nsp", data, sha1: Self.sha1(Self.bytes(50_000, seed: 8)))])
        let job = try repositories.download(source: source.id, entry: "example")
        try await wait { repositories.job(job.id)?.state.isActive == false }
        let done = try #require(repositories.job(job.id))
        #expect(done.state == .failed)
        #expect(done.message?.contains("doesn't match its SHA-1") == true, "\(done.message ?? "")")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: job.folder).appending(path: "Bad.nsp").path))
        #expect(staging(root).isEmpty)
    }

    /// The review's P2a, through Retry, for each algorithm: A published, B collides, A rewritten in place (same inode
    /// and size, other bytes), B moved away. Retry fails on A, hashed with A's own algorithm, before B is asked for;
    /// with A's bytes put back, Retry finishes, which a check by the wrong algorithm couldn't.
    @Test func aRetryRehashesPublishedFilesWithTheirOwnAlgorithm() async throws {
        for algorithm in Checksum.Algorithm.allCases {
            let state = try folder().appending(path: "downloads.json")
            let (repositories, root, credentials) = try repositories(stateFile: state)
            let first = Self.bytes(2000, seed: 1)
            let second = Self.bytes(300_000, seed: 2)
            let packages = algorithm == .sha1
                ? [sha1Package("A.nsp", first), sha1Package("B.nsp", second)]
                : [package("A.nsp", first), package("B.nsp", second)]
            let source = try await serve(
                repositories, files: ["A.nsp": first], packages: packages, token: "synthetic-\(algorithm)-token")
            server.route("/files/B.nsp", .init(body: second, chunk: 16 * 1024, delay: 0.01))
            let job = try repositories.download(source: source.id, entry: "example")
            let folder = root.appending(path: job.folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("player's B".utf8).write(to: folder.appending(path: "B.nsp"))
            try await wait { repositories.job(job.id)?.state.isActive == false }
            #expect(repositories.job(job.id)?.state == .failed)
            let identity = try #require(repositories.job(job.id)?.files.first?.published)

            // A rewritten in place: same file, same size, other bytes
            let handle = try FileHandle(forWritingTo: folder.appending(path: "A.nsp"))
            try handle.write(contentsOf: Self.bytes(2000, seed: 6))
            try handle.close()
            #expect(DownloadFiles.find(root: root, folder: job.folder, filename: "A.nsp") == .file(identity))
            try FileManager.default.removeItem(at: folder.appending(path: "B.nsp"))
            server.route("/files/B.nsp", .init(body: second))
            let asked = server.requests("/files/B.nsp").count
            _ = try repositories.retry(job.id)
            try await wait { repositories.job(job.id)?.state.isActive == false }
            let failed = try #require(repositories.job(job.id))
            #expect(failed.state == .failed)
            #expect(failed.message?.contains("no longer matches its \(algorithm.label)") == true, "\(failed.message ?? "")")
            #expect(server.requests("/files/B.nsp").count == asked)  // nothing more was fetched
            #expect(try Data(contentsOf: folder.appending(path: "A.nsp")) == Self.bytes(2000, seed: 6))

            // A's bytes back in place: Retry checks A by its own algorithm, fetches only B
            let restore = try FileHandle(forWritingTo: folder.appending(path: "A.nsp"))
            try restore.write(contentsOf: first)
            try restore.close()
            let fetchedA = server.requests("/files/A.nsp").count
            _ = try repositories.retry(job.id)
            try await wait { repositories.job(job.id)?.state.isActive == false }
            let done = try #require(repositories.job(job.id))
            #expect(done.state == .succeeded, "\(algorithm): \(done.message ?? "")")
            #expect(done.files.allSatisfy { $0.checksum.algorithm == algorithm })
            #expect(server.requests("/files/A.nsp").count == fetchedA)
            #expect(try Data(contentsOf: folder.appending(path: "B.nsp")) == second)

            // the algorithm is kept across launches, and the token is in none of what's saved
            let saved = try String(contentsOf: state, encoding: .utf8)
            #expect(saved.contains("\"\(algorithm.rawValue)\""))
            #expect(!saved.contains("synthetic-"))
            #expect(try credentials.token(for: source.id) == "synthetic-\(algorithm)-token")
            let next = Repositories(defaults: defaults(), credentials: MemoryCredentials(), stateFile: state)
            #expect(next.job(job.id)?.files.map(\.checksum) == done.files.map(\.checksum))
        }
    }

    /// downloads.json from before SHA-1 (a "sha256" per file) reads as it did; one whose checksum can't be read is
    /// left out whole rather than kept with a file it couldn't check.
    @Test func savedDownloadsFromBeforeSHA1StillRead() throws {
        let state = try folder().appending(path: "downloads.json")
        let root = try folder()
        let digest = Self.sha(Self.bytes(4))
        func record(_ id: String, _ file: [String: Any]) -> [String: Any] {
            [
                "id": id, "sourceID": "s", "sourceName": "Shelf", "entryID": "example", "entryName": "Example",
                "titleID": Self.titleID, "folder": "Example [0100000000010000]", "root": root.path,
                "state": "failed", "bytesDone": 0, "created": 0,
                "files": [["kind": "base", "filename": "A.nsp", "bytes": 4].merging(file) { $1 }],
            ]
        }
        let records = [
            record("old", ["sha256": digest, "published": ["device": 1, "inode": 2, "bytes": 4]]),
            record("sha1", ["sha1": Self.sha1(Self.bytes(4))]),
            record("bad", ["sha256": "not-hex"]),
            record("bad-sha1", ["sha1": "abc"]),
            record("none", [:]),
        ]
        try JSONSerialization.data(withJSONObject: records).write(to: state)
        let repositories = Repositories(defaults: defaults(), credentials: MemoryCredentials(), stateFile: state)
        #expect(repositories.downloads.map(\.id) == ["old", "sha1"])
        #expect(repositories.job("old")?.files.first?.checksum == Checksum(.sha256, hex: digest))
        #expect(repositories.job("old")?.files.first?.published == DownloadFiles.Published(device: 1, inode: 2, bytes: 4))
        #expect(repositories.job("sha1")?.files.first?.checksum.algorithm == .sha1)
    }

    @Test func theAPISaysWhichChecksumEachFileHas() async throws {
        let library = Library(defaults: defaults(), isScreenshot: true)
        library.root = try folder()
        func ask(_ method: String, _ path: String) async -> (Int, Any?, String) {
            let request = RemoteRequest.parse(
                Data("\(method) \(path) HTTP/1.1\r\nAuthorization: Bearer \(library.remoteToken)\r\n\r\n".utf8))!
            let response = await library.respond(to: request)
            return (response.status, try? JSONSerialization.jsonObject(with: response.body),
                    String(decoding: response.body, as: UTF8.self))
        }
        let old = Self.bytes(20_000, seed: 1)
        let archived = Self.bytes(30_000, seed: 2)
        let source = try await serve(
            library.repositories, files: ["Old.nsp": old, "Archived.nsp": archived],
            packages: [package("Old.nsp", old), sha1Package("Archived.nsp", archived, kind: "update")],
            token: "synthetic-api-token")
        let (_, entries, entriesText) = await ask("GET", "/v1/sources/\(source.id)/entries")
        let packages = try #require(((entries as? [[String: Any]])?.first?["packages"]) as? [[String: Any]])
        #expect(packages.map { $0["checksum"] as? String } == ["sha256", "sha1"])
        #expect(packages.map { $0["id"] as? String } == [Self.sha(old), "sha1:\(Self.sha1(archived))"])
        #expect(!entriesText.contains("synthetic-api-token"))

        let (accepted, job, jobText) = await ask(
            "POST", "/v1/downloads?source=\(source.id)&entry=example&packages=SHA1:\(Self.sha1(archived).uppercased())")
        #expect(accepted == 202)
        let files = try #require((job as? [String: Any])?["files"] as? [[String: Any]])
        #expect(files.map { $0["checksum"] as? String } == ["sha1"])
        #expect(!jobText.contains("synthetic-api-token"))
        let id = try #require((job as? [String: Any])?["id"] as? String)
        try await wait { library.repositories.job(id)?.state.isActive == false }
        #expect(library.repositories.job(id)?.state == .succeeded, "\(library.repositories.job(id)?.message ?? "")")
        let (_, _, listText) = await ask("GET", "/v1/downloads")
        #expect(!listText.contains("synthetic-api-token"))
        // the package's SHA-1 hex alone isn't its id: a client can't name it without the algorithm
        #expect(await ask("POST", "/v1/downloads?source=\(source.id)&entry=example&packages=\(Self.sha1(archived))").0 == 404)
    }

}
