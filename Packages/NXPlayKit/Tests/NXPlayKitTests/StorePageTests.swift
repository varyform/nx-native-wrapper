import Foundation
import Testing

@testable import NXPlayKit

/// Nintendo's store pages, for the titles titledb lacks (issue #24).
@Suite struct StorePageTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static let ocarina = "0400486024DEC000"
    static let asset = "https://assets.nintendo.com/image/upload"

    /// A store page as Next.js writes it: the game, a related game without a title ID, the records it refers to.
    static func page(images: Bool = true) throws -> String {
        let art = "store/software/switch2/70010000130792"
        var game: [String: Any] = [
            "__typename": "Product", "sku": "7100130792", "applicationId": ocarina.lowercased(),
            "name": "The Legend of Zelda™: Ocarina of Time",
            "headline": " Become the Hero of Time and save Hyrule from darkness ",
            "description": "Take up your sword and embark on a grand adventure!\n\nSet out with Navi.",
            "softwarePublisher": "Nintendo", "releaseDate": "2026-11-05T00:00:00.000Z",
            "numberOfPlayers": [
                "system": ["max": NSNull(), "min": 1], "local": NSNull(), "online": NSNull(),
            ],
            "tags": ["genres": [["code": "ACTION", "label": "Action"], ["code": "ADVENTURE", "label": "Adventure"]]],
            "contentRating": ["__ref": "ContentRating:{\"id\":\"r\"}"],
            "contentDescriptors": [
                ["__ref": "ContentDescriptor:{\"id\":\"a\"}"], ["__ref": "ContentDescriptor:{\"id\":\"b\"}"],
            ],
        ]
        if images {
            game["productImage"] = [
                "publicId": "\(art)/banner", "url": "\(asset)/q_auto/f_auto/\(art)/banner",
            ]
            game[#"productImage({"shape":"square"})"#] = ["url": "\(asset)/q_auto/f_auto/\(art)/icon"]
            game["productGallery"] = [
                ["resourceType": "video", "publicId": "/\(art)/Video/trailer"],
                ["resourceType": "image", "publicId": "\(art)/shot1"],
                ["resourceType": "image", "publicId": "\(art)/shot2"],
            ]
        }
        let state: [String: Any] = [
            "Product:{\"sku\":\"7100130792\"}": game,
            "Product:{\"sku\":\"7100096813\"}": [
                "__typename": "Product", "sku": "7100096813", "name": "Nintendo Switch™ 2 Welcome Tour",
                "headline": "not this one",
            ],
            "ContentRating:{\"id\":\"r\"}": ["__typename": "ContentRating", "code": "e10", "system": "ESRB"],
            "ContentDescriptor:{\"id\":\"a\"}": ["label": "Animated Blood"],
            "ContentDescriptor:{\"id\":\"b\"}": ["label": "Fantasy Violence"],
            "ROOT_QUERY": ["__typename": "Query"],
        ]
        let data = try JSONSerialization.data(withJSONObject: ["props": ["pageProps": ["initialApolloState": state]]])
        return """
            <html><head><script src="/app.js"></script></head><body>
            <script id="__NEXT_DATA__" type="application/json">\(String(decoding: data, as: UTF8.self))</script>
            </body></html>
            """
    }

    @Test func readsTheGamesDetailsFromItsPage() throws {
        let info = try #require(StorePage.titleInfo(fromPage: Self.page(), titleID: Self.ocarina))
        #expect(info.intro == "Become the Hero of Time and save Hyrule from darkness")
        #expect(info.description?.hasPrefix("Take up your sword") == true && info.publisher == "Nintendo")
        #expect(info.releaseDate == 2026_11_05 && info.players == 1)
        #expect(info.categories == ["Action", "Adventure"])
        #expect(info.ratingLabel == "E10+" && info.ratingContent == ["Animated Blood", "Fantasy Violence"])
        // JPEGs at full size, the videos left out
        let art = "\(Self.asset)/f_jpg/q_auto/store/software/switch2/70010000130792"
        #expect(info.banner == "\(art)/banner" && info.icon == "\(art)/icon")
        #expect(info.screenshots == ["\(art)/shot1", "\(art)/shot2"])

        #expect(try StorePage.titleInfo(fromPage: Self.page(), titleID: "0100000000010000") == nil)
        #expect(StorePage.titleInfo(fromPage: "<html>Not found</html>", titleID: Self.ocarina) == nil)
    }

    @Test func takesImagesOnlyFromNintendosAssetServer() {
        #expect(StorePage.jpeg("https://example.com/image/upload/q_auto/store/a") == nil)
        #expect(StorePage.jpeg("http://assets.nintendo.com/image/upload/store/a") == nil)
        #expect(StorePage.jpeg("/Video/store/a") == nil)
        #expect(StorePage.jpeg("\(Self.asset)/c_fill,w_100/q_auto/store/a/b") == "\(Self.asset)/f_jpg/q_auto/store/a/b")
        // an icon the asset server fetches from the eShop's image server comes from there, from nowhere else
        let eshop = "https://atum-img-lp1.cdn.nintendo.net/i/c/4591b859_1024"
        #expect(StorePage.jpeg("https://assets.nintendo.com/image/fetch/q_auto/f_auto/\(eshop)") == eshop)
        #expect(StorePage.jpeg("https://assets.nintendo.com/image/fetch/q_auto/https://example.com/a.jpg") == nil)
        #expect(StorePage.day("2026-11-05T00:00:00.000Z") == 2026_11_05 && StorePage.day("soon") == nil)
    }

    @Test func looksUpATitleTheListLacksOnceForEachList() async throws {
        let list = root.appending(path: "US.en.json")
        try Data(#"{"70010000000002": {"id": "0100F2C0115B6000", "publisher": "Nintendo"}}"#.utf8).write(to: list)
        let page = root.appending(path: "ocarina.html")
        // no images: a test downloads nothing from the asset server
        try Data(Self.page(images: false).utf8).write(to: page)
        let pages: @Sendable (String) -> URL? = { $0 == Self.ocarina ? page : nil }
        let directory = root.appending(path: "Banners")

        let store = ArtworkStore(directory: directory, titleList: list, storePage: pages, allowsFileURLs: true)
        let got = await store.fetch([Self.ocarina, "0100F2C0115B6000", "0100000000000099"])
        #expect(got[Self.ocarina]?.info?.intro == "Become the Hero of Time and save Hyrule from darkness")
        #expect(got["0100F2C0115B6000"]?.info?.publisher == "Nintendo")
        #expect(got["0100000000000099"] == nil)  // on neither

        // the next launch: both kept, the store not asked again while the list is the same
        try FileManager.default.removeItem(at: page)
        try FileManager.default.removeItem(at: list)
        let next = ArtworkStore(directory: directory, titleList: list, storePage: pages, allowsFileURLs: true)
        let again = await next.fetch([Self.ocarina, "0100000000000099"])
        #expect(again[Self.ocarina]?.info?.publisher == "Nintendo" && again["0100000000000099"] == nil)
    }

    @Test func anIndexFromBeforeTheStoreLooksItUp() async throws {
        // 1.8.9's index: the game listed as missing, the list fresh, the store never asked
        let directory = root.appending(path: "Banners")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(
            #"{"fetched": \#(Date.now.timeIntervalSinceReferenceDate), "titles": {}, "missing": ["\#(Self.ocarina)"]}"#
                .utf8
        ).write(to: directory.appending(path: "index.json"))
        let page = root.appending(path: "ocarina.html")
        try Data(Self.page(images: false).utf8).write(to: page)
        let store = ArtworkStore(
            directory: directory, titleList: root.appending(path: "none.json"), storePage: { _ in page },
            allowsFileURLs: true)
        #expect(await store.fetch([Self.ocarina])[Self.ocarina]?.info?.publisher == "Nintendo")
    }
}
