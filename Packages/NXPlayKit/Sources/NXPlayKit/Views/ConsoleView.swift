import AppKit
import SwiftUI

/// Console Mode: the window full screen. The selected game's eShop banner fills the upper part edge to edge, the clock
/// and controller over its top and the game's name and badges over its foot; the games as a carousel of their artwork
/// below it, button hints at the bottom. Down opens the selected game's details: the banner and the name slide up and
/// the store page's text, facts and screenshots take the row's place. A controller, the arrow keys with Return and
/// Esc, or the mouse drive it.
struct ConsoleView: View {
    @Environment(Library.self) private var library
    @FocusState private var focused: Bool

    static let tile = 240.0

    var body: some View {
        let games = library.navigableGames  // the extracted ones
        let selected = games.first { $0.id == library.selection } ?? games.first
        let details = library.showsDetails && selected != nil
        VStack(spacing: 0) {
            GeometryReader { geometry in
                // the banner takes what the carousel and the hints leave: about half of the screen
                let height = geometry.size.height
                let banner = max(0, height - Carousel.height)
                // the details take about 55% of the screen; the name stays clear of the top bar
                let lift =
                    details ? min(max(0, height * 0.55 - Carousel.height), max(0, banner - 300)) : 0
                VStack(spacing: 0) {
                    Banner(game: selected, banner: selected.flatMap(library.banner(for:)))
                        .frame(height: banner)
                        .overlay(alignment: .bottomLeading) {
                            if let selected {
                                Caption(game: selected, job: library.job(for: selected))
                                    .padding(.horizontal, 56)
                                    .contentShape(.rect)
                                    .onTapGesture { library.showsDetails.toggle() }
                            }
                        }
                    if games.isEmpty {
                        Text("No games ready to play yet").font(.largeTitle.bold())
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(height: Carousel.height)
                    } else {
                        Carousel(games: games, selection: selected?.id)
                            .opacity(details ? 0 : 1)
                    }
                }
                .offset(y: -lift)
                .overlay(alignment: .bottom) {
                    if details, let selected {
                        DetailsPanel(game: selected)
                            .frame(height: Carousel.height + lift)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(duration: 0.45, bounce: 0.1), value: details)
            .overlay(alignment: .top) {
                TopBar(gamepad: library.gamepad)
                    .padding(.horizontal, 56)
                    .padding(.top, 40)
            }
            // the build beside the hints, in the layout: as an overlay of the one-line hints it rose over the tiles
            // the hints over the build's reserved room, at their own width: beside it they were squeezed letter by letter
            FooterBuild(jobs: library.buildingJobs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottomTrailing) {
                    Hints(
                        game: selected, gamepad: library.gamepad,
                        mode: !details
                            ? .row : library.detailsFocus == .screenshots ? .screenshots : .text
                    )
                    .fixedSize()
                }
                .animation(.easeInOut(duration: 0.25), value: library.buildingJobs.isEmpty)
                .padding(.horizontal, 56)
                .padding(.bottom, 36)
        }
        .background { Backdrop(game: selected) }
        .overlay {
            if library.viewingShot, let selected {
                ShotViewer(
                    shots: library.screenshots(for: selected), index: library.shotIndex,
                    gamepad: library.gamepad
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: library.viewingShot)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) {
            library.handle(.left)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            library.handle(.right)
            return .handled
        }
        .onKeyPress(.upArrow) {
            library.handle(.up)
            return .handled
        }
        .onKeyPress(.downArrow) {
            library.handle(.down)
            return .handled
        }
        .onKeyPress(.return) {
            library.handle(.confirm)
            return .handled
        }
        .onExitCommand { library.handle(.back) }
    }
}

/// Behind the whole screen: the selected game's cover, blurred into colour and dimmed, so the part under the banner
/// carries the game's colours rather than black. It cross-fades as the selection moves.
private struct Backdrop: View {
    let game: Game?

    var body: some View {
        // the artwork as an overlay of a flexible colour: scaledToFill would otherwise size the layout to the image
        Color.black
            .overlay {
                if let url = game?.iconURL, let image = IconCache.image(at: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 80)
                        .saturation(1.3)
                        .id(url)
                        .transition(.opacity)
                }
            }
            .overlay { Color.black.opacity(0.8) }  // dark: the tiles and the hints stand out, the colour stays
            .clipped()
            .animation(.easeInOut(duration: 0.45), value: game?.id)
    }
}

/// The selected game's eShop banner edge to edge, sharp, its lower part fading to transparent into the blurred cover
/// below, darkened behind the top bar and the name. Without one, the cover shows through. It cross-fades as the
/// selection moves.
private struct Banner: View {
    let game: Game?
    let banner: URL?

    /// How far the fade reaches below the banner's own area, over the tiles: the image keeps its place and size there
    /// (its fill crop has more of it below), only the blend into the backdrop gets taller.
    static let overhang = 140.0

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let drawn = height + Self.overhang
            // the artwork as an overlay of a flexible colour, filling the banner's own area as before: scaledToFill
            // would otherwise size the layout to the image
            Color.clear
                .frame(height: height)
                .overlay {
                    if let banner, let image = IconCache.image(at: banner) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .id(banner)
                            .transition(.opacity)
                    }
                }
                // drawn down into the overhang, and cut there and at the top
                .frame(height: drawn, alignment: .top)
                .clipped()
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.55), location: 0),
                            .init(color: .clear, location: 0.25 * height / drawn),
                        ], startPoint: .top, endPoint: .bottom)
                }
                .overlay {
                    LinearGradient(
                        colors: [.black.opacity(0.6), .clear], startPoint: .leading,
                        endPoint: UnitPoint(x: 0.65, y: 0.5))
                }
                // opaque down to the banner's middle, then fading out through the overhang: it melts into the backdrop
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.5 * height / drawn),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom)
                }
                // laid out at the banner's height; the overhang draws over what follows, under the tiles
                .frame(height: height, alignment: .top)
        }
        .animation(.easeInOut(duration: 0.45), value: game?.id)
    }
}

