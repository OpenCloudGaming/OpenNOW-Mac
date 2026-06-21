import AppKit
import Metal
@preconcurrency import MetalKit
import QuartzCore
import SwiftUI
import simd

enum OpenNOWStartupAnimation {
    static let duration: TimeInterval = 5.2
    static let dismissalDelayNanoseconds: UInt64 = 5_650_000_000
    static let fadeDuration: TimeInterval = 0.58
}

struct OpenNOWStartupLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate = Date()

    var body: some View {
        GeometryReader { proxy in
            let compact = min(proxy.size.width, proxy.size.height) < 620

            TimelineView(.animation) { timeline in
                let elapsed = max(timeline.date.timeIntervalSince(startDate), 0)
                let rawProgress = min(elapsed / OpenNOWStartupAnimation.duration, 1)
                let progress = reduceMotion ? 1 : rawProgress

                ZStack {
                    OpenNOWStartupMetalSurface(reduceMotion: reduceMotion)
                        .ignoresSafeArea()

                    OpenNOWStartupAtmosphere(progress: progress)

                    OpenNOWStartupHologramFlight(progress: progress, size: proxy.size, compact: compact, reduceMotion: reduceMotion)

                    OpenNOWStartupDestinationTelevision(progress: progress, size: proxy.size, compact: compact, reduceMotion: reduceMotion)

                    OpenNOWStartupLogoHUD(progress: progress, compact: compact, reduceMotion: reduceMotion)

                    OpenNOWStartupStatusOverlay(progress: progress, compact: compact, reduceMotion: reduceMotion)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .background(.black)
        .onAppear { startDate = Date() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("OpenNOW is flying through digital game space into the catalog")
    }
}

private struct OpenNOWStartupAtmosphere: View {
    let progress: Double

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.96), location: 0.00),
                    .init(color: .black.opacity(0.30), location: 0.28),
                    .init(color: .black.opacity(0.08), location: 0.58),
                    .init(color: .black.opacity(0.88), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                stops: [
                    .init(color: Color.openNowGreen.opacity(0.34 + progress * 0.10), location: 0.00),
                    .init(color: Color.openNowGreen.opacity(0.12), location: 0.34),
                    .init(color: .clear, location: 1.00)
                ],
                center: .center,
                startRadius: 12,
                endRadius: 760
            )
            .blendMode(.screen)

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.82), location: 0.00),
                    .init(color: .clear, location: 0.22),
                    .init(color: .clear, location: 0.76),
                    .init(color: .black.opacity(0.86), location: 1.00)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .ignoresSafeArea()
    }
}

private struct OpenNOWStartupLogoHUD: View {
    let progress: Double
    let compact: Bool
    let reduceMotion: Bool

    var body: some View {
        let launch = reduceMotion ? 1 : startupSmoothStep(0.08, 0.44, progress)
        let arrival = reduceMotion ? 1 : startupSmoothStep(0.68, 0.96, progress)
        let width = CGFloat((compact ? 178.0 : 246.0) - launch * (compact ? 54.0 : 78.0) + arrival * (compact ? 16.0 : 22.0))
        let opacity = reduceMotion ? 0.58 : max(0.18, 1.0 - startupSmoothStep(0.72, 1.0, progress) * 0.68)

        ZStack {
            Circle()
                .stroke(Color.openNowGreen.opacity(0.18), lineWidth: 1)
                .frame(width: width * 1.22, height: width * 1.22)
                .scaleEffect(1.0 + launch * 0.18)

            Circle()
                .trim(from: 0.08, to: 0.88)
                .stroke(Color.openNowGreen.opacity(0.54), style: StrokeStyle(lineWidth: compact ? 1.4 : 1.8, lineCap: .round, dash: [12, 16]))
                .frame(width: width * 1.06, height: width * 1.06)
                .rotationEffect(.degrees((reduceMotion ? 0 : progress * 240) - 28))
                .shadow(color: Color.openNowGreen.opacity(0.48), radius: 16)

            VendorResourceImage(name: "logo-isolated", fileExtension: "svg")
                .scaledToFit()
                .frame(width: width, height: width * 0.62)
                .shadow(color: Color.openNowGreen.opacity(0.62), radius: compact ? 20 : 30)
        }
        .opacity(opacity)
        .scaleEffect(CGFloat(reduceMotion ? 0.82 : 1.0 - launch * 0.18 + arrival * 0.08))
        .offset(y: CGFloat(reduceMotion ? -34 : (-34 - launch * (compact ? 20 : 30) + arrival * (compact ? 38 : 52))))
        .blendMode(.screen)
        .allowsHitTesting(false)
    }
}

