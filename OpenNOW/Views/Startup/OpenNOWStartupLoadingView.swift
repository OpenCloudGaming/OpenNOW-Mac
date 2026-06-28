import SwiftUI

enum OpenNOWStartupAnimation {
    static let duration: TimeInterval = 5.0
    static let dismissalDelayNanoseconds: UInt64 = 5_300_000_000
    static let fadeDuration: TimeInterval = 0.56
}

struct OpenNOWStartupLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate = Date()

    var body: some View {
        GeometryReader { proxy in
            let compact = min(proxy.size.width, proxy.size.height) < 620

            TimelineView(.animation) { timeline in
                let elapsed = max(timeline.date.timeIntervalSince(startDate), 0)
                let progress = startupClamp(elapsed / OpenNOWStartupAnimation.duration)
                let loop = reduceMotion ? 0 : elapsed.truncatingRemainder(dividingBy: 3.2) / 3.2

                ZStack {
                    OpenNOWStartupBackdrop(progress: progress, loop: loop)

                    OpenNOWStartupDepthGrid(progress: progress, loop: loop, compact: compact)

                    OpenNOWStartupOrbitalSystem(progress: progress, loop: loop, compact: compact, reduceMotion: reduceMotion)

                    OpenNOWStartupDiagnostics(progress: progress, compact: compact)

                    OpenNOWStartupCoreLogo(progress: progress, loop: loop, compact: compact, reduceMotion: reduceMotion)

                    OpenNOWStartupSequenceFooter(progress: progress, loop: loop, compact: compact)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .background(.black)
        .onAppear { startDate = Date() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("OpenNOW is starting")
    }
}

private struct OpenNOWStartupBackdrop: View {
    let progress: Double
    let loop: Double

    var body: some View {
        let environmentReveal = startupSmoothStep(0.12, 0.42, progress)

        ZStack {
            Color.black

            RadialGradient(
                stops: [
                    .init(color: Color.openNowGreen.opacity(0.28 * environmentReveal), location: 0.00),
                    .init(color: Color.openNowGreen.opacity(0.10 * environmentReveal), location: 0.34),
                    .init(color: .clear, location: 1.00)
                ],
                center: UnitPoint(x: 0.50 + sin(loop * .pi * 2) * 0.035, y: 0.46),
                startRadius: 18,
                endRadius: 720
            )
            .blendMode(.screen)

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.98), location: 0.00),
                    .init(color: .black.opacity(0.22), location: 0.34),
                    .init(color: .black.opacity(0.12), location: 0.58),
                    .init(color: .black.opacity(0.92), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, Color.openNowGreen.opacity(0.045 * environmentReveal), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .rotationEffect(.degrees(-18))
                .scaleEffect(x: 1.5, y: 0.58)
                .offset(y: -90 + CGFloat(loop) * 48)
                .blendMode(.screen)
        }
        .ignoresSafeArea()
    }
}

private struct OpenNOWStartupDepthGrid: View {
    let progress: Double
    let loop: Double
    let compact: Bool

    var body: some View {
        let reveal = startupSmoothStep(0.18, 0.48, progress)
        let size = CGFloat(compact ? 420 : 680)

        ZStack {
            ForEach(0..<5, id: \.self) { index in
                let scaleValue = 0.64 + Double(index) * 0.18 + loop * 0.16
                let opacity = reveal * (0.16 - Double(index) * 0.018)

                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .stroke(Color.openNowGreen.opacity(opacity), lineWidth: index == 0 ? 1.4 : 0.9)
                    .frame(width: size, height: size * 0.54)
                    .scaleEffect(CGFloat(scaleValue))
                    .rotation3DEffect(.degrees(64), axis: (x: 1, y: 0, z: 0), perspective: 0.65)
                    .rotation3DEffect(.degrees(loop * 22 + Double(index * 4)), axis: (x: 0, y: 1, z: 0), perspective: 0.65)
                    .offset(y: CGFloat(index * 14) + CGFloat(reveal) * 34)
                    .blendMode(.screen)
            }

            ForEach(0..<9, id: \.self) { index in
                Capsule()
                    .fill(Color.openNowGreen.opacity(reveal * 0.12))
                    .frame(width: size * 0.70, height: index.isMultiple(of: 3) ? 1.2 : 0.7)
                    .offset(y: CGFloat(index - 4) * (compact ? 20 : 28))
                    .rotation3DEffect(.degrees(64), axis: (x: 1, y: 0, z: 0), perspective: 0.65)
                    .rotationEffect(.degrees(loop * 7))
                    .blendMode(.screen)
            }
        }
        .opacity(reveal)
        .offset(y: compact ? 46 : 62)
        .allowsHitTesting(false)
    }
}

private struct OpenNOWStartupCoreLogo: View {
    let progress: Double
    let loop: Double
    let compact: Bool
    let reduceMotion: Bool

    var body: some View {
        let logoReveal = startupSmoothStep(0.00, 0.16, progress)
        let systemReveal = startupSmoothStep(0.20, 0.54, progress)
        let completion = startupSmoothStep(0.80, 1.00, progress)
        let size = CGFloat(compact ? 154 : 224)
        let rotation = reduceMotion ? 0 : loop * 360
        let tilt = reduceMotion ? 0 : sin(loop * .pi * 2) * 9

        ZStack {
            Circle()
                .fill(Color.openNowGreen.opacity(0.14 + systemReveal * 0.08))
                .frame(width: size * (1.10 + completion * 0.20), height: size * (1.10 + completion * 0.20))
                .blur(radius: compact ? 26 : 42)
                .opacity(logoReveal)

            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .trim(from: CGFloat(0.06 + Double(index) * 0.04), to: CGFloat(0.84 - Double(index) * 0.06))
                    .stroke(
                        Color.openNowGreen.opacity(0.20 + systemReveal * 0.20),
                        style: StrokeStyle(lineWidth: CGFloat(index == 0 ? 1.8 : 1.0), lineCap: .round, dash: index == 1 ? [10, 15] : [22, 18])
                    )
                    .frame(width: size * CGFloat(1.22 + Double(index) * 0.20), height: size * CGFloat(1.22 + Double(index) * 0.20))
                    .rotationEffect(.degrees((index.isMultiple(of: 2) ? 1 : -1) * (rotation + Double(index * 37))))
                    .rotation3DEffect(.degrees(tilt + Double(index * 5)), axis: (x: 1, y: 0.18, z: 0), perspective: 0.72)
                    .opacity(systemReveal)
            }

            VendorResourceImage(name: "logo-isolated", fileExtension: "svg")
                .scaledToFit()
                .frame(width: size, height: size * 0.62)
                .rotation3DEffect(.degrees(rotation), axis: (x: 0.10, y: 1, z: 0.02), perspective: 0.74)
                .rotation3DEffect(.degrees(tilt), axis: (x: 1, y: 0, z: 0), perspective: 0.74)
                .scaleEffect(CGFloat(0.86 + logoReveal * 0.14 + completion * 0.05))
                .shadow(color: Color.openNowGreen.opacity(0.74), radius: compact ? 24 : 38)
                .shadow(color: .white.opacity(0.16 + completion * 0.12), radius: compact ? 8 : 12)
                .opacity(logoReveal)
        }
        .frame(width: size * 2.0, height: size * 1.55)
        .offset(y: compact ? -38 : -58)
    }
}

private struct OpenNOWStartupOrbitalSystem: View {
    let progress: Double
    let loop: Double
    let compact: Bool
    let reduceMotion: Bool

    private static let modules: [OpenNOWStartupModule] = [
        .init(title: "AUTH", detail: "session vault", angle: -150, radius: 0.78, stageStart: 0.18),
        .init(title: "CATALOG", detail: "game index", angle: -92, radius: 0.90, stageStart: 0.28),
        .init(title: "NETWORK", detail: "edge route", angle: -34, radius: 0.82, stageStart: 0.38),
        .init(title: "STREAM", detail: "profile sync", angle: 26, radius: 0.94, stageStart: 0.48),
        .init(title: "MEDIA", detail: "decoder ready", angle: 92, radius: 0.80, stageStart: 0.58),
        .init(title: "SHORTCUTS", detail: "deep links", angle: 154, radius: 0.88, stageStart: 0.66)
    ]

    var body: some View {
        GeometryReader { proxy in
            let baseRadius = min(proxy.size.width, proxy.size.height) * (compact ? 0.28 : 0.30)

            ZStack {
                ForEach(Self.modules) { module in
                    let reveal = startupSmoothStep(module.stageStart, module.stageStart + 0.16, progress)
                    let load = startupSmoothStep(module.stageStart, module.stageStart + 0.24, progress)
                    let spin = reduceMotion ? 0 : loop * 54
                    let angle = (module.angle + spin) * .pi / 180
                    let radius = baseRadius * CGFloat(module.radius)
                    let x = cos(angle) * radius
                    let y = sin(angle) * radius * 0.58

                    OpenNOWStartupModuleCard(module: module, load: load, compact: compact)
                        .frame(width: compact ? 138 : 184, height: compact ? 54 : 66)
                        .scaleEffect(CGFloat(0.74 + reveal * 0.26))
                        .rotation3DEffect(.degrees(module.angle * 0.14 + spin * 0.16), axis: (x: 0.08, y: x > 0 ? -1 : 1, z: 0), perspective: 0.72)
                        .offset(x: x, y: y - (compact ? 30 : 52))
                        .opacity(reveal)
                        .blur(radius: CGFloat((1 - reveal) * 8))
                        .blendMode(.screen)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
    }
}

private struct OpenNOWStartupModule: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let angle: Double
    let radius: Double
    let stageStart: Double
}

private struct OpenNOWStartupModuleCard: View {
    let module: OpenNOWStartupModule
    let load: Double
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.openNowGreen.opacity(0.18 + load * 0.18))
                .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.openNowGreen.opacity(0.46), lineWidth: 1) }
                .frame(width: compact ? 22 : 28, height: compact ? 22 : 28)
                .overlay {
                    Circle()
                        .fill(load > 0.96 ? Color.openNowGreen : Color.white.opacity(0.32))
                        .frame(width: compact ? 7 : 9, height: compact ? 7 : 9)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(module.title)
                    .font(.system(size: compact ? 9 : 11, weight: .black, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.90))
                Text(module.detail)
                    .font(.system(size: compact ? 8 : 9, weight: .bold))
                    .foregroundStyle(Color.openNowGreen.opacity(0.72))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 9 : 12)
        .background(.black.opacity(0.40), in: RoundedRectangle(cornerRadius: compact ? 16 : 19, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            Capsule()
                .fill(Color.openNowGreen.opacity(0.82))
                .frame(width: CGFloat(load) * (compact ? 112 : 154), height: 2)
                .padding(.horizontal, compact ? 13 : 16)
                .padding(.bottom, 6)
        }
        .overlay { RoundedRectangle(cornerRadius: compact ? 16 : 19, style: .continuous).stroke(Color.openNowGreen.opacity(0.26), lineWidth: 1) }
        .shadow(color: Color.openNowGreen.opacity(0.20), radius: compact ? 10 : 16)
    }
}

