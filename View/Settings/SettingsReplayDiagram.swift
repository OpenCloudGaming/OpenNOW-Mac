import SwiftUI

/// The Instant Replay model as one picture: the window kept on disk, with the slice a save takes from
/// its tail highlighted. Two sliders and a paragraph could not say what this says at a glance.
struct ReplayWindowDiagram: View {
    let windowSeconds: Double
    let clipSeconds: Double
    let uiScale: CGFloat

    private static let trackHeight: CGFloat = 8
    private static let minimumClipWidth: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
            labels
            track
            Text("A save writes the highlighted tail: the most recent \(Self.durationText(seconds: clipSeconds)), ending the moment you press.")
                .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var labels: some View {
        HStack(alignment: .firstTextBaseline, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            eyebrow("Kept on disk · \(Self.durationText(seconds: windowSeconds))", color: OPNDesign.Text.muted)
            Spacer(minLength: 0)
            eyebrow("\(OPNKeybindings.standard.combo(for: .saveReplay).label) saves · \(Self.durationText(seconds: clipSeconds))", color: OPNDesign.accentInk)
        }
    }

    /// Measured inside an overlay, not as a `VStack` child: a `GeometryReader` in the stack takes the
    /// height it is offered, which collapsed the caption under it.
    private var track: some View {
        Rectangle()
            .fill(OPNDesign.Fill.neutral(0.075))
            .frame(height: Self.trackHeight * uiScale)
            .overlay {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(OPNDesign.accent)
                        .frame(width: clipWidth(in: geometry.size.width))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }
            .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
    }

    /// The tail keeps its share of the track, but never shrinks below a visible sliver: a one-minute
    /// clip against a two-hour window is 0.8%, and a hairline would read as a rendering fault.
    private func clipWidth(in trackWidth: CGFloat) -> CGFloat {
        guard windowSeconds > 0 else { return trackWidth }
        let fraction = min(1, max(0, clipSeconds / windowSeconds))
        return min(trackWidth, max(Self.minimumClipWidth * uiScale, trackWidth * fraction))
    }

    private func eyebrow(_ text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.settingsFont(size: 10 * uiScale, weight: .bold))
            .tracking(1.0)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    /// One duration vocabulary for both numbers: `45 s`, `1 min`, `1 h 30 min`.
    static func durationText(seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        let hours = whole / 3_600
        let minutes = (whole % 3_600) / 60
        let remainder = whole % 60
        guard hours == 0 else { return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min" }
        guard minutes == 0 else { return remainder == 0 ? "\(minutes) min" : "\(minutes) min \(remainder) s" }
        return "\(remainder) s"
    }
}
