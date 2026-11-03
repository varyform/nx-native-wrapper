import Foundation

/// Sources through the iOS app's API (Library+Remote.swift), with the same pairing code. The iPhone or iPad browses the
/// Mac's sources and asks the Mac to download a game into its games folder; once it's there it is a game of the
/// library like any other, and installing it is the usual Install, which the player asks for. Adding and removing
/// sources, and their tokens, stay on the Mac.
///
///     GET  /v1/sources                          the sources, each with its catalog's state
///     POST /v1/sources/refresh[?source=<id>]    reads the catalogs again
///     GET  /v1/sources/<id>/entries[?q=<words>] a source's games, with what's in the games folder already
///     GET  /v1/downloads                        the downloads, running, waiting and finished
///     POST /v1/downloads?source=<id>&entry=<id>[&packages=<package id>,…]   (a package's id: its SHA-256, or sha1:<hex>)
///     POST /v1/downloads/<id>/cancel
///     POST /v1/downloads/<id>/retry
extension Library {
    /// What the downloads need from the library: the games folder, the game folders it has, a look at the folder
    /// once files land, and the quit bin/install may be waiting for.
    func connectRepositories() {
        repositories.root = { [weak self] in self?.root }
        repositories.existingFolder = { [weak self] titleID in
            self?.titleFolders[titleID.uppercased()]
        }
        repositories.onPublished = { [weak self] _ in self?.refresh() }
        repositories.onIdle = { [weak self] in self?.quitIfIdle() }
    }