private struct OpenNOWStartupDiagnostics: View {
    let progress: Double
    let compact: Bool

    private let diagnostics = [
        ("bootstrap", 0.10),
        ("secure session", 0.25),
        ("catalog cache", 0.42),
        ("stream profiles", 0.58),
        ("window state", 0.72)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            Text("LOAD SEQUENCE")
                .font(.system(size: compact ? 9 : 10, weight: .black))
                .tracking(2.2)
                .foregroundStyle(.white.opacity(0.46))

            ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, item in
                let itemProgress = startupSmoothStep(item.1, item.1 + 0.20, progress)

                HStack(spacing: 8) {
                    Circle()
                        .fill(itemProgress > 0.96 ? Color.openNowGreen : Color.white.opacity(0.18))
                        .frame(width: 7, height: 7)
                    Text(item.0.uppercased())
                        .font(.system(size: compact ? 9 : 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.44 + itemProgress * 0.38))
                    Spacer(minLength: 0)
                    Text(itemProgress > 0.96 ? "OK" : "SYNC")
                        .font(.system(size: compact ? 8 : 9, weight: .black, design: .monospaced))
                        .foregroundStyle(itemProgress > 0.96 ? Color.openNowGreen : .white.opacity(0.38))
                }
            }
        }
        .padding(compact ? 13 : 16)
        .frame(width: compact ? 190 : 232)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1) }
        .opacity(startupSmoothStep(0.22, 0.48, progress) * (1 - startupSmoothStep(0.90, 1.0, progress) * 0.35))
        .offset(x: compact ? -136 : -272, y: compact ? 132 : 158)
        .rotation3DEffect(.degrees(12), axis: (x: 0, y: 1, z: 0), perspective: 0.72)
        .allowsHitTesting(false)
    }
}

