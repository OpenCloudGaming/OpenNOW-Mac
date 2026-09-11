import SwiftUI

/// Logo, wordmark and tagline, masked so they only exist where the beam has
/// already passed.
struct OpenNOWStartupLockup: View {
    let stage: OpenNOWStartupStage
    let metrics: OpenNOWStartupMetrics

    var body: some View {
        let scale = metrics.uiScale
        let reveal = stage.reduceMotion
            ? startupSmoothStep(0.05, 0.45, stage.progress)
            : metrics.revealFraction(beamY: metrics.beamY(stage.sweep))

        VStack(spacing: (metrics.compact ? 16 : 22) * scale) {
            OpenNOWStartupLogoCore(stage: stage, metrics: metrics)

            OpenNOWStartupWordmark(stage: stage, metrics: metrics)
        }
        .frame(width: metrics.lockupWidth, height: metrics.bandHeight)
        .mask(alignment: .top) {
            OpenNOWStartupDevelopMask(reveal: reveal)
        }
        .position(x: metrics.size.width / 2, y: metrics.bandCenterY)
        .allowsHitTesting(false)
    }
}

/// Wipe mask keyed to beam position: opaque behind the beam, a short soft edge
/// at it, empty ahead of it.
private struct OpenNOWStartupDevelopMask: View {
    let reveal: Double

    var body: some View {
        let edge = startupClamp(reveal)
        let solid = max(edge - 0.10, 0)

        LinearGradient(
            stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: solid),
                .init(color: .clear, location: max(edge, solid + 0.001))
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct OpenNOWStartupLogoCore: View {
    let stage: OpenNOWStartupStage
    let metrics: OpenNOWStartupMetrics

    var body: some View {
        let chroma = stage.chroma
        let bloom = stage.bloom
        let offset = CGFloat(chroma) * (metrics.compact ? 9 : 14) * metrics.uiScale
        let accent = OpenNOWDesign.accent

        ZStack {
            // RGB split ghosts collapse into register as the beam clears the logo. Dropped rather
            // than left at zero opacity once they do: each is a screen blend over an SVG, which
            // costs its offscreen pass every frame whether or not anything of it is visible.
            if chroma > 0.01 {
                logo
                    .hueRotation(.degrees(-52))
                    .offset(x: -offset)
                    .opacity(chroma * 0.85)
                    .blendMode(.screen)

                logo
                    .hueRotation(.degrees(48))
                    .offset(x: offset)
                    .opacity(chroma * 0.85)
                    .blendMode(.screen)
            }

            logo
                .shadow(color: accent.opacity(0.34 + bloom * 0.22), radius: (metrics.compact ? 14 : 20) * metrics.uiScale)
        }
        .scaleEffect(1 + CGFloat(bloom) * 0.03)
        .frame(width: metrics.bandWidth, height: metrics.logoHeight)
    }

    private var logo: some View {
        VendorResourceImage(name: "logo-isolated", fileExtension: "svg")
            .scaledToFit()
            .frame(width: metrics.bandWidth, height: metrics.logoHeight)
    }
}

/// Per-letter stagger with a tracking collapse — the wordmark tightens into
/// place instead of fading in as a block.
private struct OpenNOWStartupWordmark: View {
    let stage: OpenNOWStartupStage
    let metrics: OpenNOWStartupMetrics

    private static let letters = Array("OPENNOW")

    var body: some View {
        let scale = metrics.uiScale
        let progress = stage.progress
        let settle = stage.wordmark
        let size = (metrics.compact ? 18.0 : 26.0) * scale
        let spacing = (8.0 - 5.6 * settle) * scale

        VStack(spacing: (metrics.compact ? 8 : 11) * scale) {
            HStack(spacing: spacing) {
                ForEach(Array(Self.letters.enumerated()), id: \.offset) { index, letter in
                    let start = 0.30 + Double(index) * 0.020
                    let reveal = stage.reduceMotion ? settle : startupSmoothStep(start, start + 0.16, progress)

                    if letter == " " {
                        Color.clear.frame(width: size * 0.34, height: 1)
                    } else {
                        OpenNOWStartupWordmarkLetter(letter: letter, size: size, reveal: reveal, scale: scale)
                    }
                }
            }

            Text("CLOUD GAMING CLIENT")
                .font(OpenNOWDesign.Typography.mono(size: metrics.compact ? 9 : 11, scale: scale, weight: .bold))
                .tracking((3.4 + 3.4 * (1 - settle)) * scale)
                .foregroundStyle(OpenNOWDesign.accent.opacity(0.92 * settle))
                .opacity(settle)
        }
    }
}

/// The blur is what makes a letter arrive rather than appear, and it is also an offscreen pass per
/// letter per frame — so it exists only while the letter is still arriving.
private struct OpenNOWStartupWordmarkLetter: View {
    let letter: Character
    let size: CGFloat
    let reveal: Double
    let scale: CGFloat

    var body: some View {
        if reveal < 0.999 {
            glyph
                .offset(y: CGFloat(1 - reveal) * 10 * scale)
                .opacity(reveal)
                .blur(radius: CGFloat(1 - reveal) * 5)
        } else {
            glyph
        }
    }

    private var glyph: some View {
        Text(String(letter))
            .font(OpenNOWDesign.Typography.display(size: size))
            .foregroundStyle(OpenNOWDesign.Text.primary)
    }
}
