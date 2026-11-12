import AppKit
import SwiftUI

/// The main window on another Mac's library (Settings › Remote): its games and their builds, to build or rebuild one
/// there and follow it, with the selected game's build log below.
struct RemoteLibraryView: View {
    let hostID: String
    @Environment(Library.self) private var library
    @State private var selection: String?

    var body: some View {
        let link = library.macLink
        if let snapshot = link.snapshots[hostID] {
            let games = filtered(snapshot.games)
            VStack(spacing: 0) {
                if let problem = link.problem {
                    HStack {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        Spacer()
                        Button("Dismiss") { link.problem = nil }
                    }
                    .padding(8)
                    Divider()
                }
                List(games, selection: $selection) { game in
                    RemoteGameRow(game: game, hostID: hostID).tag(game.id)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let game = snapshot.games.first(where: { $0.id == id }) {
                        RemoteGameActions(game: game, hostID: hostID, link: link)
                    }
                }
                if let id = selection, let job = link.jobs[hostID]?[id] {
                    Divider()
                    LogTextView(jobID: job.id, log: job.log)
                        .frame(height: library.logHeight)
                }
            }
        } else {
            ContentUnavailableView {
                Label(hostName, systemImage: "desktopcomputer")
            } description: {
                Text(statusText)
            }
        }
    }

    private var hostName: String { library.macLink.hosts.first { $0.id == hostID }?.name ?? "Another Mac" }

    private var statusText: String {
        switch library.macLink.connections[hostID] {
        case .offline(let reason): reason
        default: "Connecting\u{2026}"
        }
    }

    /// The toolbar's search narrows these too.
    private func filtered(_ games: [RemoteGame]) -> [RemoteGame] {
        let search = library.search.trimmingCharacters(in: .whitespaces)
        return games
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct RemoteGameRow: View {
    let game: RemoteGame
    let hostID: String
    @Environment(Library.self) private var library

    var body: some View {
        let link = library.macLink
        let job = link.jobs[hostID]?[game.id]
        let active = job?.status.isActive == true
        HStack(spacing: 10) {
            icon(link.icon(game.id, on: hostID))
            VStack(alignment: .leading, spacing: 3) {
                Text(game.name).lineLimit(1)
                // the bar beside the summary, so a row keeps its height while a build runs
                HStack(spacing: 8) {
                    if let job, active {
                        ProgressView(value: job.progressFraction)
                            .controlSize(.small)
                            .frame(width: 90)
                        Text(job.progress?.summary ?? (job.status == .queued ? "Waiting for the current build" : "Starting\u{2026}"))
                    } else {
                        Text(detail(job))
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if active {
                if job?.kind == .extract || job?.kind == .rebuild {
                    Button("Stop") { job?.cancel() }
                }
            } else if game.canBuild {
                Button("Build") { link.build(game, rebuild: false, on: hostID) }
            } else if game.canRebuild {
                Button("Rebuild") { link.build(game, rebuild: true, on: hostID) }
            }
        }
        .padding(.vertical, 2)
        .task(id: game.id) { if game.hasIcon { link.fetchIcon(game.id, on: hostID) } }
    }

    private func icon(_ data: Data?) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
            .frame(width: 36, height: 36)
            .overlay {
                if let data, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                } else {
                    Image(systemName: "gamecontroller").foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func detail(_ job: Job?) -> String {
        var parts = [game.version.map { "v\($0)" }].compactMap { $0 }
        parts.append(
            game.isReady ? "Built" : game.isExtracted ? "Extracted" : game.canBuild ? "Not built" : "No game files")
        if game.isKept { parts.append("kept") }
        switch job?.status {
        case .failed(let code): parts.append("last build failed (exit \(code))")
        case .cancelled: parts.append("last build stopped")
        default: break
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// A remote game's right-click menu: what its row's button does, and Rebuild beside Build for a built game.
private struct RemoteGameActions: View {
    let game: RemoteGame
    let hostID: String
    let link: MacLink

    var body: some View {
        let job = link.jobs[hostID]?[game.id]
        if job?.status.isActive == true {
            Button("Stop Build") { job?.cancel() }
                .disabled(job?.kind != .extract && job?.kind != .rebuild)
        } else {
            Button("Build") { link.build(game, rebuild: false, on: hostID) }
                .disabled(!game.canBuild)
            Button("Rebuild") { link.build(game, rebuild: true, on: hostID) }
                .disabled(!game.canRebuild)
        }
    }
}
