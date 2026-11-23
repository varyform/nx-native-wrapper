import SwiftUI

/// A volume's storage bar above Free Up Space's kinds, as System Settings › Storage draws one: each kind's share in its
/// colour, the rest of the used space in grey, then the free space; the part under the pointer names itself and its
/// size in a bubble above it.
struct StorageBar: View {
    let volume: CleanupVolume
    /// The scan is still measuring: the kinds' parts are still growing.
    var measuring = false
    @State private var hovered: String?
    @State private var bubbleSize: CGSize = .zero

    struct Segment: Identifiable {
        let id: String
        let title: Text
        let size: Int64
        let color: Color
    }

    /// A segment where the bar draws it.
    struct Placed {
        let segment: Segment
        let x: CGFloat
        let width: CGFloat
    }

    private var segments: [Segment] {
        volume.kinds.map {
            Segment(id: $0.kind.rawValue, title: Text($0.kind.title), size: $0.size, color: $0.kind.color)
        }
            + [
                Segment(id: "other", title: Text("Everything else"), size: volume.other, color: .gray),
                Segment(id: "free", title: Text("Free"), size: volume.info.available, color: .primary.opacity(0.1)),
            ]
    }

    /// Each part's share of the width, a point apart; a sliver still shows (a few MB on a 4 TB drive).
    private func placed(in width: CGFloat) -> [Placed] {
        let shown = segments.filter { $0.size > 0 }
        let total = max(1, Double(volume.info.total))
        let room = max(0, width - CGFloat(max(0, shown.count - 1)))
        var x: CGFloat = 0
        return shown.map { segment in
            let w = max(2, room * Double(segment.size) / total)
            defer { x += w + 1 }
            return Placed(segment: segment, x: x, width: w)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(volume.info.name).fontWeight(.medium)
                if measuring {
                    ProgressView().controlSize(.small)
                    Text("Measuring\u{2026}").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(bytes(volume.used)) of \(bytes(volume.info.total)) used")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            bar
            legend
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // The parts come from the width GeometryReader proposes, never from a width measured back into state: that
    // made each measurement lay the parts out again, start another animation and measure again, which hung the
    // main thread combining animations.
    private var bar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let parts = placed(in: width)
            HStack(spacing: 1) {
                ForEach(parts, id: \.segment.id) { part in
                    Rectangle()
                        .fill(part.segment.color)
                        .frame(width: part.width)
                        .opacity(hovered == nil || hovered == part.segment.id ? 1 : 0.6)
                }
            }
            .frame(width: width, height: 20, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            // one hover for the bar, not one per part: moving across the point between two never drops the bubble
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = parts.last { $0.x <= point.x }?.segment.id
                case .ended: hovered = nil
                }
            }
            // outside the clip, so the bubble can stand above the bar
            .overlay(alignment: .topLeading) {
                if let part = parts.first(where: { $0.segment.id == hovered }) {
                    bubble(for: part, in: width)
                }
            }
        }
        .frame(height: 20)
        // no animations: an inactive window holds them back, and the app took as long to come back to the front as
        // it had been in the background
    }

    /// The bubble above a part, its arrow's tip just inside the bar, kept inside the bar's width with the arrow
    /// still on the part. An offset from its measured size, which moves it without laying anything out again.
    private func bubble(for part: Placed, in barWidth: CGFloat) -> some View {
        let center = part.x + part.width / 2
        let left = min(max(0, center - bubbleSize.width / 2), max(0, barWidth - bubbleSize.width))
        return StorageBubble(
            title: part.segment.title, size: bytes(part.segment.size), arrowX: center - left
        )
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { bubbleSize = $0 }
        .offset(x: left, y: 3 - bubbleSize.height)
        // until it's measured, so it never shows in the wrong place for a frame
        .opacity(bubbleSize == .zero ? 0 : 1)
        .allowsHitTesting(false)
    }

    /// On as many lines as it needs: one line as wide as all its items made the window wider.
    private var legend: some View {
        LegendLayout(spacing: 14, lineSpacing: 4) {
            ForEach(segments.filter { $0.id != "free" && $0.size > 0 }) { segment in
                HStack(spacing: 5) {
                    Circle().fill(segment.color).frame(width: 8, height: 8)
                    segment.title
                }
                .help(Text("\(segment.title): \(bytes(segment.size))"))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func bytes(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// Items left to right, on the next line when the width runs out.
private struct LegendLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, $0.count - 1)) }.max() ?? 0
        let height = rows.map { $0.map(\.height).max() ?? 0 }.reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY, index = 0
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            let height = row.map(\.height).max() ?? 0
            for size in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += height + lineSpacing
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]], used: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].isEmpty && used + spacing + size.width > width {
                rows.append([])
                used = 0
            }
            used += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].append(size)
        }
        return rows
    }
}

/// System Settings' storage callout, which has no public API: a part's name and size in a glass bubble whose arrow
/// points down at it.
private struct StorageBubble: View {
    let title: Text
    let size: String
    /// The arrow's tip from the bubble's leading edge.
    let arrowX: CGFloat

    var body: some View {
        let shape = BubbleShape(arrowX: arrowX)
        VStack(spacing: 1) {
            title.font(.headline)
            Text(size).font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 7)
        .padding(.bottom, 7 + BubbleShape.arrow)
        .background {
            if #available(macOS 26, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.regularMaterial).overlay(shape.stroke(.separator))
            }
        }
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}

/// A rounded rectangle with an arrow at the bottom, its tip at `arrowX`, kept off the rounded corners.
private struct BubbleShape: Shape {
    static let arrow: CGFloat = 8
    let arrowX: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 12, half: CGFloat = 8
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - Self.arrow)
        let tip = min(max(arrowX, radius + half), rect.width - radius - half)
        var path = Path(roundedRect: body, cornerRadius: radius, style: .continuous)
        path.move(to: CGPoint(x: rect.minX + tip - half, y: body.maxY - 0.5))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tip, y: rect.maxY), control: CGPoint(x: rect.minX + tip - 2, y: body.maxY + 2))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tip + half, y: body.maxY - 0.5),
            control: CGPoint(x: rect.minX + tip + 2, y: body.maxY + 2))
        path.closeSubpath()
        return path
    }
}

extension CleanupKind {
    var color: Color {
        switch self {
        case .gameFiles: .red
        case .builds: .orange
        case .shaderCaches: .yellow
        case .obsolete: .green
        case .ipas: .mint
        case .xcodeBuilds: .blue
        case .installCopies: .indigo
        case .macApps: .purple
        case .metalState: .pink
        }
    }
}
