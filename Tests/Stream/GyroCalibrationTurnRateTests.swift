import Foundation
import Testing
@testable import OpenNOW

// The joystick-camera calibration rests on one arithmetic fact: `stickDeflection` divides the
// shaped rotation rate by `maxTurnRateDegreesPerSecond`. So the measurement has to read the rate a
// user actually rotates at, through the same shaping the stick uses, and the boundary between
// "a turn" and "a wobble" has to be the same boundary the setting enforces.

private let calibrationStep: Float = 1.0 / 120.0

/// A profile that isolates the rate question: no deadzone, no ramp, no smoothing, no momentum, a
/// linear curve and no anti-deadzone, so a shaped rate equals the rotation it came from.
private func calibrationSettings(mode: GyroOutputMode = .joystickCamera,
                                 maxTurnRate: Float = 500) -> ControllerGyroSettings {
    ControllerGyroSettings(mode: mode,
                           sensitivity: 1,
                           useNaturalSensitivity: true,
                           pixelsPer360: 2000,
                           conversion: .yaw,
                           smoothing: 0,
                           speedDeadzoneDegreesPerSecond: 0,
                           precisionZoneDegreesPerSecond: 0,
                           momentumHorizontal: 0,
                           momentumVertical: 0,
                           joystickPowerCurve: 1,
                           antiDeadzone: 0,
                           maxTurnRateDegreesPerSecond: maxTurnRate,
                           catchUp: false)
}

private func yawSample(_ degreesPerSecond: Float) -> ControllerMotionSample {
    ControllerMotionSample(gyroX: 0, gyroY: degreesPerSecond, gyroZ: 0)
}

/// Feeds a steady rotation through the capture far enough to travel the required rotation.
private func captured(rate: Float, steps: Int) -> GyroTurnRateCapture {
    var capture = GyroTurnRateCapture()
    for _ in 0 ..< steps {
        capture.add(horizontalDegreesPerSecond: rate, deltaTime: calibrationStep)
    }
    return capture
}

@Test func aSteadyTurnIsMeasuredAsTheRateItWasTurnedAt() {
    // 250 deg/s for 120 steps is 250 degrees of travel: a real turn, at a real rate.
    let capture = captured(rate: 250, steps: 120)
    guard case .recommend(let rate) = capture.verdict else {
        Issue.record("expected a recommendation, got \(capture.verdict)")
        return
    }
    #expect(abs(rate - 250) <= 25)
}

@Test func aWobbleIsNotYetATurn() {
    // Under the rotation threshold there is not enough evidence to tell a turn from a nudge, and
    // the wizard must keep prompting rather than recommend a number off eight samples.
    let capture = captured(rate: 300, steps: 10)
    #expect(capture.verdict == .keepRotating)
    #expect(capture.rotationProgress < 1)
}

@Test func rotationProgressReportsHowFarAlongTheTurnIs() {
    #expect(GyroTurnRateCapture().rotationProgress == 0)
    #expect(captured(rate: 250, steps: 120).rotationProgress == 1)
}

@Test func aSlowDriftIsNeverRecommendedAsATurnRate() {
    // Plenty of rotation, but never fast enough to be a turn. The floor is the setting's own
    // minimum, so recommending a value under it would be recommending a value that gets clamped.
    let capture = captured(rate: 9, steps: 2400)
    #expect(capture.rotationDegrees >= GyroTurnRateCapture.minimumRotationDegrees)
    #expect(capture.verdict == .noTurnDetected)
}

@Test func aSingleNoisyReportCannotRaiseTheMeasuredRate() {
    // One fumbled report at eighteen times the real rate must not reach the recommendation. The
    // median discards it outright, so the peak never sees it at all — a diluted spike would still
    // be a spike, and a calibration a user cannot trust is worse than no calibration.
    var capture = captured(rate: 50, steps: 20)
    capture.add(horizontalDegreesPerSecond: 900, deltaTime: calibrationStep)
    #expect(capture.peakSustainedRate == 50)

    // And it stays gone rather than arriving a window late.
    for _ in 0 ..< GyroTurnRateCapture.averagingWindow {
        capture.add(horizontalDegreesPerSecond: 50, deltaTime: calibrationStep)
    }
    #expect(capture.peakSustainedRate == 50)
}

