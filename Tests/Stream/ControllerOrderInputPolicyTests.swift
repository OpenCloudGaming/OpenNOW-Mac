import Foundation
import Testing
@testable import OpenNOW

@Suite struct ControllerOrderInputPolicyTests {
    private let timestamp = MediaTimestamp(nanoseconds: 42)

    @Test func modalNavigationOnlySendsNeutralGamepadState() {
        let held = GamepadState(deviceID: "pad", playerIndex: 2, buttons: [.south, .dpadUp], leftTrigger: 1,
                                leftStickX: 0.75, timestamp: timestamp)
        #expect(ControllerOrderInputPolicy.eventForStream(.gamepad(held)) == .gamepad(GamepadState(deviceID: "pad", playerIndex: 2, timestamp: timestamp)))
    }

    @Test func releasesStillReachStreamButPressesDoNot() {
        let release = UserInputEvent.keyboard(KeyboardEvent(deviceID: "pad", keyCode: 49, scanCode: 49, isPressed: false, timestamp: timestamp))
        let press = UserInputEvent.keyboard(KeyboardEvent(deviceID: "pad", keyCode: 49, scanCode: 49, isPressed: true, timestamp: timestamp))
        #expect(ControllerOrderInputPolicy.eventForStream(release) == release)
        #expect(ControllerOrderInputPolicy.eventForStream(press) == nil)
        let mouseRelease = UserInputEvent.mouse(.button(deviceID: "pad", button: .left, isPressed: false, timestamp: timestamp))
        #expect(ControllerOrderInputPolicy.eventForStream(mouseRelease) == mouseRelease)
        #expect(ControllerOrderInputPolicy.eventForStream(.mouse(.button(deviceID: "pad", button: .left, isPressed: true, timestamp: timestamp))) == nil)
        #expect(ControllerOrderInputPolicy.eventForStream(.mouse(.wheel(deviceID: "pad", delta: 1, timestamp: timestamp))) == nil)
    }
}
