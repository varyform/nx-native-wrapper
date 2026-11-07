import SwiftUI

/// The library's columns in a given width, with an iPhone Duo's fold kept between two tiles.
struct LibraryGrid {
    private static let tile: CGFloat = 170
    private static let spacing: CGFloat = 20
    private static let margin: CGFloat = 16

    /// How many tiles a row holds, so the controller's up and down move by one row.
    let columns: Int
    let items: [GridItem]
    let leading: CGFloat
    let trailing: CGFloat

    /// `fold` is the frame of a fold running top to bottom, in the same coordinates as `width`.
    init(width: CGFloat, fold: CGRect?) {
        let half = fold.map { min($0.midX, width - $0.midX) - Self.margin } ?? 0
        guard let fold, half >= Self.tile else {
            columns = Self.fitting(width - 2 * Self.margin)
            items = Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns)
            leading = Self.margin
            trailing = Self.margin
            return
        }
        // Apple's advice for grids: an even count wherever a fold exists, folded or flat, so the tiles split evenly
        // around it and the count doesn't change as the device folds. The fold's width isn't counted for the same reason.
        let fitting = Self.fitting(2 * half)
        let columns = max(2, fitting - fitting % 2)
        self.columns = columns
        items = (0..<columns).map { column in
            GridItem(
                .flexible(),
                spacing: column == columns / 2 - 1 ? max(Self.spacing, fold.width) : Self.spacing)
        }
        // a vertical toolbar insets one side only, which moves the fold away from the middle of the width
        leading = fold.midX - half
        trailing = width - fold.midX - half
    }

    private static func fitting(_ available: CGFloat) -> Int {
        max(2, Int((available + spacing) / (tile + spacing)))
    }
}
