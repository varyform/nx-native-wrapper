import SwiftUI

/// The games side by side from the left edge, the selected one larger and outlined. The row moves a tile at a time,
/// only when the selection would leave the screen, so it starts at the left and ends at the right.
struct Carousel: View {
    let games: [Game]
    let selection: Game.ID?
    @Environment(Library.self) private var library
    /// The first tile on screen.
    @State private var first = 0

    static let spacing = 40.0
    /// The caption's margin, plus what the selected tile grows by on each side, so its edge lines up with the name.
    static let margin = 56 + ConsoleView.tile * 0.09

    // A plain row moved by an exact offset, not a scroll view: a held controller direction repeats faster than the
    // scroll animation, and scrollTo on a lazy row mid-animation (its off-screen positions only estimated) stopped short
    // of the end, the last game selected off screen.
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: Self.spacing) {
                ForEach(games) { game in
                    Tile(
                        game: game, icon: library.icon(for: game),
                        isSelected: game.id == selection
                    )
                    .onTapGesture(count: 2) {
                        library.selection = game.id
                        library.handle(.confirm)
                    }
                    .onTapGesture { library.selection = game.id }
                }
            }
            .padding(.horizontal, Self.margin)
            .fixedSize()
            .offset(x: offset(width: width))
            .frame(width: width, height: geometry.size.height, alignment: .leading)
            // in place when Console Mode opens; a selection that moves after that slides there
            .onAppear { follow(width: width) }
            .onChange(of: selection) {
                withAnimation(.spring(duration: 0.4, bounce: 0.15)) { follow(width: width) }
            }
            .onChange(of: width) { follow(width: width) }
            .onChange(of: games.count) { follow(width: width) }
        }
        .frame(height: Self.height)
    }

    /// How many tiles fit between the margins.
    private func fits(_ width: Double) -> Int {
        max(1, Int((width - 2 * Self.margin + Self.spacing) / (ConsoleView.tile + Self.spacing)))
    }

    /// Moves the first tile on screen just enough to keep the selection there.
    private func follow(width: Double) {
        guard let index = games.firstIndex(where: { $0.id == selection }), width > 0 else { return }
        let fits = fits(width)
        first = min(max(first, index - fits + 1), index, max(0, games.count - fits))
    }

    /// The row's shift: the first tile on screen at the left margin; at the end of the row, the last tile at the right
    /// one; a row shorter than the screen stays put.
    private func offset(width: Double) -> Double {
        let step = ConsoleView.tile + Self.spacing
        let row = 2 * Self.margin + Double(games.count) * step - Self.spacing
        guard row > width else { return 0 }
        let fits = fits(width)
        if first >= games.count - fits { return width - row }
        return -Double(first) * step
    }

    static let height = ConsoleView.tile * 1.5
}

/// A game's square artwork: the eShop icon when there is one (sharper than the game's own 256-pixel icon at this
/// size), else the game's own.
struct Tile: View {
    let game: Game
    let icon: URL?
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(.white.opacity(0.08))
            .overlay {
                if let url = icon, let image = IconCache.image(at: url) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                } else {
                    Image(systemName: "gamecontroller").font(.system(size: 64)).foregroundStyle(
                        .white.opacity(0.5))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .overlay {
                RoundedRectangle(cornerRadius: 28).strokeBorder(
                    .white.opacity(isSelected ? 0.95 : 0), lineWidth: 4)
            }
            .frame(width: ConsoleView.tile, height: ConsoleView.tile)
            // the outline and the scale mark the selection; a white glow read as a lit, foreign band
            .shadow(
                color: .black.opacity(isSelected ? 0.6 : 0.4), radius: isSelected ? 24 : 14,
                y: isSelected ? 14 : 8
            )
            .scaleEffect(isSelected ? 1.18 : 0.88)
            .opacity(isSelected ? 1 : 0.55)
            .animation(.spring(duration: 0.35, bounce: 0.2), value: isSelected)
    }
}
