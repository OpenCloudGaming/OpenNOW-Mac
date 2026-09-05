import Foundation
import Testing
@testable import OpenNOW

struct NativeNVSTSixteenNineTitleTests {
    @Test func bakedBarsOnAFiveKFrameAreSixteenNineContent() {
        // 640 px of black each side of 5120x2160: content 3840 wide.
        #expect(NativeNVSTSixteenNineTitle.isSixteenNineContent(contentLeft: 0.125, contentRight: 0.875, frameWidth: 5120, frameHeight: 2160))
        // Full-frame ultrawide picture is not.
        #expect(!NativeNVSTSixteenNineTitle.isSixteenNineContent(contentLeft: 0, contentRight: 1, frameWidth: 5120, frameHeight: 2160))
        // A 16:9 frame has nothing to remove even when its content is 16:9.
        #expect(!NativeNVSTSixteenNineTitle.isSixteenNineContent(contentLeft: 0, contentRight: 1, frameWidth: 3840, frameHeight: 2160))
        // 4:3 inside 5K is not this feature's business.
        #expect(!NativeNVSTSixteenNineTitle.isSixteenNineContent(contentLeft: 0.2187, contentRight: 0.7813, frameWidth: 5120, frameHeight: 2160))
    }

    @Test func sixteenNineResolutionKeepsTheHeight() {
        #expect(NativeNVSTSixteenNineTitle.sixteenNineResolution(for: .init(width: 5120, height: 2160)) == .init(width: 3840, height: 2160))
        #expect(NativeNVSTSixteenNineTitle.sixteenNineResolution(for: .init(width: 3440, height: 1440)) == .init(width: 2560, height: 1440))
        #expect(NativeNVSTSixteenNineTitle.sixteenNineResolution(for: .init(width: 3840, height: 2160)) == nil)
        #expect(NativeNVSTSixteenNineTitle.sixteenNineResolution(for: .init(width: 1920, height: 1200)) == nil)
    }

    private func feed(_ tracker: inout NativeNVSTSixteenNineTitle.Tracker, bars: Bool, count: Int) -> [Bool] {
        var changes: [Bool] = []
        for _ in 0..<count {
            let change = bars
                ? tracker.observe(contentLeft: 0.125, contentRight: 0.875, frameWidth: 5120, frameHeight: 2160)
                : tracker.observe(contentLeft: 0, contentRight: 1, frameWidth: 5120, frameHeight: 2160)
            if let change { changes.append(change) }
        }
        return changes
    }

    /// Manor Lords, live 2026-09-05: three seconds of 16:9 intro video, then a full-frame 21:9
    /// menu for minutes. The first rule remembered it as 16:9 off the intro.
    @Test func anIntroVideoDoesNotMakeANativeTitleSixteenNine() {
        var tracker = NativeNVSTSixteenNineTitle.Tracker()
        #expect(feed(&tracker, bars: true, count: 3).isEmpty)
        // Nothing is decided before thirty samples; then the full-frame majority says native.
        let changes = feed(&tracker, bars: false, count: 40)
        #expect(changes == [false])
        #expect(tracker.verdict == false)
        #expect(!tracker.isConfirmed)
    }

    /// Streets of Rage 4: a full-frame Steam screen for a while, then bars for the whole game.
    @Test func aSixteenNineTitleIsConfirmedOnceBarsDominate() {
        var tracker = NativeNVSTSixteenNineTitle.Tracker()
        #expect(feed(&tracker, bars: false, count: 10).isEmpty)
        var changes = feed(&tracker, bars: true, count: 20)
        // 20 of 30 is 67%: inside the band, no verdict yet.
        #expect(changes.isEmpty)
        #expect(tracker.verdict == nil)
        changes = feed(&tracker, bars: true, count: 10)
        // 30 of 40 is 75%: confirmed, reported once.
        #expect(changes == [true])
        #expect(tracker.isConfirmed)
        #expect(feed(&tracker, bars: true, count: 50).isEmpty)
    }

    /// A 16:9 cutscene inside a 21:9 game must not flip a native verdict; a long one may.
    @Test func verdictHoldsInsideTheHysteresisBand() {
        var tracker = NativeNVSTSixteenNineTitle.Tracker()
        #expect(feed(&tracker, bars: false, count: 40) == [false])
        // 40 native + 40 bars = 50%: inside the band, still native.
        #expect(feed(&tracker, bars: true, count: 40).isEmpty)
        #expect(tracker.verdict == false)
        // 40 native + 100 bars = 71%: the game really is 16:9 after all.
        #expect(feed(&tracker, bars: true, count: 60) == [true])
    }

    @Test func launchProfileOverrideOnlyWhenEnabledKnownAndFillIsBlack() {
        var profile = OPNStreamPreferenceProfile()
        profile.resolution = .init(width: 5120, height: 2160)
        profile.streamSixteenNineTitlesAtSixteenNine = true
        profile.pillarboxFillMode = .black
        let overridden = OPNStreamPreferences.applyingSixteenNineOverride(profile, titleIsSixteenNine: true)
        #expect(overridden.resolution == .init(width: 3840, height: 2160))
        #expect(overridden.resolutionOverriddenForSixteenNine)

        #expect(OPNStreamPreferences.applyingSixteenNineOverride(profile, titleIsSixteenNine: false).resolution == profile.resolution)
        var disabled = profile
        disabled.streamSixteenNineTitlesAtSixteenNine = false
        #expect(OPNStreamPreferences.applyingSixteenNineOverride(disabled, titleIsSixteenNine: true).resolution == profile.resolution)
        var repaint = profile
        repaint.pillarboxFillMode = .blurredMirror
        #expect(OPNStreamPreferences.applyingSixteenNineOverride(repaint, titleIsSixteenNine: true).resolution == profile.resolution)
    }
}
