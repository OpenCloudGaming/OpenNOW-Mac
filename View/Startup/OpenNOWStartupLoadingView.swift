import SwiftUI

enum OpenNOWStartupAnimation {
    static let duration: TimeInterval = 1.8
    static let dismissalDelayNanoseconds: UInt64 = 2_000_000_000
    static let fadeDuration: TimeInterval = 0.35
}

struct OpenNOWStartupLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate = Date()

    var body: some View {
        GeometryReader { proxy in
            let compact = min(proxy.size.width, proxy.size.height) < 620

            TimelineView(.animation) { timeline in
                let elapsed = max(timeline.date.timeIntervalSince(startDate), 0)
                let progress = reduceMotion ? 1 : startupClamp(elapsed / OpenNOWStartupAnimation.duration)
                let pulse = reduceMotion ? 0.5 : elapsed.truncatingRemainder(dividingBy: 1.8) / 1.8

                ZStack {
                    OpenNOWStartupBackdrop(progress: progress, pulse: pulse)

                    VStack(spacing: 0) {
                        Spacer()

                        OpenNOWStartupMark(progress: progress, pulse: pulse, compact: compact, reduceMotion: reduceMotion)

                        VStack(spacing: compact ? 9 : 12) {
                            Text("OPENNOW")
                                .font(.nvidia(size: compact ? 20 : 25, weight: .bold))
                                .tracking(compact ? 6 : 9)
                                .foregroundStyle(.white)

                            Text(statusText(progress))
                                .font(.nvidia(size: compact ? 9 : 10, weight: .bold))
                                .tracking(2.4)
                                .foregroundStyle(Color.openNowGreen.opacity(0.86))
                        }
                        .opacity(startupSmoothStep(0.16, 0.38, progress))
                        .offset(y: compact ? 26 : 36)

                        Spacer()

                        OpenNOWStartupSignalRail(progress: progress, pulse: pulse)
                            .frame(width: compact ? 180 : 240, height: 18)
                            .padding(.bottom, compact ? 30 : 46)
                    }
                    .padding(.horizontal, 24)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("OpenNOW is starting")
                .accessibilityValue(statusText(progress))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .background(.black)
        .onAppear { startDate = Date() }
    }

    private func statusText(_ progress: Double) -> String {
        if progress < 0.28 { return "SYSTEM WAKE" }
        if progress < 0.76 { return "LINKING CLOUD" }
        return "READY"
    }
}

private struct OpenNOWStartupBackdrop: View {
    let progress: Double
    let pulse: Double

    var body: some View {
        let reveal = startupSmoothStep(0.08, 0.46, progress)

        ZStack {
            Color.black

            RadialGradient(
                stops: [
                    .init(color: Color.openNowGreen.opacity(0.22 * reveal), location: 0),
                    .init(color: Color.openNowGreen.opacity(0.07 * reveal), location: 0.34),
                    .init(color: .clear, location: 0.78)
                ],
                center: UnitPoint(x: 0.5, y: 0.46),
                startRadius: 8,
                endRadius: 640
            )
            .blendMode(.screen)

            Rectangle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: Color.openNowGreen.opacity(0.10 * reveal), location: 0.48),
                            .init(color: Color.openNowGreen.opacity(0.34 * reveal), location: 0.50),
                            .init(color: Color.openNowGreen.opacity(0.10 * reveal), location: 0.52),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .scaleEffect(x: 0.25 + reveal * 0.75)
                .offset(y: CGFloat(pulse - 0.5) * 24)
                .blur(radius: 0.5)

            LinearGradient(
                colors: [.black.opacity(0.78), .clear, .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

private struct OpenNOWStartupMark: View {
    let progress: Double
    let pulse: Double
    let compact: Bool
    let reduceMotion: Bool

    var body: some View {
        let reveal = startupSmoothStep(0.02, 0.30, progress)
        let settled = startupSmoothStep(0.46, 0.88, progress)
        let size = CGFloat(compact ? 148 : 214)

        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let phase = (pulse + Double(index) * 0.24).truncatingRemainder(dividingBy: 1)
                let animatedScale = reduceMotion ? 1.0 + Double(index) * 0.16 : 0.86 + phase * 0.72
                let animatedOpacity = reduceMotion ? 0.12 : (1 - phase) * 0.20

                RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                    .stroke(Color.openNowGreen.opacity(animatedOpacity * reveal), lineWidth: index == 0 ? 1.2 : 0.7)
                    .frame(width: size * 1.28, height: size * 0.72)
                    .scaleEffect(CGFloat(animatedScale))
            }

            RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
                .fill(Color.openNowGreen.opacity(0.10 * reveal))
                .frame(width: size * 1.18, height: size * 0.66)
                .blur(radius: compact ? 26 : 38)

            VendorResourceImage(name: "logo-isolated", fileExtension: "svg")
                .scaledToFit()
                .frame(width: size, height: size * 0.62)
                .scaleEffect(CGFloat(0.82 + reveal * 0.18 + settled * 0.025))
                .opacity(reveal)
                .blur(radius: CGFloat((1 - reveal) * 9))
                .shadow(color: Color.openNowGreen.opacity(0.68), radius: compact ? 22 : 34)
                .shadow(color: .white.opacity(0.12), radius: 8)
        }
        .frame(width: size * 1.8, height: size)
    }
}

private struct OpenNOWStartupSignalRail: View {
    let progress: Double
    let pulse: Double

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let completedWidth = max(width * CGFloat(progress), 3)
            let signalX = min(max(CGFloat(pulse) * width, 2), width - 2)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.10))
                    .frame(height: 1)

                Capsule()
                    .fill(Color.openNowGreen.opacity(0.62))
                    .frame(width: completedWidth, height: 1)

                Circle()
                    .fill(Color.openNowGreen)
                    .frame(width: 4, height: 4)
                    .offset(x: signalX - 2)
                    .shadow(color: Color.openNowGreen, radius: 7)
            }
            .frame(maxHeight: .infinity)
        }
        .opacity(startupSmoothStep(0.12, 0.34, progress))
        .accessibilityHidden(true)
    }
}

private func startupClamp(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

private func startupSmoothStep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
    let clampedValue = startupClamp((value - edge0) / (edge1 - edge0))
    return clampedValue * clampedValue * (3 - 2 * clampedValue)
}
