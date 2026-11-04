import SwiftUI

/// Extracted games first, with their icons; then the ones still to extract.
struct GameGrid: View {
    @Environment(Library.self) private var library

    /// A card pads its content by `cardInset` for its selection highlight: the grid sits that much further out, so the
    /// artwork lines up with the section title (the highlight reaches into the margin, as in Photos), and the cards'
    /// spacing is what's left of the gap between two artworks.
    static let margin = 20.0
    static let cardInset = 10.0
    static let artworkGap = 24.0

    private let columns = [
        GridItem(
            .adaptive(minimum: 180, maximum: 220), spacing: artworkGap - 2 * cardInset,
            alignment: .top)
    ]

    var body: some View {
        let shown = library.shownGames
        let extracted = shown.filter(\.isExtracted)
        let remaining = shown.filter { !$0.isExtracted }
        ScrollViewReader { proxy in
            ScrollView {
                if library.games.isEmpty {
                    ContentUnavailableView(
                        "No Games",
                        systemImage: "gamecontroller",
                        description: Text("No subfolder here holds NSP, NSZ, XCI, XCZ or NUP files.")
                    )
                    .padding(.top, 40)
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: library.search)
                        .padding(.top, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if !extracted.isEmpty {
                            section("Extracted", extracted)
                        }
                        if !remaining.isEmpty {
                            section("Not Extracted", remaining, extractAll: true)
                        }
                    }
                    .padding(.vertical, Self.margin)
                    .padding(.horizontal, Self.margin - Self.cardInset)
                }
            }
            .background(.background)
            // a controller moves the selection: keep it in view
            .onChange(of: library.selection) {
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(library.selection) }
            }
        }
    }

    private func section(_ title: LocalizedStringKey, _ games: [Game], extractAll: Bool = false)
        -> some View
    {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title3.bold())
                Text("\(games.count)").foregroundStyle(.secondary)
                Spacer()
                if extractAll {
                    Button("Extract All") { library.extractAll() }
                        .disabled(library.extractableGames.isEmpty)
                }
            }
            .padding(.horizontal, Self.cardInset)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(games) { game in
                    GameCard(
                        game: game, job: library.job(for: game),
                        isSelected: library.selection == game.id
                    )
                    .id(game.id)
                }
            }
        }
    }
}
