import SwiftUI

/// Centered step bus. Reads as one horizontal run of equal-width stations
/// spanning exactly the rail width beneath it, so every station's marker, label
/// and stamp sit on a shared baseline instead of drifting per row the way the
/// left-anchored ledger did.
struct OpenNOWStartupTelemetry: View, Equatable {
    let stage: OpenNOWStartupStage
    let metrics: OpenNOWStartupMetrics

    /// The last station settles at 0.84, so progress past that changes nothing on this layer.
    nonisolated static func == (lhs: OpenNOWStartupTelemetry, rhs: OpenNOWStartupTelemetry) -> Bool {
        min(lhs.stage.progress, 0.85) == min(rhs.stage.progress, 0.85)
            && lhs.stage.duration == rhs.stage.duration
            && lhs.metrics == rhs.metrics
    }

    private static let entries: [(label: String, mark: Double)] = [
        ("core.bootstrap", 0.20),
        ("vault.session", 0.34),
        ("catalog.index", 0.48),
        ("stream.profiles", 0.62),
        ("input.devices", 0.74),
        ("window.state", 0.84)
    ]

    var body: some View {
        let scale = metrics.uiScale
        let width = metrics.railWidth
        let gap = width / CGFloat(max(Self.entries.count - 1, 1))
        let marker = 7 * scale

        VStack(spacing: 12 * scale) {
            Text("LOAD SEQUENCE")
                .font(OpenNOWDesign.Typography.mono(size: 9, scale: scale))
                .tracking(2.4 * scale)
                .foregroundStyle(OpenNOWDesign.Text.muted)

            ZStack(alignment: .topLeading) {
                OpenNOWStartupBusTrack(
                    fill: busFill,
                    trackWidth: width,
                    scale: scale
                )
                .offset(y: (marker - 1) / 2)

                HStack(spacing: 0) {
                    ForEach(Array(Self.entries.enumerated()), id: \.offset) { _, entry in
                        OpenNOWStartupBusStation(
                            label: entry.label,
                            stamp: entry.mark * stage.duration,
                            settled: stage.progress >= entry.mark,
                            reveal: startupSmoothStep(entry.mark - 0.16, entry.mark - 0.02, stage.progress),
                            marker: marker,
                            scale: scale
                        )
                        .frame(width: gap)
                    }
                }
                .frame(width: width + gap)
                .offset(x: -gap / 2)
            }
            // Pin the run's layout width to the rail's: the station row is a gap
            // wider than that and must overhang, not stretch the block.
            .frame(width: width, alignment: .topLeading)
        }
        .frame(width: width)
        .position(x: metrics.size.width / 2, y: metrics.railY - (metrics.compact ? 62 : 84) * scale)
        .opacity(stage.telemetry)
        .allowsHitTesting(false)
    }

    /// Progress along the run, measured between the first and last station so the
    /// line reaches a marker exactly when that station settles.
    private var busFill: Double {
        guard let first = Self.entries.first?.mark, let last = Self.entries.last?.mark, last > first else { return 0 }
        return startupClamp((stage.progress - first) / (last - first))
    }
}

private struct OpenNOWStartupBusTrack: View {
    let fill: Double
    let trackWidth: CGFloat
    let scale: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(OpenNOWDesign.Stroke.subtle)
                .frame(width: trackWidth, height: 1)

            Rectangle()
                .fill(OpenNOWDesign.accent.opacity(0.60))
                .frame(width: trackWidth * CGFloat(fill), height: 1)
                .shadow(color: OpenNOWDesign.accent.opacity(0.55), radius: 4 * scale)
        }
        .frame(width: trackWidth, alignment: .leading)
    }
}

private struct OpenNOWStartupBusStation: View {
    let label: String
    let stamp: Double
    let settled: Bool
    let reveal: Double
    let marker: CGFloat
    let scale: CGFloat

    var body: some View {
        let accent = OpenNOWDesign.accent

        VStack(spacing: 8 * scale) {
            Rectangle()
                .fill(settled ? accent : OpenNOWDesign.Surface.deep)
                .frame(width: marker, height: marker)
                .overlay {
                    Rectangle()
                        .stroke(settled ? accent : OpenNOWDesign.Stroke.strong, lineWidth: 1)
                }
                .shadow(color: settled ? accent.opacity(0.85) : .clear, radius: 6 * scale)
                // Opaque pad so the bus line passes between stations, not through them.
                .padding(4 * scale)
                .background(Color.black)

            Text(label)
                .font(OpenNOWDesign.Typography.mono(size: 9, scale: scale))
                .foregroundStyle(settled ? OpenNOWDesign.Text.secondary : OpenNOWDesign.Text.muted)
                .lineLimit(1)
                .fixedSize()

            Text(String(format: "%.2fs", stamp))
                .font(OpenNOWDesign.Typography.mono(size: 8, scale: scale, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(settled ? accent.opacity(0.80) : OpenNOWDesign.Text.muted)
        }
        .opacity(0.38 + reveal * 0.62)
        .offset(y: CGFloat(1 - reveal) * 4 * scale)
    }
}