private struct OpenNOWStartupStatusOverlay: View {
    let progress: Double
    let compact: Bool
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: compact ? 10 : 14) {
                Text("OPENNOW")
                    .font(.system(size: compact ? 16 : 20, weight: .black, design: .rounded))
                    .tracking(compact ? 4.5 : 6.5)
                    .foregroundStyle(.white)

                Rectangle()
                    .fill(Color.openNowGreen.opacity(0.75))
                    .frame(width: compact ? 34 : 48, height: 1)

                Text("CATALOG APPROACH")
                    .font(.system(size: compact ? 9 : 11, weight: .bold))
                    .tracking(compact ? 1.8 : 2.8)
                    .foregroundStyle(Color.openNowGreen.opacity(0.92))
            }
            .padding(.top, compact ? 32 : 44)
            .opacity(reduceMotion ? 0.78 : 1.0 - startupSmoothStep(0.80, 1.0, progress) * 0.42)

            Spacer(minLength: 0)

            VStack(spacing: compact ? 10 : 14) {
                Text(statusText)
                    .font(.system(size: compact ? 12 : 14, weight: .bold))
                    .tracking(compact ? 1.4 : 2.0)
                    .foregroundStyle(.white.opacity(0.78))

                OpenNOWStartupProgressRail(reduceMotion: reduceMotion, progress: progress)
                    .frame(width: compact ? 226 : 356, height: 5)

                Text("Holographic game lanes resolving into your cloud catalog")
                    .font(.system(size: compact ? 10 : 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.48))
            }
            .padding(.bottom, compact ? 34 : 52)
            .opacity(reduceMotion ? 0.78 : 1.0 - startupSmoothStep(0.88, 1.0, progress) * 0.62)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var statusText: String {
        if progress < 0.30 { return "ENTERING DIGITAL SPACE" }
        if progress < 0.58 { return "GAME HOLOGRAMS PASSING" }
        if progress < 0.82 { return "CATALOG SCREEN ACQUIRED" }
        return "DIVING INTO CATALOG VIEW"
    }
}

private struct OpenNOWStartupProgressRail: View {
    let reduceMotion: Bool
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation) { timeline in
                let width = max(proxy.size.width, 1)
                let phase = reduceMotion ? min(progress, 1) : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.20) / 1.20
                let sweepWidth = max(width * 0.36, 88)
                let offset = (-sweepWidth) + ((width + sweepWidth * 2) * CGFloat(phase))
                let fillWidth = max(width * CGFloat(min(progress, 1)), 12)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.16))
                    Capsule()
                        .fill(Color.openNowGreen.opacity(0.26))
                        .frame(width: fillWidth)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.clear, Color.openNowGreen.opacity(0.62), Color.openNowGreen, Color.openNowGreen.opacity(0.62), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: sweepWidth)
                        .offset(x: offset)
                        .shadow(color: Color.openNowGreen.opacity(0.72), radius: 8)
                }
                .clipShape(Capsule())
            }
        }
    }
}

private struct OpenNOWStartupHologramFlight: View {
    let progress: Double
    let size: CGSize
    let compact: Bool
    let reduceMotion: Bool

    private static let cards: [OpenNOWStartupGameHologram] = [
        .init(title: "STAR RAID", subtitle: "SCI-FI ACTION", laneX: -0.72, laneY: -0.28, start: 0.03, duration: 0.40, tilt: -18, accent: Color(red: 0.47, green: 1.00, blue: 0.16)),
        .init(title: "NEON RALLY", subtitle: "ARCADE RACING", laneX: 0.70, laneY: -0.18, start: 0.12, duration: 0.42, tilt: 16, accent: Color(red: 0.80, green: 1.00, blue: 0.34)),
        .init(title: "FROST KEEP", subtitle: "FANTASY QUEST", laneX: -0.58, laneY: 0.24, start: 0.22, duration: 0.44, tilt: -12, accent: Color(red: 0.35, green: 0.92, blue: 1.00)),
        .init(title: "GRID OPS", subtitle: "TACTICAL CO-OP", laneX: 0.62, laneY: 0.20, start: 0.31, duration: 0.43, tilt: 20, accent: Color(red: 0.48, green: 1.00, blue: 0.10)),
        .init(title: "SKYFORGE", subtitle: "OPEN WORLD", laneX: -0.80, laneY: -0.04, start: 0.42, duration: 0.38, tilt: -22, accent: Color(red: 0.96, green: 1.00, blue: 0.42)),
        .init(title: "ZERO LATENCY", subtitle: "CLOUD READY", laneX: 0.78, laneY: -0.32, start: 0.51, duration: 0.35, tilt: 18, accent: Color(red: 0.43, green: 1.00, blue: 0.24))
    ]

