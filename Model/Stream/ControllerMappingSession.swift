import Foundation

/// Owned by the polling queue; nil profile uses the unchanged native gamepad path.
struct ControllerMappingSession: Sendable {
    let deviceID: InputDeviceID
    let playerIndex: Int
    private(set) var profile: ControllerMappingProfile?
    /// How the guide button resolves for this pad. Kept beside the engine rather than inside it
    /// because it must keep working when `profile` is nil — remote input is off whenever a local
    /// overlay owns the pad, and the guide is the button that closes that overlay.
    private(set) var guideBinding: ControllerBindingTarget
    private var engine = ControllerBindingEngine()
    private var previousGamepadState: GamepadState?
    private var guideActive = false

    init(deviceID: InputDeviceID,
         playerIndex: Int,
         profile: ControllerMappingProfile? = nil,
         guideBinding: ControllerBindingTarget = ControllerMappingProfile.guideDefault) {
        self.deviceID = deviceID
        self.playerIndex = playerIndex
        self.profile = profile
        self.guideBinding = guideBinding
    }

    mutating func configure(profile: ControllerMappingProfile?,
                            guideBinding: ControllerBindingTarget? = nil,
                            timestamp: MediaTimestamp) -> [UserInputEvent] {
        if let guideBinding { self.guideBinding = guideBinding }
        previousGamepadState = nil
        guard self.profile != profile else { return [] }
        let releases = reset(timestamp: timestamp)
        self.profile = profile
        return releases
    }

    mutating func process(_ snapshot: ControllerInputSnapshot, now: ContinuousClock.Instant,
                          timestamp: MediaTimestamp) -> ControllerBindingResult {
        var snapshot = snapshot
        var commands: [KeybindingAction] = []
        if case .streamCommand(let action) = guideBinding {
            let guide = snapshot.buttons.contains(.mode)
            if guide, !guideActive { commands.append(action) }
            guideActive = guide
            // Consumed: a guide bound to an app action never reaches the seat, and the engine must
            // not fire the same command again through the ordinary control pass.
            snapshot.buttons.remove(.mode)
        } else {
            guideActive = false
        }
        if let profile {
            var result = engine.apply(profile: profile, snapshot: snapshot, deviceID: deviceID,
                                      playerIndex: playerIndex, now: now, timestamp: timestamp)
            result.commands.insert(contentsOf: commands, at: 0)
            return result
        }
        let state = snapshot.gamepadState(deviceID: deviceID, playerIndex: playerIndex, timestamp: MediaTimestamp(nanoseconds: 0))
        guard previousGamepadState != state else { return ControllerBindingResult(commands: commands) }
        previousGamepadState = state
        return ControllerBindingResult(
            events: [.gamepad(snapshot.gamepadState(deviceID: deviceID, playerIndex: playerIndex, timestamp: timestamp))],
            commands: commands
        )
    }

    mutating func reset(timestamp: MediaTimestamp) -> [UserInputEvent] {
        previousGamepadState = nil
        guideActive = false
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
