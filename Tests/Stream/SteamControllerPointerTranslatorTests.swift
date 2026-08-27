import Foundation
import Testing
@testable import OpenNOW

@Suite struct SteamControllerPadPointerTranslatorTests {
    @Test func touchStartProducesNoMovement() {
        var translator = SteamControllerPadPointerTranslator()
        let actions = translator.translate(SteamControllerTrackpadState(x: 0.4, y: 0.2, touched: true), settings: SteamControllerPadSettings(mode: .mouse))
        #expect(actions.isEmpty)
    }

    @Test func dragMovesMouseWithInvertedYByDefault() {
        var translator = SteamControllerPadPointerTranslator()
        let settings = SteamControllerPadSettings(mode: .mouse)
        _ = translator.translate(SteamControllerTrackpadState(x: 0, y: 0, touched: true), settings: settings)
        let actions = translator.translate(SteamControllerTrackpadState(x: 0.1, y: 0.1, touched: true), settings: settings)
        let expected = Int16((0.1 * SteamControllerPadPointerTranslator.basePointsPerPadUnit).rounded(.towardZero))
        #expect(actions.moveDeltaX == expected)
        #expect(actions.moveDeltaY == -expected)
    }

    @Test func invertYFlipsVerticalDirection() {
        var translator = SteamControllerPadPointerTranslator()
        let settings = SteamControllerPadSettings(mode: .mouse, invertY: true)
        _ = translator.translate(SteamControllerTrackpadState(x: 0, y: 0, touched: true), settings: settings)
        let actions = translator.translate(SteamControllerTrackpadState(x: 0, y: 0.1, touched: true), settings: settings)
        let expected = Int16((0.1 * SteamControllerPadPointerTranslator.basePointsPerPadUnit).rounded(.towardZero))
        #expect(actions.moveDeltaY == expected)
    }

    @Test func sensitivityScalesMovement() {
        var translator = SteamControllerPadPointerTranslator()
        let settings = SteamControllerPadSettings(mode: .mouse, sensitivity: 2.0)
        _ = translator.translate(SteamControllerTrackpadState(x: 0, y: 0, touched: true), settings: settings)
        let actions = translator.translate(SteamControllerTrackpadState(x: 0.1, y: 0, touched: true), settings: settings)
        let expected = Int16((0.1 * SteamControllerPadPointerTranslator.basePointsPerPadUnit * 2.0).rounded(.towardZero))
        #expect(actions.moveDeltaX == expected)
    }

    @Test func liftingFingerResetsAnchor() {
        var translator = SteamControllerPadPointerTranslator()
        let settings = SteamControllerPadSettings(mode: .mouse)
        _ = translator.translate(SteamControllerTrackpadState(x: -0.5, y: 0, touched: true), settings: settings)
        _ = translator.translate(SteamControllerTrackpadState(touched: false), settings: settings)
        let retouch = translator.translate(SteamControllerTrackpadState(x: 0.5, y: 0, touched: true), settings: settings)
        #expect(retouch.isEmpty)
    }

    @Test func scrollWheelModeProducesWheelDeltaNotMovement() {
        var translator = SteamControllerPadPointerTranslator()
        let settings = SteamControllerPadSettings(mode: .scrollWheel)
        _ = translator.translate(SteamControllerTrackpadState(x: 0, y: 0, touched: true), settings: settings)
        let actions = translator.translate(SteamControllerTrackpadState(x: 0, y: 0.5, touched: true), settings: settings)
        let expected = Int16((0.5 * SteamControllerPadPointerTranslator.baseWheelUnitsPerPadUnit).rounded(.towardZero))
        #expect(actions.wheelDelta == expected)
        #expect(actions.moveDeltaX == 0)
        #expect(actions.moveDeltaY == 0)
    }

    @Test func disabledModeProducesNothing() {
        var translator = SteamControllerPadPointerTranslator()
        let settings = SteamControllerPadSettings(mode: .disabled)
        _ = translator.translate(SteamControllerTrackpadState(x: 0, y: 0, touched: true), settings: settings)
        let actions = translator.translate(SteamControllerTrackpadState(x: 0.3, y: 0.3, touched: true), settings: settings)
        #expect(actions.isEmpty)
    }
}

@Suite struct SteamControllerStickPointerTranslatorTests {
    @Test func belowDeadzoneProducesNothing() {
        var translator = SteamControllerStickPointerTranslator()
        let actions = translator.translate(x: 0.05, y: 0.05, settings: SteamControllerPadSettings(mode: .mouse))
        #expect(actions.isEmpty)
    }

    @Test func deflectionMovesMouse() {
        var translator = SteamControllerStickPointerTranslator()
        let actions = translator.translate(x: 0.5, y: 0, settings: SteamControllerPadSettings(mode: .mouse))
        #expect(actions.moveDeltaX > 0)
        #expect(actions.moveDeltaY == 0)
    }

    @Test func joystickPassthroughModeProducesNothing() {
        var translator = SteamControllerStickPointerTranslator()
        let actions = translator.translate(x: 0.5, y: 0.5, settings: SteamControllerPadSettings(mode: .joystickPassthrough))
        #expect(actions.isEmpty)
    }

    @Test func scrollWheelModeProducesWheelDelta() {
        var translator = SteamControllerStickPointerTranslator()
        let actions = translator.translate(x: 0, y: 0.5, settings: SteamControllerPadSettings(mode: .scrollWheel))
        #expect(actions.wheelDelta != 0)
        #expect(actions.moveDeltaX == 0)
        #expect(actions.moveDeltaY == 0)
    }
}
