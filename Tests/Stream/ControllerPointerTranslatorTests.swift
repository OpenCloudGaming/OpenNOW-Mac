import Foundation
import Testing
@testable import OpenNOW

@Suite struct ControllerPadPointerTranslatorTests {
    private let step: Float = 1.0 / 120.0

    @Test func touchStartProducesNoMovement() {
        var translator = ControllerPadPointerTranslator()
        let actions = translator.translate(ControllerTrackpadState(x: 0.4, y: 0.2, touched: true),
                                           settings: ControllerPadSettings(mode: .mouse),
                                           deltaTime: step)
        #expect(actions.isEmpty)
    }

    /// A steady drag has to track the finger: after the smoothing filter settles, the emitted
    /// total should match the distance covered, with Y inverted by default.
    @Test func sustainedDragMovesMouseWithInvertedY() {
        var translator = ControllerPadPointerTranslator()
        let settings = ControllerPadSettings(mode: .mouse)
        var pad = ControllerTrackpadState(x: 0, y: 0, touched: true)
        _ = translator.translate(pad, settings: settings, deltaTime: step)

        var totalX = 0
        var totalY = 0
        for frame in 1...60 {
            pad.x = Float(frame) * 0.01
            pad.y = Float(frame) * 0.01
            let actions = translator.translate(pad, settings: settings, deltaTime: step)
            totalX += Int(actions.moveDeltaX)
            totalY += Int(actions.moveDeltaY)
        }

        let rawTotal = Int((0.6 * ControllerPadPointerTranslator.basePointsPerPadUnit).rounded(.towardZero))
        #expect(totalX > rawTotal * 3 / 4)
        #expect(totalX <= rawTotal)
        #expect(totalY < -rawTotal * 3 / 4)
        #expect(totalY >= -rawTotal)
    }

    @Test func invertYFlipsVerticalDirection() {
        var translator = ControllerPadPointerTranslator()
        let settings = ControllerPadSettings(mode: .mouse, invertY: true)
        var pad = ControllerTrackpadState(x: 0, y: 0, touched: true)
        _ = translator.translate(pad, settings: settings, deltaTime: step)

        var totalY = 0
        for frame in 1...60 {
            pad.y = Float(frame) * 0.01
            totalY += Int(translator.translate(pad, settings: settings, deltaTime: step).moveDeltaY)
        }
        #expect(totalY > 0)
    }

    @Test func sensitivityScalesMovement() {
        var slow = ControllerPadPointerTranslator()
        var fast = ControllerPadPointerTranslator()
        var pad = ControllerTrackpadState(x: 0, y: 0, touched: true)
        let slowSettings = ControllerPadSettings(mode: .mouse, sensitivity: 1.0)
        let fastSettings = ControllerPadSettings(mode: .mouse, sensitivity: 2.0)
        _ = slow.translate(pad, settings: slowSettings, deltaTime: step)
        _ = fast.translate(pad, settings: fastSettings, deltaTime: step)

        var slowTotal = 0
        var fastTotal = 0
        for frame in 1...60 {
            pad.x = Float(frame) * 0.01
            slowTotal += Int(slow.translate(pad, settings: slowSettings, deltaTime: step).moveDeltaX)
            fastTotal += Int(fast.translate(pad, settings: fastSettings, deltaTime: step).moveDeltaX)
        }
        #expect(fastTotal > slowTotal)
    }

    @Test func liftingFingerResetsAnchor() {
        var translator = ControllerPadPointerTranslator()
        let settings = ControllerPadSettings(mode: .mouse)
        _ = translator.translate(ControllerTrackpadState(x: -0.5, y: 0, touched: true), settings: settings, deltaTime: step)
        _ = translator.translate(ControllerTrackpadState(touched: false), settings: settings, deltaTime: step)
        let retouch = translator.translate(ControllerTrackpadState(x: 0.5, y: 0, touched: true), settings: settings, deltaTime: step)
        #expect(retouch.isEmpty)
    }

