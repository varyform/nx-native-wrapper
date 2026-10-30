import SwiftUI

/// Console Mode's marks for the game being built: on its tile a bright arc running round the border and a pill with
/// how far it is, and when its tile is off screen a marker at that edge of the row pointing to it.
enum TileBuild: Equatable {
    /// Building now, this far (0...1).
    case running(Double)
    /// Waiting its turn.
    case queued
}

/// The arc running round a tile's border while its game builds; still with Reduce Motion.
struct BuildRing: View {
    var cornerRadius = 28.0
    var lineWidth = 5.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let turn =
                timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4)
                / 2.4
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    AngularGradient(
                        stops: [
                            .init(color: .blue.opacity(0), location: 0),
                            .init(color: .blue.opacity(0), location: 0.55),
                            .init(color: .blue, location: 0.85),
                            .init(color: .white, location: 0.97),
                            .init(color: .blue.opacity(0), location: 1),
                        ],
                        center: .center, angle: .degrees(reduceMotion ? 0 : turn * 360)),
                    lineWidth: lineWidth)
        }
        .allowsHitTesting(false)
    }
}

/// "Building 42%" or "Queued", at the foot of the tile.
struct TileBuildPill: View {
    let build: TileBuild

    var body: some View {
        Group {
            switch build {
            case .running(let fraction):
                Label("Building \(Int((fraction * 100).rounded()))%", systemImage: "hammer.fill")
            case .queued:
                Label("Queued", systemImage: "clock")
            }
        }
        .font(.headline)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .foregroundStyle(.white)
        .background(
            Capsule().fill(build == .queued ? Color.gray.opacity(0.85) : Color.blue.opacity(0.9))
        )
        .padding(.bottom, 14)
    }
}

/// At the edge of the row when the game being built is off screen that way: an arrow, its icon and how far it is.
/// It nudges toward the game; a click selects it.
struct OffscreenBuild: View {
    let game: Game
    let icon: URL?
    let fraction: Double
    /// The game is to the left (else to the right).
    let toLeft: Bool
    @Environment(Library.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            if toLeft { arrow }
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.08))
                if let icon, let image = IconCache.image(at: icon) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay { BuildRing(cornerRadius: 14, lineWidth: 3) }
            VStack(alignment: .leading, spacing: 2) {
                Text("Building").font(.headline)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
            if !toLeft { arrow }
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 22).fill(.black.opacity(0.6)))
        .phaseAnimator(reduceMotion ? [0.0] : [0.0, 6.0]) { marker, nudge in
            marker.offset(x: toLeft ? -nudge : nudge)
        } animation: { _ in
            .easeInOut(duration: 0.7)
        }
        .contentShape(.rect)
        .onTapGesture { library.selection = game.id }
        .help("\(game.name): show it")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var arrow: some View {
        Image(systemName: toLeft ? "chevron.left" : "chevron.right").font(.title.weight(.bold))
    }
}
