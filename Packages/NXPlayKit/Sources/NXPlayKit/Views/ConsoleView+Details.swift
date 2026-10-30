import SwiftUI

/// The selected game's store page under its name, when down opens it: the whole description beside the facts, then
/// the screenshots across the window. Up and down scroll the text a page at a time, then move to the screenshots;
/// up at the top closes the details. A trackpad or wheel scrolls it too.
struct DetailsPanel: View {
    let game: Game
    @Environment(Library.self) private var library
    @State private var position = ScrollPosition(edge: .top)
    @State private var scroll = Scroll()
    /// The text block's bottom, in the scroll view's visible coordinates: on screen when within its height.
    @State private var textBottom = 0.0

    struct Scroll: Equatable {
        var offset = 0.0
        var visible = 0.0
        var content = 0.0
    }

    var body: some View {
        let info = library.info(for: game)
        let shots = library.screenshots(for: game)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .top, spacing: 56) {
                    Text(info?.description ?? "The eShop has no description of this game.")
                        .font(.title3)
                        .lineSpacing(4)
                        .foregroundStyle(.white.opacity(info?.description == nil ? 0.5 : 0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Facts(game: game, info: info)
                        .frame(width: 400, alignment: .leading)
                }
                .padding(.horizontal, 56)
                .onGeometryChange(for: Double.self) {
                    $0.frame(in: .scrollView).maxY
                } action: {
                    textBottom = $0
                }
                if !shots.isEmpty {
                    ShotRow(
                        shots: shots, index: library.shotIndex,
                        focused: library.detailsFocus == .screenshots
                    ) { index in
                        library.shotIndex = index
                        library.viewingShot = true
                    }
                    .transition(.opacity)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 32)
            .animation(.easeInOut(duration: 0.3), value: shots)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: Scroll.self) {
            Scroll(
                offset: $0.contentOffset.y, visible: $0.containerSize.height,
                content: $0.contentSize.height)
        } action: { _, new in
            scroll = new
        }
        // a soft edge where the text scrolls away under the name
        .mask {
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06)],
                startPoint: .top, endPoint: .bottom)
        }
        .foregroundStyle(.white)
        .onChange(of: library.detailsScroll) { _, request in
            step(down: request.down, hasShots: !shots.isEmpty)
        }
        .onChange(of: game.id) {
            library.detailsFocus = .text
            position.scrollTo(edge: .top)
        }
        .task(id: game.id) { library.loadScreenshots(game) }
    }

    /// Down: the next page of the text, then the screenshots. Up: back to the text, the page before, and at the top
    /// the details close.
    private func step(down: Bool, hasShots: Bool) {
        let page = max(80, scroll.visible * 0.7)
        let end = max(0, scroll.content - scroll.visible)
        withAnimation(.easeInOut(duration: 0.3)) {
            if down {
                guard library.detailsFocus == .text else { return }
                if textBottom <= scroll.visible + 4 || scroll.offset >= end - 1 {
                    if hasShots {
                        library.detailsFocus = .screenshots
                        position.scrollTo(edge: .bottom)
                    }
                } else {
                    position.scrollTo(y: min(end, scroll.offset + page))
                }
            } else if library.detailsFocus == .screenshots {
                library.detailsFocus = .text
                position.scrollTo(y: max(0, min(end, textBottom + scroll.offset - scroll.visible)))
            } else if scroll.offset <= 1 {
                library.showsDetails = false
            } else {
                position.scrollTo(y: max(0, scroll.offset - page))
            }
        }
    }
}

/// The store page's facts, as a list of labels and values.
struct Facts: View {
    let game: Game
    let info: TitleInfo?

    var body: some View {
        let rating = info?.ratingLabel.map { label in
            (["ESRB \(label)"]
                + (info?.ratingContent.isEmpty == false
                    ? [info!.ratingContent.joined(separator: ", ")] : []))
                .joined(separator: " · ")
        }
        let rows: [(String, String?)] = [
            ("Publisher", info?.publisher),
            ("Released", info?.released?.formatted(date: .long, time: .omitted)),
            ("Players", info?.playersLabel),
            (
                "Genre",
                info.flatMap { $0.categories.isEmpty ? nil : $0.categories.joined(separator: ", ") }
            ),
            ("Rating", rating),
            ("Version", game.version),
        ]
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 10) {
            ForEach(rows.filter { $0.1 != nil }, id: \.0) { row in
                GridRow {
                    Text(row.0).foregroundStyle(.white.opacity(0.55))
                    Text(row.1 ?? "").lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 17))
    }
}

/// The screenshots across the window, the chosen one outlined while the row has the focus; a click shows one over the
/// whole screen.
struct ShotRow: View {
    let shots: [URL]
    let index: Int
    let focused: Bool
    let open: (Int) -> Void

    static let height = 230.0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(Array(shots.enumerated()), id: \.offset) { i, file in
                        let chosen = focused && i == index
                        Group {
                            if let image = IconCache.image(at: file) {
                                Image(nsImage: image).resizable().interpolation(.high)
                                    .scaledToFill()
                            } else {
                                Color.white.opacity(0.08)
                            }
                        }
                        .frame(width: Self.height * 16 / 9, height: Self.height)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(.white.opacity(chosen ? 0.95 : 0), lineWidth: 4)
                        }
                        .shadow(
                            color: .black.opacity(chosen ? 0.6 : 0.3), radius: chosen ? 18 : 8, y: 8
                        )
                        .scaleEffect(chosen ? 1.05 : 1)
                        .opacity(focused && !chosen ? 0.7 : 1)
                        .animation(.spring(duration: 0.3, bounce: 0.15), value: chosen)
                        .id(i)
                        .onTapGesture { open(i) }
                    }
                }
                .padding(.horizontal, 56)
                .padding(.vertical, 14)  // room for the chosen one's growth and shadow
            }
            .scrollClipDisabled()
            .onChange(of: index) {
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }
}

/// A screenshot over the whole screen; left and right page through them, any other button closes it.
struct ShotViewer: View {
    let shots: [URL]
    let index: Int
    let gamepad: Gamepad
    @Environment(Library.self) private var library

    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
            if shots.indices.contains(index), let image = IconCache.image(at: shots[index]) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 56)
                    .padding(.top, 48)
                    .padding(.bottom, 110)
                    .id(index)
                    .transition(.opacity)
            }
            VStack {
                Spacer()
                HStack {
                    Text("\(index + 1) of \(shots.count)")
                        .font(.title3.weight(.medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Hints(game: nil, gamepad: gamepad, mode: .viewer)
                }
                .padding(.horizontal, 56)
                .padding(.bottom, 36)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: index)
        .contentShape(.rect)
        .onTapGesture { library.viewingShot = false }
    }
}
