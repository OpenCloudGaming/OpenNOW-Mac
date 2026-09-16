import Foundation

enum ControllerOrderInputPolicy {
    static func eventForStream(_ event: UserInputEvent) -> UserInputEvent? {
        switch event {
        case .gamepad(let state):
            return .gamepad(GamepadState(deviceID: state.deviceID, playerIndex: state.playerIndex, timestamp: state.timestamp))
        case .keyboard(let key) where !key.isPressed:
            return event
        case .mouse(.button(_, _, false, _)):
            return event
        default:
            return nil
        }
    }
}
