import SwiftUI

/// Grid, bloom, scanlines and grain in one `Canvas` pass.
///
/// The previous build stacked five `rotation3DEffect` rectangles under nine
/// capsules, all with `.blendMode(.screen)`, which forces an offscreen pass per
/// layer on exactly the frames where app bootstrap is saturating the CPU. One
/// canvas draws the same depth for a single composite.
struct OpenNOWStartupBackdrop: View {
    let stage: OpenNOWStartupStage
    let metrics: OpenNOWStartupMetrics

    var body: some View {
        let ignite = stage.ignite
        let bloom = stage.bloom
        let develop = stage.develop
        let drift = stage.drift
        let frameIndex = stage.frameIndex
        let reduceMotion = stage.reduceMotion
        let bandCenterY = metrics.bandCenterY

        Canvas(opaque: true, rendersAsynchronously: false) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

            drawCoreBloom(in: &context, size: size, centerY: bandCenterY, develop: develop, bloom: bloom)
            drawFloorGrid(in: &context, size: size, ignite: ignite, drift: drift)
            drawVignette(in: &context, size: size)

            guard !reduceMotion else { return }
            drawScanlines(in: &context, size: size, ignite: ignite)
            drawGrain(in: &context, size: size, frameIndex: frameIndex)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func drawCoreBloom(in context: inout GraphicsContext, size: CGSize, centerY: CGFloat, develop: Double, bloom: Double) {
        let accent = OpenNOWDesign.accent
        let radius = min(size.width, size.height) * (0.34 + bloom * 0.06)
        let center = CGPoint(x: size.width / 2, y: centerY)
        let gradient = Gradient(stops: [
            .init(color: accent.opacity(0.11 * develop + 0.05 * bloom), location: 0.00),
            .init(color: accent.opacity(0.04 * develop + 0.02 * bloom), location: 0.34),
            .init(color: .clear, location: 1.00)
        ])

        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: radius)
        )
    }

    /// Perspective floor converging on the logo band. Both families are built as
    /// one `Path` each so the whole grid costs two stroke calls.
    private func drawFloorGrid(in context: inout GraphicsContext, size: CGSize, ignite: Double, drift: Double) {
        guard ignite > 0.001 else { return }
        let accent = OpenNOWDesign.accent
        let vanishing = CGPoint(x: size.width / 2, y: size.height * 0.46)
        let depth = size.height - vanishing.y
        guard depth > 0 else { return }

        var rays = Path()
        let rayCount = 17
        for index in 0...rayCount {
            let t = Double(index) / Double(rayCount)
            let spread = (t - 0.5) * 4.4
            rays.move(to: vanishing)
            rays.addLine(to: CGPoint(x: vanishing.x + size.width * CGFloat(spread), y: size.height))
        }
        context.stroke(rays, with: .color(accent.opacity(0.13 * ignite)), lineWidth: 1)

        var rows = Path()
        let rowCount = 13
        for index in 0..<rowCount {
            let t = (Double(index) + drift) / Double(rowCount)
            let y = vanishing.y + depth * CGFloat(pow(t, 2.3))
            rows.move(to: CGPoint(x: 0, y: y))
            rows.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(rows, with: .color(accent.opacity(0.16 * ignite)), lineWidth: 1)

        // Horizon: the one bright line, so the grid reads as ground and not wallpaper.
        var horizon = Path()
        horizon.move(to: CGPoint(x: 0, y: vanishing.y))
        horizon.addLine(to: CGPoint(x: size.width, y: vanishing.y))
        context.stroke(horizon, with: .color(accent.opacity(0.46 * ignite)), lineWidth: 1)
    }

    private func drawVignette(in context: inout GraphicsContext, size: CGSize) {
        let gradient = Gradient(stops: [
            .init(color: .clear, location: 0.00),
            .init(color: .clear, location: 0.30),
            .init(color: .black.opacity(0.55), location: 0.72),
            .init(color: .black.opacity(0.94), location: 1.00)
        ])
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                gradient,
                center: CGPoint(x: size.width / 2, y: size.height / 2),
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.74
            )
        )
    }

    private func drawScanlines(in context: inout GraphicsContext, size: CGSize, ignite: Double) {
        guard ignite > 0.001 else { return }
        var path = Path()
        var y: CGFloat = 0
        while y < size.height {
            path.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
            y += 3
        }
        context.fill(path, with: .color(.black.opacity(0.22 * ignite)))
    }

    private func drawGrain(in context: inout GraphicsContext, size: CGSize, frameIndex: Int) {
        var path = Path()
        let count = 220
        for index in 0..<count {
            let seed = index &+ frameIndex &* 977
            let x = CGFloat(startupHash(seed)) * size.width
            let y = CGFloat(startupHash(seed &+ 7919)) * size.height
            path.addRect(CGRect(x: x, y: y, width: 1.5, height: 1.5))
        }
        context.fill(path, with: .color(.white.opacity(0.035)))
    }
}
