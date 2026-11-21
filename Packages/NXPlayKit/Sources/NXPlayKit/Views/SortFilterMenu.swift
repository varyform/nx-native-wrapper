import SwiftUI

/// The toolbar's Sort & Filter menu: its icon fills while a filter hides games.
struct SortFilterMenu: View {
    @Environment(Library.self) private var library

    var body: some View {
        Menu {
            Section("Sort By") { GameSortItems() }
            Section("Show") { GameFilterItems() }
        } label: {
            Label(
                "Sort and Filter",
                systemImage: library.filter == .all
                    ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help("Sort the games, or show only some of them")
    }
}

/// View › Sort By and View › Show, the toolbar menu's choices. The shortcuts live here only: a toolbar menu's
/// shortcut answers too, and a rotation that ran twice would skip a filter.
public struct SortFilterMenuItems: View {
    @Environment(Library.self) private var library

    public init() {}

    public var body: some View {
        Menu("Sort By") { GameSortItems() }
        Menu("Show") {
            GameFilterItems(shortcuts: true)
            Divider()
            // ⌃Tab, as tabs rotate in Safari and Finder
            Button("Next Filter") { library.rotateFilter() }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Filter") { library.rotateFilter(forward: false) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
        }
    }
}

/// The order and its direction. A list column's order (Version, Title ID, Status) checks none of the three.
struct GameSortItems: View {
    @Environment(Library.self) private var library

    var body: some View {
        Picker(
            "Sort By",
            selection: Binding(get: { library.sort }, set: { library.sortGames(by: $0) })
        ) {
            ForEach(Library.GameSort.menuChoices, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Picker(
            "Order",
            selection: Binding(
                get: { library.sortAscending },
                set: { library.sortGames(by: library.sort, ascending: $0) })
        ) {
            // the order's natural way first
            ForEach([library.sort.startsAscending, !library.sort.startsAscending], id: \.self) {
                Text(library.sort.directionTitle(ascending: $0)).tag($0)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// The filters; in the menu bar ⌥⌘1 to ⌥⌘5, beside the views' ⌘1 and ⌘2.
struct GameFilterItems: View {
    var shortcuts = false
    @Environment(Library.self) private var library

    var body: some View {
        Picker("Show", selection: Bindable(library).filter) {
            ForEach(Array(Library.GameFilter.allCases.enumerated()), id: \.element) { index, filter in
                Text(filter.title).tag(filter)
                    .keyboardShortcut(shortcuts ? Self.shortcut(index) : nil)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    static func shortcut(_ index: Int) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
    }
}

/// The grid's and the list's empty state when games are there but the search or the filter hides them all.
struct NoShownGames: View {
    @Environment(Library.self) private var library

    var body: some View {
        if library.filter == .all {
            ContentUnavailableView.search(text: library.search)
        } else {
            ContentUnavailableView {
                Label("No Matching Games", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                let filter = Text(library.filter.title)
                if library.search.isEmpty {
                    Text("No games match the “\(filter)” filter.")
                } else {
                    Text("No games in “\(filter)” match “\(library.search)”.")
                }
            } actions: {
                Button("Show All Games") { library.filter = .all }
            }
        }
    }
}

extension Library.GameSort {
    var title: LocalizedStringKey {
        switch self {
        case .name: "Name"
        case .lastPlayed: "Last Played"
        case .dateAdded: "Date Added"
        case .version: "Version"
        case .titleID: "Title ID"
        case .status: "Status"
        }
    }

    func directionTitle(ascending: Bool) -> LocalizedStringKey {
        switch (self, ascending) {
        case (.name, true): "A to Z"
        case (.name, false): "Z to A"
        case (_, true) where isDate: "Oldest First"
        case (_, false) where isDate: "Newest First"
        case (_, true): "Ascending"
        case (_, false): "Descending"
        }
    }
}

extension Library.GameFilter {
    var title: LocalizedStringKey {
        switch self {
        case .all: "All Games"
        case .switch1: "Switch 1 Games"
        case .switch2: "Switch 2 Games"
        case .needsAttention: "Needs Attention"
        case .kept: "Kept Builds"
        }
    }
}
