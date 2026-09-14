import SwiftUI

enum StartupAnimation {
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
struct StartupLoadingView: View {
    var duration: TimeInterval = StartupAnimation.duration

    @Environment(\.accessibilityReduceMotion) private var isSystemReduceMotionEnabled
    @AppStorage(OPNThemePreferences.isMotionReducedKey) private var isReduceMotionPreferenceEnabled = false
    @Environment(\.opnUIScale) private var uiScale
    @State private var clock = StartupClock()

    private var isMotionReduced: Bool {
        OPNDesign.Motion.isMotionReduced(system: isSystemReduceMotionEnabled, preference: isReduceMotionPreferenceEnabled)
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = StartupMetrics(size: proxy.size, uiScale: uiScale)

            // `.animation` rather than `.periodic`: the periodic schedule fires off a timer that
            // drifts against the display refresh, so even an unloaded run beats against vsync.
            TimelineView(.animation(minimumInterval: OPNDesign.Motion.heroFrameInterval, paused: false)) { timeline in
                let elapsed = clock.advance(to: timeline.date)
                let stage = StartupStage(
                    progress: startupClamp(elapsed / duration),
                    elapsed: elapsed,
                    duration: duration,
                    reduceMotion: isMotionReduced
                )

                ZStack {
                    StartupBackdrop(stage: stage, metrics: metrics)

                    // `.equatable()` on the layers that go static: each compares only the values it
                    // actually draws, so a chrome layer whose reveal finished at 26% of the run
                    // stops rebuilding its shapes and text on every one of the remaining frames.
                    StartupFrameMarks(stage: stage, metrics: metrics)
                        .equatable()

                    StartupLockup(stage: stage, metrics: metrics)

                    if !metrics.compact {
                        StartupTelemetry(stage: stage, metrics: metrics)
                            .equatable()
                    }

                    StartupRail(stage: stage, metrics: metrics)
                        .equatable()

                    if !stage.reduceMotion {
                        StartupScanBeam(stage: stage, metrics: metrics)
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
