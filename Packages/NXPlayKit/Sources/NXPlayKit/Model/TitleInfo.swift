import Foundation

/// What the eShop says about a game, from the community title database blawar/titledb (the source NX2Apple's front end
/// uses too), or for a game titledb lacks from Nintendo's store page (StorePage): its banner (1920×1080), its square
/// icon, screenshots and the store page's text and facts. Images come only from Nintendo's servers.
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
