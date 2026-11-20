import SwiftUI

/// Above a failed job's output: what stopped, whose it is to fix, and what can help now (FailureHelp). Most failures
/// are nxnative's; the card says so, and points at nxnative's newer commits and issues for the game.
struct FailureCard: View {
    let job: Job
    let report: FailureReport
    @Environment(Library.self) private var library
    @Environment(\.openWindow) private var openWindow

    private var help: FailureHelp { report.help }
    private var game: Game { library.games.first { $0.id == job.game.id } ?? job.game }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(help.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(help.explanation)
                .fixedSize(horizontal: false, vertical: true)
            if help.restored {
                Text("Your build from before this rebuild is back, so the game plays as it did.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if help.isNXNatives, game.titleID != nil {
                fixes
                issues
            }
            actions
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08))
    }

    // nxnative's commits for the game that this Mac's checkout doesn't have yet
    @ViewBuilder private var fixes: some View {
        if let newer = report.newer {
            if newer.isEmpty {
                Text("nxnative has no newer changes for this game yet.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("nxnative has \(newer.count) newer change\(newer.count == 1 ? "" : "s") for this game:")
                    ForEach(newer.prefix(5)) { commit in
                        Link(destination: Self.commitURL(commit.hash)) {
                            Text("\(commit.subject) (\(commit.age))").lineLimit(1)
                        }
                    }
                }
            }
        } else {
            Text("Looking for newer nxnative changes for this game…").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var issues: some View {
        if let id = game.titleID {
            if let found = report.issues, !found.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reported in nxnative:")
                    ForEach(found.prefix(4)) { issue in
                        Link(destination: issue.url) {
                            Text("#\(issue.number) \(issue.title)\(issue.isOpen ? "" : " (closed)")").lineLimit(1)
                        }
                    }
                }
            } else if report.issuesChecked {
                Link(
                    report.issues == nil ? "Search nxnative's issues for this game" : "No nxnative issue names this game yet",
                    destination: NXNativeIssues.searchPage(titleID: id))
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if help.restored, game.state == .ready {
                Button("Play Current Build") { library.playCurrentBuild(game) }
                    .help("Plays the build that was put back, without the nxnative changes that failed")
                if !game.isKept, game.canKeep {
                    Button("Keep This Build") { library.setKept(true, game) }
                        .help("nxnative updates won't rebuild it again until you unkeep it, or press Rebuild")
                }
            }
            if help.retries { Button("Try Again") { retry() } }
            if let newer = report.newer, !newer.isEmpty, game.canBuildFromFiles {
                Button("Update and Rebuild") { library.rebuild(game) }
            }
            switch help.known {
            case .otherMetal?: SettingsLink { Text("Settings…") }
            case .diskFull?: Button("Free Up Space…") { openWindow(id: CleanupView.windowID) }
            default: EmptyView()
            }
            Spacer()
            if help.isNXNatives {
                Button("Check Again") { library.checkForFixes(job) }
                    .disabled(report.newer == nil)
                Button("Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(library.failureDetails(job), forType: .string)
                }
                .help("The game, nxnative's commit, this Mac and the end of the output, for an nxnative issue")
                Link("New nxnative Issue", destination: Self.newIssue)
            }
        }
        .controlSize(.small)
        .disabled(library.isBusy(game))
    }

    private func retry() {
        switch job.kind {
        case .play: library.play(game)
        case .rebuild: library.rebuild(game)
        case .extract: library.extract(game)
        default: library.rebuild(game)
        }
    }

    static func commitURL(_ hash: String) -> URL {
        URL(string: "https://github.com/\(NXNativeIssues.repository)/commit/\(hash)")!
    }
    static let newIssue = URL(string: "https://github.com/\(NXNativeIssues.repository)/issues/new/choose")!
}
