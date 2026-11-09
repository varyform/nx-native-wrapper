import SwiftUI

/// The selected game's last nxplay run: what it is doing and its whole output.
struct LogPanel: View {
    @Environment(Library.self) private var library

    var body: some View {
        let game = library.selectedGame
        let job = game.flatMap(library.job(for:))
        VStack(spacing: 0) {
            // the header keeps its height; the split view's extra height goes to the output
            header(game: game, job: job)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Group {
                if let job {
                    LogTextView(jobID: job.id, log: job.log)
                } else {
                    ContentUnavailableView(
                        "No Output",
                        systemImage: "text.alignleft",
                        description: Text(
                            game == nil
                                ? "Select a game."
                                : "Extract or play the game to see nxplay's output here.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(game: Game?, job: Job?) -> some View {
        HStack(spacing: 10) {
            Text(game?.name ?? "Log").font(.headline).lineLimit(1)
            if let job {
                Text(statusText(job))
                    .foregroundStyle(job.status == .succeeded && !job.warnings.isEmpty ? .orange : .secondary)
                    .lineLimit(1)
                    .help(warningHelp(job))
                if job.status == .running, job.kind != .play || job.isBuilding,
                    let progress = job.progress
                {
                    ProgressView(value: progress.fraction)
                        .frame(width: 140)
                    Text(progress.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let job, job.status.isActive {
                Button(job.kind == .play && !job.isBuilding ? "Stop" : "Cancel") { job.cancel() }
            }
            if let job {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.log.text, forType: .string)
                }
                .labelStyle(.iconOnly)
                .help("Copy the output")
            }
            if let logs = game?.logsFolder {
                Button("Build Logs", systemImage: "folder") { NSWorkspace.shared.open(logs) }
                    .labelStyle(.iconOnly)
                    .help("Open the build's per-step logs")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func statusText(_ job: Job) -> String {
        let action =
            switch job.kind {
            case .extract: "Extract"
            case .rebuild: "Rebuild"
            case .play: "Play"
            case .ipa: "Build IPA"
            case .macApp: "Make Mac App"
            case .install(let device): "Install on \(device.name)"
            }
        let state =
            switch job.status {
            case .queued: "waiting"
            case .running: job.kind == .play && !job.isBuilding ? "running" : "in progress"
            case .succeeded where !job.warnings.isEmpty: "done, with a warning"
            case .succeeded: "done"
            case .failed(let code): "failed (exit \(code))"
            case .cancelled: "cancelled"
            }
        return "\(action) · \(state)"
    }

    private func warningHelp(_ job: Job) -> String {
        guard job.status == .succeeded, !job.warnings.isEmpty else { return "" }
        return "Finished without what \(job.warnings.joined(separator: ", ")) makes: the log says why."
    }
}
