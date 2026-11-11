import Foundation

/// The eShop artwork and details of the games here: banners (Console Mode's backdrop) and icons (its tiles) downloaded
/// ahead, screenshots when a game's details are opened. The title list is large (about 90 MB), so it is fetched only
/// while a game lacks something, reduced to the details of the games asked about and kept beside the images; each
/// image is downloaded once. A game the list lacks is looked up on Nintendo's store, once for each list.
actor ArtworkStore {
    static let titleListURL = URL(
        string: "https://raw.githubusercontent.com/blawar/titledb/master/US.en.json")!
    /// The list is third-party data: images only come from Nintendo's servers, over HTTPS: the eShop's CDN titledb
    /// links to, and the asset server of the store's pages.
    static let imageHosts: Set = ["img-eshop.cdn.nintendo.net", StorePage.imageHost, StorePage.eshopImageHost]
    static let indexLifetime: TimeInterval = 7 * 86_400

    nonisolated let directory: URL
    private let titleList: URL
    private let storePage: @Sendable (String) -> URL?
    private let allowsFileURLs: Bool  // tests serve the list, the store's pages and the images from disk
    private var listTried = false  // one download of the list per launch, even when it fails
    private var storeTried: Set<String> = []  // one look at the store per title and launch, even when it fails

    init(
        directory: URL = ArtworkStore.defaultDirectory, titleList: URL = ArtworkStore.titleListURL,
        storePage: @escaping @Sendable (String) -> URL? = StorePage.url(for:), allowsFileURLs: Bool = false
    ) {
        self.directory = directory
        self.titleList = titleList
        self.storePage = storePage
        self.allowsFileURLs = allowsFileURLs
    }

    /// Caches: everything here can be downloaded again.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "com.varyform.nxplay/Banners", directoryHint: .isDirectory)
    }

    nonisolated var iconDirectory: URL {
        directory.appending(path: "icons", directoryHint: .isDirectory)
    }

    /// The banners on disk, by title ID.
    nonisolated func cachedBanners() -> [String: URL] { Self.jpegs(in: directory) }

    /// The eShop icons on disk, by title ID.
    nonisolated func cachedIcons() -> [String: URL] { Self.jpegs(in: iconDirectory) }

    /// The details kept from the list, by title ID.
    nonisolated func cachedInfo() -> [String: TitleInfo] { savedIndex()?.titles ?? [:] }

    private nonisolated static func jpegs(in folder: URL) -> [String: URL] {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil))
            ?? []
        return Dictionary(
            files.filter { $0.pathExtension == "jpg" }.map {
                ($0.deletingPathExtension().lastPathComponent, $0)
            }, uniquingKeysWith: { a, _ in a })
    }

    /// What one title has on disk now.
    struct Found: Sendable {
        var banner: URL?
        var icon: URL?
        var info: TitleInfo?
    }

    /// Fetches what these titles (upper-case title IDs) lack: details, banner, icon; in the order given, handing each
    /// title over as it lands → the titles that got anything.
    @discardableResult
    func fetch(
        _ titleIDs: [String], each: (@Sendable (String, Found) async -> Void)? = nil
    ) async -> [String: Found] {
        let banners = cachedBanners()
        let icons = cachedIcons()
        let info = cachedInfo()
        var seen = Set<String>()
        let wanted = titleIDs.filter {
            (banners[$0] == nil || icons[$0] == nil || info[$0] == nil) && seen.insert($0).inserted
        }
        guard !wanted.isEmpty, await index(for: wanted) != nil, let titles = await lookUpInStore(wanted) else {
            return [:]
        }
        try? FileManager.default.createDirectory(
            at: iconDirectory, withIntermediateDirectories: true)
        var got: [String: Found] = [:]
        for id in wanted {
            guard let title = titles[id] else { continue }
            var found = Found(banner: banners[id], icon: icons[id], info: title)
            if found.banner == nil {
                found.banner = await image(title.banner, to: directory.appending(path: "\(id).jpg"))
            }
            if found.icon == nil {
                found.icon = await image(title.icon, to: iconDirectory.appending(path: "\(id).jpg"))
            }
            got[id] = found
            await each?(id, found)
        }
        return got
    }

    /// A title's screenshots on disk, downloaded the first time they are asked for.
    func screenshots(for id: String) async -> [URL] {
        guard let links = cachedInfo()[id]?.screenshots, !links.isEmpty else { return [] }
        let folder = directory.appending(path: "screenshots/\(id)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [URL] = []
        for (index, link) in links.prefix(8).enumerated() {
            let file = folder.appending(path: "\(index).jpg")
            if FileManager.default.fileExists(atPath: file.path) {
                files.append(file)
            } else if let saved = await image(link, to: file) {
                files.append(saved)
            }
        }
        return files
    }

    private func image(_ link: String?, to file: URL) async -> URL? {
        guard let link, let url = URL(string: link), allowed(url), let data = await download(url),
            (try? data.write(to: file, options: .atomic)) != nil
        else { return nil }
        return file
    }

    // MARK: - The title list

    struct Index: Codable {
        let fetched: Date
        /// The details of the titles asked about so far, by title ID.
        var titles: [String: TitleInfo]?
        /// Titles asked about that the list doesn't have: no new download for them until the index is stale.
        var missing: [String]?
        /// The missing titles looked up on Nintendo's store since the list was fetched, found or not.
        var inStore: [String]?
    }

    private struct Entry: Decodable {
        let id: String?
        let info: TitleInfo

        private enum Key: String, CodingKey {
            case id, bannerUrl, iconUrl, screenshots, intro, description, publisher, releaseDate,
                numberOfPlayers, category, rating, ratingContent
        }

        /// Each field on its own: a field of another type in someone else's data leaves that field out, not the list.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            func text(_ key: Key) -> String? {
                (try? c.decodeIfPresent(String.self, forKey: key)).flatMap {
                    let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
            }
            func number(_ key: Key) -> Int? {
                (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil
            }
            func texts(_ key: Key) -> [String] {
                ((try? c.decodeIfPresent([String?].self, forKey: key)) ?? nil)?.compactMap(\.self)
                    ?? []
            }
            id = text(.id)
            info = TitleInfo(
                banner: text(.bannerUrl), icon: text(.iconUrl), screenshots: texts(.screenshots),
                intro: text(.intro), description: text(.description), publisher: text(.publisher),
                releaseDate: number(.releaseDate), players: number(.numberOfPlayers),
                categories: texts(.category), rating: number(.rating),
                ratingContent: texts(.ratingContent))
        }
    }

    private var indexFile: URL { directory.appending(path: "index.json") }

    private nonisolated func savedIndex() -> Index? {
        (try? Data(contentsOf: directory.appending(path: "index.json"))).flatMap {
            try? JSONDecoder().decode(Index.self, from: $0)
        }
    }

    /// The details of the wanted titles: the saved index while it is fresh and knows them all (or knows the list lacks
    /// them), else the list again, once a launch.
    private func index(for wanted: [String]) async -> [String: TitleInfo]? {
        let saved = savedIndex()
        let known = Set((saved?.titles ?? [:]).keys).union(saved?.missing ?? [])
        if let saved, let titles = saved.titles,
            listTried
                || (Date.now.timeIntervalSince(saved.fetched) < Self.indexLifetime
                    && Set(wanted).isSubset(of: known))
        {
            return titles
        }
        guard !listTried else { return saved?.titles }
        listTried = true
        // the titles asked about before stay: their details refresh with the list
        let asked = Set(wanted).union(saved?.titles.map { Array($0.keys) } ?? [])
        guard let data = await download(titleList),
            let found = await Task.detached(operation: {
                Self.titles(fromTitleList: data, wanted: asked)
            }).value
        else { return saved?.titles }
        save(Index(fetched: .now, titles: found, missing: asked.subtracting(found.keys).sorted()))
        return found
    }

    private func save(_ index: Index) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(index) {
            try? encoded.write(to: indexFile, options: .atomic)
        }
    }

    /// The saved index's titles, with the wanted ones the list lacks looked up on Nintendo's store: each once a launch,
    /// and once for each list (a list fetched again forgets them, so a game's details refresh with it). Every Switch 2
    /// game is one of them: titledb has none.
    private func lookUpInStore(_ wanted: [String]) async -> [String: TitleInfo]? {
        guard var index = savedIndex(), var titles = index.titles else { return nil }
        let looked = Set(index.inStore ?? [])
        let ask = wanted.filter { titles[$0] == nil && !looked.contains($0) && storeTried.insert($0).inserted }
        guard !ask.isEmpty else { return titles }
        for id in ask {
            if let info = await storeInfo(id) { titles[id] = info }
        }
        index.titles = titles
        index.missing = (index.missing ?? []).filter { titles[$0] == nil }
        index.inStore = looked.union(ask).sorted()
        save(index)
        return titles
    }

    /// The game's store page, through the eShop's link to it → its details.
    private func storeInfo(_ id: String) async -> TitleInfo? {
        guard let url = storePage(id), let (data, response) = try? await URLSession.shared.data(from: url)
        else { return nil }
        if !(allowsFileURLs && url.isFileURL) {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                http.url?.scheme == "https", http.url?.host == StorePage.host
            else { return nil }
        }
        return await Task.detached {
            StorePage.titleInfo(fromPage: String(decoding: data, as: UTF8.self), titleID: id)
        }.value
    }

    /// titledb's region list: {nsuid: {id, bannerUrl, …}} → the details of the wanted titles; a title listed twice
    /// takes its lowest nsuid's entry, the same one every time.
    static func titles(fromTitleList data: Data, wanted: Set<String>) -> [String: TitleInfo]? {
        guard let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return nil
        }
        var titles: [String: TitleInfo] = [:]
        for (_, entry) in entries.sorted(by: { $0.key < $1.key }) {
            guard let id = entry.id?.uppercased(), wanted.contains(id), titles[id] == nil else {
                continue
            }
            titles[id] = entry.info
        }
        return titles
    }

    private func allowed(_ url: URL) -> Bool {
        if allowsFileURLs, url.isFileURL { return true }
        return url.scheme == "https" && url.host.map(Self.imageHosts.contains) == true
    }

    private func download(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url) else {
            return nil
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
        return data
    }
}
