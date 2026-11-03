import Foundation
import Testing

@testable import NXPlayIOSLogic

/// A Mac for the Sources tests: made-up answers named after it, a log of what it was asked, and requests that can be
/// held until the test lets them answer (or fail).
actor SourcesMac: SourcesAPI {
    struct Refused: LocalizedError {
        let errorDescription: String?
    }

    let name: String
    private(set) var calls: [String] = []
    private var toHold: [String: Int] = [:]
    private var held: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var failing: Set<String> = []
    /// The downloads each `downloads()` answers, in turn (taken when it's asked); the last one stays.
    private var downloadReplies: [[RemoteDownload]]

    init(_ name: String, downloads: [[RemoteDownload]] = [[]]) {
        self.name = name
        downloadReplies = downloads
    }

    /// The next `count` requests of `call` wait for `release`.
    func hold(_ call: String, count: Int = 1) { toHold[call, default: 0] += count }
    func fail(_ call: String) { failing.insert(call) }
    func release(_ call: String) { held.removeValue(forKey: call)?.forEach { $0.resume() } }
    func isHolding(_ call: String) -> Bool { !(held[call]?.isEmpty ?? true) }
    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }

    private func arrive(_ call: String) async throws {
        calls.append(call)
        if let left = toHold[call], left > 0 {
            toHold[call] = left - 1
            await withCheckedContinuation { held[call, default: []].append($0) }
        }
        if failing.contains(call) { throw Refused(errorDescription: "\(name) refused \(call)") }
    }

    func sources() async throws -> [RemoteSource] {
        try await arrive("sources")
        return [Sample.source("\(name) shelf")]
    }

    func refreshSources() async throws -> [RemoteSource] {
        try await arrive("refreshSources")
        return [Sample.source("\(name) shelf, read again")]
    }

    func entries(of source: String, matching words: String) async throws -> [RemoteEntry] {
        try await arrive("entries")
        return [Sample.entry("\(name) game")]
    }

    func downloads() async throws -> [RemoteDownload] {
        let reply = downloadReplies.count > 1 ? downloadReplies.removeFirst() : downloadReplies.first ?? []
        try await arrive("downloads")
        return reply
    }

    func download(_ entry: RemoteEntry, from source: String, packages: [String]) async throws -> RemoteDownload {
        try await arrive("download")
        return Sample.download("\(name) job", state: "queued")
    }

    func cancelDownload(_ id: String) async throws { try await arrive("cancel") }
    func retryDownload(_ id: String) async throws { try await arrive("retry") }
}

enum Sample {
    static func source(_ name: String) -> RemoteSource {
        RemoteSource(
            id: name, name: name, origin: "https://catalog.example", enabled: true, state: "loaded", error: nil,
            entries: 1, issues: 0, refreshed: nil)
    }

    static func entry(_ name: String) -> RemoteEntry {
        RemoteEntry(
            id: name, name: name, titleID: "0100000000010000", version: "1.0", publisher: "", description: "",
            folder: name, libraryGame: nil, issues: [], packages: [])
    }

    static func download(_ id: String, state: String) -> RemoteDownload {
        RemoteDownload(
            id: id, source: "s", sourceName: "Shelf", entry: "e", entryName: id, titleID: "0100000000010000",
            folder: "Game", state: state, message: nil, bytesDone: 0, totalBytes: 10, fraction: 0, fileIndex: 0,
            files: [], libraryGame: nil)
    }
}

/// Sources belongs to one pairing (MacSources): what the old Mac answers after pairing again or unpairing, and what a
/// screen of the old pairing asks, change nothing.
@MainActor @Suite struct SourcesSessionTests {
    /// The launcher's part: the paired Mac, the problem it shows, and the library reads a finished download asks for.
    final class Paired {
        var mac: SourcesMac?
        var problems: [String] = []
        var libraryReads = 0
    }

