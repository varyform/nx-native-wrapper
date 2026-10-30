import Foundation
import Testing

@testable import NXPlayKit

@Suite struct ArtworkTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-artwork-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func image(_ name: String, _ text: String) throws -> URL {
        let url = root.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// titledb's shape: {nsuid: {id, bannerUrl, iconUrl, …}}, with a title listed twice, one without a banner, one
    /// whose banner is on another host, and fields of odd types.
    private func titleList(banner: URL, icon: URL? = nil, shot: URL? = nil) throws -> URL {
        let list: [String: [String: Any?]] = [
            "70010000000002": [
                "id": "0100f2c0115b6000", "bannerUrl": banner.absoluteString,
                "iconUrl": icon?.absoluteString,
                "screenshots": shot.map { [$0.absoluteString, nil] },
                "intro": " STEP INTO A WORLD OF ADVENTURE ", "description": "Forget everything.",
                "publisher": "Nintendo", "releaseDate": 20_230_512, "numberOfPlayers": 1,
                "category": ["Adventure", "Action"], "rating": 10,
                "ratingContent": ["Fantasy Violence"],
            ],
            "70010000000009": ["id": "0100F2C0115B6000", "bannerUrl": "file:///elsewhere.jpg"],
            // a rating as text and an empty intro: those fields are left out, not the entry or the list
            "70010000000003": [
                "id": "01007EF00011E000", "bannerUrl": NSNull(), "rating": "E", "intro": "",
                "publisher": "Nintendo",
            ],
            "70010000000004": [
                "id": "010093801237C000", "bannerUrl": "https://example.com/banner.jpg",
            ],
        ]
        let url = root.appending(path: "US.en.json")
        try JSONSerialization.data(withJSONObject: list.mapValues { $0.compactMapValues { $0 } })
            .write(to: url)
        return url
    }

    @Test func fetchesTheDetailsBannerAndIconOnce() async throws {
        let list = try titleList(
            banner: image("totk.jpg", "banner"), icon: image("icon.jpg", "icon"),
            shot: image("shot.jpg", "shot"))
        let store = ArtworkStore(
            directory: root.appending(path: "Banners"), titleList: list, allowsFileURLs: true)

        let got = await store.fetch(["0100F2C0115B6000", "01007EF00011E000"])
        let totk = try #require(got["0100F2C0115B6000"])
        #expect(try Data(contentsOf: #require(totk.banner)) == Data("banner".utf8))
        #expect(try Data(contentsOf: #require(totk.icon)) == Data("icon".utf8))
        let info = try #require(totk.info)
        #expect(info.intro == "STEP INTO A WORLD OF ADVENTURE" && info.publisher == "Nintendo")
        #expect(info.players == 1 && info.categories == ["Adventure", "Action"])
        #expect(info.ratingLabel == "E10+" && info.ratingContent == ["Fantasy Violence"])
        #expect(
            info.released.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
                == 2023)
        // no banner or icon, but its details
        let botw = try #require(got["01007EF00011E000"]?.info)
        #expect(botw.publisher == "Nintendo" && botw.rating == nil && botw.intro == nil)
        #expect(store.cachedInfo().keys.sorted() == ["01007EF00011E000", "0100F2C0115B6000"])

        // screenshots on demand, then from disk
        let shots = await store.screenshots(for: "0100F2C0115B6000")
        #expect(shots.count == 1)
        try FileManager.default.removeItem(at: root.appending(path: "shot.jpg"))
        #expect(await store.screenshots(for: "0100F2C0115B6000") == shots)

        // all on disk: nothing to fetch, not even the list
        try FileManager.default.removeItem(at: list)
        let again = ArtworkStore(
            directory: root.appending(path: "Banners"), titleList: list, allowsFileURLs: true)
        #expect(await again.fetch(["0100F2C0115B6000"]).isEmpty)
    }

    @Test func aTitleTheListLacksDoesntFetchItAgain() async throws {
        let list = try titleList(banner: image("totk.jpg", "banner"))
        let directory = root.appending(path: "Banners")
        _ = await ArtworkStore(directory: directory, titleList: list, allowsFileURLs: true)
            .fetch(["0100F2C0115B6000", "0100000000000099"])
        // the next launch: the index knows the missing title, so the list (gone now) isn't needed
        try FileManager.default.removeItem(at: list)
        let next = ArtworkStore(directory: directory, titleList: list, allowsFileURLs: true)
        let got = await next.fetch(["0100F2C0115B6000", "0100000000000099"])
        #expect(got["0100F2C0115B6000"]?.info?.publisher == "Nintendo")
        #expect(got["0100000000000099"] == nil)
    }

    @Test func handsOverEachTitleAsItLandsInTheOrderAsked() async throws {
        let a = try image("a.jpg", "a")
        let b = try image("b.jpg", "b")
        let list = root.appending(path: "list.json")
        try JSONSerialization.data(withJSONObject: [
            "1": ["id": "0100000000000001", "bannerUrl": a.absoluteString],
            "2": ["id": "0100000000000002", "bannerUrl": b.absoluteString],
        ]).write(to: list)
        let store = ArtworkStore(
            directory: root.appending(path: "Banners"), titleList: list, allowsFileURLs: true)
        let order = Order()
        // the game Console Mode opens on first, whatever the title IDs' order; a repeat is asked once
        let got = await store.fetch(["0100000000000002", "0100000000000001", "0100000000000002"]) {
            id, _ in await order.add(id)
        }
        #expect(got.count == 2)
        #expect(await order.ids == ["0100000000000002", "0100000000000001"])
    }

    actor Order {
        var ids: [String] = []
        func add(_ id: String) { ids.append(id) }
    }

    @Test func takesImagesOnlyFromNintendosCDN() async throws {
        let list = try titleList(banner: root.appending(path: "missing.jpg"))
        let store = ArtworkStore(directory: root.appending(path: "Banners"), titleList: list)
        // a file URL and another host: neither is downloaded, the details still are
        let got = await store.fetch(["0100F2C0115B6000", "010093801237C000"])
        #expect(got.values.allSatisfy { $0.banner == nil && $0.icon == nil })
        #expect(store.cachedBanners().isEmpty)
    }

    @Test func aTitleListedTwiceTakesItsLowestNsuidsEntry() throws {
        let titles = try #require(
            ArtworkStore.titles(
                fromTitleList: Data(contentsOf: titleList(banner: URL(filePath: "/first.jpg"))),
                wanted: ["0100F2C0115B6000", "01007EF00011E000"]))
        #expect(titles["0100F2C0115B6000"]?.banner == "file:///first.jpg")
        #expect(titles["01007EF00011E000"]?.banner == nil)
        #expect(titles["010093801237C000"] == nil)  // not asked for
    }
}
