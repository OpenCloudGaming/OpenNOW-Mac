import Foundation
import Testing
@testable import OpenNOW

// Both calibration passes end in a number written into a profile, so the tests are about what the
// pass refuses as much as what it produces: an offset measured while the user was moving, or a turn
// rate nothing consumes, must not reach the profile.

private let sessionStep: Float = 1.0 / 120.0

private func sessionSettings(mode: GyroOutputMode = .joystickCamera,
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

private func motion(gyroY: Float) -> ControllerMotionSample {
    ControllerMotionSample(gyroX: 0, gyroY: gyroY, gyroZ: 0)
}

/// Runs an offset capture to completion at a fixed cadence.
private func runOffsetCapture(_ sample: (Int) -> ControllerMotionSample?) -> GyroCalibrationSession {
    var session = GyroCalibrationSession()
    session.start(.zeroRateOffset)
    var index = 0
    while session.isRunning, index < 10_000 {
        session.ingest(sample(index), settings: sessionSettings(), deltaTime: sessionStep)
        index += 1
    }
    return session
}

@Test func aStillPadProducesTheMeasuredOffset() {
    // A pad with a real 2 deg/s zero-rate error, held still: the capture must report that error, not
    // zero — reporting zero is what the removed Recalibrate button did and why it was useless.
    let session = runOffsetCapture { _ in motion(gyroY: 2) }
    guard case .measuredOffset(let x, let y, let z) = session.result else {
        Issue.record("expected a measured offset, got \(session.result)")
        return
    }
    #expect(abs(y) > 1)
    #expect(abs(x) < 0.5)
    #expect(abs(z) < 0.5)
}

@Test func anOffsetCaptureThatRunsOverIsNotStalledByAStillPad() {
    // The capture is paced by the caller's cadence, not by the pad changing: a pad reporting the same
    // value every poll must still reach the end.
    let session = runOffsetCapture { _ in motion(gyroY: 0) }
    #expect(!session.isRunning)
    #expect(session.result != .none)
}

@Test func movingVoidsTheOffsetCapture() {
    // A bias measured while the user is turning is a measurement of their hands. The pass refuses it
    // rather than storing a wrong offset that then seeds every session.
    let session = runOffsetCapture { index in index > 100 ? motion(gyroY: 120) : motion(gyroY: 0) }
    #expect(session.result == .movedDuringCapture)
}

@Test func aControllerWithNoMotionSaysSoInsteadOfMeasuringNothing() {
    let session = runOffsetCapture { _ in nil }
    #expect(session.result == .noMotionData)
}

@Test func cancellingLeavesNoResultBehind() {
    // A cancelled pass must not leave a recommendation on screen for a value that was never measured.
    var session = GyroCalibrationSession()
    session.start(.turnRate)
    session.ingest(motion(gyroY: 250), settings: sessionSettings(), deltaTime: sessionStep)
    session.cancel()
    #expect(session.result == .none)
    #expect(!session.isRunning)
    #expect(session.progress == 0)
}

@Test func aTurnRateCaptureRecommendsTheRateThatWasTurned() {
    var session = GyroCalibrationSession()
    session.start(.turnRate)
    var index = 0
    while session.isRunning, index < 10_000 {
        session.ingest(motion(gyroY: 250), settings: sessionSettings(), deltaTime: sessionStep)
        index += 1
    }
    guard case .turnRateRecommended(let rate) = session.result else {
        Issue.record("expected a recommended rate, got \(session.result)")
        return
    }
    #expect(abs(rate - 250) <= 25)
    // It finishes by itself rather than asking the user to stop turning.
    #expect(!session.isRunning)
}

@Test func aTurnRateCaptureReportsProgressWhileItRuns() {
    var session = GyroCalibrationSession()
    session.start(.turnRate)
    for _ in 0 ..< 10 {
        session.ingest(motion(gyroY: 250), settings: sessionSettings(), deltaTime: sessionStep)
    }
    #expect(session.isRunning)
    #expect(session.progress > 0 && session.progress < 1)
    #expect(session.liveTurnRate > 0)
    // Ten samples is not yet a turn, so the running prompt must be "keep turning" rather than an
    // explanation of a failure the user has not made.
    #expect(session.liveTurnRateVerdict == .keepRotating)
}

@Test func theTurnRatePassIsIgnoredForAnOutputThatDoesNotReadIt() {
    // `maxTurnRateDegreesPerSecond` is read by the joystick-camera deflection and nothing else, so
    // measuring it in another mode would recommend a number no code consumes.
    var session = GyroCalibrationSession()
    session.start(.turnRate)
    for _ in 0 ..< 400 {
        session.ingest(motion(gyroY: 250), settings: sessionSettings(mode: .mouse), deltaTime: sessionStep)
    }
    #expect(session.result == .none)
    #expect(session.liveTurnRate == 0)
}

@Test func applyingAMeasuredOffsetStoresItAndLeavesTheEstimatorOut() {
    // Two decisions in one: the measurement is stored, and the mode becomes Manual — a stored offset
    // left on Automatic is a seed the estimator re-learns over, so storing one and changing nothing
    // else would not be a state that means anything.
    let session = runOffsetCapture { _ in motion(gyroY: 2) }
    let applied = session.applyingMeasuredOffset(to: sessionSettings())
    #expect(abs(applied.biasY) > 1)
    #expect(applied.calibrationMode == .manual)
}

@Test func applyingWithNothingMeasuredChangesNothing() {
    var session = GyroCalibrationSession()
    let untouched = sessionSettings(maxTurnRate: 321)
    #expect(session.applyingMeasuredOffset(to: untouched) == untouched)
    #expect(session.applyingMeasuredTurnRate(to: untouched) == untouched)

    // And a cancelled pass must not leave a value that a later APPLY could pick up.
    session.start(.turnRate)
    session.ingest(motion(gyroY: 250), settings: untouched, deltaTime: sessionStep)
    session.cancel()
    #expect(session.applyingMeasuredTurnRate(to: untouched) == untouched)
}

@Test func applyingAMeasuredTurnRateWritesTheSetting() {
    var session = GyroCalibrationSession()
    session.start(.turnRate)
    var index = 0
    while session.isRunning, index < 10_000 {
        session.ingest(motion(gyroY: 250), settings: sessionSettings(maxTurnRate: 500), deltaTime: sessionStep)
        index += 1
    }
    let applied = session.applyingMeasuredTurnRate(to: sessionSettings(maxTurnRate: 500))
    #expect(abs(applied.maxTurnRateDegreesPerSecond - 250) <= 25)
}

@Test func startingAPassClearsTheOneBeforeIt() {
    var session = GyroCalibrationSession()
    session.start(.turnRate)
    for _ in 0 ..< 400 {
        session.ingest(motion(gyroY: 250), settings: sessionSettings(), deltaTime: sessionStep)
    }
    #expect(session.result != .none)

    session.start(.zeroRateOffset)
    #expect(session.result == .none)
    #expect(session.progress == 0)
    #expect(session.liveTurnRate == 0)
}
