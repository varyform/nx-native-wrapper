import Foundation

/// The grid's and the list's games: searched, filtered and in the chosen order. Console Mode keeps its own.
extension Library {
    /// What the games are ordered by: the toolbar offers the first three, the list's column headers all of them.
    public enum GameSort: String, CaseIterable, Sendable {
        case name, lastPlayed, dateAdded, version, titleID, status

        /// The toolbar's choices; the rest belong to the list's columns.
        public static let menuChoices: [GameSort] = [.name, .lastPlayed, .dateAdded]

        /// Which way a fresh choice of it goes: names from A, dates from the latest.
        public var startsAscending: Bool { !isDate }

        var isDate: Bool { self == .lastPlayed || self == .dateAdded }
    }

    /// Which games the grid and the list show.
    public enum GameFilter: String, CaseIterable, Sendable {
        case all, switch1, switch2, needsAttention, kept
    }

    /// The games the grid and the list show, in the order they show them.
    public var shownGames: [Game] {
        Self.sorted(
            Self.filtered(games, search: search, filter: filter, needsAttention: needsAttention),
            by: sort, ascending: sortAscending)
    }

    /// A new order: `ascending` nil goes the order's natural way (the toolbar), the list's headers say which.
    public func sortGames(by sort: GameSort, ascending: Bool? = nil) {
        self.sort = sort
        sortAscending = ascending ?? sort.startsAscending
    }

    /// Something to do before the game plays as it should: a launcher still to save, a Mac app older than its build,
    /// or nxnative's news for its profile.
    public func needsAttention(_ game: Game) -> Bool {
        game.state == .extracted || game.macAppOutdated || !news(game).isEmpty
    }

    /// Those with every word of the search in their name, title ID or folder name, that the filter lets through.
    nonisolated static func filtered(
        _ games: [Game], search: String, filter: GameFilter, needsAttention: (Game) -> Bool
    ) -> [Game] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        return games.filter { game in
            let fields = [game.name, game.titleID ?? "", game.folder.lastPathComponent]
            let found = words.allSatisfy { word in
                fields.contains { $0.localizedStandardContains(word) }
            }
            guard found else { return false }
            return switch filter {
            case .all: true
            // a game not extracted yet may have no title ID: it is neither
            case .switch1: game.titleID?.hasPrefix("01") == true
            case .switch2: game.isSwitch2
            case .needsAttention: needsAttention(game)
            case .kept: game.isKept
            }
        }
    }

    /// Ties go by name, so an order never shuffles games between refreshes; a game with no date goes last either way.
    nonisolated static func sorted(_ games: [Game], by sort: GameSort, ascending: Bool) -> [Game] {
        func byName(_ a: Game, _ b: Game) -> Bool {
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.folder.path < b.folder.path : order == .orderedAscending
        }
        func text(_ a: Game, _ b: Game, _ key: (Game) -> String) -> Bool {
            let order = key(a).localizedStandardCompare(key(b))
            return order == .orderedSame ? byName(a, b) : (order == .orderedAscending) == ascending
        }
        func date(_ a: Game, _ b: Game, _ key: (Game) -> Date?) -> Bool {
            switch (key(a), key(b)) {
            case (let x?, let y?) where x != y: ascending ? x < y : x > y
            case (_?, nil): true
            case (nil, _?): false
            default: byName(a, b)
            }
        }
        return games.sorted { a, b in
            switch sort {
            case .name: ascending ? byName(a, b) : byName(b, a)
            case .lastPlayed: date(a, b, \.lastPlayed)
            case .dateAdded: date(a, b, \.added)
            case .version: text(a, b) { $0.version ?? "" }
            case .titleID: text(a, b) { $0.titleID ?? "" }
            case .status:
                statusRank(a) == statusRank(b)
                    ? byName(a, b) : (statusRank(a) < statusRank(b)) == ascending
            }
        }
    }

    /// Ready first, then extracted, then the rest, as the grid's sections go.
    nonisolated static func statusRank(_ game: Game) -> Int {
        switch game.state {
        case .ready: 0
        case .extracted: 1
        case .notExtracted: 2
        }
    }
}