    var body: some View {
        ZStack {
            ForEach(Self.cards) { card in
                OpenNOWStartupGameHologramCard(card: card, compact: compact)
                    .frame(width: compact ? 156 : 214, height: compact ? 104 : 142)
                    .modifier(OpenNOWStartupHologramFlightModifier(card: card, progress: progress, size: size, reduceMotion: reduceMotion))
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

private struct OpenNOWStartupHologramFlightModifier: ViewModifier {
    let card: OpenNOWStartupGameHologram
    let progress: Double
    let size: CGSize
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let local = reduceMotion ? 0.58 : startupClamped((progress - card.start) / card.duration)
        let eased = startupEaseOutCubic(local)
        let flyOpacity = sin(local * .pi)
        let tvFade = 1.0 - startupSmoothStep(0.72, 0.94, progress)
        let opacity = reduceMotion ? 0.22 : max(0, flyOpacity * tvFade * 0.86)
        let x = CGFloat(card.laneX * (0.10 + 0.66 * eased)) * size.width
        let y = CGFloat(card.laneY * (0.08 + 0.48 * eased)) * size.height
        let scale = CGFloat(reduceMotion ? 0.72 : 0.18 + eased * 1.72)
        let blur = CGFloat(reduceMotion ? 1.0 : (1.0 - local) * 1.2 + startupSmoothStep(0.72, 1.0, local) * 9.0)

        content
            .scaleEffect(scale)
            .rotation3DEffect(.degrees(card.tilt * (0.38 + eased * 0.88)), axis: (x: 0.14, y: card.laneX > 0 ? -1 : 1, z: 0.08), perspective: 0.58)
            .offset(x: x, y: y)
            .blur(radius: blur)
            .opacity(opacity)
            .blendMode(.screen)
    }
}

private struct OpenNOWStartupGameHologram: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let laneX: Double
    let laneY: Double
    let start: Double
    let duration: Double
    let tilt: Double
    let accent: Color
}

private struct OpenNOWStartupGameHologramCard: View {
    let card: OpenNOWStartupGameHologram
    let compact: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: compact ? 16 : 20, style: .continuous)
                .fill(.black.opacity(0.30))
                .overlay {
                    RoundedRectangle(cornerRadius: compact ? 16 : 20, style: .continuous)
                        .stroke(card.accent.opacity(0.72), lineWidth: 1.2)
                }
                .shadow(color: card.accent.opacity(0.32), radius: 18)

            OpenNOWStartupCoverPattern(accent: card.accent)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous))
                .padding(compact ? 8 : 10)

            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                Text(card.title)
                    .font(.system(size: compact ? 12 : 16, weight: .black, design: .rounded))
                    .tracking(compact ? 1.1 : 1.7)
                    .foregroundStyle(.white)
                Text(card.subtitle)
                    .font(.system(size: compact ? 7 : 9, weight: .bold))
                    .tracking(compact ? 0.8 : 1.2)
                    .foregroundStyle(card.accent.opacity(0.92))
            }
            .padding(compact ? 14 : 18)
        }
    }
}

private struct OpenNOWStartupCoverPattern: View {
    let accent: Color

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [accent.opacity(0.74), Color.black.opacity(0.22), accent.opacity(0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            GeometryReader { proxy in
                let stripeCount = 7
                ForEach(0..<stripeCount, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(index.isMultiple(of: 2) ? 0.20 : 0.10))
                        .frame(width: proxy.size.width * 0.72, height: 2)
                        .rotationEffect(.degrees(-31))
                        .offset(x: -proxy.size.width * 0.16, y: CGFloat(index) * proxy.size.height / CGFloat(stripeCount - 1))
                }

                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 1)
                    .frame(width: proxy.size.height * 0.78, height: proxy.size.height * 0.78)
                    .offset(x: proxy.size.width * 0.50, y: -proxy.size.height * 0.10)
            }
        }
    }
}

private struct OpenNOWStartupDestinationTelevision: View {
    let progress: Double
    let size: CGSize
    let compact: Bool
    let reduceMotion: Bool

    var body: some View {
        let approach = reduceMotion ? 1 : startupSmoothStep(0.40, 0.94, progress)
        let opacity = reduceMotion ? 1 : startupSmoothStep(0.32, 0.50, progress)
        let impact = reduceMotion ? 0 : startupSmoothStep(0.84, 1.0, progress)
        let baseWidth: CGFloat = min(size.width * (compact ? 0.82 : 0.70), compact ? 560 : 900)
        let scale = CGFloat(reduceMotion ? 0.94 : 0.12 + approach * 1.26 + impact * 0.20)
        let offsetY: CGFloat = reduceMotion ? 0 : CGFloat((1.0 - approach) * 0.18 - impact * 0.035) * size.height

        OpenNOWStartupTelevisionFrame(compact: compact, glow: impact)
            .frame(width: baseWidth, height: baseWidth * 0.58)
            .scaleEffect(scale)
            .offset(y: offsetY)
            .opacity(opacity)
            .shadow(color: Color.openNowGreen.opacity(0.36 + impact * 0.30), radius: compact ? 34 : 58)
            .rotation3DEffect(.degrees(reduceMotion ? 0 : (1.0 - approach) * 12), axis: (x: 1, y: 0, z: 0), perspective: 0.68)
            .allowsHitTesting(false)
    }
}