    private func sources(_ paired: Paired) -> MacSources {
        let model = MacSources()
        model.client = { paired.mac }
        model.onProblem = { paired.problems.append($0) }
        model.onFinished = { paired.libraryReads += 1 }
        return model
    }

    /// As Launcher pairs again (or unpairs, with nil): the session ends in the same step the Mac changes.
    private func pairAgain(_ model: MacSources, _ paired: Paired, with mac: SourcesMac?) {
        model.reset()
        paired.mac = mac
    }

    private func until(_ what: String, _ condition: () async -> Bool) async {
        let deadline = Date.now.addingTimeInterval(5)
        while !(await condition()) {
            guard Date.now < deadline else {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func theOldMacsLateSourcesNeverReplaceTheNewMacs() async {
        let a = SourcesMac("Mac A", downloads: [[Sample.download("A job", state: "running")]])
        let b = SourcesMac("Mac B", downloads: [[Sample.download("B job", state: "queued")]])
        let paired = Paired()
        paired.mac = a
        let model = sources(paired)
        await a.hold("sources")
        let old = Task { await model.load() }
        await until("A's sources to be asked") { await a.isHolding("sources") }

        pairAgain(model, paired, with: b)
        await model.load()
        #expect(model.sources.map(\.name) == ["Mac B shelf"])
        #expect(model.downloads.map(\.id) == ["B job"])

        await a.release("sources")
        await old.value
        #expect(model.sources.map(\.name) == ["Mac B shelf"])
        #expect(model.downloads.map(\.id) == ["B job"])
        // nothing more was asked of A for that old screen, and nothing of B on A's behalf
        #expect(await a.count("downloads") == 0)
        #expect(await b.count("downloads") == 1)
        #expect(paired.problems.isEmpty)
    }

    @Test func theOldMacsLateFailureIsntShownButTheCurrentOnesIs() async {
        let a = SourcesMac("Mac A")
        let b = SourcesMac("Mac B")
        await a.hold("refreshSources")
        await a.fail("refreshSources")
        let paired = Paired()
        paired.mac = a
        let model = sources(paired)
        let old = Task { await model.load(refreshing: true) }
        await until("A's refresh to be asked") { await a.isHolding("refreshSources") }
        pairAgain(model, paired, with: b)
        await a.release("refreshSources")
        await old.value
        #expect(paired.problems.isEmpty)

        await b.fail("sources")
        await model.load()
        #expect(paired.problems == ["Mac B refused sources"])
    }

    @Test func unpairingForgetsTheListsAndDropsWhatsOnItsWay() async {
        let a = SourcesMac("Mac A", downloads: [[Sample.download("A1", state: "running")], [Sample.download("A2", state: "running")]])
        let paired = Paired()
        paired.mac = a
        let model = sources(paired)
        await model.load()
        #expect(model.sources.map(\.name) == ["Mac A shelf"])
        #expect(model.downloads.map(\.id) == ["A1"])

        // the Sources screen's polling asks again, and the player unpairs before it answers
        await a.hold("downloads")
        let poll = Task { await model.loadDownloads() }
        await until("the poll to be asked") { await a.isHolding("downloads") }
        pairAgain(model, paired, with: nil)
        #expect(model.sources.isEmpty && model.downloads.isEmpty)
        await a.release("downloads")
        await poll.value
        #expect(model.sources.isEmpty && model.downloads.isEmpty)
        await model.load()
        await model.loadDownloads()
        #expect(model.sources.isEmpty && model.downloads.isEmpty)
        #expect(paired.problems.isEmpty)
    }

    @Test func aScreenOfTheOldPairingSendsNothingToTheNewMac() async {
        let a = SourcesMac("Mac A", downloads: [[Sample.download("A job", state: "failed")]])
        let b = SourcesMac("Mac B")
        let paired = Paired()
        paired.mac = a
        let model = sources(paired)
        await model.load()
        let screen = model.session
        let source = model.sources[0]
        let job = model.downloads[0]
        let entry = Sample.entry("Mac A game")

        pairAgain(model, paired, with: b)
        #expect(model.session != screen)
        await model.download(entry, from: source, packages: ["sha"], in: screen)
        await model.cancel(job, in: screen)
        await model.retry(job, in: screen)
        #expect(await model.entries(of: source, matching: "", in: screen) == nil)
        #expect(await b.calls.isEmpty)
        let askedOfA = await a.calls
        #expect(askedOfA == ["sources", "downloads"])

        // the new pairing's own screen does reach B
        await model.retry(job, in: model.session)
        #expect(await b.calls == ["retry", "downloads"])
    }

    @Test func anActionOnItsWayWhenThePairingChangesChangesNothing() async {
        let a = SourcesMac("Mac A")
        let b = SourcesMac("Mac B", downloads: [[Sample.download("B job", state: "running")]])
        let paired = Paired()
        paired.mac = a
        let model = sources(paired)
        await model.load()
        let screen = model.session
        await a.hold("download")
        await a.fail("download")
        let tap = Task { await model.download(Sample.entry("Mac A game"), from: model.sources[0], packages: [], in: screen) }
        await until("A's download to be asked") { await a.isHolding("download") }

        pairAgain(model, paired, with: b)
        await model.load()
        await a.release("download")
        await tap.value
        #expect(model.downloads.map(\.id) == ["B job"])
        #expect(await b.count("downloads") == 1)
        #expect(paired.problems.isEmpty)
    }

    @Test func aLateCatalogFromTheOldMacIsDropped() async {
        let a = SourcesMac("Mac A")
        let b = SourcesMac("Mac B")
        let paired = Paired()
        paired.mac = a
        let model = sources(paired)
        await model.load()
        let screen = model.session
        let source = model.sources[0]
        await a.hold("entries")
        let search = Task { await model.entries(of: source, matching: "game", in: screen) }
        await until("A's catalog to be asked") { await a.isHolding("entries") }
        pairAgain(model, paired, with: b)
        await a.release("entries")
        #expect(await search.value == nil)
        // the current session's catalog still comes through
        #expect(await model.entries(of: source, matching: "", in: model.session)?.map(\.name) == ["Mac B game"])
    }

    @Test func theDownloadsAskedForLastStay() async {
        let a = SourcesMac(
            "Mac A",
            downloads: [[Sample.download("asked first", state: "running")], [Sample.download("asked last", state: "running")]])
        let paired = Paired()
        paired.mac = a
        let model = sources(paired)
        await a.hold("downloads")
        let slow = Task { await model.loadDownloads() }
        await until("the first poll to be asked") { await a.isHolding("downloads") }
        await model.loadDownloads()
        #expect(model.downloads.map(\.id) == ["asked last"])
        await a.release("downloads")
        await slow.value
        #expect(model.downloads.map(\.id) == ["asked last"])
    }

    @Test func onlyTheCurrentMacsFinishedDownloadReadsTheLibrary() async {
        let a = SourcesMac(
            "Mac A",
            downloads: [[Sample.download("j", state: "running")], [Sample.download("j", state: "succeeded")]])
        let paired = Paired()
        paired.mac = a
        let model = sources(paired)
        await model.loadDownloads()
        await a.hold("downloads")
        let poll = Task { await model.loadDownloads() }
        await until("the poll to be asked") { await a.isHolding("downloads") }
        pairAgain(model, paired, with: SourcesMac("Mac B"))
        await a.release("downloads")
        await poll.value
        #expect(paired.libraryReads == 0)
        #expect(model.downloads.isEmpty)

        // the same within one pairing does read it
        let c = SourcesMac(
            "Mac C",
            downloads: [[Sample.download("k", state: "running")], [Sample.download("k", state: "succeeded")]])
        pairAgain(model, paired, with: c)
        await model.loadDownloads()
        await model.loadDownloads()
        #expect(paired.libraryReads == 1)
    }
}
