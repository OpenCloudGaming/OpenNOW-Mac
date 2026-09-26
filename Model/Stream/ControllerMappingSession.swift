import Foundation

/// Owned by the polling queue; nil profile uses the unchanged native gamepad path.
struct ControllerMappingSession: Sendable {
    let deviceID: InputDeviceID
    let playerIndex: Int
    private(set) var profile: ControllerMappingProfile?
    /// Kept beside the engine because it must resolve when `profile` is nil — remote input is off
    /// whenever a local overlay owns the pad, and the guide is the button that closes that overlay.
    private(set) var guideBinding: ControllerBindingTarget
    private var engine = ControllerBindingEngine()
    private var previousGamepadState: GamepadState?
    private var isGuideActive = false

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
        let guide = resolveGuide(in: snapshot)
        guard let profile else {
            return forwardingNativeSnapshot(guide, timestamp: timestamp)
        }
        var result = engine.apply(profile: profile, snapshot: guide.snapshot, deviceID: deviceID,
                                  playerIndex: playerIndex, now: now, timestamp: timestamp)
        result.commands.insert(contentsOf: guide.commands, at: 0)
        return result
    }

    mutating func reset(timestamp: MediaTimestamp) -> [UserInputEvent] {
        previousGamepadState = nil
        isGuideActive = false
        return engine.reset(deviceID: deviceID, playerIndex: playerIndex, timestamp: timestamp)
    }

    private mutating func resolveGuide(in snapshot: ControllerInputSnapshot) -> GuideResolution {
        guard case .streamCommand(let action) = guideBinding else {
            isGuideActive = false
            return GuideResolution(snapshot: snapshot, commands: [])
        }
        let isGuidePressed = snapshot.buttons.contains(.mode)
        let isNewPress = isGuidePressed && !isGuideActive
        isGuideActive = isGuidePressed
        var consumedSnapshot = snapshot
        consumedSnapshot.buttons.remove(.mode)
        return GuideResolution(snapshot: consumedSnapshot, commands: isNewPress ? [action] : [])
    }

    private mutating func forwardingNativeSnapshot(_ guide: GuideResolution,
                                                   timestamp: MediaTimestamp) -> ControllerBindingResult {
        let state = guide.snapshot.gamepadState(deviceID: deviceID, playerIndex: playerIndex,
                                                timestamp: MediaTimestamp(nanoseconds: 0))
        guard previousGamepadState != state else { return ControllerBindingResult(commands: guide.commands) }
        previousGamepadState = state
        return ControllerBindingResult(
            events: [.gamepad(guide.snapshot.gamepadState(deviceID: deviceID, playerIndex: playerIndex, timestamp: timestamp))],
            commands: guide.commands
        )
    }

    /// A snapshot with the guide bit already consumed, plus the command that consumption fired.
    private struct GuideResolution {
        let snapshot: ControllerInputSnapshot
        let commands: [KeybindingAction]
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
