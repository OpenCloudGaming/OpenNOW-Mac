import SwiftUI

enum OpenNOWStartupAnimation {
    static let duration: TimeInterval = 3.4
    static let dismissalDelayNanoseconds: UInt64 = 3_700_000_000
    static let fadeDuration: TimeInterval = 0.52
}

struct OpenNOWStartupLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate = Date()

    var body: some View {
        GeometryReader { proxy in
            let compact = min(proxy.size.width, proxy.size.height) < 620

            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSince(startDate)
                let phase = reduceMotion ? 0 : elapsed.truncatingRemainder(dividingBy: OpenNOWStartupAnimation.duration) / OpenNOWStartupAnimation.duration
                let progress = min(max(elapsed / OpenNOWStartupAnimation.duration, 0), 1)

                ZStack {
                    OpenNOWStartupBackdrop(phase: phase, progress: progress)

                    VStack(spacing: compact ? 18 : 26) {
                        Spacer(minLength: compact ? 50 : 82)

                        OpenNOWStartupRotatingLogo(phase: phase, compact: compact, reduceMotion: reduceMotion)

                        VStack(spacing: compact ? 8 : 10) {
                            Text("OPENNOW")
                                .font(.system(size: compact ? 24 : 36, weight: .black, design: .rounded))
                                .tracking(compact ? 7 : 11)
                                .foregroundStyle(.white)
                                .shadow(color: Color.openNowGreen.opacity(0.55), radius: 18)

                            Text("STARTING CLOUD GAMING CLIENT")
                                .font(.system(size: compact ? 10 : 12, weight: .bold))
                                .tracking(compact ? 2.1 : 3.2)
                                .foregroundStyle(.white.opacity(0.64))
                        }

                        OpenNOWStartupProgressRail(phase: phase, progress: progress)
                            .frame(width: compact ? 218 : 330, height: 5)
                            .padding(.top, compact ? 3 : 8)

                        Spacer(minLength: compact ? 54 : 84)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
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
    let phase: Double
    let progress: Double

    var body: some View {
        ZStack {
            Color.black

            RadialGradient(
                stops: [
                    .init(color: Color.openNowGreen.opacity(0.24), location: 0.00),
                    .init(color: Color.openNowGreen.opacity(0.08), location: 0.36),
                    .init(color: .clear, location: 1.00)
                ],
                center: UnitPoint(x: 0.5 + sin(phase * .pi * 2) * 0.04, y: 0.44),
                startRadius: 20,
                endRadius: 620
            )
            .blendMode(.screen)

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.94), location: 0.00),
                    .init(color: .black.opacity(0.10), location: 0.34),
                    .init(color: .black.opacity(0.12), location: 0.62),
                    .init(color: .black.opacity(0.88), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(Color.openNowGreen.opacity(0.06), lineWidth: 1)
                    .frame(width: CGFloat(260 + index * 120), height: CGFloat(260 + index * 120))
                    .scaleEffect(1 + progress * 0.12)
                    .rotation3DEffect(.degrees(phase * 360 + Double(index * 18)), axis: (x: 0.2, y: 1, z: 0))
                    .blendMode(.screen)
            }
        }
        .ignoresSafeArea()
    }
}

private struct OpenNOWStartupRotatingLogo: View {
    let phase: Double
    let compact: Bool
    let reduceMotion: Bool

    var body: some View {
        let size = compact ? CGFloat(154) : CGFloat(220)
        let rotation = reduceMotion ? 0 : phase * 360
        let tilt = reduceMotion ? 0 : sin(phase * .pi * 2) * 10

        ZStack {
            Circle()
                .fill(Color.openNowGreen.opacity(0.12))
                .frame(width: size * 1.22, height: size * 1.22)
                .blur(radius: compact ? 26 : 38)

            Circle()
                .stroke(Color.openNowGreen.opacity(0.24), lineWidth: 1.2)
                .frame(width: size * 1.08, height: size * 1.08)
                .rotation3DEffect(.degrees(rotation), axis: (x: 0.18, y: 1, z: 0.05), perspective: 0.62)

            VendorResourceImage(name: "logo-isolated", fileExtension: "svg")
                .scaledToFit()
                .frame(width: size, height: size * 0.62)
                .rotation3DEffect(.degrees(rotation), axis: (x: 0.12, y: 1, z: 0), perspective: 0.72)
                .rotation3DEffect(.degrees(tilt), axis: (x: 1, y: 0, z: 0), perspective: 0.72)
                .shadow(color: Color.openNowGreen.opacity(0.75), radius: compact ? 24 : 36)
                .shadow(color: .white.opacity(0.16), radius: compact ? 8 : 12)
        }
        .frame(width: size * 1.5, height: size * 1.08)
    }
}

private struct OpenNOWStartupProgressRail: View {
    let phase: Double
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fillWidth = max(width * CGFloat(progress), 12)
            let sweepWidth = max(width * 0.34, 72)
            let offset = -sweepWidth + (width + sweepWidth * 2) * CGFloat(phase)

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
