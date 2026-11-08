import Foundation
import Testing

@testable import NXPlayKit

@Suite struct LibrarySortingTests {
    static let day = 86_400.0

    static func game(
        _ name: String, folder: String? = nil, titleID: String? = nil, version: String? = nil,
        played: Double? = nil, added: Double? = nil, kept: Bool = false, state: Game.State = .ready
    ) -> Game {
        var game = Game(
            folder: URL(filePath: "/games/\(folder ?? name)"), name: name, titleID: titleID,
            version: version, languages: [], iconURL: nil, buildFolder: nil, ipaURL: nil,
            xcodeBuildFolder: nil, hasPackages: true, state: state)
        game.lastPlayed = played.map { Date(timeIntervalSince1970: $0 * day) }
        game.added = added.map { Date(timeIntervalSince1970: $0 * day) }
        game.isKept = kept
        return game
    }

    static let games = [
        game("Zelda", titleID: "0100000000010000", version: "1.10", played: 3, added: 1),
        game("animal", titleID: "0400000000020000", version: "1.9", added: 5, kept: true),
        game("Mario", titleID: "0100000000030000", version: "2.0", played: 7, state: .extracted),
        game("Mario", folder: "Mario copy", titleID: "0100000000030000", version: "2.0", played: 7),
        game("New", state: .notExtracted),
    ]

    static func order(_ sort: Library.GameSort, ascending: Bool) -> [String] {
        Library.sorted(games, by: sort, ascending: ascending).map(\.folder.lastPathComponent)
    }

    @Test func namesGoAsFinderSortsThemTiesByFolder() {
        #expect(Self.order(.name, ascending: true) == ["animal", "Mario", "Mario copy", "New", "Zelda"])
        #expect(Self.order(.name, ascending: false) == ["Zelda", "New", "Mario copy", "Mario", "animal"])
    }

    @Test func aGameWithNoDateGoesLastEitherWay() {
        #expect(Self.order(.lastPlayed, ascending: false) == ["Mario", "Mario copy", "Zelda", "animal", "New"])
        #expect(Self.order(.lastPlayed, ascending: true) == ["Zelda", "Mario", "Mario copy", "animal", "New"])
        #expect(Self.order(.dateAdded, ascending: false) == ["animal", "Zelda", "Mario", "Mario copy", "New"])
    }

    @Test func versionsCompareAsNumbers() {
        #expect(Self.order(.version, ascending: true) == ["New", "animal", "Zelda", "Mario", "Mario copy"])
        #expect(Self.order(.status, ascending: true) == ["animal", "Mario copy", "Zelda", "Mario", "New"])
    }

    @Test func filtersTakeTheSearchAlong() {
        func shown(_ filter: Library.GameFilter, _ search: String = "") -> [String] {
            Library.filtered(Self.games, search: search, filter: filter) { $0.state == .extracted }
                .map(\.folder.lastPathComponent)
        }
        #expect(shown(.all).count == 5)
        #expect(shown(.switch1) == ["Zelda", "Mario", "Mario copy"])  // no title ID yet: neither
        #expect(shown(.switch2) == ["animal"])
        #expect(shown(.needsAttention) == ["Mario"])
        #expect(shown(.kept) == ["animal"])
        #expect(shown(.switch1, "copy") == ["Mario copy"])
        #expect(shown(.switch2, "mario").isEmpty)
    }

    @MainActor @Test func theOrderIsRememberedTheFilterIsNot() {
        let suite = testDefaultsName()
        defer { removeTestDefaults(suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let library = Library(defaults: defaults, isScreenshot: true)
        #expect(library.sort == .name && library.sortAscending)
        library.sortGames(by: .lastPlayed)
        #expect(!library.sortAscending)  // the latest first
        library.sortGames(by: .lastPlayed, ascending: true)
        library.filter = .kept

        let again = Library(defaults: defaults, isScreenshot: true)
        #expect(again.sort == .lastPlayed && again.sortAscending)
        #expect(again.filter == .all)
    }
}
