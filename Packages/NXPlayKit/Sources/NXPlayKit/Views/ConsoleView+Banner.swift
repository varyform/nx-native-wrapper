import SwiftUI

/// Behind the whole screen: the selected game's cover, blurred into colour and dimmed, so the part under the banner
/// carries the game's colours rather than black. It cross-fades as the selection moves.
struct Backdrop: View {
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
struct Banner: View {
    let game: Game?
    let banner: URL?

    /// How far the fade reaches below the banner's own area, over the tiles: the image keeps its place and size there
    /// (its fill crop has more of it below), only the blend into the backdrop gets taller.
    static let overhang = 80.0

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

struct TopBar: View {
    let gamepad: Gamepad
    @Environment(Library.self) private var library

    var body: some View {
        HStack(spacing: 20) {
            HStack(spacing: 12) {
                Logo().frame(height: 30)
                Text("NX Play")
            }
            .font(.title2.weight(.bold))
            if case .ready(let version, _) = library.updater.state {
                UpdatePill(version: version)
            }
            Spacer()
            // each controller with the player it is in a game: one shows its name, several only their numbers and
            // batteries, to fit
            let players = gamepad.players
            HStack(spacing: 18) {
                ForEach(players) { player in
                    HStack(spacing: 6) {
                        Image(systemName: "gamecontroller")
                        if let number = player.number, players.count > 1 || number > 1 {
                            Text("P\(number)").fontWeight(.semibold).monospacedDigit()
                        }
                        if players.count == 1 { Text(player.name) }
                        if let battery = player.battery {
                            Image(systemName: Self.battery(battery))
                        }
                    }
                    .help(player.name)
                }
            }
            .font(.title3)
            .foregroundStyle(.white.opacity(0.8))
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.title2.weight(.semibold).monospacedDigit())
            }
        }
        .foregroundStyle(.white)
    }

    static func battery(_ level: Float) -> String {
        level > 0.75
            ? "battery.100percent"
            : level > 0.5
                ? "battery.75percent" : level > 0.25 ? "battery.50percent" : "battery.25percent"
    }
}

/// Beside the logo while an update waits: a quiet ask, never taking the focus. Y or a click opens its card.
struct UpdatePill: View {
    let version: String
    @Environment(Library.self) private var library

    var body: some View {
        // looked at again hourly: one waiting for days says since when
        TimelineView(.periodic(from: .now, by: 3600)) { context in
            Button {
                library.openUpdate()
            } label: {
                Pill(
                    text: Self.text(version, library: library, now: context.date),
                    symbol: "arrow.down.circle.fill", color: .blue)
            }
            .buttonStyle(.plain)
        }
    }

    static func text(_ version: String, library: Library, now: Date) -> LocalizedStringKey {
        if library.quitsWhenIdle { return "Restarting for \(version)" }
        if let since = library.updater.waitingSince(now: now) {
            return "Update \(version) waiting since \(since.formatted(.dateTime.weekday(.wide)))"
        }
        return "Update \(version) ready"
    }
}

/// The selected game's name, badges and what it is doing, at the foot of the banner.
struct Caption: View {
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

/// A badge sized for the couch: solid, to read over any banner.
struct Pill: View {
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
