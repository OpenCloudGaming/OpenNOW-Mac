import Foundation

/// Owned by the polling queue; nil profile uses the unchanged native gamepad path.
struct ControllerMappingSession: Sendable {
    let deviceID: InputDeviceID
    let playerIndex: Int
    private(set) var profile: ControllerMappingProfile?
    private var engine = ControllerBindingEngine()
    private var previousGamepadState: GamepadState?

    init(deviceID: InputDeviceID, playerIndex: Int, profile: ControllerMappingProfile? = nil) {
        self.deviceID = deviceID
        self.playerIndex = playerIndex
        self.profile = profile
    }

    mutating func configure(profile: ControllerMappingProfile?, timestamp: MediaTimestamp) -> [UserInputEvent] {
        previousGamepadState = nil
        guard self.profile != profile else { return [] }
        let releases = reset(timestamp: timestamp)
        self.profile = profile
        return releases
    }

    mutating func process(_ snapshot: ControllerInputSnapshot, now: ContinuousClock.Instant,
                          timestamp: MediaTimestamp) -> [UserInputEvent] {
        if let profile {
            return engine.apply(profile: profile, snapshot: snapshot, deviceID: deviceID,
                                playerIndex: playerIndex, now: now, timestamp: timestamp).events
        }
        let state = snapshot.gamepadState(deviceID: deviceID, playerIndex: playerIndex, timestamp: MediaTimestamp(nanoseconds: 0))
        guard previousGamepadState != state else { return [] }
        previousGamepadState = state
        return [.gamepad(snapshot.gamepadState(deviceID: deviceID, playerIndex: playerIndex, timestamp: timestamp))]
    }

    mutating func reset(timestamp: MediaTimestamp) -> [UserInputEvent] {
        previousGamepadState = nil
        return engine.reset(deviceID: deviceID, playerIndex: playerIndex, timestamp: timestamp)
    }
}

extension ControllerInputSnapshot {
    func gamepadState(deviceID: InputDeviceID, playerIndex: Int, timestamp: MediaTimestamp) -> GamepadState {
        GamepadState(deviceID: deviceID, playerIndex: playerIndex, buttons: buttons,
                     leftTrigger: leftTrigger, rightTrigger: rightTrigger,
                     leftStickX: leftStickX, leftStickY: leftStickY,
                     rightStickX: rightStickX, rightStickY: rightStickY, timestamp: timestamp)
    }
}