private struct TopBar: View {
    let gamepad: Gamepad

    var body: some View {
        HStack(spacing: 20) {
            HStack(spacing: 12) {
                Logo().frame(height: 30)
                Text("NX Play")
            }
            .font(.title2.weight(.bold))
            Spacer()
            if let name = gamepad.name {
                HStack(spacing: 6) {
                    Image(systemName: "gamecontroller")
                    Text(name)
                    if let battery = gamepad.battery {
                        Image(
                            systemName: battery > 0.75
                                ? "battery.100percent"
                                : battery > 0.5
                                    ? "battery.75percent"
                                    : battery > 0.25 ? "battery.50percent" : "battery.25percent")
                    }
                }
                .font(.title3)
                .foregroundStyle(.white.opacity(0.8))
            }
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.title2.weight(.semibold).monospacedDigit())
            }
        }
        .foregroundStyle(.white)
    }
}

/// The games side by side from the left edge, the selected one larger and outlined. The row moves a tile at a time,
/// only when the selection would leave the screen, so it starts at the left and ends at the right.
private struct Carousel: View {
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
                        game: game, icon: library.eshopIcon(for: game) ?? game.iconURL,
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
private struct Tile: View {
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

/// The selected game's name, badges and what it is doing, at the foot of the banner.
private struct Caption: View {
    let game: Game
    let job: Job?
    @Environment(Library.self) private var library