private struct OpenNOWStartupTelevisionFrame: View {
    let compact: Bool
    let glow: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 30 : 42, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), Color.black.opacity(0.94), Color.white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: compact ? 30 : 42, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                }

            RoundedRectangle(cornerRadius: compact ? 22 : 30, style: .continuous)
                .fill(Color.black)
                .padding(compact ? 13 : 18)
                .overlay {
                    RoundedRectangle(cornerRadius: compact ? 22 : 30, style: .continuous)
                        .stroke(Color.openNowGreen.opacity(0.54 + glow * 0.36), lineWidth: 1.4)
                        .padding(compact ? 13 : 18)
                }

            OpenNOWStartupCatalogPreview(compact: compact)
                .padding(compact ? 18 : 25)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 18 : 25, style: .continuous))

            RoundedRectangle(cornerRadius: compact ? 22 : 30, style: .continuous)
                .stroke(Color.openNowGreen.opacity(0.22 + glow * 0.24), lineWidth: compact ? 7 : 10)
                .blur(radius: compact ? 12 : 18)
                .padding(compact ? 13 : 18)
                .blendMode(.screen)
        }
    }
}

private struct OpenNOWStartupCatalogPreview: View {
    let compact: Bool

    var body: some View {
        GeometryReader { proxy in
            let inset = proxy.size.width * 0.026
            ZStack {
                Color.gfnBackgroundGreen

                LinearGradient(
                    colors: [Color.openNowGreen.opacity(0.18), .clear, .black.opacity(0.34)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: inset) {
                    HStack(spacing: inset * 0.74) {
                        VendorResourceImage(name: "logo-isolated", fileExtension: "svg")
                            .scaledToFit()
                            .frame(width: proxy.size.width * 0.10, height: proxy.size.height * 0.06)

                        OpenNOWStartupPreviewSearchBar()

                        ForEach(0..<3, id: \.self) { _ in
                            Circle()
                                .fill(.white.opacity(0.16))
                                .frame(width: max(proxy.size.width * 0.022, 8), height: max(proxy.size.width * 0.022, 8))
                        }
                    }
                    .frame(height: proxy.size.height * 0.13)

                    HStack(alignment: .top, spacing: inset) {
                        OpenNOWStartupPreviewSidebar()
                            .frame(width: proxy.size.width * 0.16)

                        VStack(spacing: inset) {
                            OpenNOWStartupPreviewHero(compact: compact)
                                .frame(height: proxy.size.height * 0.35)

                            OpenNOWStartupPreviewRails()
                        }
                    }
                }
                .padding(inset)
            }
        }
    }
}

private struct OpenNOWStartupPreviewSearchBar: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 999, style: .continuous)
            .fill(.white.opacity(0.08))
            .overlay(alignment: .leading) {
                HStack(spacing: 7) {
                    Circle()
                        .stroke(Color.openNowGreen.opacity(0.72), lineWidth: 1.2)
                        .frame(width: 10, height: 10)
                    Capsule()
                        .fill(.white.opacity(0.20))
                        .frame(width: 86, height: 5)
                }
                .padding(.leading, 13)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
    }
}

private struct OpenNOWStartupPreviewSidebar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(0..<5, id: \.self) { index in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(index == 0 ? Color.openNowGreen : .white.opacity(0.16))
                        .frame(width: 9, height: 9)
                    Capsule()
                        .fill(index == 0 ? Color.openNowGreen.opacity(0.85) : .white.opacity(0.16))
                        .frame(width: index == 2 ? 42 : 58, height: 5)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(index == 0 ? Color.openNowGreen.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }
}

private struct OpenNOWStartupPreviewHero: View {
    let compact: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.openNowGreen.opacity(0.66), Color(red: 0.03, green: 0.16, blue: 0.10), Color.black.opacity(0.48)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(alignment: .trailing) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.17), lineWidth: 2)
                        Circle().stroke(Color.openNowGreen.opacity(0.34), lineWidth: 10).blur(radius: 8)
                    }
                    .frame(width: compact ? 96 : 142, height: compact ? 96 : 142)
                    .offset(x: compact ? 26 : 38)
                }

            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                Capsule()
                    .fill(Color.openNowGreen)
                    .frame(width: compact ? 48 : 68, height: 7)
                Capsule()
                    .fill(.white.opacity(0.76))
                    .frame(width: compact ? 130 : 190, height: compact ? 9 : 12)
                Capsule()
                    .fill(.white.opacity(0.28))
                    .frame(width: compact ? 94 : 132, height: 5)
            }
            .padding(compact ? 15 : 21)
        }
    }
}