@Test func aGenuinelyFasterTurnStillRaisesThePeak() {
    // The spike rejection must not flatten real measurement: a sustained faster turn is exactly what
    // the calibration is looking for, and the median preserves it.
    var capture = captured(rate: 50, steps: 20)
    for _ in 0 ..< 20 {
        capture.add(horizontalDegreesPerSecond: 300, deltaTime: calibrationStep)
    }
    #expect(abs(capture.peakSustainedRate - 300) < 0.001)
}

@Test func theRecommendationIsAReadableRoundNumber() {
    let capture = captured(rate: 254, steps: 120)
    #expect(capture.recommendedRate.truncatingRemainder(dividingBy: GyroTurnRateCapture.roundingStep) == 0)
}

@Test func theRecommendationStaysInsideTheRangeTheSettingsAccept() {
    // A recommendation outside the model's own clamp would be silently corrected on save, so the
    // wizard would report one number and the profile would keep another.
    let fast = captured(rate: 3000, steps: 120)
    #expect(fast.recommendedRate == ControllerGyroSettings.maximumMaxTurnRate)

    var slow = GyroTurnRateCapture()
    slow.add(horizontalDegreesPerSecond: ControllerGyroSettings.minimumMaxTurnRate, deltaTime: calibrationStep)
    #expect(slow.recommendedRate >= ControllerGyroSettings.minimumMaxTurnRate)
}

@Test func resettingForgetsTheMeasurement() {
    var capture = captured(rate: 250, steps: 120)
    capture.reset()
    #expect(capture.sampleCount == 0)
    #expect(capture.rotationDegrees == 0)
    #expect(capture.peakSustainedRate == 0)
    #expect(capture.verdict == .keepRotating)
}

@Test func theMeasuredRateIsTheRateTheStickReceives() {
    // The anti-divergence test. `process` is `shapedRates` plus mode routing, so a processor fed the
    // same samples as the measuring one must deflect by exactly the measured rate over the limit.
    // If shaping ever forks, the wizard starts recommending values its own output path disagrees
    // with, and this is what catches it.
    let settings = calibrationSettings(maxTurnRate: 500)
    var streaming = GyroProcessor()
    var measuring = GyroProcessor()

    for _ in 0 ..< 40 {
        let sample = yawSample(250)
        let output = streaming.process(sample, settings: settings, isActive: true, deltaTime: calibrationStep)
        guard let shaped = measuring.shapedRates(sample, settings: settings, isActive: true, deltaTime: calibrationStep) else {
            Issue.record("expected shaped rates for an enabled profile")
            return
        }
        let expected = min(max(shaped.horizontal / settings.maxTurnRateDegreesPerSecond, -1), 1)
        #expect(abs(output.stickX - expected) < 0.0001)
    }
}

@Test func aLiveRotationThroughTheShapingReachesARecommendation() {
    // End to end through the real pipeline: a user turning at 250 deg/s in a joystick-camera
    // profile produces a recommendation near 250, with no mouse delta and no live session involved.
    let settings = calibrationSettings()
    var processor = GyroProcessor()
    var capture = GyroTurnRateCapture()

    for _ in 0 ..< 180 {
        guard let shaped = processor.shapedRates(yawSample(250), settings: settings, isActive: true, deltaTime: calibrationStep) else {
            Issue.record("expected shaped rates for an enabled profile")
            return
        }
        capture.add(horizontalDegreesPerSecond: shaped.horizontal, deltaTime: shaped.deltaTime)
    }

    guard case .recommend(let rate) = capture.verdict else {
        Issue.record("expected a recommendation, got \(capture.verdict)")
        return
    }
    #expect(abs(rate - 250) <= 25)
}