    /// The reported bug: a resting finger's tremor must not move the cursor. A 10 Hz, 0.01-unit
    /// shake is what physiological tremor looks like on the pad; the filter plus threshold should
    /// emit only a small fraction of the movement the raw signal carries.
    @Test func restingTremorProducesLittleMovement() {
        var translator = ControllerPadPointerTranslator()
        let settings = ControllerPadSettings(mode: .mouse)
        var pad = ControllerTrackpadState(x: 0, y: 0, touched: true)
        _ = translator.translate(pad, settings: settings, deltaTime: step)

        var rawMovement = 0
        var emittedMovement = 0
        var previousX: Float = 0
        for frame in 1...240 {
            pad.x = 0.01 * sin(2 * Float.pi * 10 * Float(frame) * step)
            rawMovement += Int(abs(pad.x - previousX) * ControllerPadPointerTranslator.basePointsPerPadUnit)
            previousX = pad.x
            emittedMovement += Int(abs(translator.translate(pad, settings: settings, deltaTime: step).moveDeltaX))
        }
        #expect(rawMovement > 0)
        #expect(emittedMovement < rawMovement / 4)
    }

    /// The other half of the trade: the filter must not swallow a real flick.
    @Test func flickIsNotDelayed() {
        var translator = ControllerPadPointerTranslator()
        let settings = ControllerPadSettings(mode: .mouse)
        var pad = ControllerTrackpadState(x: 0, y: 0, touched: true)
        _ = translator.translate(pad, settings: settings, deltaTime: step)

        var rawMovement = 0
        var emittedMovement = 0
        var previousX: Float = 0
        for frame in 1...20 {
            pad.x = Float(frame) * 0.02
            rawMovement += Int((pad.x - previousX) * ControllerPadPointerTranslator.basePointsPerPadUnit)
            previousX = pad.x
            emittedMovement += Int(translator.translate(pad, settings: settings, deltaTime: step).moveDeltaX)
        }
        #expect(emittedMovement > rawMovement * 3 / 4)
    }

    @Test func scrollWheelModeProducesWheelDeltaNotMovement() {
        var translator = ControllerPadPointerTranslator()
        let settings = ControllerPadSettings(mode: .scrollWheel)
        var pad = ControllerTrackpadState(x: 0, y: 0, touched: true)
        _ = translator.translate(pad, settings: settings, deltaTime: step)

        var totalWheel = 0
        var totalMove = 0
        for frame in 1...40 {
            pad.y = Float(frame) * 0.01
            let actions = translator.translate(pad, settings: settings, deltaTime: step)
            totalWheel += Int(actions.wheelDelta)
            totalMove += Int(actions.moveDeltaX) + Int(actions.moveDeltaY)
        }
        #expect(totalWheel != 0)
        #expect(totalMove == 0)
    }

    @Test func disabledModeProducesNothing() {
        var translator = ControllerPadPointerTranslator()
        let settings = ControllerPadSettings(mode: .disabled)
        _ = translator.translate(ControllerTrackpadState(x: 0, y: 0, touched: true), settings: settings, deltaTime: step)
        let actions = translator.translate(ControllerTrackpadState(x: 0.3, y: 0.3, touched: true), settings: settings, deltaTime: step)
        #expect(actions.isEmpty)
    }
}

@Suite struct ControllerStickPointerTranslatorTests {
    @Test func belowDeadzoneProducesNothing() {
        var translator = ControllerStickPointerTranslator()
        let actions = translator.translate(x: 0.05, y: 0.05, settings: ControllerPadSettings(mode: .mouse))
        #expect(actions.isEmpty)
    }

    @Test func deflectionMovesMouse() {
        var translator = ControllerStickPointerTranslator()
        let actions = translator.translate(x: 0.5, y: 0, settings: ControllerPadSettings(mode: .mouse))
        #expect(actions.moveDeltaX > 0)
        #expect(actions.moveDeltaY == 0)
    }

    @Test func joystickPassthroughModeProducesNothing() {
        var translator = ControllerStickPointerTranslator()
        let actions = translator.translate(x: 0.5, y: 0.5, settings: ControllerPadSettings(mode: .joystickPassthrough))
        #expect(actions.isEmpty)
    }

    @Test func scrollWheelModeProducesWheelDelta() {
        var translator = ControllerStickPointerTranslator()
        let actions = translator.translate(x: 0, y: 0.5, settings: ControllerPadSettings(mode: .scrollWheel))
        #expect(actions.wheelDelta != 0)
        #expect(actions.moveDeltaX == 0)
        #expect(actions.moveDeltaY == 0)
    }
}
