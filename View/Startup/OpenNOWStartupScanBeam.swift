import SwiftUI

/// The falling beam. It is the only travelling element on screen, and it ends
/// its travel exactly on the rail so the progress bar reads as its residue.
struct OpenNOWStartupScanBeam: View {
    let stage: OpenNOWStartupStage
    let metrics: OpenNOWStartupMetrics

    var body: some View {
        let scale = metrics.uiScale
        let sweep = stage.sweep
        let landing = startupSmoothStep(0.88, 1.00, sweep)
        let haloHeight = (metrics.compact ? 64.0 : 104.0) * scale

        ZStack(alignment: .top) {
            beam(width: metrics.size.width, haloHeight: haloHeight, thickness: 1.6 * scale, intensity: 1 - landing)
                .offset(y: metrics.beamY(sweep) - haloHeight)

            // Priming pass: a thinner, faster beam that clears the frame before
            // the developing sweep starts, so the screen never opens on stillness.
            beam(width: metrics.size.width, haloHeight: haloHeight * 0.5, thickness: 1.0 * scale, intensity: (1 - stage.preSweep) * 0.7)
                .offset(y: metrics.beamY(stage.preSweep) - haloHeight * 0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .blendMode(.screen)
        .allowsHitTesting(false)
    }

    private func beam(width: CGFloat, haloHeight: CGFloat, thickness: CGFloat, intensity: Double) -> some View {
        let accent = OpenNOWDesign.accent

        return VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.00),
                    .init(color: accent.opacity(0.05), location: 0.62),
                    .init(color: accent.opacity(0.26), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: haloHeight)

            Rectangle()
                .fill(accent)
                .frame(height: thickness)
                .shadow(color: accent.opacity(0.85), radius: 8 * metrics.uiScale)
                .shadow(color: accent.opacity(0.30), radius: 22 * metrics.uiScale)
        }
        .frame(width: width)
        .opacity(intensity)
    }
}
