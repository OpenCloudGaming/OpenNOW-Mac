import Foundation
import Testing
@testable import OpenNOW

private func snapshot(leftPad: SteamControllerTrackpadState = SteamControllerTrackpadState(),
                      rightPad: SteamControllerTrackpadState = SteamControllerTrackpadState()) -> SteamControllerInputSnapshot {
    SteamControllerInputSnapshot(leftPad: leftPad, rightPad: rightPad)
}

@Suite struct SteamControllerTrackpadMouseTranslatorTests {
    @Test func touchStartProducesNoMovement() {
        var translator = SteamControllerTrackpadMouseTranslator()
        let actions = translator.translate(snapshot(rightPad: SteamControllerTrackpadState(x: 0.4, y: 0.2, touched: true)))
        #expect(actions.isEmpty)
    }

    @Test func rightPadDragMovesMouseWithInvertedY() {
        var translator = SteamControllerTrackpadMouseTranslator()
        _ = translator.translate(snapshot(rightPad: SteamControllerTrackpadState(x: 0, y: 0, touched: true)))
        let actions = translator.translate(snapshot(rightPad: SteamControllerTrackpadState(x: 0.1, y: 0.1, touched: true)))
        let expected = Int16((0.1 * SteamControllerTrackpadMouseTranslator.pointsPerPadUnit).rounded(.towardZero))
        #expect(actions.moveDeltaX == expected)
        #expect(actions.moveDeltaY == -expected)
    }

    @Test func slowDragAccumulatesFractionalMovement() {
        var translator = SteamControllerTrackpadMouseTranslator()
        var pad = SteamControllerTrackpadState(x: 0, y: 0, touched: true)
        _ = translator.translate(snapshot(rightPad: pad))
        let step: Float = 0.0005
        var total: Int = 0
        for index in 1...10 {
            pad.x = step * Float(index)
            total += Int(translator.translate(snapshot(rightPad: pad)).moveDeltaX)
        }
        let expected = Int((step * 10 * SteamControllerTrackpadMouseTranslator.pointsPerPadUnit).rounded(.towardZero))
        #expect(total == expected)
    }

    @Test func liftingFingerResetsAnchor() {
        var translator = SteamControllerTrackpadMouseTranslator()
        _ = translator.translate(snapshot(rightPad: SteamControllerTrackpadState(x: -0.5, y: 0, touched: true)))
        _ = translator.translate(snapshot(rightPad: SteamControllerTrackpadState(touched: false)))
        let retouch = translator.translate(snapshot(rightPad: SteamControllerTrackpadState(x: 0.5, y: 0, touched: true)))
        #expect(retouch.isEmpty)
    }

    @Test func leftPadDragScrolls() {
        var translator = SteamControllerTrackpadMouseTranslator()
        _ = translator.translate(snapshot(leftPad: SteamControllerTrackpadState(x: 0, y: 0, touched: true)))
        let actions = translator.translate(snapshot(leftPad: SteamControllerTrackpadState(x: 0, y: 0.5, touched: true)))
        let expected = Int16((0.5 * SteamControllerTrackpadMouseTranslator.wheelUnitsPerPadUnit).rounded(.towardZero))
        #expect(actions.wheelDelta == expected)
        #expect(actions.moveDeltaX == 0)
        #expect(actions.moveDeltaY == 0)
    }

    @Test func padClicksMapToMouseButtons() {
        var translator = SteamControllerTrackpadMouseTranslator()
        let press = translator.translate(snapshot(
            leftPad: SteamControllerTrackpadState(touched: true, pressed: true),
            rightPad: SteamControllerTrackpadState(touched: true, pressed: true)
        ))
        #expect(press.buttonTransitions.contains(SteamControllerTrackpadMouseActions.ButtonTransition(button: .left, isPressed: true)))
        #expect(press.buttonTransitions.contains(SteamControllerTrackpadMouseActions.ButtonTransition(button: .middle, isPressed: true)))

        let release = translator.translate(snapshot())
        #expect(release.buttonTransitions.contains(SteamControllerTrackpadMouseActions.ButtonTransition(button: .left, isPressed: false)))
        #expect(release.buttonTransitions.contains(SteamControllerTrackpadMouseActions.ButtonTransition(button: .middle, isPressed: false)))

        let idle = translator.translate(snapshot())
        #expect(idle.isEmpty)
    }
}
