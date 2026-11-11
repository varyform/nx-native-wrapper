import Foundation

/// Nintendo's US store, for a title titledb doesn't have: every Switch 2 game, and Switch games newer than its last
/// update (issue #24). `ec.nintendo.com/apps/<title ID>/US` is the eShop's own link to a game's store page; it
/// redirects to the page, whose data names the game by the same title ID and carries everything titledb gives.
/// Its images are on Nintendo's asset server, served as JPEG at their full size (a 1920×1080 banner, a 1024×1024
/// icon).
enum StorePage {
    static let host = "www.nintendo.com"
    static let imageHost = "assets.nintendo.com"
    /// The eShop's own image server: some pages' icons are the asset server fetching a JPEG from it.
    static let eshopImageHost = "atum-img-lp1.cdn.nintendo.net"

    static func url(for titleID: String) -> URL? {
        URL(string: "https://ec.nintendo.com/apps/\(titleID.uppercased())/US")
    }

    /// The page's data (Next.js's, a cache of the store's GraphQL answers) → the details of the game with this title
    /// ID. A page also lists other games, related or bought together, without a title ID.
    static func titleInfo(fromPage html: String, titleID: String) -> TitleInfo? {
        guard let state = apolloState(html) else { return nil }
        let id = titleID.lowercased()
        let products = state.values.filter {
            $0["__typename"] as? String == "Product" && ($0["applicationId"] as? String)?.lowercased() == id
        }
        // the game itself before its pass or bundle, the same one every time
        guard
            let product = products.sorted(by: {
                ($0["productImage"] == nil ? 1 : 0, $0["sku"] as? String ?? "")
                    < ($1["productImage"] == nil ? 1 : 0, $1["sku"] as? String ?? "")
            }).first
        else { return nil }
        return info(product, in: state)
    }

    private static func apolloState(_ html: String) -> [String: [String: Any]]? {
        guard let start = html.range(of: #"<script id="__NEXT_DATA__" type="application/json">"#),
            let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
            let data = html[start.upperBound..<end.lowerBound].data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let props = root["props"] as? [String: Any],
            let page = props["pageProps"] as? [String: Any],
            let state = page["initialApolloState"] as? [String: Any]
        else { return nil }
        return state.compactMapValues { $0 as? [String: Any] }
    }

    private static func info(_ product: [String: Any], in state: [String: [String: Any]]) -> TitleInfo {
        func text(_ value: Any?) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return nil }
            return text
        }
        /// A reference to another record of the page ({"__ref": key}) → that record.
        func record(_ value: Any?) -> [String: Any]? {
            (value as? [String: Any]).flatMap { $0["__ref"] as? String }.flatMap { state[$0] }
        }
        let image = { (key: String) in
            (product[key] as? [String: Any]).flatMap { text($0["url"]) ?? text($0["publicId"]) }.flatMap(jpeg)
        }
        let gallery = (product["productGallery"] as? [[String: Any]] ?? [])
            .filter { $0["resourceType"] as? String == "image" }
            .compactMap { text($0["publicId"]).flatMap(jpeg) }
        let genres = ((product["tags"] as? [String: Any])?["genres"] as? [[String: Any]] ?? [])
            .compactMap { text($0["label"]) }
        let players = ((product["numberOfPlayers"] as? [String: Any])?["system"] as? [String: Any])
            .flatMap { ($0["max"] as? Int) ?? ($0["min"] as? Int) }
        let rating = record(product["contentRating"]).flatMap { rating -> Int? in
            guard rating["system"] as? String == "ESRB" else { return nil }
            return esrbAges[(rating["code"] as? String ?? "").lowercased()]
        }
        let descriptors = (product["contentDescriptors"] as? [Any] ?? []).compactMap { text(record($0)?["label"]) }
        return TitleInfo(
            banner: image("productImage"), icon: image(#"productImage({"shape":"square"})"#), screenshots: gallery,
            intro: text(product["headline"]), description: text(product["description"]),
            publisher: text(product["softwarePublisher"]), releaseDate: text(product["releaseDate"]).flatMap(day),
            players: players, categories: genres, rating: rating, ratingContent: descriptors)
    }

    /// The ages TitleInfo keeps, as titledb gives them for the US list.
    private static let esrbAges = ["e": 6, "e10": 10, "t": 13, "m": 17, "ao": 18]

    /// "2026-11-05T00:00:00.000Z" → 20261105, as titledb writes a date.
    static func day(_ date: String) -> Int? {
        let digits = date.prefix(10).filter(\.isNumber)
        return digits.count == 8 ? Int(digits) : nil
    }

    /// An image on the asset server, as its link or its id, as a JPEG at full size: the link the page gives takes
    /// whatever format the browser accepts (WebP, AVIF), and NX Play keeps JPEGs. One the asset server fetches from
    /// the eShop's image server comes from there, a JPEG already.
    static func jpeg(_ image: String) -> String? {
        var path: Substring
        if let url = URL(string: image), let host = url.host {
            guard url.scheme == "https", host == imageHost else { return nil }
            if let fetch = image.range(of: "/image/fetch/") {
                guard let inner = image[fetch.upperBound...].range(of: "https://"),
                    let source = URL(string: String(image[inner.lowerBound...])),
                    source.host == eshopImageHost
                else { return nil }
                return source.absoluteString
            }
            guard let upload = url.path.range(of: "/image/upload/") else { return nil }
            path = url.path[upload.upperBound...]
        } else {
            path = Substring(image)
        }
        // the transformations before the image's id: q_auto, f_auto, c_fill,w_100…
        var parts = path.split(separator: "/")
        while let first = parts.first, first.contains("_") { parts.removeFirst() }
        guard parts.first == "store" else { return nil }
        return "https://\(imageHost)/image/upload/f_jpg/q_auto/" + parts.joined(separator: "/")
    }
}
