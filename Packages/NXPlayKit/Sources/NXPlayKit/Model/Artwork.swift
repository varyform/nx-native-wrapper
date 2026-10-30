import Foundation

/// What the eShop says about a game, from the community title database blawar/titledb (the source NX2Apple's front end
/// uses too): its banner (1920×1080), its square icon, screenshots and the store page's text and facts. Images come
/// only from Nintendo's CDN.
public struct TitleInfo: Codable, Equatable, Sendable {
    public var banner: String?
    public var icon: String?
    public var screenshots: [String] = []
    /// The store page's tagline ("STEP INTO A WORLD OF ADVENTURE").
    public var intro: String?
    public var description: String?
    public var publisher: String?
    /// yyyymmdd, as titledb writes it.
    public var releaseDate: Int?
    public var players: Int?
    public var categories: [String] = []
    /// The US list's age rating (ESRB): 6, 10, 13, 17, 18.
    public var rating: Int?
    public var ratingContent: [String] = []

    public var released: Date? {
        guard let date = releaseDate, date > 1900_00_00 else { return nil }
        return DateComponents(
            calendar: Calendar(identifier: .gregorian), year: date / 10000, month: date / 100 % 100,
            day: date % 100
        ).date
    }

    /// "E10+" for the ESRB ages the US list gives.
    public var ratingLabel: String? {
        guard let rating else { return nil }
        switch rating {
        case ...6: return "E"
        case 10: return "E10+"
        case 13: return "T"
        case 17: return "M"
        case 18: return "AO"
        default: return "\(rating)+"
        }
    }

    /// "1 player", "Up to 4 players".
    public var playersLabel: String? {
        guard let players, players > 0 else { return nil }
        return players == 1 ? "1 player" : "Up to \(players) players"
    }
}

/// The eShop artwork and details of the games here: banners (Console Mode's backdrop) and icons (its tiles) downloaded
/// ahead, screenshots when a game's details are opened. The title list is large (about 90 MB), so it is fetched only
/// while a game lacks something, reduced to the details of the games asked about and kept beside the images; each
/// image is downloaded once.
actor ArtworkStore {
    static let titleListURL = URL(
        string: "https://raw.githubusercontent.com/blawar/titledb/master/US.en.json")!
    /// The list is third-party data: images only come from Nintendo's CDN, over HTTPS.
    static let imageHost = "img-eshop.cdn.nintendo.net"
    static let indexLifetime: TimeInterval = 7 * 86_400

    nonisolated let directory: URL
    private let titleList: URL
    private let allowsFileURLs: Bool  // tests serve the list and the images from disk
    private var listTried = false  // one download of the list per launch, even when it fails

    init(
        directory: URL = ArtworkStore.defaultDirectory, titleList: URL = ArtworkStore.titleListURL,
        allowsFileURLs: Bool = false
    ) {
        self.directory = directory
        self.titleList = titleList
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
        guard !wanted.isEmpty, let titles = await index(for: wanted) else { return [:] }
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
        let index = Index(
            fetched: .now, titles: found, missing: asked.subtracting(found.keys).sorted())
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(index) {
            try? encoded.write(to: indexFile, options: .atomic)
        }
        return found
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
        return url.scheme == "https" && url.host == Self.imageHost
    }

    private func download(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url) else {
            return nil
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
        return data
    }
}
