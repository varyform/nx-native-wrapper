import SwiftUI

struct GameCard: View {
    let game: Game
    let job: Job?
    let isSelected: Bool
    @Environment(Library.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GameIcon(url: library.icon(for: game))
                // under the badges, not around the card: a container's help hides theirs
                .help(help)
                .overlay(alignment: .topLeading) { ProfileBadges(game: game).padding(6) }
                .overlay(alignment: .topTrailing) { IconBadges(game: game).padding(6) }
                // on the artwork, so a build doesn't make the card taller
                .overlay(alignment: .bottom) {
                    if let job, job.showsProgress {
                        IconProgressBar(fraction: job.progressFraction)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name)
                    .font(.headline)
                    .lineLimit(2, reservesSpace: true)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(help)
            GameStatus(game: game, job: job)
        }
        .padding(GameGrid.cardInset)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(
                isSelected ? Color.accentColor.opacity(0.15) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14).strokeBorder(
                isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(count: 2) { library.primaryAction(for: game) }
        .simultaneousGesture(TapGesture().onEnded { library.selection = game.id })
        .contextMenu { GameActions(game: game) }
    }

    private var help: String {
        job.flatMap { $0.showsProgress ? $0.progressText : nil } ?? game.folder.path
    }

    private var subtitle: String {
        let parts = [game.version.map { "v\($0)" }, game.titleID].compactMap(\.self)
        return parts.isEmpty ? game.folder.lastPathComponent : parts.joined(separator: " · ")
    }
}

/// Title first, then the state badge and the action under it.
private struct GameStatus: View {
    let game: Game
    let job: Job?

    var body: some View {
        HStack(spacing: 6) {
            GameBadge(game: game, job: job)
            Spacer(minLength: 4)
            GameActionButton(game: game, job: job)
        }
        .controlSize(.small)
    }
}

/// The game's state, or what its job is doing: the card's and the list's status.
struct GameBadge: View {
    let game: Game
    let job: Job?

    /// " · 64%", the whole build's, while one runs: the card's bar has no text of its own.
    private var percent: String {
        guard let job, job.status == .running, job.showsProgress, job.progress != nil else {
            return ""
        }
        return " · \(Int((job.progressFraction * 100).rounded()))%"
    }

    var body: some View {
        switch (job?.status, job?.kind) {
        case (.running?, .play?):
            Badge(
                text: job?.isBuilding == true
                    ? "Building\(percent)" : job?.isPreparing == true ? "Preparing…" : "Running",
                color: .green)
        case (.running?, .ipa?):
            Badge(text: "Building IPA\(percent)", color: .blue)
        case (.running?, .macApp?):
            Badge(text: "Making App\(percent)", color: .blue)
        case (.running?, .install?):
            Badge(text: "Installing\(percent)", color: .blue)
        case (.running?, _):
            Badge(text: "Extracting\(percent)", color: .blue)
        case (.queued?, _):
            Badge(text: "Queued", color: .secondary)
        case (.failed?, _):
            Badge(text: "Failed", color: .red)
        default:
            if game.isCopying {
                Badge(text: "Copying…", color: .orange)
                    .help(
                        "Finder is still copying a game file here; NX Play waits until it's complete."
                    )
            } else {
                switch game.state {
                case .ready: Badge(text: "Ready", color: .green)
                case .extracted: Badge(text: "Extracted", color: .blue)
                case .notExtracted:
                    Badge(
                        text: game.hasPackages ? "Not extracted" : "No NSP files", color: .secondary
                    )
                }
            }
        }
    }
}

/// Play, Extract, or Stop / Cancel while its job runs.
struct GameActionButton: View {
    let game: Game
    let job: Job?
    @Environment(Library.self) private var library

    var body: some View {
        if let job, job.status.isActive {
            Button(job.kind == .play && !job.isBuilding ? "Stop" : "Cancel", role: .cancel) {
                job.cancel()
            }
        } else if game.isExtracted {
            compactButton("Play", systemImage: "play.fill") { library.play(game) }
                .buttonStyle(.borderedProminent)
        } else {
            compactButton("Extract", systemImage: "square.and.arrow.down") { library.extract(game) }
                .disabled(!game.canExtract)
        }
    }

    /// Title and icon, or the icon alone when there's no room for the title.
    private func compactButton(
        _ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            Button(title, systemImage: systemImage, action: action)
                .labelStyle(.titleAndIcon)
            Button(title, systemImage: systemImage, action: action)
                .labelStyle(.iconOnly)
                .help(Text(title))
        }
    }
}

/// A thin bar along the bottom of a game's artwork, inside its rounded corners, on a dark track that reads over any art.
struct IconProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.55))
                Capsule().fill(Color.accentColor)
                    .frame(width: max(6, geometry.size.width * min(max(fraction, 0), 1)))
                    .animation(.easeOut(duration: 0.3), value: fraction)
            }
        }
        .frame(height: 6)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .shadow(color: .black.opacity(0.4), radius: 2)
        .accessibilityElement()
        .accessibilityLabel("Build progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}
