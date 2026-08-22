import SwiftUI

enum MacForceNowStartupAnimation {
    static let duration: TimeInterval = 2.4
    static let quickDuration: TimeInterval = 0.9
    static let dismissalDelayNanoseconds: UInt64 = 2_400_000_000
    static let quickDismissalDelayNanoseconds: UInt64 = 1_000_000_000
    static let fadeDuration: TimeInterval = 0.4
}

/// Boot sequence for the app window.
///
/// The screen is a single gesture rather than a set of competing widgets: an
/// accent scan beam falls from the top edge, develops the logo lockup in the
/// band it has already passed, then lands on the bottom rail and becomes the
/// progress bar. Every stage is keyed off normalized progress, so the same
/// choreography plays whole at both the 2.4s cold duration and the 0.9s warm
/// one instead of skipping its later half.
struct MacForceNowStartupLoadingView: View {
    var duration: TimeInterval = MacForceNowStartupAnimation.duration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.opnUIScale) private var uiScale
    @State private var startDate = Date()

    var body: some View {
        GeometryReader { proxy in
            let metrics = MacForceNowStartupMetrics(size: proxy.size, uiScale: uiScale)

            TimelineView(.periodic(from: .now, by: MacForceNowDesign.Motion.heroFrameInterval)) { timeline in
                let elapsed = max(timeline.date.timeIntervalSince(startDate), 0)
                let stage = MacForceNowStartupStage(
                    progress: startupClamp(elapsed / duration),
                    elapsed: elapsed,
                    duration: duration,
                    reduceMotion: reduceMotion
                )

                ZStack {
                    MacForceNowStartupBackdrop(stage: stage, metrics: metrics)

                    MacForceNowStartupFrameMarks(stage: stage, metrics: metrics)

                    MacForceNowStartupLockup(stage: stage, metrics: metrics)

                    if !metrics.compact {
                        MacForceNowStartupTelemetry(stage: stage, metrics: metrics)
                    }

                    MacForceNowStartupRail(stage: stage, metrics: metrics)

                    if !stage.reduceMotion {
                        MacForceNowStartupScanBeam(stage: stage, metrics: metrics)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .background(.black)
        .onAppear { startDate = Date() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("MacForce Now is starting")
    }
}

// MARK: - Timeline

/// Every derived value the layers need, computed once per frame so no subview
/// re-derives an easing curve the others already paid for.
private struct MacForceNowStartupStage {
    let progress: Double
    let elapsed: TimeInterval
    let duration: TimeInterval
    let reduceMotion: Bool

    /// Grid, vignette and frame marks arrive first so the beam has a stage to fall through.
    var ignite: Double { startupSmoothStep(0.00, 0.18, progress) }
    /// Primary beam travel, top edge to rail.
    var sweep: Double { reduceMotion ? 1 : startupEaseInOut(startupSmoothStep(0.04, 0.60, progress)) }
    /// Fast priming pass that crosses the whole screen before the real sweep.
    var preSweep: Double { reduceMotion ? 1 : startupSmoothStep(0.00, 0.13, progress) }
    /// Chromatic split on the logo, collapsing to a clean register.
    var chroma: Double { reduceMotion ? 0 : 1 - startupSmoothStep(0.08, 0.54, progress) }
    var wordmark: Double { startupSmoothStep(0.30, 0.62, progress) }
    var telemetry: Double { startupSmoothStep(0.16, 0.34, progress) }
    var rail: Double { startupSmoothStep(0.46, 0.98, progress) }
    /// Single confirmation pulse once the client is up.
    var bloom: Double { startupSmoothStep(0.84, 1.00, progress) }
    var frameMarks: Double { startupSmoothStep(0.06, 0.26, progress) }
    /// Tracks the lockup reveal so the core bloom lights with the logo, not before it.
    var develop: Double { reduceMotion ? startupSmoothStep(0.05, 0.45, progress) : startupSmoothStep(0.18, 0.60, progress) }

    var frameIndex: Int { Int(elapsed * 60) }
    var drift: Double { reduceMotion ? 0 : elapsed.truncatingRemainder(dividingBy: 2.6) / 2.6 }

    var statusText: String {
        if progress < 0.20 { return "IGNITING CORE" }
        if progress < 0.44 { return "ATTACHING SERVICES" }
        if progress < 0.68 { return "INDEXING CATALOG" }
        if progress < 0.90 { return "ARMING STREAM SURFACE" }
        return "READY"
    }
}

private struct MacForceNowStartupMetrics {
    let size: CGSize
    let uiScale: CGFloat

    var compact: Bool { min(size.width, size.height) < 620 }

    var bandWidth: CGFloat { (compact ? 208 : 296) * uiScale }
    /// logo-isolated.svg ships at 680x410.
    var logoHeight: CGFloat { bandWidth * (410.0 / 680.0) }
    var bandHeight: CGFloat { logoHeight + (compact ? 74 : 96) * uiScale }
    /// The lockup is wider than the logo so the wordmark never clips its mask.
    var lockupWidth: CGFloat { bandWidth * 2.1 }
    var bandCenterY: CGFloat { size.height * 0.43 }
    var bandTop: CGFloat { bandCenterY - bandHeight / 2 }

    var inset: CGFloat { (compact ? 22 : 40) * uiScale }
    var railY: CGFloat { size.height - (compact ? 46 : 68) * uiScale }
    var railWidth: CGFloat { min(size.width - inset * 2, (compact ? 420 : 760) * uiScale) }
    var railCells: Int { compact ? 22 : 38 }

    /// Absolute y of the falling beam for a given sweep value.
    func beamY(_ sweep: Double) -> CGFloat {
        let start = -size.height * 0.06
        return start + (railY - start) * CGFloat(sweep)
    }

    /// How much of the logo band the beam has already developed, 0...1.
    func revealFraction(beamY: CGFloat) -> Double {
        guard bandHeight > 0 else { return 1 }
        return startupClamp(Double((beamY - bandTop) / bandHeight))
    }
}

// MARK: - Backdrop

/// Grid, bloom, scanlines and grain in one `Canvas` pass.
///
/// The previous build stacked five `rotation3DEffect` rectangles under nine
/// capsules, all with `.blendMode(.screen)`, which forces an offscreen pass per
/// layer on exactly the frames where app bootstrap is saturating the CPU. One
/// canvas draws the same depth for a single composite.
private struct MacForceNowStartupBackdrop: View {
    let stage: MacForceNowStartupStage
    let metrics: MacForceNowStartupMetrics

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
        let accent = MacForceNowDesign.accent
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
        let accent = MacForceNowDesign.accent
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

// MARK: - Frame marks

/// Corner brackets, product mark and build stamp. HUD chrome, drawn with the
/// app's square geometry rather than the rounded cards this screen used before.
private struct MacForceNowStartupFrameMarks: View {
    let stage: MacForceNowStartupStage
    let metrics: MacForceNowStartupMetrics

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
                MacForceNowStartupCornerBracket(arm: arm)
                    .stroke(MacForceNowDesign.accent.opacity(0.52 * reveal), lineWidth: 1)
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
                Text("MACFORCE NOW")
                    .font(MacForceNowDesign.Typography.label(size: 11, scale: scale, weight: .black))
                    .tracking(3.4 * scale)
                    .foregroundStyle(MacForceNowDesign.Text.secondary)
                Text("BOOT SEQUENCE")
                    .font(MacForceNowDesign.Typography.mono(size: 9, scale: scale))
                    .tracking(1.6 * scale)
                    .foregroundStyle(MacForceNowDesign.accent.opacity(0.72))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(metrics.inset + arm + 14 * scale)
            .opacity(reveal)

            Text(Self.version)
                .font(MacForceNowDesign.Typography.mono(size: 9, scale: scale))
                .tracking(1.4 * scale)
                .foregroundStyle(MacForceNowDesign.Text.muted)
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

private struct MacForceNowStartupCornerBracket: Shape {
    let arm: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        return path
    }
}

// MARK: - Scan beam

/// The falling beam. It is the only travelling element on screen, and it ends
/// its travel exactly on the rail so the progress bar reads as its residue.
private struct MacForceNowStartupScanBeam: View {
    let stage: MacForceNowStartupStage
    let metrics: MacForceNowStartupMetrics

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
        let accent = MacForceNowDesign.accent

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

// MARK: - Lockup

/// Logo, wordmark and tagline, masked so they only exist where the beam has
/// already passed.
private struct MacForceNowStartupLockup: View {
    let stage: MacForceNowStartupStage
    let metrics: MacForceNowStartupMetrics

    var body: some View {
        let scale = metrics.uiScale
        let reveal = stage.reduceMotion
            ? startupSmoothStep(0.05, 0.45, stage.progress)
            : metrics.revealFraction(beamY: metrics.beamY(stage.sweep))

        VStack(spacing: (metrics.compact ? 16 : 22) * scale) {
            MacForceNowStartupLogoCore(stage: stage, metrics: metrics)

            MacForceNowStartupWordmark(stage: stage, metrics: metrics)
        }
        .frame(width: metrics.lockupWidth, height: metrics.bandHeight)
        .mask(alignment: .top) {
            MacForceNowStartupDevelopMask(reveal: reveal)
        }
        .position(x: metrics.size.width / 2, y: metrics.bandCenterY)
        .allowsHitTesting(false)
    }
}

/// Wipe mask keyed to beam position: opaque behind the beam, a short soft edge
/// at it, empty ahead of it.
private struct MacForceNowStartupDevelopMask: View {
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

private struct MacForceNowStartupLogoCore: View {
    let stage: MacForceNowStartupStage
    let metrics: MacForceNowStartupMetrics

    var body: some View {
        let chroma = stage.chroma
        let bloom = stage.bloom
        let offset = CGFloat(chroma) * (metrics.compact ? 9 : 14) * metrics.uiScale
        let accent = MacForceNowDesign.accent

        ZStack {
            // RGB split ghosts collapse into register as the beam clears the logo.
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
private struct MacForceNowStartupWordmark: View {
    let stage: MacForceNowStartupStage
    let metrics: MacForceNowStartupMetrics

    private static let letters = Array("MACFORCE NOW")

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
                        Text(String(letter))
                            .font(MacForceNowDesign.Typography.display(size: size))
                            .foregroundStyle(MacForceNowDesign.Text.primary)
                            .offset(y: CGFloat(1 - reveal) * 10 * scale)
                            .opacity(reveal)
                            .blur(radius: CGFloat(1 - reveal) * 5)
                    }
                }
            }

            Text("CLOUD GAMING CLIENT")
                .font(MacForceNowDesign.Typography.mono(size: metrics.compact ? 9 : 11, scale: scale, weight: .bold))
                .tracking((3.4 + 3.4 * (1 - settle)) * scale)
                .foregroundStyle(MacForceNowDesign.accent.opacity(0.92 * settle))
                .opacity(settle)
        }
    }
}

// MARK: - Telemetry

/// Centered step bus. Reads as one horizontal run of equal-width stations
/// spanning exactly the rail width beneath it, so every station's marker, label
/// and stamp sit on a shared baseline instead of drifting per row the way the
/// left-anchored ledger did.
private struct MacForceNowStartupTelemetry: View {
    let stage: MacForceNowStartupStage
    let metrics: MacForceNowStartupMetrics

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
                .font(MacForceNowDesign.Typography.mono(size: 9, scale: scale))
                .tracking(2.4 * scale)
                .foregroundStyle(MacForceNowDesign.Text.muted)

            ZStack(alignment: .topLeading) {
                MacForceNowStartupBusTrack(
                    fill: busFill,
                    trackWidth: width,
                    scale: scale
                )
                .offset(y: (marker - 1) / 2)

                HStack(spacing: 0) {
                    ForEach(Array(Self.entries.enumerated()), id: \.offset) { _, entry in
                        MacForceNowStartupBusStation(
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

private struct MacForceNowStartupBusTrack: View {
    let fill: Double
    let trackWidth: CGFloat
    let scale: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(MacForceNowDesign.Stroke.subtle)
                .frame(width: trackWidth, height: 1)

            Rectangle()
                .fill(MacForceNowDesign.accent.opacity(0.60))
                .frame(width: trackWidth * CGFloat(fill), height: 1)
                .shadow(color: MacForceNowDesign.accent.opacity(0.55), radius: 4 * scale)
        }
        .frame(width: trackWidth, alignment: .leading)
    }
}

private struct MacForceNowStartupBusStation: View {
    let label: String
    let stamp: Double
    let settled: Bool
    let reveal: Double
    let marker: CGFloat
    let scale: CGFloat

    var body: some View {
        let accent = MacForceNowDesign.accent

        VStack(spacing: 8 * scale) {
            Rectangle()
                .fill(settled ? accent : MacForceNowDesign.Surface.deep)
                .frame(width: marker, height: marker)
                .overlay {
                    Rectangle()
                        .stroke(settled ? accent : MacForceNowDesign.Stroke.strong, lineWidth: 1)
                }
                .shadow(color: settled ? accent.opacity(0.85) : .clear, radius: 6 * scale)
                // Opaque pad so the bus line passes between stations, not through them.
                .padding(4 * scale)
                .background(Color.black)

            Text(label)
                .font(MacForceNowDesign.Typography.mono(size: 9, scale: scale))
                .foregroundStyle(settled ? MacForceNowDesign.Text.secondary : MacForceNowDesign.Text.muted)
                .lineLimit(1)
                .fixedSize()

            Text(String(format: "%.2fs", stamp))
                .font(MacForceNowDesign.Typography.mono(size: 8, scale: scale, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(settled ? accent.opacity(0.80) : MacForceNowDesign.Text.muted)
        }
        .opacity(0.38 + reveal * 0.62)
        .offset(y: CGFloat(1 - reveal) * 4 * scale)
    }
}

// MARK: - Rail

/// Segmented progress. Discrete cells snapping on read as machine state; the
/// smooth capsule this replaces read as a generic download bar.
private struct MacForceNowStartupRail: View {
    let stage: MacForceNowStartupStage
    let metrics: MacForceNowStartupMetrics

    var body: some View {
        let scale = metrics.uiScale
        let fill = stage.progress
        let percent = Int((stage.progress * 100).rounded())

        VStack(spacing: 10 * scale) {
            HStack(alignment: .firstTextBaseline) {
                Text(stage.statusText)
                    .font(MacForceNowDesign.Typography.label(size: metrics.compact ? 10 : 12, scale: scale, weight: .black))
                    .tracking((metrics.compact ? 2.0 : 3.0) * scale)
                    .foregroundStyle(MacForceNowDesign.Text.secondary)

                Spacer(minLength: 12 * scale)

                Text("\(percent)%")
                    .font(MacForceNowDesign.Typography.mono(size: metrics.compact ? 10 : 12, scale: scale, weight: .black))
                    .foregroundStyle(MacForceNowDesign.accent)
                    .contentTransition(.identity)
            }

            MacForceNowStartupSegmentBar(fill: fill, cells: metrics.railCells, scale: scale)
                .frame(height: (metrics.compact ? 8 : 11) * scale)
        }
        .frame(width: metrics.railWidth)
        .position(x: metrics.size.width / 2, y: metrics.railY - (metrics.compact ? 6 : 8) * scale)
        .opacity(stage.frameMarks * (1 - stage.bloom * 0.15))
        .allowsHitTesting(false)
    }
}

private struct MacForceNowStartupSegmentBar: View {
    let fill: Double
    let cells: Int
    let scale: CGFloat

    var body: some View {
        let accent = MacForceNowDesign.accent
        let filledCount = Int((Double(cells) * fill).rounded(.down))

        HStack(spacing: 3 * scale) {
            ForEach(0..<cells, id: \.self) { index in
                let isFilled = index < filledCount
                let isHead = index == filledCount - 1

                Rectangle()
                    .fill(isFilled ? accent.opacity(isHead ? 1.0 : 0.72) : MacForceNowDesign.Stroke.regular)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(y: isHead ? 1.0 : (isFilled ? 0.78 : 0.42), anchor: .bottom)
                    .shadow(color: isHead ? accent.opacity(0.95) : .clear, radius: 10 * scale)
            }
        }
    }
}

// MARK: - Math

private func startupClamp(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

private func startupSmoothStep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
    guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
    let clampedValue = startupClamp((value - edge0) / (edge1 - edge0))
    return clampedValue * clampedValue * (3 - 2 * clampedValue)
}

/// Slow out of the top edge, decelerate onto the rail.
private func startupEaseInOut(_ value: Double) -> Double {
    let clamped = startupClamp(value)
    return clamped < 0.5
        ? 2 * clamped * clamped
        : 1 - pow(-2 * clamped + 2, 2) / 2
}

/// Deterministic hash for grain placement; no `Math.random` state to carry
/// between frames, so the pattern is reproducible for a given frame index.
private func startupHash(_ seed: Int) -> Double {
    let value = sin(Double(seed) * 12.9898) * 43758.5453
    return value - floor(value)
}
