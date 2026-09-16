import Foundation
import Testing
@testable import OpenNOW

@Suite struct ControllerPadPointerTranslatorTests {
    @Test func touchStartProducesNoMovement() {
        var translator = ControllerPadPointerTranslator()
        let actions = translator.translate(ControllerTrackpadState(x: 0.4, y: 0.2, touched: true), settings: ControllerPadSettings(mode: .mouse))
        #expect(actions.isEmpty)
    }

    @Test func dragMovesMouseWithInvertedYByDefault() {
        var translator = ControllerPadPointerTranslator()
        let settings = ControllerPadSettings(mode: .mouse)
        _ = translator.translate(ControllerTrackpadState(x: 0, y: 0, touched: true), settings: settings)
        let actions = translator.translate(ControllerTrackpadState(x: 0.1, y: 0.1, touched: true), settings: settings)
        let expected = Int16((0.1 * ControllerPadPointerTranslator.basePointsPerPadUnit).rounded(.towardZero))
        #expect(actions.moveDeltaX == expected)
        #expect(actions.moveDeltaY == -expected)
    }

    @Test func invertYFlipsVerticalDirection() {
        var translator = ControllerPadPointerTranslator()
        let settings = ControllerPadSettings(mode: .mouse, invertY: true)
        _ = translator.translate(ControllerTrackpadState(x: 0, y: 0, touched: true), settings: settings)
        let actions = translator.translate(ControllerTrackpadState(x: 0, y: 0.1, touched: true), settings: settings)
        let expected = Int16((0.1 * ControllerPadPointerTranslator.basePointsPerPadUnit).rounded(.towardZero))
        #expect(actions.moveDeltaY == expected)
    }

    @Test func sensitivityScalesMovement() {
        var translator = ControllerPadPointerTranslator()
        let settings = ControllerPadSettings(mode: .mouse, sensitivity: 2.0)
        _ = translator.translate(ControllerTrackpadState(x: 0, y: 0, touched: true), settings: settings)
        let actions = translator.translate(ControllerTrackpadState(x: 0.1, y: 0, touched: true), settings: settings)
        let expected = Int16((0.1 * ControllerPadPointerTranslator.basePointsPerPadUnit * 2.0).rounded(.towardZero))
        #expect(actions.moveDeltaX == expected)
    }

    @Test func liftingFingerResetsAnchor() {
        var translator = ControllerPadPointerTranslator()
        let settings = ControllerPadSettings(mode: .mouse)
        _ = translator.translate(ControllerTrackpadState(x: -0.5, y: 0, touched: true), settings: settings)
        _ = translator.translate(ControllerTrackpadState(touched: false), settings: settings)
        let retouch = translator.translate(ControllerTrackpadState(x: 0.5, y: 0, touched: true), settings: settings)
        #expect(retouch.isEmpty)
    }

    @Test func scrollWheelModeProducesWheelDeltaNotMovement() {
        var translator = ControllerPadPointerTranslator()
        let settings = ControllerPadSettings(mode: .scrollWheel)
        _ = translator.translate(ControllerTrackpadState(x: 0, y: 0, touched: true), settings: settings)
        let actions = translator.translate(ControllerTrackpadState(x: 0, y: 0.5, touched: true), settings: settings)
        let expected = Int16((0.5 * ControllerPadPointerTranslator.baseWheelUnitsPerPadUnit).rounded(.towardZero))
        #expect(actions.wheelDelta == expected)
        #expect(actions.moveDeltaX == 0)
        #expect(actions.moveDeltaY == 0)
    }

    @Test func disabledModeProducesNothing() {
        var translator = ControllerPadPointerTranslator()
        let settings = ControllerPadSettings(mode: .disabled)
        _ = translator.translate(ControllerTrackpadState(x: 0, y: 0, touched: true), settings: settings)
        let actions = translator.translate(ControllerTrackpadState(x: 0.3, y: 0.3, touched: true), settings: settings)
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