    var body: some View {
        let info = library.info(for: game)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(game.name)
                    .font(.system(size: 64, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: 1000, alignment: .leading)
                if let intro = info?.intro {
                    Text(intro)
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
            HStack(spacing: 10) {
                GameBadge(game: game, job: job).scaleEffect(1.3).padding(.horizontal, 10)
                if let profile = library.profile(game) {
                    switch profile.stage {
                    case .tested, .profiled:
                        Pill(text: "Known game", symbol: "checkmark", color: .green)
                    case .bringUp:
                        Pill(text: "In bring-up", symbol: "hammer.fill", color: .orange)
                    }
                } else if game.titleID != nil {
                    Pill(text: "No profile", symbol: "questionmark", color: .gray)
                }
                let news = library.news(game).count
                if news > 0 {
                    Pill(text: "\(news) new from nxnative", symbol: "sparkles", color: .blue)
                }
                if game.isKept { Pill(text: "Kept", symbol: "lock.fill", color: .orange) }
                Text(Self.facts(game, info)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            .font(.title3)
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.2), value: game.id)
    }

    /// "v1.6.0 · Nintendo · 2017 · Played yesterday".
    static func facts(_ game: Game, _ info: TitleInfo?) -> String {
        [
            game.version.map { "v\($0)" }, info?.publisher,
            info?.released.map { $0.formatted(.dateTime.year()) },
            game.lastPlayed.map { "Played \($0.formatted(.relative(presentation: .named)))" },
        ].compactMap(\.self).joined(separator: " · ")
    }
}

/// The selected game's store page under its name, when down opens it: the whole description beside the facts, then
/// the screenshots across the window. Up and down scroll the text a page at a time, then move to the screenshots;
/// up at the top closes the details. A trackpad or wheel scrolls it too.
private struct DetailsPanel: View {
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

/// The screenshots across the window, the chosen one outlined while the row has the focus; a click shows one over the
/// whole screen.
private struct ShotRow: View {
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
private struct ShotViewer: View {
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

/// The store page's facts, as a list of labels and values.
private struct Facts: View {
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

/// A badge sized for the couch: solid, to read over any banner.
private struct Pill: View {
    let text: LocalizedStringKey
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(Capsule().fill(color.opacity(0.9)))
    }
}

/// The footer's left: the build running (a game that needs a rebuild before it plays, or any other), whichever game is
/// selected, so the banner's caption keeps its place. Several builds: the running one, with how many there are.
private struct FooterBuild: View {
    let jobs: [Job]

    static let bar = 520.0

    var body: some View {
        let job = jobs.first
        // the spinner and the title, the bar with its percentage, the stage: the text lines end where the bar does.
        // Drawn without a build too, invisible: its space stays, so the banner and the tiles don't move as builds
        // start and end.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // no spinning while nothing builds: the placeholder only holds the space
                if job != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Color.clear.frame(width: 16, height: 16)
                }
                Text(
                    job.map { $0.kind == .play ? "Building \($0.game.name)" : $0.game.name } ?? " "
                )
                .fontWeight(.semibold)
                if jobs.count > 1 {
                    Text("+\(jobs.count - 1) more").foregroundStyle(.white.opacity(0.6))
                        .layoutPriority(1)
                }
            }
            .font(.title3)
            .frame(width: Self.bar, alignment: .leading)
            HStack(spacing: 14) {
                ProgressView(value: job?.progressFraction ?? 0)
                    .tint(.white)
                    .frame(width: Self.bar)
                Text("\(Int(((job?.progressFraction ?? 0) * 100).rounded()))%")
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
            Text(job?.progressText ?? " ")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: Self.bar, alignment: .leading)
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(.white)
        .opacity(job == nil ? 0 : 1)
        .accessibilityHidden(job == nil)
    }
}

/// What the buttons do, with the connected controller's own symbols, or the keys without one.
private struct Hints: View {
    let game: Game?
    let gamepad: Gamepad
    let mode: Mode

    /// What the buttons do where the focus is: the games' row, the details' text or screenshots, a screenshot shown.
    enum Mode { case row, text, screenshots, viewer }

    var body: some View {
        let pad = gamepad.symbol(for: .down) != nil
        let sideways = gamepad.symbol(for: .left) ?? "arrow.left.arrow.right"
        let confirm = gamepad.symbol(for: .confirm) ?? "return"
        let back = gamepad.symbol(for: .back) ?? "escape"
        HStack(spacing: 32) {
            switch mode {
            case .row:
                hint(sideways, "Choose")
                if game != nil {
                    hint(pad ? "dpad.down.filled" : "arrow.down", "Details")
                    hint(confirm, "Play")
                }
                hint(back, "Exit")
            case .text:
                hint(sideways, "Choose")
                hint(pad ? "dpad" : "arrow.up.arrow.down", "Scroll")
                hint(confirm, "Play")
                hint(back, "Close")
            case .screenshots:
                hint(sideways, "Browse")
                hint(confirm, "View")
                hint(back, "Close")
            case .viewer:
                hint(sideways, "Browse")
                hint(back, "Close")
            }
        }
        .font(.title3.weight(.medium))
        .foregroundStyle(.white.opacity(0.85))
    }

    private func hint(_ symbol: String, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.title2)
            Text(title)
        }
    }
}

/// The toolbar button.
struct ConsoleToggle: View {
    @Environment(Library.self) private var library

    var body: some View {
        Button {
            library.consoleMode.toggle()
        } label: {
            Label("Console Mode", systemImage: "gamecontroller")
        }
        .help("Console Mode: full screen, for a controller (⇧⌘F, or the controller's Menu button)")
    }
}

/// View › Console Mode, ⇧⌘F.
public struct ConsoleMenuItem: View {
    @Environment(Library.self) private var library

    public init() {}

    public var body: some View {
        Button(library.consoleMode ? "Exit Console Mode" : "Console Mode") {
            library.consoleMode.toggle()
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
    }
}
