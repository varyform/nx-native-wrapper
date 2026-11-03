import Foundation
import Observation

/// What Sources asks the paired Mac (MacClient; NXPlayKit's Library+Repositories.swift answers).
protocol SourcesAPI: Sendable {
    func sources() async throws -> [RemoteSource]
    func refreshSources() async throws -> [RemoteSource]
    func entries(of source: String, matching words: String) async throws -> [RemoteEntry]
    func downloads() async throws -> [RemoteDownload]
    func download(_ entry: RemoteEntry, from source: String, packages: [String]) async throws -> RemoteDownload
    func cancelDownload(_ id: String) async throws
    func retryDownload(_ id: String) async throws
}

extension MacClient: SourcesAPI {}

/// Sources on this device: the paired Mac's sources and its downloads, and what the player asks of them. It all
/// belongs to one pairing, its session. Pairing again (with this Mac or another) or unpairing starts a new session
/// (`reset`): the old lists go, and an answer still on its way from the old pairing, a list or an error, changes
/// nothing. What a screen of the old session asks (Download, Cancel, Retry, a catalog) is never sent to the Mac paired
/// since. Of two answers to the same list, the one asked for last stays.
@MainActor @Observable
final class MacSources {
    /// One pairing's turn at Sources.
    struct Session: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    private(set) var sources: [RemoteSource] = []
    private(set) var downloads: [RemoteDownload] = []
    private(set) var session = Session(id: 0)

    /// The paired Mac to ask, nil when there's none. Read at each request: a reconnect moves it to another of the same
    /// Mac's addresses within the session.
    @ObservationIgnored var client: () -> (any SourcesAPI)? = { nil }
    /// Something went wrong for the current pairing: the launcher shows it.
    @ObservationIgnored var onProblem: (String) -> Void = { _ in }
    /// A download of the current pairing just finished: there's a new game in the Mac's library.
    @ObservationIgnored var onFinished: () async -> Void = {}

    /// Each request for a list gets the next ticket; an answer older than the one shown is dropped.
    @ObservationIgnored private var tickets: UInt64 = 0
    @ObservationIgnored private var shownSources: UInt64 = 0
    @ObservationIgnored private var shownDownloads: UInt64 = 0

    /// The pairing was replaced or removed: a new session, with nothing of the old Mac's shown.
    func reset() {
        session = Session(id: session.id &+ 1)
        sources = []
        downloads = []
    }

    /// The Mac's sources, then its downloads; `refreshing` has the Mac read the catalogs again first.
    func load(refreshing: Bool = false) async {
        let session = session
        guard let api = client() else { return }
        let ticket = nextTicket()
        do {
            let list = refreshing ? try await api.refreshSources() : try await api.sources()
            guard session == self.session, ticket > shownSources else { return }
            shownSources = ticket
            sources = list
            await loadDownloads(in: session)
        } catch {
            report(error, in: session)
        }
    }

    /// The downloads, as the Mac has them. One that just finished brought a game: `onFinished`.
    func loadDownloads() async {
        await loadDownloads(in: session)
    }

    private func loadDownloads(in session: Session) async {
        guard session == self.session, let api = client() else { return }
        let ticket = nextTicket()
        guard let list = try? await api.downloads(), session == self.session, ticket > shownDownloads else { return }
        shownDownloads = ticket
        let finished = list.contains { job in
            job.state == "succeeded" && downloads.first { $0.id == job.id }?.isActive == true
        }
        downloads = list
        if finished { await onFinished() }
    }

    /// A source's games, for a screen of `session`. Nil when it couldn't ask, the answer failed, or the pairing changed
    /// meanwhile.
    func entries(of source: RemoteSource, matching words: String, in session: Session) async -> [RemoteEntry]? {
        guard session == self.session, let api = client() else { return nil }
        do {
            let list = try await api.entries(of: source.id, matching: words)
            return session == self.session ? list : nil
        } catch is CancellationError {
            return nil
        } catch {
            if (error as? URLError)?.code != .cancelled { report(error, in: session) }
            return nil
        }
    }

    func download(_ entry: RemoteEntry, from source: RemoteSource, packages: [String], in session: Session) async {
        await act(in: session) { _ = try await $0.download(entry, from: source.id, packages: packages) }
    }

    func cancel(_ job: RemoteDownload, in session: Session) async {
        await act(in: session) { try await $0.cancelDownload(job.id) }
    }

    func retry(_ job: RemoteDownload, in session: Session) async {
        await act(in: session) { try await $0.retryDownload(job.id) }
    }

    /// Asks the Mac for something the player chose on a screen of `session`, then reads the downloads again. Nothing is
    /// sent once that session is over: the ids it has are another Mac's.
    private func act(in session: Session, _ request: (any SourcesAPI) async throws -> Void) async {
        guard session == self.session, let api = client() else { return }
        do {
            try await request(api)
            await loadDownloads(in: session)
        } catch {
            report(error, in: session)
        }
    }

    private func report(_ error: any Error, in session: Session) {
        guard session == self.session else { return }
        onProblem(error.localizedDescription)
    }

    private func nextTicket() -> UInt64 {
        tickets &+= 1
        return tickets
    }
}
