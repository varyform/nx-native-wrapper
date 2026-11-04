import Foundation
import Observation

/// Sources: the player's own repositories of game files, each a catalog on a server they run (Catalog/README.md), and
/// the downloads from them into the games folder. NX Play comes with no source. Each source loads on its own, so one
/// that's down or broken only shows its own error. Downloads run one at a time, in order, each into its game's folder
/// in the games folder (the folder the library already has for that title ID, else a new one), where the library
/// finds them like any game copied in. Installing on a device stays a separate step the player takes.
@MainActor @Observable
public final class Repositories {
    public enum CatalogState: Sendable, Equatable {
        case notLoaded
        case loading
        case loaded(Catalog, at: Date)
        case failed(String)
    }

    public internal(set) var sources: [RepositorySource] {
        didSet { defaults.set(sources.map(\.plist), forKey: Self.sourcesKey) }
    }
    /// Each source's catalog, by source id.
    public internal(set) var states: [String: CatalogState] = [:]
    /// The downloads, oldest first: the running and queued ones and the last finished ones.
    public internal(set) var downloads: [DownloadJob] = [] {
        didSet { saveDownloads() }
    }

    /// The games folder downloads go to.
    @ObservationIgnored var root: () -> URL? = { nil }
    /// The library's folder for a title ID, when it has the game already: an update goes beside its base game.
    @ObservationIgnored var existingFolder: (String) -> String? = { _ in nil }
    /// A download put its files in the games folder: the library looks again.
    @ObservationIgnored var onPublished: (DownloadJob) -> Void = { _ in }
    /// The last download ended: nothing runs.
    @ObservationIgnored var onIdle: () -> Void = {}
    @ObservationIgnored var freeSpace: (URL) -> Int64? = DownloadFiles.freeSpace
    /// Room a download leaves free on the games folder's volume, beyond its own bytes.
    @ObservationIgnored var headroom: Int64 = 2 * 1024 * 1024 * 1024

    static let sourcesKey = "repositorySources"
    static let maxActive = 20
    static let keptFinished = 50

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let credentials: any CredentialStore
    /// downloads.json: the downloads' status between launches. Nil keeps it in memory (screenshots).
    @ObservationIgnored private let stateFile: URL?
    @ObservationIgnored private var running: (id: String, task: Task<Void, Never>)?
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var savedKey: [String] = []
    /// Runs of a download that a Retry or the trimming of old downloads replaced, as they ended (the last
    /// `keptEnded`): a Retry reuses the download's id, so whoever followed an earlier run (the control API) reads
    /// how that run ended here, never the new run's state.
    @ObservationIgnored private(set) var endedRuns: [DownloadJob] = []
    static let keptEnded = 100

    init(defaults: UserDefaults, credentials: any CredentialStore, stateFile: URL?) {
        self.defaults = defaults
        self.credentials = credentials
        self.stateFile = stateFile
        sources =
            (defaults.array(forKey: Self.sourcesKey) as? [[String: Any]] ?? [])
            .compactMap(RepositorySource.init(plist:))
        downloads = Self.loadDownloads(stateFile)
    }

    // MARK: - Sources

    public struct Failure: Error, LocalizedError, Equatable {
        public let message: String
        /// The HTTP status the Mac's API answers with.
        public let status: Int
        public var errorDescription: String? { message }

        init(_ message: String, status: Int = 422) {
            self.message = message
            self.status = status
        }
    }

