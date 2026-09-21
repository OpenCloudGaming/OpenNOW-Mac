import Foundation
import Testing
@testable import OpenNOW

// The test action's whole contract is arithmetic: the steps must sum to exactly one calibrated
// turn, in bounded pieces, in the direction asked for. Every one of those is a property that a
// dropped remainder or an off-by-one silently breaks.

@Test func stepsSumToExactlyOneCalibratedTurn() {
    for pixelsPer360: Float in [100, 401, 1234, 2000, 32000, 7999] {
        let steps = GyroCalibrationTurn.steps(pixelsPer360: pixelsPer360, forward: true)
        #expect(steps.reduce(0) { $0 + Int($1) } == Int(pixelsPer360))
    }
}

@Test func anExactCalibratedTurnIsNotRoundedAway() {
    // 2000 is the shipped default and 32000 the maximum, so both are sizes a user will actually
    // trigger. A partition that lost its remainder would leave the view short of where it started.
    #expect(GyroCalibrationTurn.steps(pixelsPer360: 2000, forward: true).reduce(0) { $0 + Int($1) } == 2000)
    #expect(GyroCalibrationTurn.steps(pixelsPer360: 32000, forward: true).reduce(0) { $0 + Int($1) } == 32000)
}

@Test func noSingleEventCarriesMoreThanTheChannelStep() {
    for pixelsPer360: Float in [100, 1234, 2000, 32000] {
        let steps = GyroCalibrationTurn.steps(pixelsPer360: pixelsPer360, forward: true)
        #expect(steps.allSatisfy { abs(Int($0)) <= Int(GyroCalibrationTurn.maximumStepPixels) })
    }
}

@Test func aBackwardTurnIsTheMirrorOfAForwardOne() {
    for pixelsPer360: Float in [100, 1234, 2000, 32000] {
        let forward = GyroCalibrationTurn.steps(pixelsPer360: pixelsPer360, forward: true)
        let backward = GyroCalibrationTurn.steps(pixelsPer360: pixelsPer360, forward: false)
        #expect(forward.map(-) == backward)
        #expect(backward.allSatisfy { $0 <= 0 })
    }
}

@Test func aTurnSmallerThanOneStepIsStillOneStep() {
    // The smallest calibration the settings allow (100 counts per 360°) must not be dropped by the
    // step limit, and a fractional calibration must not round the action away entirely.
    #expect(GyroCalibrationTurn.steps(pixelsPer360: 100, forward: true) == [100])
    #expect(GyroCalibrationTurn.steps(pixelsPer360: 0.4, forward: true) == [])
}

@Test func aTurnIsClampedToTheWiresSignedRange() {
    // One step is an Int16 on the wire. An over-range calibration is clamped rather than wrapped:
    // a wrapped delta would fling the view across the screen.
    let steps = GyroCalibrationTurn.steps(pixelsPer360: 99_999, forward: true)
    #expect(steps.reduce(0) { $0 + Int($1) } == Int(Int16.max))
    #expect(steps.allSatisfy { $0 > 0 })
}

@Test func aZeroOrNegativeCalibrationEmitsNothing() {
    #expect(GyroCalibrationTurn.steps(pixelsPer360: 0, forward: true).isEmpty)
    #expect(GyroCalibrationTurn.steps(pixelsPer360: -500, forward: true).isEmpty)
}

@Test func theStepCountIsBoundedForAFullRangeTurn() {
    // The backlog argument only holds if a full turn stays a bounded number of events.
    #expect(GyroCalibrationTurn.stepCount(pixelsPer360: 32000) == 80)
    #expect(GyroCalibrationTurn.stepCount(pixelsPer360: 2000) == 5)
}

@Test @MainActor func emitReportsEveryAcceptedStep() async {
    var emitted: [Int16] = []
    let accepted = await GyroCalibrationTurn.emit(pixelsPer360: 1000, forward: true, interval: .zero) { event in
        if case .mouse(.moved(_, let deltaX, _, _)) = event {
            emitted.append(deltaX)
            return true
        }
        return false
    }
    #expect(accepted == 3)
    #expect(emitted == [334, 333, 333])
    #expect(emitted.reduce(0) { $0 + Int($1) } == 1000)
}

@Test @MainActor func emitStopsWhenTheSessionGoesAway() async {
    // A stream that ends mid-turn must short-circuit instead of being counted as delivered, which
    // is how the wizard tells "the turn ran" from "the stream died while it ran".
    var calls = 0
    let accepted = await GyroCalibrationTurn.emit(pixelsPer360: 2000, forward: true, interval: .zero) { _ in
        calls += 1
        return calls < 3
    }
    #expect(accepted == 2)
    #expect(calls == 3)
}

@Test @MainActor func emitHoldsNoButtonOrKeyState() async {
    // The action is relative movement only. This is the assertion behind the acceptance criterion
    // that emitting it cannot leave a stuck input: there is nothing here that can be left down.
    var sawNonMoveEvent = false
    _ = await GyroCalibrationTurn.emit(pixelsPer360: 800, forward: true, interval: .zero) { event in
        if case .mouse(.moved) = event {} else { sawNonMoveEvent = true }
        return true
    }
    #expect(!sawNonMoveEvent)
}

@Test func aSyntheticMoveUsesTheSharedPointerDevice() {
    // The anti-AFK nudge and this action must be the same event, or the seat sees two devices.
    let move = UserInputEvent.relativeMouseMove(deltaX: 12, deltaY: 0)
    #expect(move.deviceID == "mouse")
    guard case .mouse(.moved(let deviceID, 12, 0, _)) = move else {
        Issue.record("expected a relative move on the shared pointer device")
        return
    }
    #expect(deviceID == "mouse")
}
