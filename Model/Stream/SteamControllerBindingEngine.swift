import Foundation

public struct SteamControllerBindingResult: Sendable {
    public var events: [UserInputEvent] = []
    public var nextReapplyDelay: Duration?
}

/// Turns a raw `SteamControllerInputSnapshot` into the events the stream actually sees,
/// according to a `SteamControllerMappingProfile`. Replaces the old fixed 1:1 button
/// passthrough, the grip-only chord mapper, and the global trackpad-mouse toggle with one
/// per-device engine that covers every control.
public struct SteamControllerBindingEngine: Sendable {
    public static let modifierLeadTime: Duration = .milliseconds(50)
    private static let chordModifierButtons: GamepadButtons = [.leftShoulder, .rightShoulder]
    private static let triggerActiveThreshold: Float = 0.5

    private var previousActiveControls: Set<SteamControllerControl> = []
    private var holdInstants: [SteamControllerControl: ContinuousClock.Instant] = [:]
    private var leftPadTranslator = SteamControllerPadPointerTranslator()
    private var rightPadTranslator = SteamControllerPadPointerTranslator()
    private var leftStickTranslator = SteamControllerStickPointerTranslator()
    private var rightStickTranslator = SteamControllerStickPointerTranslator()

    public init() {}

    /// Buttons, triggers, sticks, chords, and keyboard/mouse-button bindings — everything
    /// except trackpad/stick continuous pointer motion (see `applyPointerMotion`). Split
    /// out so a caller can suppress just the pointer half (e.g. while a "hold to use the
    /// local cursor instead" modifier is held) without losing button/gamepad forwarding.
    public mutating func applyDiscreteControls(profile: SteamControllerMappingProfile,
                                                snapshot: SteamControllerInputSnapshot,
                                                deviceID: InputDeviceID,
                                                playerIndex: Int,
                                                now: ContinuousClock.Instant,
                                                timestamp: MediaTimestamp) -> SteamControllerBindingResult {
        let active = Self.activeControls(snapshot: snapshot)
        updateHoldInstants(active: active, now: now)

        var outputButtons: GamepadButtons = []
        var leftTriggerPulled = false
        var rightTriggerPulled = false
        var nextReapplyDelay: Duration?
        var events: [UserInputEvent] = []

        for control in SteamControllerControl.allCases {
            let isActive = active.contains(control)
            let wasActive = previousActiveControls.contains(control)
            switch profile.binding(for: control) {
            case .passthroughButton:
                if isActive, let bit = control.gamepadButton {
                    outputButtons.insert(bit)
                }

            case .disabled:
                break

            case .gamepadChord(let combo):
                guard isActive else { continue }
                let modifiers = combo.buttons.intersection(Self.chordModifierButtons)
                let actionButtons = combo.buttons.subtracting(modifiers)
                outputButtons.formUnion(modifiers)
                leftTriggerPulled = leftTriggerPulled || combo.leftTrigger
                rightTriggerPulled = rightTriggerPulled || combo.rightTrigger
                guard !actionButtons.isEmpty else { continue }
                let hasModifierPhase = combo.leftTrigger || combo.rightTrigger || !modifiers.isEmpty
                let held = holdInstants[control].map { now - $0 } ?? .zero
                if !hasModifierPhase || held >= Self.modifierLeadTime {
                    outputButtons.formUnion(actionButtons)
                } else {
                    let remaining = Self.modifierLeadTime - held
                    nextReapplyDelay = nextReapplyDelay.map { min($0, remaining) } ?? remaining
                }

            case .keyboardKey(let keyCode, let modifiers):
                guard isActive != wasActive else { continue }
                events.append(.keyboard(KeyboardEvent(
                    deviceID: deviceID, keyCode: keyCode, scanCode: keyCode,
                    modifiers: modifiers, isPressed: isActive, timestamp: timestamp
                )))

            case .mouseButton(let button):
                guard isActive != wasActive else { continue }
                events.append(.mouse(.button(deviceID: deviceID, button: button, isPressed: isActive, timestamp: timestamp)))

            case .mouseScroll(let delta):
                guard isActive, !wasActive else { continue }
                events.append(.mouse(.wheel(deviceID: deviceID, delta: delta, timestamp: timestamp)))
            }
        }
        if snapshot.buttons.contains(.quickAccess) { outputButtons.insert(.quickAccess) }
        previousActiveControls = active

        let leftTrigger = leftTriggerPulled ? 1 : (Self.consumesTrigger(profile.binding(for: .leftTrigger)) ? 0 : snapshot.leftTrigger)
        let rightTrigger = rightTriggerPulled ? 1 : (Self.consumesTrigger(profile.binding(for: .rightTrigger)) ? 0 : snapshot.rightTrigger)
        let leftStickPassthrough = profile.leftStick.mode == .joystickPassthrough
        let rightStickPassthrough = profile.rightStick.mode == .joystickPassthrough

        events.append(.gamepad(GamepadState(
            deviceID: deviceID,
            playerIndex: playerIndex,
            buttons: outputButtons,
            leftTrigger: leftTrigger,
            rightTrigger: rightTrigger,
            leftStickX: leftStickPassthrough ? snapshot.leftStickX : 0,
            leftStickY: leftStickPassthrough ? snapshot.leftStickY : 0,
            rightStickX: rightStickPassthrough ? snapshot.rightStickX : 0,
            rightStickY: rightStickPassthrough ? snapshot.rightStickY : 0,
            timestamp: timestamp
        )))

        return SteamControllerBindingResult(events: events, nextReapplyDelay: nextReapplyDelay)
    }