private struct OpenNOWStartupPreviewRails: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<2, id: \.self) { row in
                VStack(alignment: .leading, spacing: 7) {
                    Capsule()
                        .fill(.white.opacity(row == 0 ? 0.34 : 0.24))
                        .frame(width: row == 0 ? 112 : 88, height: 6)

                    HStack(spacing: 9) {
                        ForEach(0..<5, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.17), Color.openNowGreen.opacity((index + row).isMultiple(of: 2) ? 0.36 : 0.18), Color.black.opacity(0.22)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .overlay(alignment: .bottomLeading) {
                                    Capsule()
                                        .fill(.white.opacity(0.28))
                                        .frame(width: 38, height: 4)
                                        .padding(8)
                                }
                                .frame(height: row == 0 ? 46 : 40)
                        }
                    }
                }
            }
        }
    }
}

private func startupClamped(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

private func startupSmoothStep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
    let x = startupClamped((value - edge0) / (edge1 - edge0))
    return x * x * (3 - 2 * x)
}

private func startupEaseOutCubic(_ value: Double) -> Double {
    1 - pow(1 - startupClamped(value), 3)
}

private struct OpenNOWStartupMetalSurface: NSViewRepresentable {
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = reduceMotion ? 24 : 60
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        guard let device = MTLCreateSystemDefaultDevice(), let renderer = OpenNOWStartupMetalRenderer(device: device, pixelFormat: view.colorPixelFormat, reduceMotion: reduceMotion) else {
            return view
        }

        view.device = device
        context.coordinator.renderer = renderer
        view.delegate = renderer
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.setReduceMotion(reduceMotion)
        view.preferredFramesPerSecond = reduceMotion ? 24 : 60
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.renderer = nil
    }

    final class Coordinator {
        var renderer: OpenNOWStartupMetalRenderer?
    }
}

