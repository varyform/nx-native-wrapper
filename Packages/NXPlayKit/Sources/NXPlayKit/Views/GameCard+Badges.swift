import SwiftUI

/// One badge on a game: an icon, or text when it has none, with its tooltip. The text is what VoiceOver reads and
/// what an overflowing card's "+N" lists.
struct BadgeSpec: Identifiable {
    let text: String
    var symbol: String? = nil
    let color: Color
    let help: String
    var id: String { text }
}

enum GameBadges {
    /// What a game has besides its build, most telling first: an overflowing card keeps the first ones. Switch 2 is the
    /// card's subtitle; the list, with room to spare, shows it as a badge.
    static func icons(_ game: Game, switch2: Bool) -> [BadgeSpec] {
        var badges: [BadgeSpec] = []
        if switch2, game.isSwitch2 {
            badges.append(
                BadgeSpec(
                    text: "Switch 2", color: .red, help: switch2Help))
        }
        if let link = game.nxnativeLink {
            badges.append(NXNativeBadge.spec(link))
        }
        if game.isKept {
            badges.append(
                BadgeSpec(
                    text: "Kept", symbol: "lock.fill", color: .orange,
                    help:
                        "Keep This Build: nxnative updates don't rebuild this game, so it keeps playing as it does now. Rebuild replaces it."
                ))
        }
        if let app = game.macAppURL {
            badges.append(
                game.macAppOutdated
                    ? BadgeSpec(
                        text: "App out of date", symbol: "arrow.triangle.2.circlepath", color: .orange,
                        help:
                            "\(app.lastPathComponent) was packed with older nxnative code than the game's build, so Play starts the build. Update Mac App packs it again; a rebuild does it by itself when the game files are there."
                    )
                    : BadgeSpec(
                        text: "App", symbol: "macwindow", color: .teal,
                        help:
                            "\(app.lastPathComponent): Play starts this app, with the game's save and NX Play's settings. A rebuild packs it again."
                    ))
        }
        if let xcode = game.xcodeBuildFolder {
            badges.append(
                BadgeSpec(
                    text: "Xcode", symbol: "hammer.fill", color: .indigo,
                    help:
                        "Xcode build for Install on Device, a full copy of the game (\(xcode.deletingLastPathComponent().lastPathComponent)/xcode-derived-data). Tools › Free Up Space removes it."
                ))
        }
        if let ipa = game.ipaURL {
            badges.append(BadgeSpec(text: "IPA", symbol: "iphone", color: .accentColor, help: help(ipa)))
        }
        return badges
    }

    static let switch2Help =
        "A Switch 2 game. nxnative builds it from a NUP file or a dump of its files (base, updates, DLC), with no prod.keys, and tests it on the Mac only."

    static func help(_ ipa: URL) -> String {
        let size = (try? ipa.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return ipa.lastPathComponent
            + (size.map {
                ", " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
            } ?? "")
    }
}

/// The list's badges: all of them, with room for them.
struct IconBadges: View {
    let game: Game

    var body: some View {
        HStack(spacing: 4) {
            ForEach(GameBadges.icons(game, switch2: true)) { IconBadge(spec: $0) }
        }
    }
}

/// The card's badges over its artwork: nxnative's on the left, the build's on the right, as many of those as fit and
/// a "+N" for the rest, so a game with everything never runs them off the artwork.
struct CardBadges: View {
    let game: Game
    @Environment(Library.self) private var library

