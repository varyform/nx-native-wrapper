import SwiftUI

/// Console Mode's build progress as a staircase: a step per stage of the build, rising left to right, the done ones
/// solid, the current one filling as it goes (pulsing when its work can't be counted), and a figure walking up them,
/// along the current step as its share grows. It waves from the top step once the build is done.
struct BuildStairs: View {
    let progress: BuildProgress?

    static let height = 56.0
    private static let low = 8.0, high = 36.0, gap = 6.0

    var body: some View {
        // before the first stage: the steps of a typical build, the figure at the foot
        let stages = max(progress?.stages ?? 6, 1)
        let current = min(max((progress?.stage ?? 1) - 1, 0), stages - 1)
        let finished = progress?.isLastStageDone == true
        let within = finished ? 1 : progress?.finished == true ? 1 : progress?.stageFraction
        GeometryReader { geometry in
            let width = (geometry.size.width - Self.gap * Double(stages - 1)) / Double(stages)
            ZStack(alignment: .bottomLeading) {
                ForEach(0..<stages, id: \.self) { index in
                    step(
                        index, of: stages, width: width,
                        done: finished || index < current || (index == current && within == 1),
                        filling: index == current && progress != nil ? within : nil,
                        pulsing: index == current && progress != nil && within == nil)
                }
                Walker(waving: finished)
                    .offset(
                        x: Double(current) * (width + Self.gap) + width * (within ?? 0.5) - 11,
                        y: -Self.height(current, of: stages) - 1)
            }
            .frame(
                width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading
            )
            .animation(.easeInOut(duration: 0.8), value: current)
            .animation(.easeInOut(duration: 0.8), value: within)
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

/// The figure on the stairs: walking with a bob in its step, waving from the top.
private struct Walker: View {
    let waving: Bool

    var body: some View {
        Image(systemName: waving ? "figure.wave" : "figure.walk")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .phaseAnimator(waving ? [0.0] : [0.0, -3.0]) { figure, lift in
                figure.offset(y: lift)
            } animation: { _ in
                .easeInOut(duration: 0.3)
            }
    }
}
