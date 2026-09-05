import CoreGraphics
import Foundation

/// A 16:9 game streamed into a wider frame ships its black side bars as encoded pixels: at
/// 5120x2160 that is 640 columns each side, a quarter of every frame's pixels spent on nothing —
/// decoded, transmitted, paced. Once a title is known to do this, the next launch can request a
/// 16:9 resolution of the same height instead (3840x2160 for a 5K2K display) and let the window
/// letterbox: same picture, three-quarters of the work, and the encoder's bitrate spent entirely
/// on the game.
///
/// Detection reads the pillarbox detector's content span; the verdict is remembered per title in
/// `OPNStreamPreferences` and applied by `launchProfile(forGame:)`. It applies only while the
/// pillarbox fill is Black: the repaint modes work on bars *inside* the frame, and a 16:9 stream
/// has none to repaint.
enum NativeNVSTSixteenNineTitle {
    static let sixteenNine = 16.0 / 9.0
    /// How close the measured content aspect has to be to 16:9.
    static let aspectTolerance = 0.03
    /// How much wider than 16:9 the frame has to be before the bars are worth removing.
    static let minimumFrameSurplus = 0.1
    /// Samples (about a second apart) before a verdict is allowed at all. Publisher logos and
    /// intro videos are 16:9 letterboxed in almost every title, 21:9-native ones included: Manor
    /// Lords confirmed as 16:9 off its intro in the first three seconds, then showed a full-frame
    /// menu for the rest of the session. Thirty seconds outlasts the intros.
    static let minimumSamples = 30
    /// Share of samples with 16:9 bars at or above which the title counts as 16:9, and at or
    /// below which it counts as native; between the two the previous verdict stands.
    static let sixteenNineShare = 0.7
    static let nativeShare = 0.3

    /// True when `contentLeft...contentRight` of a `frameWidth`x`frameHeight` frame is 16:9
    /// picture inside a frame wide enough to matter.
    static func isSixteenNineContent(contentLeft: Double, contentRight: Double, frameWidth: Double, frameHeight: Double) -> Bool {
        guard frameWidth > 0, frameHeight > 0, contentRight > contentLeft else { return false }
        let frameAspect = frameWidth / frameHeight
        guard frameAspect > sixteenNine + minimumFrameSurplus else { return false }
        let contentAspect = (contentRight - contentLeft) * frameAspect
        return abs(contentAspect - sixteenNine) <= aspectTolerance
    }

    /// The 16:9 resolution of the same height, or nil when `resolution` is not usefully wider than
    /// 16:9 already. Even width, as every codec wants.
    static func sixteenNineResolution(for resolution: OPNStreamResolutionOption) -> OPNStreamResolutionOption? {
        guard resolution.width > 0, resolution.height > 0 else { return nil }
        let aspect = Double(resolution.width) / Double(resolution.height)
        guard aspect > sixteenNine + minimumFrameSurplus else { return nil }
        let width = Int((Double(resolution.height) * sixteenNine / 2).rounded()) * 2
        return OPNStreamResolutionOption(width: width, height: resolution.height)
    }

    /// Tallies bar and full-frame samples and turns them into a verdict with hysteresis, so one
    /// intro video or one 16:9 cutscene in a 21:9 game does not decide anything on its own.
    struct Tracker: Equatable, Sendable {
        private(set) var barSamples = 0
        private(set) var fullSamples = 0
        /// nil until `minimumSamples` have been seen; then true for a 16:9 title, false for a
        /// native one, holding its last value inside the hysteresis band.
        private(set) var verdict: Bool?

        var totalSamples: Int { barSamples + fullSamples }
        /// Compatibility with the first shape of this type: the confirmed-16:9 reading.
        var isConfirmed: Bool { verdict == true }
        var agreeingSamples: Int { barSamples }

        /// Feeds one HUD sample; returns the verdict when it changes (nil when it did not).
        mutating func observe(contentLeft: Double, contentRight: Double, frameWidth: Double, frameHeight: Double) -> Bool? {
            if NativeNVSTSixteenNineTitle.isSixteenNineContent(contentLeft: contentLeft, contentRight: contentRight, frameWidth: frameWidth, frameHeight: frameHeight) {
                barSamples += 1
            } else {
                fullSamples += 1
            }
            guard totalSamples >= NativeNVSTSixteenNineTitle.minimumSamples else { return nil }
            let share = Double(barSamples) / Double(totalSamples)
            let next: Bool?
            if share >= NativeNVSTSixteenNineTitle.sixteenNineShare { next = true }
            else if share <= NativeNVSTSixteenNineTitle.nativeShare { next = false }
            else { next = verdict }
            guard let next, next != verdict else { return nil }
            verdict = next
            return next
        }
    }
}