    var body: some View {
        let badges = GameBadges.icons(game, switch2: false)
        HStack(alignment: .top, spacing: 4) {
            ForEach(ProfileBadges.specs(game, library: library)) { IconBadge(spec: $0) }
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                ForEach(Array((0...badges.count).reversed()), id: \.self) { shown in
                    HStack(spacing: 4) {
                        ForEach(badges.prefix(shown)) { IconBadge(spec: $0) }
                        if shown < badges.count {
                            let rest = badges.dropFirst(shown)
                            IconBadge(
                                spec: BadgeSpec(
                                    text: "+\(rest.count)", color: .gray,
                                    help: rest.map(\.text).joined(separator: ", ")))
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }
}

/// How far nxnative has got with a game: tested, in bring-up, or a profile it guesses (none). Then, when nxnative
/// changed the game's profile since its build, what the next rebuild brings.
struct ProfileBadges: View {
    let game: Game
    @Environment(Library.self) private var library

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.specs(game, library: library)) { IconBadge(spec: $0) }
        }
    }

    static func specs(_ game: Game, library: Library) -> [BadgeSpec] {
        var badges: [BadgeSpec] = []
        if let profile = library.profile(game) {
            switch profile.stage {
            case .tested, .profiled:
                badges.append(
                    BadgeSpec(text: "Known game", symbol: "checkmark", color: .green, help: help(profile)))
            case .bringUp:
                badges.append(
                    BadgeSpec(text: "In bring-up", symbol: "hammer.fill", color: .orange, help: help(profile)))
            }
        } else if game.titleID != nil {
            badges.append(
                BadgeSpec(
                    text: "Guessed", symbol: "questionmark", color: .gray,
                    help:
                        "No profile in nxnative: the game is packed from a profile guessed from its files, and may not boot."
                ))
        }
        let news = library.news(game)
        if !news.isEmpty {
            badges.append(
                BadgeSpec(
                    text: "\(news.count) new", symbol: "sparkles", color: .blue,
                    help: help(news, kept: game.isKept)))
        }
        return badges
    }

    static func help(_ profile: GameProfile) -> String {
        [
            profile.headline,
            profile.stage == .bringUp
                ? profile.galleryNote.map {
                    "In nxnative's tested games" + ($0.isEmpty ? "" : " · \($0)")
                }
                : nil,
            profile.validated.map { "Regression-checked: \($0)" },
            "Game › nxnative Notes… has more.",
        ].compactMap(\.self).joined(separator: "\n")
    }

    static func help(_ news: [ProfileCommit], kept: Bool) -> String {
        let list =
            news.prefix(8).map { "• \($0.subject) (\($0.age))" }
            + (news.count > 8 ? ["• … and \(news.count - 8) more"] : [])
        return
            ([
                "nxnative changed this game's profile since its build (\(news.count) commit\(news.count == 1 ? "" : "s")):"
            ] + list + [
                kept
                    ? "The build is kept, so it plays without them until you rebuild."
                    : "The next play rebuilds with them."
            ]).joined(separator: "\n")
    }
}

/// Solid, to read over any artwork.
struct IconBadge: View {
    let spec: BadgeSpec

    var body: some View {
        Group {
            // the symbol in place of the text, which VoiceOver still reads
            if let symbol = spec.symbol {
                Image(systemName: symbol).accessibilityLabel(spec.text)
            } else {
                Text(spec.text)
            }
        }
        .font(.caption2.weight(.bold))
        // one height and at least a square for all of them: symbols are taller or shorter than text, and a row of
        // mixed badges looked uneven
        .frame(minWidth: 13, minHeight: 13, maxHeight: 13)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(.white)
        .background(Capsule().fill(spec.color))
        .shadow(radius: 2)
        .help(spec.help)
    }
}

struct Badge: View {
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// A game that builds with its own nxnative checkout (a `nxnative` link in its folder), with the branch it's on, or a
/// link that names no checkout, so the game quietly builds with the shared one.
enum NXNativeBadge {
    static func spec(_ link: NXNativeLink) -> BadgeSpec {
        switch link {
        case .checkout(let path, let branch):
            BadgeSpec(
                text: name(path, branch), symbol: "arrow.triangle.branch", color: .purple,
                help:
                    "Builds with its own nxnative checkout, \(abbreviated(path))\(branch.map { " (branch \($0))" } ?? ""), not the shared one. Its updates come from that checkout. Remove the nxnative link in the game's folder to go back to the shared checkout."
            )
        case .broken(let path):
            BadgeSpec(
                text: "nxnative link", symbol: "exclamationmark.triangle.fill", color: .orange,
                help:
                    "The game's folder has an nxnative link to \(abbreviated(path)), which isn't an nxnative checkout, so the game builds with the shared one. Fix the link or remove it."
            )
        }
    }

    /// The branch, else the checkout's folder name.
    static func name(_ path: String, _ branch: String?) -> String {
        branch ?? URL(filePath: path).lastPathComponent
    }

    static func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}