    /// Adds a source from what the player typed: the catalog's address, a name (the host when empty) and an access
    /// token (sent as `Authorization: Bearer` to the catalog's origin only), which goes to the Keychain.
    @discardableResult
    public func addSource(name: String, address: String, token: String = "") throws -> RepositorySource {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), url.scheme != nil else {
            throw Failure("“\(address)” isn't an address: write it as https://server/catalog.json")
        }
        if let problem = RepositoryAddress.problem(with: url) ?? RepositoryAddress.secretQueryProblem(url) {
            throw Failure("Can't add it: \(problem)")
        }
        guard !sources.contains(where: { $0.url == url }) else {
            throw Failure("That catalog is a source already", status: 409)
        }
        let trimmed = Catalog.clean(name)
        let source = RepositorySource(
            name: trimmed.isEmpty ? url.host() ?? address : String(trimmed.prefix(60)), url: url)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            do {
                try credentials.setToken(token, for: source.id)
            } catch {
                throw Failure("Can't add it: \(error.localizedDescription)", status: 500)
            }
        }
        sources.append(source)
        return source
    }

    /// Removes the source, then its token. The source is gone even when the Keychain refuses to delete the token:
    /// that throws, so the player hears it's still there.
    public func removeSource(_ id: String) throws {
        for job in downloads where job.sourceID == id && job.state.isActive { cancel(job.id) }
        let name = source(id)?.name ?? id
        sources.removeAll { $0.id == id }
        states[id] = nil
        do {
            try credentials.setToken(nil, for: id)
        } catch {
            throw Failure("Removed \(name), but its access token is still in the Keychain: \(error.localizedDescription)", status: 500)
        }
    }

    public func setEnabled(_ enabled: Bool, _ id: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].enabled = enabled
        if !enabled { states[id] = nil }
    }

    /// Saves a new token for the source (an empty one removes it). When the Keychain refuses, it throws and the old
    /// token stays as it was.
    public func setToken(_ token: String, for id: String) throws {
        do {
            try credentials.setToken(token.trimmingCharacters(in: .whitespacesAndNewlines), for: id)
        } catch {
            throw Failure(error.localizedDescription, status: 500)
        }
        states[id] = .notLoaded
    }

    public enum TokenState: Equatable, Sendable {
        case none, saved
        /// The Keychain couldn't be read: whether there's a token isn't known.
        case unreadable(String)
    }

    public func tokenState(_ id: String) -> TokenState {
        do {
            return try credentials.token(for: id) == nil ? .none : .saved
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    public func source(_ id: String) -> RepositorySource? { sources.first { $0.id == id } }

    /// The source's token for its origin, nil when it has none. A Keychain that can't be read throws: the request
    /// isn't sent without the token as if there were none.
    func auth(for source: RepositorySource) throws -> SourceAuth? {
        let token: String?
        do {
            token = try credentials.token(for: source.id)
        } catch {
            throw Failure("\(error.localizedDescription). Open Access Token… to save it again.", status: 500)
        }
        guard let origin = source.origin, let token else { return nil }
        return SourceAuth(origin: origin, token: token)
    }

    /// Reads a source's catalog again. A failure is that source's own state; the others keep theirs.
    public func refresh(_ id: String) async {
        guard let source = source(id), source.enabled, loading.insert(id).inserted else { return }
        defer { loading.remove(id) }
        states[id] = .loading
        do {
            // the token goes to the source's own origin; the files' relative addresses resolve against where the
            // catalog came from, after any redirect
            let (data, url) = try await RepositoryTransfer.data(
                from: source.url, auth: auth(for: source), limit: Catalog.maxBytes)
            let catalog = try await Catalog.load(data, base: url)
            // removed or turned off while it loaded
            guard self.source(id)?.enabled == true else { return }
            states[id] = .loaded(catalog, at: .now)
        } catch {
            guard self.source(id)?.enabled == true else { return }
            states[id] = .failed(error.localizedDescription)
        }
    }

    /// Every source that's on, side by side.
    public func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for source in sources where source.enabled {
                group.addTask { await self.refresh(source.id) }
            }
        }
    }

    /// The sources that are on and haven't been read yet (or failed): what opening Sources reads.
    public func refreshStale() async {
        await withTaskGroup(of: Void.self) { group in
            for source in sources where source.enabled {
                switch states[source.id] ?? .notLoaded {
                case .notLoaded, .failed: group.addTask { await self.refresh(source.id) }
                default: break
                }
            }
        }
    }

    public func catalog(_ id: String) -> Catalog? {
        if case .loaded(let catalog, _) = states[id] { return catalog }
        return nil
    }

    /// The entries of one source (or every source that's on) with every word of `search` in their name, title ID or
    /// publisher, by name.
    public func entries(source id: String?, search: String = "") -> [SourceEntry] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        return sources.filter { $0.enabled && (id == nil || $0.id == id) }
            .flatMap { source in
                (catalog(source.id)?.entries ?? []).map { SourceEntry(source: source, entry: $0) }
            }
            .filter { (row: SourceEntry) in
                let entry = row.entry
                let fields = [entry.name, entry.titleID, entry.publisher, entry.id]
                return words.allSatisfy { word in fields.contains { $0.localizedStandardContains(word) } }
            }
            .sorted { $0.entry.name.localizedStandardCompare($1.entry.name) == .orderedAscending }
    }

    // MARK: - Where files go

    /// The game's folder in the games folder: the library's, when it has the game (built or not), else the folder a
    /// download of the game is going to or went to, else a new one named after it. So an update or DLC from another
    /// catalog, which may name the game differently, goes beside its base game.
    public func folder(for entry: CatalogEntry) -> String {
        existingFolder(entry.titleID) ?? downloadedFolder(entry.titleID)
            ?? DownloadFiles.folderName(name: entry.name, titleID: entry.titleID)
    }

    /// The folder of the newest download of the title into the current games folder: one on its way, or one that
    /// finished and whose folder is still there.
    private func downloadedFolder(_ titleID: String) -> String? {
        guard let root = root() else { return nil }
        return downloads.last { job in
            guard job.root == root.path, job.titleID.caseInsensitiveCompare(titleID) == .orderedSame else {
                return false
            }
            if job.state.isActive { return true }
            var info = stat()
            return job.state == .succeeded && DownloadFiles.isPlainName(job.folder)
                && lstat(root.appending(path: job.folder).path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        }?.folder
    }

    /// The package's file is in the game's folder already.
    public func isPresent(_ package: CatalogPackage, of entry: CatalogEntry) -> Bool {
        guard let root = root() else { return false }
        return DownloadFiles.exists(root: root, folder: folder(for: entry), filename: package.filename)
    }

    /// The download of the package now running or waiting, if any.
    public func activeJob(for package: CatalogPackage) -> DownloadJob? {
        downloads.first { $0.state.isActive && $0.files.contains { $0.checksum == package.checksum } }
    }

    // MARK: - Downloads

    /// Queues the entry's packages (`packageIDs`, else all) that aren't in the game's folder yet. Refused with the
    /// reason when there's no games folder, nothing to download, the same file already downloading, too many waiting,
    /// or too little room for it.
    @discardableResult
    public func download(source sourceID: String, entry entryID: String, packages packageIDs: Set<String>? = nil)
        throws -> DownloadJob
    {
        guard let source = source(sourceID), source.enabled else {
            throw Failure("No source \(sourceID)", status: 404)
        }
        guard let catalog = catalog(sourceID) else {
            throw Failure("\(source.name) isn't loaded: refresh it first", status: 409)
        }
        guard let entry = catalog.entries.first(where: { $0.id == entryID }) else {
            throw Failure("\(source.name) has no entry \(entryID)", status: 404)
        }
        guard let root = root() else {
            throw Failure("Choose a games folder on the Mac first", status: 409)
        }
        if let packageIDs, let unknown = packageIDs.first(where: { id in !entry.packages.contains { $0.id == id } }) {
            throw Failure("\(entry.name) has no package \(unknown)", status: 404)
        }
        let chosen = entry.packages.filter { packageIDs?.contains($0.id) ?? true }
        let wanted = chosen.filter { !isPresent($0, of: entry) }
        guard !wanted.isEmpty else {
            throw Failure("\(entry.name) is in your games folder already", status: 409)
        }
        let folder = folder(for: entry)
        let job = DownloadJob(
            id: UUID().uuidString, source: source, entry: entry, folder: folder, root: root,
            files: wanted.map(DownloadJob.File.init))
        try admit(job)
        downloads.append(job)
        trimFinished()
        startNext()
        return job
    }

    /// A download may join the queue: its folder isn't a dump, nothing of it is already on the way, and there's room
    /// in the queue and on the disk.
    private func admit(_ job: DownloadJob) throws {
        try refuseDump(root: URL(filePath: job.root, directoryHint: .isDirectory), folder: job.folder)
        let active = downloads.filter { $0.state.isActive && $0.id != job.id }
        let names = Set(job.files.map { $0.filename.lowercased() })
        let hashes = Set(job.files.map(\.checksum))
        if let other = active.first(where: { other in
            other.files.contains { hashes.contains($0.checksum) }
                || (other.root == job.root && other.folder == job.folder
                    && other.files.contains { names.contains($0.filename.lowercased()) })
        }) {
            throw Failure("\(other.entryName) is downloading that file already", status: 409)
        }
        guard active.count < Self.maxActive else {
            throw Failure("\(Self.maxActive) downloads are waiting already", status: 429)
        }
        // a retry whose files are all in already only checks them again: it needs no room
        guard job.remainingBytes > 0 else { return }
        let needed = active.filter { $0.root == job.root }.reduce(job.remainingBytes) { $0 + $1.remainingBytes }
        try checkSpace(needed, in: URL(filePath: job.root, directoryHint: .isDirectory))
    }

    /// Refuses a game folder that is a Switch 2 dump (GameDump). nxnative builds a folder as a dump only while it has
    /// no NSP, NSZ, XCI or XCZ of its own, so a package downloaded beside the dump's `base/` would turn it into a game
    /// built from packages, which asks for prod.keys, and an update or DLC alone has no base game to build. The dump
    /// stays as it is: on adding to the queue, on retrying, and again when the download starts and before its files
    /// go in, for a folder that became a dump while it waited.
    private func refuseDump(root: URL, folder: String) throws {
        guard DownloadFiles.isPlainName(folder),
            GameDump.isDump(root.appending(path: folder, directoryHint: .isDirectory))
        else { return }
        throw Failure(
            "\(folder) is a Switch 2 dump (base/, updates/, dlc/). NX Play doesn't download NSP, NSZ, XCI or XCZ files into a dump: beside its base/ they'd be built in place of the dump. Add an update or DLC to the dump itself, as files in its updates/ or dlc/ folder.",
            status: 409)
    }

    private func checkSpace(_ needed: Int64, in root: URL) throws {
        guard let free = freeSpace(root) else { return }
        guard free >= needed + headroom else {
            let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            throw Failure(
                "Not enough space in the games folder: \(format(needed)) to download and \(format(headroom)) to spare, \(format(free)) free",
                status: 507)
        }
    }

    /// Stops this run of a download, only while it's the download's current run: a cancel meant for a run a Retry
    /// replaced never reaches the new run.
    public func cancel(_ id: String, attempt: Int) {
        guard job(id)?.attempt == attempt else { return }
        cancel(id)
    }

    /// The download's run `attempt`: its current record, or the run as it ended before a Retry replaced it.
    public func run(_ id: String, attempt: Int) -> DownloadJob? {
        if let job = job(id), job.attempt == attempt { return job }
        return endedRuns.last { $0.id == id && $0.attempt == attempt }
    }

    private func keepEnded(_ jobs: [DownloadJob]) {
        endedRuns.append(contentsOf: jobs)
        if endedRuns.count > Self.keptEnded { endedRuns.removeFirst(endedRuns.count - Self.keptEnded) }
    }

    /// Stops a running download (its partial file is deleted) or takes a waiting one off the queue.
    public func cancel(_ id: String) {
        guard let index = downloads.firstIndex(where: { $0.id == id }), downloads[index].state.isActive else {
            return
        }
        if running?.id == id {
            running?.task.cancel()  // perform() marks it cancelled once the transfer has stopped
        } else {
            downloads[index].state = .cancelled
            downloads[index].finished = .now
        }
    }

    /// Starts a failed or cancelled download again from the beginning, with the source's current catalog. Files it
    /// already put in the game's folder count as done: the very files it published, still there. Anything else where
    /// one of its files goes (the player's own file, a folder, a link) is a conflict: the download stays failed and the
    /// file stays as it is.
    @discardableResult
    public func retry(_ id: String) throws -> DownloadJob {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else {
            throw Failure("No download \(id)", status: 404)
        }
        var job = downloads[index]
        let ended = job
        guard job.state == .failed || job.state == .cancelled else {
            throw Failure("\(job.entryName) isn't stopped", status: 409)
        }
        guard let entry = catalog(job.sourceID)?.entries.first(where: { $0.id == job.entryID }) else {
            throw Failure("Refresh \(job.sourceName) first: its catalog isn't loaded or no longer lists \(job.entryName)", status: 409)
        }
        let root = URL(filePath: job.root, directoryHint: .isDirectory)
        var done: [DownloadJob.File] = []
        var files: [DownloadJob.File] = []
        for file in job.files {
            switch DownloadFiles.find(root: root, folder: job.folder, filename: file.filename) {
            case nil:
                guard let package = entry.packages.first(where: { $0.checksum == file.checksum }) else {
                    throw Failure("\(job.sourceName) no longer lists \(file.filename)", status: 409)
                }
                files.append(DownloadJob.File(package))
            case .file(let found) where file.published != nil && found == file.published:
                done.append(file)
            default:
                throw Failure(
                    "\(job.folder)/\(file.filename) is already in the games folder and isn't the file this download put there. NX Play doesn't replace files: move it out of the way, then Retry.",
                    status: 409)
            }
        }
        job.files = done + files
        job.fileIndex = done.count
        job.bytesDone = done.reduce(0) { $0 + $1.bytes }
        job.state = .queued
        job.message = nil
        job.finished = nil
        job.attempt += 1
        try admit(job)
        // the run that ended stays readable as it ended, in the same turn the new run takes its place
        keepEnded([ended])
        downloads[index] = job
        startNext()
        return job
    }

    public var isActive: Bool { downloads.contains { $0.state.isActive } }

    public func job(_ id: String) -> DownloadJob? { downloads.first { $0.id == id } }

    /// Stops what runs when NX Play quits: the next launch clears its staging folder.
    func stopAll() {
        running?.task.cancel()
    }

    private func startNext() {
        guard running == nil, let next = downloads.first(where: { $0.state == .queued }) else { return }
        let id = next.id
        let task = Task { [weak self] in
            await self?.perform(id)
            guard let self else { return }
            running = nil
            startNext()
            if running == nil { onIdle() }
        }
        running = (id, task)
    }

    private func update(_ id: String, _ change: (inout DownloadJob) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        change(&downloads[index])
    }

    /// One download: each file streamed into the staging folder and checked, then all of them published.
    private func perform(_ id: String) async {
        guard let job = job(id), job.state == .queued else { return }
        update(id) { $0.state = .running }
        let root = URL(filePath: job.root, directoryHint: .isDirectory)
        var staging: DownloadFiles.Staging?
        defer { staging?.remove() }
        do {
            try refuseDump(root: root, folder: job.folder)
            if job.remainingBytes > 0 { try checkSpace(job.remainingBytes, in: root) }
            guard let source = source(job.sourceID) else { throw Failure("The source was removed") }
            let auth = try auth(for: source)
            let made = try DownloadFiles.Staging(root: root, id: id)
            staging = made
            var done: Int64 = 0
            for (index, file) in job.files.enumerated() {
                // put there by an earlier try of this download
                if let published = file.published {
                    try await DownloadFiles.verifyPublished(root: root, folder: job.folder, filename: file.filename, identity: published, bytes: file.bytes, checksum: file.checksum)
                    done += file.bytes
                    continue
                }
                guard let url = file.url else { throw Failure("Refresh \(job.sourceName) and retry") }
                update(id) { $0.fileIndex = index }
                let handle = try made.create(index)
                let base = done
                let digest = try await RepositoryTransfer.download(
                    from: url, auth: auth, into: handle, expected: file.bytes, algorithm: file.checksum.algorithm
                ) { [weak self] bytes in
                    Task { @MainActor in self?.update(id) { $0.bytesDone = base + bytes } }
                }
                try await Task.detached { try handle.synchronize() }.value
                try handle.close()
                guard made.size(index) == file.bytes else {
                    throw Failure("\(file.filename) isn't the size the catalog says")
                }
                guard digest == file.checksum else {
                    throw Failure(
                        "\(file.filename) doesn't match its \(file.checksum.algorithm.label) in the catalog: the server's file isn't the one listed, or it was damaged on the way. Nothing was put in your games folder.")
                }
                done += file.bytes
                update(id) { $0.bytesDone = done }
            }
            try Task.checkCancellation()
            update(id) { $0.state = .verifying }
            try refuseDump(root: root, folder: job.folder)
            for (index, file) in job.files.enumerated() where file.published == nil {
                let published = try made.publish(index, folder: job.folder, filename: file.filename)
                update(id) { $0.files[index].published = published }
            }
            for file in job.files where file.published != nil {
                try await DownloadFiles.verifyPublished(root: root, folder: job.folder, filename: file.filename, identity: file.published!, bytes: file.bytes, checksum: file.checksum)
            }
            try Task.checkCancellation()
            update(id) {
                $0.state = .succeeded
                $0.finished = .now
            }
            if let finished = self.job(id) { onPublished(finished) }
        } catch is CancellationError {
            update(id) {
                $0.state = .cancelled
                $0.finished = .now
            }
        } catch {
            update(id) {
                $0.state = .failed
                $0.message = error.localizedDescription
                $0.finished = .now
            }
        }
    }

    // MARK: - Status between launches

    private func trimFinished() {
        let finished = downloads.filter { !$0.state.isActive }
        guard finished.count > Self.keptFinished else { return }
        let dropped = Set(finished.prefix(finished.count - Self.keptFinished).map(\.id))
        keepEnded(downloads.filter { dropped.contains($0.id) })
        downloads.removeAll { dropped.contains($0.id) }
    }

    /// Written when a download's state changes, not at each step of its progress.
    private func saveDownloads() {
        guard let stateFile else { return }
        let key = downloads.map {
            "\($0.id) \($0.state.rawValue) \($0.files.count) \($0.files.filter { $0.published != nil }.count) \($0.message ?? "")"
        }
        guard key != savedKey else { return }
        savedKey = key
        let records = downloads.map(\.record)
        guard let data = try? JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(
            at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateFile, options: .atomic)
    }

    /// The downloads as NX Play left them. One that was running or waiting stopped when it quit: it shows as failed,
    /// for Retry, and what it left in the staging folder is deleted.
    private static func loadDownloads(_ file: URL?) -> [DownloadJob] {
        guard let file, let data = try? Data(contentsOf: file),
            let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        var jobs = records.compactMap(DownloadJob.init(record:))
        for index in jobs.indices where jobs[index].state.isActive {
            jobs[index].state = .failed
            jobs[index].message = "NX Play quit before the download finished: Retry starts it again"
        }
        for root in Set(jobs.map(\.root)) {
            DownloadFiles.removeStaging(in: URL(filePath: root, directoryHint: .isDirectory))
        }
        return jobs
    }
}

