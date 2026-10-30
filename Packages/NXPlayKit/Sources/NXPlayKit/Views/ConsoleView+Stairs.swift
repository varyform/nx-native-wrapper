import SwiftUI

/// Console Mode's build progress as a staircase: a step per stage of the build, rising left to right, the done ones
/// solid, the current one filling as it goes (pulsing when its work can't be counted), and a figure (StairWalker)
/// walking up them to where the build is, pacing its step while the build doesn't move, waving from the top once done.
struct BuildStairs: View {
    let progress: BuildProgress?
    /// A build is on: the figure moves (it stands still, and costs nothing, while the footer is hidden).
    var active = true
    /// A Metroid builds or is selected: the figure suits up (StairWalker+Metroid.swift).
    var metroid = false
    @State private var walker = StairWalker()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height = 56.0
    /// Room above the top step for the figure.
    static let headroom = 34.0
    private static let low = 8.0, high = 36.0, gap = 6.0

    var body: some View {
        // before the first stage: the steps of a typical build, the figure pacing the first
        let stages = max(progress?.stages ?? 6, 1)
        let current = min(max((progress?.stage ?? 1) - 1, 0), stages - 1)
        let finished = progress?.isLastStageDone == true
        let within = finished ? 1 : progress?.finished == true ? 1 : progress?.stageFraction
        GeometryReader { geometry in
            let width = (geometry.size.width - Self.gap * Double(stages - 1)) / Double(stages)
            let stairs = StairGeometry(stages: stages, width: width, gap: Self.gap)
            ZStack(alignment: .bottomLeading) {
                ForEach(0..<stages, id: \.self) { index in
                    step(
                        index, of: stages, width: width,
                        done: finished || index < current || (index == current && within == 1),
                        filling: index == current && progress != nil ? within : nil,
                        pulsing: index == current && progress != nil && within == nil)
                }
            }
            .frame(
                width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading
            )
            .animation(.easeInOut(duration: 0.8), value: current)
            .animation(.easeInOut(duration: 0.8), value: within)
            .overlay(alignment: .bottomLeading) {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active || reduceMotion))
                { timeline in
                    Canvas { context, size in
                        walker.update(
                            now: timeline.date, stairs: stairs,
                            goal: stairs.start(current) + width
                                * min(max(within ?? 0.5, 0.06), 0.94),
                            step: current, countable: progress != nil && within != nil,
                            finished: finished, animate: active && !reduceMotion, metroid: metroid)
                        Self.draw(walker.pose, shots: walker.shots, in: context, height: size.height)
                    }
                }
                .frame(width: geometry.size.width, height: Self.height + Self.headroom)
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)  // the percentage and the line under it say it
    }

    private func step(
        _ index: Int, of stages: Int, width: Double, done: Bool, filling: Double?, pulsing: Bool
    ) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(.white.opacity(done ? 0.95 : 0.16))
            if !done, let filling {
                RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.75))
                    .frame(width: max(0, width * filling))
            }
            if pulsing {
                RoundedRectangle(cornerRadius: 4).fill(.white)
                    .phaseAnimator([0.08, 0.4]) { shape, opacity in
                        shape.opacity(opacity)
                    } animation: { _ in
                        .easeInOut(duration: 0.9)
                    }
            }
        }
        .frame(width: width, height: Self.height(index, of: stages))
        .offset(x: Double(index) * (width + Self.gap))
    }

    /// A step's height: the first low, the last high.
    static func height(_ index: Int, of stages: Int) -> Double {
        stages == 1 ? high : low + (high - low) * Double(index) / Double(stages - 1)
    }
}
