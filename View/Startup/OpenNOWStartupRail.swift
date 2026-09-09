import SwiftUI

/// Segmented progress. Discrete cells snapping on read as machine state; the
/// smooth capsule this replaces read as a generic download bar.
struct OpenNOWStartupRail: View {
    let stage: OpenNOWStartupStage
    let metrics: OpenNOWStartupMetrics

    var body: some View {
        let scale = metrics.uiScale
        let fill = stage.progress
        let percent = Int((stage.progress * 100).rounded())

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

            OpenNOWStartupSegmentBar(fill: fill, cells: metrics.railCells, scale: scale)
                .frame(height: (metrics.compact ? 8 : 11) * scale)
        }
        .frame(width: metrics.railWidth)
        .position(x: metrics.size.width / 2, y: metrics.railY - (metrics.compact ? 6 : 8) * scale)
        .opacity(stage.frameMarks * (1 - stage.bloom * 0.15))
        .allowsHitTesting(false)
    }
}

private struct OpenNOWStartupSegmentBar: View {
    let fill: Double
    let cells: Int
    let scale: CGFloat

    var body: some View {
        let accent = OpenNOWDesign.accent
        let filledCount = Int((Double(cells) * fill).rounded(.down))

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