    /// The library's game folders by the base game's title ID, for the downloads to find a game's folder. A built game
    /// has its title ID from its build; one that's only files so far (downloaded or copied in) from a `[title ID]` in
    /// the folder's name, as Sources names its folders, else in the name of a game file in it, as dumps are named
    /// (`Game [0100000000010000][v0].nsp`; an update's or DLC's ID counts for its base game). Built games come first,
    /// then folder names, then file names; the library's order (by name) settles the rest.
    static func titleFolderIndex(_ games: [Game]) -> [String: String] {
        func ids(in name: String) -> [String] {
            name.matches(of: #/\[([0-9A-Fa-f]{16})\]/#).compactMap { Catalog.baseTitleID(String($0.1)) }
        }
        var folders: [String: String] = [:]
        for game in games {
            if let titleID = game.titleID.flatMap(Catalog.baseTitleID) {
                folders[titleID] = folders[titleID] ?? game.folder.lastPathComponent
            }
        }
        for game in games where game.titleID == nil {
            let name = game.folder.lastPathComponent
            for titleID in ids(in: name) + (Catalog.isTitleID(name) ? [name.uppercased()] : []) {
                folders[titleID] = folders[titleID] ?? name
            }
        }
        for game in games where game.titleID == nil && game.hasPackages {
            let files = GameScanner.children(of: game.folder)
                .filter { GameScanner.packageExtensions.contains($0.pathExtension.lowercased()) }
                .map(\.lastPathComponent).sorted()
            for titleID in files.flatMap(ids(in:)) {
                folders[titleID] = folders[titleID] ?? game.folder.lastPathComponent
            }
        }
        return folders
    }

    /// The answer to a Sources request, nil for any other path.
    func respondToRepositories(_ request: RemoteRequest) async -> RemoteResponse? {
        let route = request.route
        if route("GET", "v1/sources") != nil {
            return .json(repositories.sources.map(remoteJSON))
        }
        if route("POST", "v1/sources/refresh") != nil {
            if let id = request.query["source"] {
                guard repositories.source(id) != nil else { return .error(404, "No source \(id)") }
                await repositories.refresh(id)
            } else {
                await repositories.refreshAll()
            }
            return .json(repositories.sources.map(remoteJSON))
        }
        if let id = route("GET", "v1/sources/*/entries")?.first {
            guard let source = repositories.source(id) else { return .error(404, "No source \(id)") }
            guard source.enabled else { return .error(409, "\(source.name) is turned off on the Mac") }
            if repositories.catalog(id) == nil { await repositories.refresh(id) }
            if case .failed(let message) = repositories.states[id] { return .error(502, message) }
            let entries = repositories.entries(source: id, search: request.query["q"] ?? "")
            return .json(entries.map { remoteJSON($0.entry) })
        }
        if route("GET", "v1/downloads") != nil {
            return .json(repositories.downloads.map(remoteJSON))
        }
        if route("POST", "v1/downloads") != nil {
            let packages = request.query["packages"].map {
                Set($0.split(separator: ",").map { $0.lowercased() })
            }
            return answer(status: 202) {
                try repositories.download(
                    source: request.query["source"] ?? "", entry: request.query["entry"] ?? "",
                    packages: packages)
            }
        }
        if let id = route("POST", "v1/downloads/*/cancel")?.first {
            guard repositories.job(id) != nil else { return .error(404, "No download \(id)") }
            repositories.cancel(id)
            return .json(repositories.job(id).map(remoteJSON) ?? [:])
        }
        if let id = route("POST", "v1/downloads/*/retry")?.first {
            return answer(status: 202) { try repositories.retry(id) }
        }
        return nil
    }

    private func answer(status: Int, _ start: () throws -> DownloadJob) -> RemoteResponse {
        do {
            return .json(remoteJSON(try start()), status: status)
        } catch let failure as Repositories.Failure {
            return .error(failure.status, failure.message)
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    /// The library's game in a download's folder, by the id /v1/games gives it: what Install takes.
    func libraryGameID(folder: String) -> String? {
        games.first { $0.folder.lastPathComponent == folder }?.folder.lastPathComponent
    }

    private func remoteJSON(_ source: RepositorySource) -> [String: Any] {
        var json: [String: Any] = [
            "id": source.id, "name": source.name, "origin": source.origin?.text ?? "",
            "enabled": source.enabled, "error": NSNull(), "entries": 0, "issues": 0, "refreshed": NSNull(),
        ]
        switch repositories.states[source.id] ?? .notLoaded {
        case .notLoaded: json["state"] = "notLoaded"
        case .loading: json["state"] = "loading"
        case .loaded(let catalog, let at):
            json["state"] = "loaded"
            json["entries"] = catalog.entries.count
            json["issues"] = catalog.issues.count
            json["refreshed"] = at.ISO8601Format()
        case .failed(let message):
            json["state"] = "failed"
            json["error"] = message
        }
        return json
    }

    private func remoteJSON(_ entry: CatalogEntry) -> [String: Any] {
        let folder = repositories.folder(for: entry)
        return [
            "id": entry.id, "name": entry.name, "titleID": entry.titleID, "version": entry.version,
            "publisher": entry.publisher, "description": entry.summary, "folder": folder,
            "libraryGame": libraryGameID(folder: folder) ?? NSNull(),
            "issues": entry.issues,
            "packages": entry.packages.map { package in
                [
                    "id": package.id, "kind": package.kind.rawValue, "filename": package.filename,
                    "bytes": package.bytes, "checksum": package.checksum.algorithm.rawValue,
                    "titleID": package.titleID ?? NSNull(),
                    "version": package.version ?? NSNull(),
                    "present": repositories.isPresent(package, of: entry),
                    "download": repositories.activeJob(for: package)?.id ?? NSNull(),
                ] as [String: Any]
            },
        ]
    }

    private func remoteJSON(_ job: DownloadJob) -> [String: Any] {
        [
            "id": job.id, "source": job.sourceID, "sourceName": job.sourceName, "entry": job.entryID,
            "entryName": job.entryName, "titleID": job.titleID, "folder": job.folder,
            "state": job.state.rawValue, "message": job.message ?? NSNull(),
            "bytesDone": job.bytesDone, "totalBytes": job.totalBytes, "fraction": job.fraction,
            "fileIndex": job.fileIndex,
            "files": job.files.map {
                [
                    "kind": $0.kind.rawValue, "filename": $0.filename, "bytes": $0.bytes,
                    "checksum": $0.checksum.algorithm.rawValue,
                ] as [String: Any]
            },
            "libraryGame": (job.state == .succeeded ? libraryGameID(folder: job.folder) : nil) ?? NSNull(),
        ]
    }
}
