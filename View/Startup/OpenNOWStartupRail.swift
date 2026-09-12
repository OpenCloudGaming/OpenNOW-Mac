import SwiftUI

/// Segmented progress. Discrete cells snapping on read as machine state; the
/// smooth capsule this replaces read as a generic download bar.
struct OpenNOWStartupRail: View, Equatable {
    let stage: OpenNOWStartupStage
    let metrics: OpenNOWStartupMetrics

    /// The bar is quantised twice over - whole cells, whole percent - so it only has a new frame
    /// to draw when one of those steps, not on every tick between them.
    nonisolated static func == (lhs: OpenNOWStartupRail, rhs: OpenNOWStartupRail) -> Bool {
        lhs.percent == rhs.percent
            && lhs.filledCount == rhs.filledCount
            && lhs.stage.statusText == rhs.stage.statusText
            && lhs.stage.frameMarks == rhs.stage.frameMarks
            && lhs.stage.bloom == rhs.stage.bloom
            && lhs.metrics == rhs.metrics
    }

    nonisolated fileprivate var percent: Int { Int((stage.progress * 100).rounded()) }
    nonisolated fileprivate var filledCount: Int { Int((Double(metrics.railCells) * stage.progress).rounded(.down)) }

    var body: some View {
        let scale = metrics.uiScale

        VStack(spacing: 10 * scale) {
            HStack(alignment: .firstTextBaseline) {
                Text(stage.statusText)
                    .font(OpenNOWDesign.Typography.label(size: metrics.compact ? 10 : 12, scale: scale, weight: .black))
                    .tracking((metrics.compact ? 2.0 : 3.0) * scale)
                    .foregroundStyle(OpenNOWDesign.Text.secondary)

                Spacer(minLength: 12 * scale)

                Text("\(percent)%")
                    .font(OpenNOWDesign.Typography.mono(size: metrics.compact ? 10 : 12, scale: scale, weight: .black))
                    .foregroundStyle(OpenNOWDesign.accent)
                    .contentTransition(.identity)
            }

            OpenNOWStartupSegmentBar(filledCount: filledCount, cells: metrics.railCells, scale: scale)
                .frame(height: (metrics.compact ? 8 : 11) * scale)
        }
        .frame(width: metrics.railWidth)
        .position(x: metrics.size.width / 2, y: metrics.railY - (metrics.compact ? 6 : 8) * scale)
        .opacity(stage.frameMarks * (1 - stage.bloom * 0.15))
        .allowsHitTesting(false)
    }
}

private struct OpenNOWStartupSegmentBar: View {
    let filledCount: Int
    let cells: Int
    let scale: CGFloat

    var body: some View {
        let accent = OpenNOWDesign.accent

        HStack(spacing: 3 * scale) {
            ForEach(0..<cells, id: \.self) { index in
                let isFilled = index < filledCount
                let isHead = index == filledCount - 1

                Rectangle()
                    .fill(isFilled ? accent.opacity(isHead ? 1.0 : 0.72) : OpenNOWDesign.Stroke.regular)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(y: isHead ? 1.0 : (isFilled ? 0.78 : 0.42), anchor: .bottom)
                    .shadow(color: isHead ? accent.opacity(0.95) : .clear, radius: 10 * scale)
            }
        }
    }
}