/// A catalog entry with its source. An entry's id is unique only in its own catalog (two sources often list the same
/// game by its title ID), so a list of several sources' entries tells them apart by both.
public struct SourceEntry: Identifiable, Sendable {
    public let source: RepositorySource
    public let entry: CatalogEntry

    public var id: EntryKey { EntryKey(source: source.id, entry: entry.id) }
}

public struct EntryKey: Hashable, Sendable {
    public let source: String
    public let entry: String
}

/// One download: an entry's packages, from one source into one game folder.
public struct DownloadJob: Identifiable, Sendable, Equatable {
    public enum State: String, Sendable {
        case queued, running, verifying, succeeded, failed, cancelled

        public var isActive: Bool { self == .queued || self == .running || self == .verifying }
    }

    public struct File: Sendable, Equatable {
        public let kind: CatalogPackage.Kind
        public let filename: String
        public let bytes: Int64
        /// What the file's bytes must match, by the algorithm its catalog named.
        public let checksum: Checksum
        /// From the catalog; not kept between launches (a retry takes it from the catalog again).
        let url: URL?
        /// The file this download put in the game's folder, once it has: what a retry counts as done.
        var published: DownloadFiles.Published?

        init(_ package: CatalogPackage) {
            kind = package.kind
            filename = package.filename
            bytes = package.bytes
            checksum = package.checksum
            url = package.url
        }

