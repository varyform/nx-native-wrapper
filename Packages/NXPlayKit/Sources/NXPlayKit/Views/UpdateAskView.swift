import SwiftUI

/// Play's question when nxnative has new code for the game's build (nxplay's NXPLAY_UPDATE=ask): update first, or play
/// the build as it is, the way a console offers a game's update at its start. In Console Mode the controller moves
/// the highlight (Library.handleUpdatePrompt).
struct UpdateAskView: View {
    let prompt: UpdatePrompt
    @Environment(Library.self) private var library

    var body: some View {
        let ask = prompt.ask
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                GameIcon(url: library.icon(for: prompt.job.game)).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update \(prompt.job.game.name) first?").font(.title2.bold())
                    Text(ask.headline).foregroundStyle(.secondary)
                }
            }
            if !ask.gameCommits.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ask.gameCommits.prefix(5), id: \.hash) { commit in
                        Text(commit.subject).lineLimit(2)
                    }
                    if ask.gameCommits.count > 5 {
                        Text("and \(ask.gameCommits.count - 5) more").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(ask.shadersText, systemImage: "cpu")
                if let estimate = ask.estimateText { Label(estimate, systemImage: "clock") }
                Label(
                    "Commits that don't name the game can still fix it.",
                    systemImage: "info.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                row(
                    .update, "Update Now",
                    detail: "Rebuild with the new code, then play", default: true)
                row(
                    .current, "Play Current Build",
                    detail: "Play now; the next Play asks again", default: false)
                DontPlayRow(highlighted: library.updatePrompt?.focus == .cancel) {
                    library.answerUpdate(.cancel)
                }
            }
            Text("Settings \u{203A} General can stop asking.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 520)
    }

    private func row(_ row: UpdatePrompt.Row, _ title: String, detail: String, default isDefault: Bool)
        -> some View
    {
        Button {
            library.answerUpdate(row == .update ? .update : .current)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.tint, lineWidth: 2)
                .opacity(library.consoleMode && library.updatePrompt?.focus == row ? 1 : 0)
        )
        .keyboardShortcut(isDefault ? .defaultAction : nil)
    }
}
