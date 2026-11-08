import SwiftUI

/// The games as a list: extracted games, then the ones still to extract, as the grid shows them; each section
/// sortable by any column, the order the toolbar's menu sets too, with the arrow keys moving the selection.
/// Double-click and the context menu do what they do on a card.
struct GameList: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        let rows = library.shownGames.map(GameRow.init)
        let extracted = rows.filter(\.game.isExtracted)
        let remaining = rows.filter { !$0.game.isExtracted }
        if library.games.isEmpty {
            ContentUnavailableView(
                "No Games", systemImage: "gamecontroller",
                description: Text("No subfolder here holds NSP, NSZ, XCI, XCZ or NUP files."))
        } else if rows.isEmpty {
            NoShownGames()
        } else {
            Table(of: GameRow.self, selection: $library.selection, sortOrder: order) {
                TableColumn("Game", value: \.name) { row in
                    HStack(spacing: 8) {
                        // beside the badges, not around them: a container's help hides theirs
                        HStack(spacing: 8) {
                            GameIcon(url: library.icon(for: row.game)).frame(width: 28, height: 28)
                            Text(row.game.name).lineLimit(1)
                        }
                        .help(row.game.folder.path)
                        Spacer(minLength: 4)
                        HStack(spacing: 4) {
                            ProfileBadges(game: row.game).library(library)
                            IconBadges(game: row.game)
                        }
                        .scaleEffect(0.85)
                    }
                }
                .width(min: 200, ideal: 300)
                TableColumn("Version", value: \.version) { row in
                    Text(row.version).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Title ID", value: \.titleID) { row in
                    Text(row.titleID).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                .width(min: 130, ideal: 150)
                TableColumn("Status", value: \.statusRank) { row in
                    let job = library.job(for: row.game)
                    // the bar beside the badge, so a row stays one line tall while a build runs
                    HStack(spacing: 8) {
                        GameBadge(game: row.game, job: job)
                        if let job, job.showsProgress {
                            ProgressView(value: job.progressFraction)
                                .controlSize(.small)
                                .frame(minWidth: 40, maxWidth: 90)
                                .help(job.progressText)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .width(min: 120, ideal: 170)
                TableColumn("Last Played", value: \.lastPlayed) { row in
                    DateCell(date: row.game.lastPlayed)
                }
                .width(min: 80, ideal: 100)
                TableColumn("Added", value: \.added) { row in
                    DateCell(date: row.game.added)
                }
                .width(min: 80, ideal: 100)
                TableColumn("") { row in
                    GameActionButton(game: row.game, job: library.job(for: row.game))
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .library(library)  // see below
                }
                .width(min: 44, ideal: 90)
            } rows: {
                if !extracted.isEmpty {
                    Section {
                        ForEach(extracted) { TableRow($0) }
                    } header: {
                        SectionHeader(title: "Extracted", count: extracted.count)
                    }
                }
                if !remaining.isEmpty {
                    Section {
                        ForEach(remaining) { TableRow($0) }
                    } header: {
                        SectionHeader(title: "Not Extracted", count: remaining.count) {
                            Button("Extract All") { library.extractAll() }
                                .controlSize(.small)
                                .disabled(library.extractableGames.isEmpty)
                        }
                    }
                }
            }
            // Table builds cells and menus in views of their own (cells while scrolling): those don't always get
            // the window's environment, and a view reading Library from it crashed. Hand it to them directly.
            .contextMenu(forSelectionType: Game.ID.self) { ids in
                if let id = ids.first, let game = library.games.first(where: { $0.id == id }) {
                    GameActions(game: game).library(library)
                }
            } primaryAction: { ids in
                if let id = ids.first, let game = library.games.first(where: { $0.id == id }) {
                    library.primaryAction(for: game)
                }
            }
        }
    }

    /// The library's order as the table's: a header click sorts the grid too.
    private var order: Binding<[KeyPathComparator<GameRow>]> {
        Binding(
            get: {
                [GameRow.comparator(library.sort, order: library.sortAscending ? .forward : .reverse)]
            },
            set: { comparators in
                guard let first = comparators.first,
                    let sort = Library.GameSort.allCases.first(where: {
                        GameRow.comparator($0, order: .forward).keyPath == first.keyPath
                    })
                else { return }
                library.sortGames(by: sort, ascending: first.order == .forward)
            })
    }
}

/// A date column's cell: blank for none.
private struct DateCell: View {
    let date: Date?

    var body: some View {
        Text(date?.formatted(date: .abbreviated, time: .omitted) ?? "")
            .monospacedDigit().foregroundStyle(.secondary)
    }
}

/// A section's title and count, as the grid's, with an optional button at the end.
private struct SectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    let count: Int
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Text("\(count)").foregroundStyle(.secondary)
            Spacer()
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, count: Int) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// A game with the key paths its columns sort by. The library does the sorting (Library+Sorting): these only tell
/// the table which header shows the arrow.
struct GameRow: Identifiable {
    let game: Game
    var id: Game.ID { game.id }
    var name: String { game.name }
    var version: String { game.version ?? "" }
    var titleID: String { game.titleID ?? "" }
    var statusRank: Int { Library.statusRank(game) }
    var lastPlayed: Date { game.lastPlayed ?? .distantPast }
    var added: Date { game.added ?? .distantPast }

    static func comparator(_ sort: Library.GameSort, order: SortOrder) -> KeyPathComparator<GameRow> {
        switch sort {
        case .name: KeyPathComparator(\.name, order: order)
        case .lastPlayed: KeyPathComparator(\.lastPlayed, order: order)
        case .dateAdded: KeyPathComparator(\.added, order: order)
        case .version: KeyPathComparator(\.version, order: order)
        case .titleID: KeyPathComparator(\.titleID, order: order)
        case .status: KeyPathComparator(\.statusRank, order: order)
        }
    }
}

/// Grid or list: the toolbar's switch.
struct ViewStylePicker: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        Picker("View", selection: $library.viewStyle) {
            Label("Grid", systemImage: "square.grid.2x2").tag(Library.ViewStyle.grid)
            Label("List", systemImage: "list.bullet").tag(Library.ViewStyle.list)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .help("Show the games as a grid or a list")
    }
}

/// View › as Grid ⌘1 / as List ⌘2, as Finder's View menu does.
public struct ViewStyleMenuItems: View {
    @Environment(Library.self) private var library

    public init() {}

    public var body: some View {
        @Bindable var library = library
        Picker("View", selection: $library.viewStyle) {
            Text("as Grid").tag(Library.ViewStyle.grid).keyboardShortcut("1")
            Text("as List").tag(Library.ViewStyle.list).keyboardShortcut("2")
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}