        init(kind: CatalogPackage.Kind, filename: String, bytes: Int64, checksum: Checksum) {
            self.kind = kind
            self.filename = filename
            self.bytes = bytes
            self.checksum = checksum
            url = nil
        }
    }

    public let id: String
    public let sourceID: String
    public let sourceName: String
    public let entryID: String
    public let entryName: String
    public let titleID: String
    /// The game's folder, in the games folder.
    public let folder: String
    /// The games folder, as it was when the download was asked for.
    public let root: String
    public internal(set) var files: [File]
    public internal(set) var state: State = .queued
    /// Why it failed.
    public internal(set) var message: String?
    /// Across its files.
    public internal(set) var bytesDone: Int64 = 0
    /// The file downloading now.
    public internal(set) var fileIndex = 0
    public let created: Date
    public internal(set) var finished: Date?
    /// Which run of this download: 1, then one more for each Retry (which keeps the id).
    public internal(set) var attempt = 1

    init(id: String, source: RepositorySource, entry: CatalogEntry, folder: String, root: URL, files: [File]) {
        self.id = id
        sourceID = source.id
        sourceName = source.name
        entryID = entry.id
        entryName = entry.name
        titleID = entry.titleID
        self.folder = folder
        self.root = root.path
        self.files = files
        created = .now
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var remainingBytes: Int64 { max(0, totalBytes - bytesDone) }
    public var fraction: Double { totalBytes > 0 ? Double(bytesDone) / Double(totalBytes) : 0 }

    var record: [String: Any] {
        var record: [String: Any] = [
            "id": id, "sourceID": sourceID, "sourceName": sourceName, "entryID": entryID,
            "entryName": entryName, "titleID": titleID, "folder": folder, "root": root,
            "state": state.rawValue, "bytesDone": bytesDone, "attempt": attempt,
            "created": created.timeIntervalSince1970,
            "files": files.map { file -> [String: Any] in
                // a SHA-256 as "sha256", as downloads.json always had it; a SHA-1 as "sha1"
                var record: [String: Any] = [
                    "kind": file.kind.rawValue, "filename": file.filename, "bytes": file.bytes,
                ].merging(file.checksum.field) { old, _ in old }
                if let published = file.published {
                    record["published"] = [
                        "device": published.device, "inode": published.inode, "bytes": published.bytes,
                    ]
                }
                return record
            },
        ]
        if let message { record["message"] = message }
        if let finished { record["finished"] = finished.timeIntervalSince1970 }
        return record
    }

    init?(record: [String: Any]) {
        guard let id = record["id"] as? String, let sourceID = record["sourceID"] as? String,
            let entryID = record["entryID"] as? String, let folder = record["folder"] as? String,
            DownloadFiles.isPlainName(folder), let root = record["root"] as? String,
            let state = (record["state"] as? String).flatMap(State.init(rawValue:)),
            let rawFiles = record["files"] as? [[String: Any]]
        else { return nil }
        self.id = id
        self.sourceID = sourceID
        sourceName = record["sourceName"] as? String ?? ""
        self.entryID = entryID
        entryName = record["entryName"] as? String ?? entryID
        titleID = record["titleID"] as? String ?? ""
        self.folder = folder
        self.root = root
        // a file whose checksum can't be read back would leave the download unable to check it: the whole download
        // is left out rather than retried without it
        guard rawFiles.allSatisfy({ (try? Checksum.read($0)) != nil }) else { return nil }
        files = rawFiles.compactMap { file in
            guard let kind = (file["kind"] as? String).flatMap(CatalogPackage.Kind.init(rawValue:)),
                let filename = file["filename"] as? String, CatalogPackage.filenameProblem(filename) == nil,
                let bytes = (file["bytes"] as? NSNumber)?.int64Value, let checksum = try? Checksum.read(file)
            else { return nil }
            var found = File(kind: kind, filename: filename, bytes: bytes, checksum: checksum)
            if let published = file["published"] as? [String: Any],
                let device = (published["device"] as? NSNumber)?.int64Value,
                let inode = (published["inode"] as? NSNumber)?.uint64Value,
                let size = (published["bytes"] as? NSNumber)?.int64Value
            {
                found.published = DownloadFiles.Published(device: device, inode: inode, bytes: size)
            }
            return found
        }
        self.state = state
        message = record["message"] as? String
        bytesDone = (record["bytesDone"] as? NSNumber)?.int64Value ?? 0
        created = Date(timeIntervalSince1970: record["created"] as? Double ?? 0)
        finished = (record["finished"] as? Double).map(Date.init(timeIntervalSince1970:))
        attempt = max(1, (record["attempt"] as? NSNumber)?.intValue ?? 1)
    }
}
