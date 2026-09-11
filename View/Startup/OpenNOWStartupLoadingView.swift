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
    @State private var clock = OpenNOWStartupClock()

    var body: some View {
        GeometryReader { proxy in
            let metrics = OpenNOWStartupMetrics(size: proxy.size, uiScale: uiScale)

            // `.animation` rather than `.periodic`: the periodic schedule fires off a timer that
            // drifts against the display refresh, so even an unloaded run beats against vsync.
            TimelineView(.animation(minimumInterval: OpenNOWDesign.Motion.heroFrameInterval, paused: false)) { timeline in
                let elapsed = clock.advance(to: timeline.date)
                let stage = OpenNOWStartupStage(
                    progress: startupClamp(elapsed / duration),
                    elapsed: elapsed,
                    duration: duration,
                    reduceMotion: reduceMotion
                )

                ZStack {
                    OpenNOWStartupBackdrop(stage: stage, metrics: metrics)

                    // `.equatable()` on the layers that go static: each compares only the values it
                    // actually draws, so a chrome layer whose reveal finished at 26% of the run
                    // stops rebuilding its shapes and text on every one of the remaining frames.
                    OpenNOWStartupFrameMarks(stage: stage, metrics: metrics)
                        .equatable()

                    OpenNOWStartupLockup(stage: stage, metrics: metrics)

                    if !metrics.compact {
                        OpenNOWStartupTelemetry(stage: stage, metrics: metrics)
                            .equatable()
                    }

                    OpenNOWStartupRail(stage: stage, metrics: metrics)
                        .equatable()

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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("OpenNOW is starting")
    }
}