@MainActor
private final class OpenNOWStartupMetalRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: any MTLCommandQueue
    private let backgroundPipeline: any MTLRenderPipelineState
    private let scenePipeline: any MTLRenderPipelineState
    private let vertexBuffer: any MTLBuffer
    private let vertexCount: Int
    private let startTime = CACurrentMediaTime()
    private var reduceMotion: Bool
    private var viewportSize = SIMD2<Float>(1, 1)

    init?(device: any MTLDevice, pixelFormat: MTLPixelFormat, reduceMotion: Bool) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let backgroundPipeline = Self.makePipeline(device: device, library: library, pixelFormat: pixelFormat, vertexName: "opn_startup_background_vertex", fragmentName: "opn_startup_background_fragment", blended: false),
              let scenePipeline = Self.makePipeline(device: device, library: library, pixelFormat: pixelFormat, vertexName: "opn_startup_scene_vertex", fragmentName: "opn_startup_scene_fragment", blended: true) else {
            return nil
        }

        let vertices = Self.makeSceneVertices()
        guard let vertexBuffer = Self.makeVertexBuffer(device: device, vertices: vertices) else { return nil }

        self.commandQueue = commandQueue
        self.backgroundPipeline = backgroundPipeline
        self.scenePipeline = scenePipeline
        self.vertexBuffer = vertexBuffer
        self.vertexCount = vertices.count
        self.reduceMotion = reduceMotion
        super.init()
    }

    func setReduceMotion(_ reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = SIMD2<Float>(Float(max(size.width, 1)), Float(max(size.height, 1)))
    }

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        let drawableSize = view.drawableSize
        viewportSize = SIMD2<Float>(Float(max(drawableSize.width, 1)), Float(max(drawableSize.height, 1)))

        var uniforms = OpenNOWStartupMetalUniforms(
            viewportSize: viewportSize,
            time: Float(CACurrentMediaTime() - startTime),
            reduceMotion: reduceMotion ? 1 : 0,
            opacity: 1
        )

        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OpenNOWStartupMetalUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.setRenderPipelineState(scenePipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<OpenNOWStartupMetalUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OpenNOWStartupMetalUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func makePipeline(device: any MTLDevice, library: any MTLLibrary, pixelFormat: MTLPixelFormat, vertexName: String, fragmentName: String, blended: Bool) -> (any MTLRenderPipelineState)? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertexName)
        descriptor.fragmentFunction = library.makeFunction(name: fragmentName)
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = blended
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = blended ? .one : .zero
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = blended ? .oneMinusSourceAlpha : .zero
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeVertexBuffer(device: any MTLDevice, vertices: [OpenNOWStartupMetalVertex]) -> (any MTLBuffer)? {
        vertices.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: baseAddress, length: bytes.count, options: .storageModeShared)
        }
    }

    private static func makeSceneVertices() -> [OpenNOWStartupMetalVertex] {
        var vertices: [OpenNOWStartupMetalVertex] = []
        vertices.reserveCapacity(1800)

        appendRing(to: &vertices, radius: 0.58, thickness: 0.018, z: 0.00, segments: 56, phase: 0.0, color: SIMD4<Float>(0.84, 1.00, 0.36, 0.26), intensity: 0.84)
        appendRing(to: &vertices, radius: 0.86, thickness: 0.026, z: 0.02, segments: 64, phase: 1.7, color: SIMD4<Float>(0.46, 0.90, 0.10, 0.34), intensity: 1.00)
        appendRing(to: &vertices, radius: 1.18, thickness: 0.032, z: -0.02, segments: 72, phase: 3.4, color: SIMD4<Float>(0.38, 0.82, 0.14, 0.28), intensity: 0.88)
        appendRing(to: &vertices, radius: 1.52, thickness: 0.022, z: -0.06, segments: 80, phase: 5.1, color: SIMD4<Float>(0.72, 1.00, 0.28, 0.20), intensity: 0.70)

        for index in 0..<12 {
            let progress = Float(index) / 12
            let angle = progress * .pi * 2
            let radius: Float = index.isMultiple(of: 2) ? 1.18 : 1.42
            let center = SIMD3<Float>(cos(angle) * radius, sin(angle) * radius * 0.62, sin(angle * 1.8) * 0.08)
            appendPanel(to: &vertices, center: center, width: 0.060, height: 0.72, yaw: angle * 0.20, roll: angle + .pi / 2, color: SIMD4<Float>(0.42, 0.92, 0.16, 0.22), intensity: 0.72, phase: angle * 1.8)
        }

        for index in 0..<24 {
            let progress = Float(index) / 24
            let angle = progress * .pi * 2.0 + (index.isMultiple(of: 2) ? 0.18 : -0.24)
            let radius: Float = 0.82 + Float(index % 5) * 0.16
            let center = SIMD3<Float>(cos(angle) * radius, sin(angle) * radius * 0.56, sin(angle * 2.1) * 0.10)
            let width: Float = index.isMultiple(of: 3) ? 0.34 : 0.25
            let height: Float = index.isMultiple(of: 4) ? 0.20 : 0.14
            let color = index.isMultiple(of: 4) ? SIMD4<Float>(0.84, 1.00, 0.38, 0.30) : SIMD4<Float>(0.46, 0.92, 0.16, 0.24)
            appendPanel(to: &vertices, center: center, width: width, height: height, yaw: angle * 0.22, roll: -angle * 0.36, color: color, intensity: index.isMultiple(of: 3) ? 1.08 : 0.82, phase: Float(index) * 0.61 + 0.4)
        }

        return vertices
    }

    private static func appendRing(to vertices: inout [OpenNOWStartupMetalVertex], radius: Float, thickness: Float, z: Float, segments: Int, phase: Float, color: SIMD4<Float>, intensity: Float) {
        for segment in 0..<segments where segment % 11 != 8 && segment % 13 != 6 {
            let start = (Float(segment) / Float(segments)) * .pi * 2
            let end = (Float(segment + 1) / Float(segments)) * .pi * 2
            let inner = radius - thickness
            let outer = radius + thickness
            let localPhase = phase + Float(segment) * 0.17

            let a = ringPoint(angle: start, radius: inner, z: z, phase: phase)
            let b = ringPoint(angle: end, radius: inner, z: z, phase: phase)
            let c = ringPoint(angle: end, radius: outer, z: z, phase: phase)
            let d = ringPoint(angle: start, radius: outer, z: z, phase: phase)
            appendQuad(to: &vertices, a: a, b: b, c: c, d: d, color: color, intensity: intensity, phase: localPhase)
        }
    }

    private static func ringPoint(angle: Float, radius: Float, z: Float, phase: Float) -> SIMD3<Float> {
        SIMD3<Float>(cos(angle) * radius, sin(angle) * radius, z + sin(angle * 3.0 + phase) * 0.045)
    }

    private static func appendPanel(to vertices: inout [OpenNOWStartupMetalVertex], center: SIMD3<Float>, width: Float, height: Float, yaw: Float, roll: Float, color: SIMD4<Float>, intensity: Float, phase: Float) {
        let rollCos = cos(roll)
        let rollSin = sin(roll)
        let yawCos = cos(yaw)
        let yawSin = sin(yaw)

        func yawed(_ vector: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(vector.x * yawCos + vector.z * yawSin, vector.y, -vector.x * yawSin + vector.z * yawCos)
        }

        let right = yawed(SIMD3<Float>(rollCos, rollSin, 0)) * (width * 0.5)
        let up = yawed(SIMD3<Float>(-rollSin, rollCos, 0)) * (height * 0.5)
        appendQuad(to: &vertices, a: center - right - up, b: center + right - up, c: center + right + up, d: center - right + up, color: color, intensity: intensity, phase: phase)
    }

    private static func appendQuad(to vertices: inout [OpenNOWStartupMetalVertex], a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>, d: SIMD3<Float>, color: SIMD4<Float>, intensity: Float, phase: Float) {
        let material = SIMD2<Float>(intensity, phase)
        vertices.append(OpenNOWStartupMetalVertex(position: SIMD4<Float>(a.x, a.y, a.z, phase), color: color, uv: SIMD2<Float>(0, 0), material: material))
        vertices.append(OpenNOWStartupMetalVertex(position: SIMD4<Float>(b.x, b.y, b.z, phase), color: color, uv: SIMD2<Float>(1, 0), material: material))
        vertices.append(OpenNOWStartupMetalVertex(position: SIMD4<Float>(c.x, c.y, c.z, phase), color: color, uv: SIMD2<Float>(1, 1), material: material))
        vertices.append(OpenNOWStartupMetalVertex(position: SIMD4<Float>(a.x, a.y, a.z, phase), color: color, uv: SIMD2<Float>(0, 0), material: material))
        vertices.append(OpenNOWStartupMetalVertex(position: SIMD4<Float>(c.x, c.y, c.z, phase), color: color, uv: SIMD2<Float>(1, 1), material: material))
        vertices.append(OpenNOWStartupMetalVertex(position: SIMD4<Float>(d.x, d.y, d.z, phase), color: color, uv: SIMD2<Float>(0, 1), material: material))
    }

    private static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct StartupUniforms {
    float2 viewportSize;
    float time;
    float reduceMotion;
    float opacity;
};

