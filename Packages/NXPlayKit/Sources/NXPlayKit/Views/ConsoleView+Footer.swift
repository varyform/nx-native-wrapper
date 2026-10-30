import SwiftUI

/// The footer's left: the build running (a game that needs a rebuild before it plays, or any other), whichever game is
/// selected, so the banner's caption keeps its place. Several builds: the running one, with how many there are.
struct FooterBuild: View {
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
                Text(job.map(Self.title) ?? " ")
                    .fontWeight(.semibold)
                if jobs.count > 1 {
                    Text("+\(jobs.count - 1) more").foregroundStyle(.white.opacity(0.6))
                        .layoutPriority(1)
                }
            }
            .font(.title3)
            .frame(width: Self.bar, alignment: .leading)
            HStack(spacing: 14) {
                // getting ready has no amount yet: a moving bar, no percentage (its room kept)
                let preparing = job?.isPreparing == true
                Group {
                    if preparing {
                        ProgressView().progressViewStyle(.linear)
                    } else {
                        ProgressView(value: job?.progressFraction ?? 0)
                    }
                }
                .tint(.white)
                .frame(width: Self.bar)
                Text("\(Int(((job?.progressFraction ?? 0) * 100).rounded()))%")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .opacity(preparing ? 0 : 1)
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

    /// "Preparing ANIMAL WELL" while nxplay gets ready, "Building ANIMAL WELL" for a play that builds first.
    static func title(_ job: Job) -> String {
        guard job.kind == .play else { return job.game.name }
        return (job.isPreparing ? "Preparing " : "Building ") + job.game.name
    }
}

/// What the buttons do, with the connected controller's own symbols, or the keys without one.
struct Hints: View {
    let game: Game?
    let gamepad: Gamepad
    let mode: Mode
    /// An update waits: the row says which button shows it.
    var update = false

    /// What the buttons do where the focus is: the games' row, the details' text or screenshots, a screenshot shown.
    enum Mode { case row, text, screenshots, viewer }

    var body: some View {
        let pad = gamepad.symbol(for: .down) != nil
        let sideways = gamepad.symbol(for: .left) ?? "arrow.left.arrow.right"
        let confirm = gamepad.symbol(for: .confirm) ?? "return"
        let back = gamepad.symbol(for: .back) ?? "escape"
        let info = gamepad.symbol(for: .info) ?? "u.square"
        HStack(spacing: 32) {
            switch mode {
            case .row:
                hint(sideways, "Choose")
                if game != nil {
                    hint(pad ? "dpad.down.filled" : "arrow.down", "Details")
                    hint(confirm, "Play")
                }
                if update { hint(info, "Update") }
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