private struct OpenNOWStartupSequenceFooter: View {
    let progress: Double
    let loop: Double
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 10 : 13) {
            Text(statusText)
                .font(.system(size: compact ? 11 : 13, weight: .black, design: .rounded))
                .tracking(compact ? 1.8 : 2.8)
                .foregroundStyle(.white.opacity(0.76))

            OpenNOWStartupProgressRail(loop: loop, progress: progress)
                .frame(width: compact ? 230 : 360, height: 5)

            Text("Logo core initializes first. Services attach as the cloud client comes online.")
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))
                .multilineTextAlignment(.center)
                .frame(width: compact ? 280 : 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, compact ? 30 : 48)
        .opacity(1 - startupSmoothStep(0.94, 1.0, progress) * 0.55)
        .allowsHitTesting(false)
    }

    private var statusText: String {
        if progress < 0.22 { return "IGNITING LOGO CORE" }
        if progress < 0.46 { return "ATTACHING SECURE SERVICES" }
        if progress < 0.70 { return "INDEXING CLOUD CATALOG" }
        if progress < 0.90 { return "PREPARING STREAM SURFACE" }
        return "OPENNOW READY"
    }
}

private struct OpenNOWStartupProgressRail: View {
    let loop: Double
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fillWidth = max(width * CGFloat(progress), 12)
            let sweepWidth = max(width * 0.34, 72)
            let offset = -sweepWidth + (width + sweepWidth * 2) * CGFloat(loop)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.15))
                Capsule()
                    .fill(Color.openNowGreen.opacity(0.24))
                    .frame(width: fillWidth)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.openNowGreen.opacity(0.72), Color.openNowGreen, Color.openNowGreen.opacity(0.72), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: sweepWidth)
                    .offset(x: offset)
                    .shadow(color: Color.openNowGreen.opacity(0.70), radius: 8)
            }
            .clipShape(Capsule())
        }
    }
}

private func startupClamp(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

private func startupSmoothStep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
    let clampedValue = startupClamp((value - edge0) / (edge1 - edge0))
    return clampedValue * clampedValue * (3 - 2 * clampedValue)
}
