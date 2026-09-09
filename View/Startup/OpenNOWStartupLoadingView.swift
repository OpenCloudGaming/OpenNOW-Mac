import SwiftUI

enum OpenNOWStartupAnimation {
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
struct OpenNOWStartupLoadingView: View {
    var duration: TimeInterval = OpenNOWStartupAnimation.duration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.opnUIScale) private var uiScale
    @State private var startDate = Date()

    var body: some View {
        GeometryReader { proxy in
            let metrics = OpenNOWStartupMetrics(size: proxy.size, uiScale: uiScale)

            TimelineView(.periodic(from: .now, by: OpenNOWDesign.Motion.heroFrameInterval)) { timeline in
                let elapsed = max(timeline.date.timeIntervalSince(startDate), 0)
                let stage = OpenNOWStartupStage(
                    progress: startupClamp(elapsed / duration),
                    elapsed: elapsed,
                    duration: duration,
                    reduceMotion: reduceMotion
                )

                ZStack {
                    OpenNOWStartupBackdrop(stage: stage, metrics: metrics)

                    OpenNOWStartupFrameMarks(stage: stage, metrics: metrics)

                    OpenNOWStartupLockup(stage: stage, metrics: metrics)

                    if !metrics.compact {
                        OpenNOWStartupTelemetry(stage: stage, metrics: metrics)
                    }

                    OpenNOWStartupRail(stage: stage, metrics: metrics)

                    if !stage.reduceMotion {
                        OpenNOWStartupScanBeam(stage: stage, metrics: metrics)
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
        .accessibilityLabel("OpenNOW is starting")
    }
}