struct StartupVertex {
    float4 position;
    float4 color;
    float2 uv;
    float2 material;
};

struct SceneOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
    float2 material;
    float3 world;
};

struct BackgroundOut {
    float4 position [[position]];
    float2 uv;
};

static float opn_line(float value, float thickness) {
    float cell = abs(fract(value - 0.5) - 0.5);
    return 1.0 - smoothstep(thickness, thickness + fwidth(value) * 1.65, cell);
}

static float opn_hash21(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

vertex BackgroundOut opn_startup_background_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    const float2 uvs[3] = { float2(0.0, 1.0), float2(2.0, 1.0), float2(0.0, -1.0) };
    BackgroundOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

fragment float4 opn_startup_background_fragment(BackgroundOut in [[stage_in]], constant StartupUniforms &uniforms [[buffer(0)]]) {
    float2 uv = in.uv;
    float aspect = uniforms.viewportSize.x / max(uniforms.viewportSize.y, 1.0);
    float motion = 1.0 - uniforms.reduceMotion * 0.86;
    float t = uniforms.time * motion;
    float2 p = uv * 2.0 - 1.0;
    p.x *= aspect;

    float radius = max(length(p), 0.002);
    float angle = atan2(p.y, p.x);
    float tunnelMask = 1.0 - smoothstep(0.38, 1.48, radius);
    float radialGrid = opn_line(angle * 4.42 + t * 0.38, 0.026) * (1.0 - smoothstep(0.98, 1.50, radius));
    float depthGrid = opn_line((1.0 / radius) + t * 2.15, 0.020) * tunnelMask;
    float coreGlow = exp(-radius * 2.4);

    float2 starCell = floor((uv + float2(t * 0.030, -t * 0.018)) * float2(72.0, 42.0));
    float starSeed = opn_hash21(starCell);
    float star = step(0.965, starSeed) * (0.42 + 0.58 * sin(t * 8.0 + starSeed * 6.28));
    float streakDistance = abs(fract(uv.y * 42.0 - t * (1.5 + starSeed)) - 0.5);
    float streak = star * (1.0 - smoothstep(0.18, 0.90, streakDistance));

    float horizon = 0.26 + sin(t * 0.18) * 0.018;
    float floorDepth = 1.0 / max(0.06, horizon - p.y);
    float floorMask = (1.0 - smoothstep(horizon - 0.02, horizon + 0.17, p.y)) * smoothstep(-1.06, -0.12, p.y);
    float2 gridCoordinate = float2(p.x * floorDepth * 1.35, floorDepth * 0.78 + t * 0.50);
    float floorGrid = max(opn_line(gridCoordinate.x, 0.016), opn_line(gridCoordinate.y, 0.012)) * floorMask;
    float portalGlow = exp(-abs(radius - (0.30 + sin(t * 0.30) * 0.018)) * 10.0);
    float scan = 0.5 + 0.5 * sin((uv.y * 82.0) - t * 10.5);

    float3 base = float3(0.002, 0.004, 0.003);
    float3 green = float3(0.46, 0.90, 0.10);
    float3 acid = float3(0.78, 1.00, 0.28);
    float3 color = base;
    color += green * coreGlow * 0.20;
    color += acid * radialGrid * 0.10;
    color += acid * depthGrid * (0.22 + scan * 0.18);
    color += acid * floorGrid * (0.38 + scan * 0.22);
    color += green * portalGlow * 0.10;
    color += acid * streak * 0.18;
    color *= 1.0 - smoothstep(0.76, 1.55, radius) * 0.74;
    return float4(color, 1.0);
}

vertex SceneOut opn_startup_scene_vertex(const device StartupVertex *vertices [[buffer(0)]], constant StartupUniforms &uniforms [[buffer(1)]], uint vertexID [[vertex_id]]) {
    StartupVertex startupVertex = vertices[vertexID];
    float motion = 1.0 - uniforms.reduceMotion;
    float aspect = uniforms.viewportSize.x / max(uniforms.viewportSize.y, 1.0);
    float3 position = startupVertex.position.xyz;
    float phase = startupVertex.position.w;
    float flightProgress = clamp(uniforms.time / 5.2, 0.0, 1.0);
    float arrival = smoothstep(0.74, 1.0, flightProgress);
    float lane = fract(phase * 0.137 + uniforms.time * (0.20 + startupVertex.material.x * 0.035) * motion);
    float radialScale = mix(0.28, 1.98, lane);
    float cameraDepth = mix(5.6, 0.72, lane) + position.z * 0.18;

    position.xy *= radialScale;
    position.x += sin(uniforms.time * 0.46 + phase * 1.8) * 0.10 * motion * (1.0 - arrival);
    position.y += cos(uniforms.time * 0.52 + phase * 1.4) * 0.07 * motion * (1.0 - arrival);

    float roll = sin(uniforms.time * 0.24) * 0.08 * motion * (1.0 - arrival);
    float cr = cos(roll);
    float sr = sin(roll);
    float2 rolled = float2(position.x * cr - position.y * sr, position.x * sr + position.y * cr);

    float perspective = 1.78 / max(cameraDepth, 0.68);
    float2 clip = rolled * perspective;
    clip.x /= aspect;
    clip *= 1.0 + arrival * 0.22;

    SceneOut out;
    out.position = float4(clip, 0.12 + lane * 0.72, 1.0);
    out.color = startupVertex.color;
    out.uv = startupVertex.uv;
    out.material = startupVertex.material;
    out.world = float3(rolled, cameraDepth);
    return out;
}

fragment float4 opn_startup_scene_fragment(SceneOut in [[stage_in]], constant StartupUniforms &uniforms [[buffer(1)]]) {
    float2 centered = abs(in.uv - 0.5) * 2.0;
    float edge = max(centered.x, centered.y);
    float rim = smoothstep(0.62, 1.0, edge);
    float core = 1.0 - smoothstep(0.10, 0.92, edge);
    float diagonal = 1.0 - smoothstep(0.012, 0.09, abs((in.uv.x - in.uv.y) + sin(in.material.y) * 0.16));
    float shimmer = 0.70 + 0.30 * sin(uniforms.time * 3.2 + in.material.y * 2.7 + in.world.z * 1.6);
    float3 green = float3(0.46, 0.90, 0.10);
    float3 acid = float3(0.82, 1.00, 0.36);
    float3 color = in.color.rgb * (0.56 + in.material.x * 0.34);
    color += acid * rim * 0.58;
    color += green * diagonal * 0.22;
    color += green * core * 0.12;
    float nearBoost = 1.0 - smoothstep(0.78, 4.8, in.world.z);
    float alpha = in.color.a * (0.30 + rim * 0.82 + core * 0.24 + diagonal * 0.22 + nearBoost * 0.30) * shimmer * uniforms.opacity;
    return float4(color, alpha);
}
"""
}

private struct OpenNOWStartupMetalUniforms {
    var viewportSize: SIMD2<Float>
    var time: Float
    var reduceMotion: Float
    var opacity: Float
}

private struct OpenNOWStartupMetalVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
    var uv: SIMD2<Float>
    var material: SIMD2<Float>
}
