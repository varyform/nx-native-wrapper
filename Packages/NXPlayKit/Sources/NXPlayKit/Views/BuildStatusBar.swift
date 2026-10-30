import SwiftUI

/// A slim bar under the games while builds run and the log is hidden: what the log header would say. One build: its
/// game, stage and Cancel. Several: how many, their average progress (the Dock's), and the running one's stage.
/// Clicking the text selects that game; the button shows the log.
struct BuildStatusBar: View {
    let jobs: [Job]
    @Environment(Library.self) private var library

    var body: some View {
        let current = jobs[0]  // a running one, when any runs (Library.buildingJobs)
        HStack(spacing: 10) {
            Button {
                library.selection = current.game.id
            } label: {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.semibold)
                    Text(current.progressText).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Select \(current.game.name)")
            Spacer(minLength: 8)
            ProgressView(
                value: jobs.count == 1 ? current.progressFraction : library.buildFraction ?? 0
            )
            .frame(width: 160)
            if jobs.count == 1 {
                Button("Cancel") { current.cancel() }
            }
            Button {
                withAnimation(.snappy(duration: 0.2)) { library.showsLog = true }
                library.selection = current.game.id
            } label: {
                Label("Show Log", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .labelStyle(.iconOnly)
            .help("Show the log (⇧⌘Y)")
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    /// The game, or "3 builds · 2 waiting · ANIMAL WELL"; "Waiting for the power adapter · 3 builds" on battery.
    private var title: String {
        if library.waitingForPower {
            return "Waiting for the power adapter · "
                + (jobs.count == 1 ? jobs[0].game.name : "\(jobs.count) builds")
        }
        guard jobs.count > 1 else { return jobs[0].game.name }
        let waiting = jobs.filter { $0.status == .queued }.count
        let parts: [String?] = [
            "\(jobs.count) builds", waiting > 0 ? "\(waiting) waiting" : nil, jobs[0].game.name,
        ]
        return parts.compactMap(\.self).joined(separator: " · ")
    }
}