    /// Trackpad/stick continuous pointer motion (mouse-move or scroll-wheel), driven by
    /// each control's `SteamControllerPadSettings`. Stateful per pad/stick — call once per
    /// input report, same as `applyDiscreteControls`.
    public mutating func applyPointerMotion(profile: SteamControllerMappingProfile,
                                             snapshot: SteamControllerInputSnapshot,
                                             deviceID: InputDeviceID,
                                             timestamp: MediaTimestamp) -> [UserInputEvent] {
        var events: [UserInputEvent] = []
        events.append(contentsOf: Self.pointerEvents(
            leftPadTranslator.translate(snapshot.leftPad, settings: profile.leftPad),
            deviceID: deviceID, timestamp: timestamp
        ))
        events.append(contentsOf: Self.pointerEvents(
            rightPadTranslator.translate(snapshot.rightPad, settings: profile.rightPad),
            deviceID: deviceID, timestamp: timestamp
        ))
        if profile.leftStick.mode != .joystickPassthrough {
            events.append(contentsOf: Self.pointerEvents(
                leftStickTranslator.translate(x: snapshot.leftStickX, y: snapshot.leftStickY, settings: profile.leftStick),
                deviceID: deviceID, timestamp: timestamp
            ))
        }
        if profile.rightStick.mode != .joystickPassthrough {
            events.append(contentsOf: Self.pointerEvents(
                rightStickTranslator.translate(x: snapshot.rightStickX, y: snapshot.rightStickY, settings: profile.rightStick),
                deviceID: deviceID, timestamp: timestamp
            ))
        }
        return events
    }

    public mutating func apply(profile: SteamControllerMappingProfile,
                                snapshot: SteamControllerInputSnapshot,
                                deviceID: InputDeviceID,
                                playerIndex: Int,
                                now: ContinuousClock.Instant,
                                timestamp: MediaTimestamp) -> SteamControllerBindingResult {
        var result = applyDiscreteControls(profile: profile, snapshot: snapshot, deviceID: deviceID, playerIndex: playerIndex, now: now, timestamp: timestamp)
        result.events.append(contentsOf: applyPointerMotion(profile: profile, snapshot: snapshot, deviceID: deviceID, timestamp: timestamp))
        return result
    }

    private mutating func updateHoldInstants(active: Set<SteamControllerControl>, now: ContinuousClock.Instant) {
        for control in active where holdInstants[control] == nil {
            holdInstants[control] = now
        }
        for control in Array(holdInstants.keys) where !active.contains(control) {
            holdInstants.removeValue(forKey: control)
        }
    }

    private static func activeControls(snapshot: SteamControllerInputSnapshot) -> Set<SteamControllerControl> {
        var active: Set<SteamControllerControl> = []
        for control in SteamControllerControl.allCases {
            if let bit = control.gamepadButton, snapshot.buttons.contains(bit) {
                active.insert(control)
            }
        }
        if snapshot.leftTrigger > Self.triggerActiveThreshold { active.insert(.leftTrigger) }
        if snapshot.rightTrigger > Self.triggerActiveThreshold { active.insert(.rightTrigger) }
        if snapshot.leftPad.pressed { active.insert(.leftPadClick) }
        if snapshot.rightPad.pressed { active.insert(.rightPadClick) }
        return active
    }

    private static func consumesTrigger(_ target: SteamControllerBindingTarget) -> Bool {
        switch target {
        case .passthroughButton: false
        default: true
        }
    }

    private static func pointerEvents(_ actions: SteamControllerPointerActions, deviceID: InputDeviceID, timestamp: MediaTimestamp) -> [UserInputEvent] {
        guard !actions.isEmpty else { return [] }
        var events: [UserInputEvent] = []
        if actions.moveDeltaX != 0 || actions.moveDeltaY != 0 {
            events.append(.mouse(.moved(deviceID: deviceID, deltaX: actions.moveDeltaX, deltaY: actions.moveDeltaY, timestamp: timestamp)))
        }
        if actions.wheelDelta != 0 {
            events.append(.mouse(.wheel(deviceID: deviceID, delta: actions.wheelDelta, timestamp: timestamp)))
        }
        return events
    }
}
