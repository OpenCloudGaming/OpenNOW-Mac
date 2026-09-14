import SwiftUI

/// Corner brackets, product mark and build stamp. HUD chrome, drawn with the
/// app's square geometry rather than the rounded cards this screen used before.
struct StartupFrameMarks: View, Equatable {
    let stage: StartupStage
    let metrics: StartupMetrics

    /// Everything here is keyed off `frameMarks`, which is settled by 26% of the run.
    nonisolated static func == (lhs: StartupFrameMarks, rhs: StartupFrameMarks) -> Bool {
        lhs.stage.frameMarks == rhs.stage.frameMarks && lhs.metrics == rhs.metrics
    }

    private static let version: String = {
        let bundle = Bundle.main.infoDictionary
        let short = bundle?["CFBundleShortVersionString"] as? String ?? "0"
        return "v\(short)"
    }()

    var body: some View {
        let reveal = stage.frameMarks
        let scale = metrics.uiScale
        let arm = (metrics.compact ? 18.0 : 26.0) * scale

        ZStack {
            ForEach(0..<4, id: \.self) { corner in
                StartupCornerBracket(arm: arm)
                    .stroke(OPNDesign.Fixed.accent.opacity(0.52 * reveal), lineWidth: 1)
                    .frame(width: arm, height: arm)
                    .rotationEffect(.degrees(Double(corner) * 90))
                    .padding(metrics.inset)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: Self.alignment(for: corner)
                    )
                    .offset(y: CGFloat(1 - reveal) * 8 * scale)
            }

            VStack(alignment: .leading, spacing: 4 * scale) {
                Text("OPENNOW")
                    .font(OPNDesign.Typography.label(size: 11, scale: scale, weight: .black))
                    .tracking(3.4 * scale)
                    .foregroundStyle(OPNDesign.Fixed.ink(0.72))
                Text("BOOT SEQUENCE")
                    .font(OPNDesign.Typography.mono(size: 9, scale: scale))
                    .tracking(1.6 * scale)
                    .foregroundStyle(OPNDesign.accentInk.opacity(0.72))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(metrics.inset + arm + 14 * scale)
            .opacity(reveal)

            Text(Self.version)
                .font(OPNDesign.Typography.mono(size: 9, scale: scale))
                .tracking(1.4 * scale)
                .foregroundStyle(OPNDesign.Fixed.ink(0.38))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(metrics.inset + arm + 14 * scale)
                .opacity(reveal)
        }
        .allowsHitTesting(false)
    }

    private static func alignment(for corner: Int) -> Alignment {
        switch corner {
        case 0: return .topLeading
        case 1: return .topTrailing
        case 2: return .bottomTrailing
        default: return .bottomLeading
        }
    }
}

private struct StartupCornerBracket: Shape {
    let arm: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        return path
    }
}
