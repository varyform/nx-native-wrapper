import SwiftUI

/// What a game has besides its build, on its icon: an IPA in its folder, an Xcode build from Install on Device.
struct IconBadges: View {
    let game: Game

    var body: some View {
        HStack(spacing: 4) {
            if game.isKept {
                IconBadge(
                    text: "Kept", symbol: "lock.fill", color: .orange,
                    help:
                        "Keep This Build: nxnative updates don't rebuild this game, so it keeps playing as it does now. Rebuild replaces it."
                )
            }
            if let app = game.macAppURL {
                IconBadge(
                    text: "App", color: .teal,
                    help:
                        "\(app.lastPathComponent): a standalone Mac app of the game, with its own save in ~/Library/Application Support/nxnative."
                )
            }
            if let xcode = game.xcodeBuildFolder {
                IconBadge(
                    text: "Xcode", color: .indigo,
                    help:
                        "Xcode build for Install on Device, a full copy of the game (\(xcode.deletingLastPathComponent().lastPathComponent)/xcode-derived-data). Tools › Free Up Space removes it."
                )
            }
            if let ipa = game.ipaURL {
                IconBadge(text: "IPA", color: .accentColor, help: Self.help(ipa))
            }
        }
    }

    static func help(_ ipa: URL) -> String {
        let size = (try? ipa.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return ipa.lastPathComponent
            + (size.map {
                ", " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
            } ?? "")
    }
}

/// How far nxnative has got with a game: tested, in bring-up, or a profile it guesses (none). Then, when nxnative
/// changed the game's profile since its build, what the next rebuild brings.
struct ProfileBadges: View {
    let game: Game
    @Environment(Library.self) private var library

    var body: some View {
        HStack(spacing: 4) {
            if let profile = library.profile(game) {
                switch profile.stage {
                case .tested, .profiled:
                    IconBadge(
                        text: "Known game", symbol: "checkmark", color: .green,
                        help: Self.help(profile))
                case .bringUp:
                    IconBadge(
                        text: "In bring-up", symbol: "hammer.fill", color: .orange,
                        help: Self.help(profile))
                }
            } else if game.titleID != nil {
                IconBadge(
                    text: "Guessed", symbol: "questionmark", color: .gray,
                    help:
                        "No profile in nxnative: the game is packed from a profile guessed from its files, and may not boot."
                )
            }
            let news = library.news(game)
            if !news.isEmpty {
                IconBadge(
                    text: "\(news.count) new", symbol: "sparkles", color: .blue,
                    help: Self.help(news, kept: game.isKept))
            }
        }
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
    let text: String
    /// Shown instead of the text, which VoiceOver still reads.
    var symbol: String? = nil
    let color: Color
    let help: String

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol).accessibilityLabel(text)
            } else {
                Text(text)
            }
        }
        .font(.caption2.weight(.bold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(.white)
        .background(Capsule().fill(color))
        .shadow(radius: 2)
        .help(help)
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
