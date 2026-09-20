import Foundation

public struct ControllerBindingResult: Sendable {
    public var events: [UserInputEvent] = []
    public var nextReapplyDelay: Duration?
}

/// Turns a raw `ControllerInputSnapshot` into the events the stream actually sees,
/// according to a `ControllerMappingProfile`. Replaces the old fixed 1:1 button
/// passthrough, the grip-only chord mapper, and the global trackpad-mouse toggle with one
/// per-device engine that covers every control.
public struct ControllerBindingEngine: Sendable {
    public static let modifierLeadTime: Duration = .milliseconds(50)
    private static let chordModifierButtons: GamepadButtons = [.leftShoulder, .rightShoulder]
    static let triggerActiveThreshold: Float = 0.5
    /// Report interval assumed for the very first gyro step, before two instants have been seen.
    private static let assumedReportInterval: Float = 1.0 / 120.0

    private var previousActiveControls: Set<ControllerControl> = []
    private var holdInstants: [ControllerControl: ContinuousClock.Instant] = [:]
    private var leftPadTranslator = ControllerPadPointerTranslator()
    private var rightPadTranslator = ControllerPadPointerTranslator()
    private var leftStickTranslator = ControllerStickPointerTranslator()
    private var rightStickTranslator = ControllerStickPointerTranslator()
    private var touchpadTranslator = ControllerPadPointerTranslator()
    private var previousProfile: ControllerMappingProfile?
    private var heldKeys: [UInt16: KeyboardModifiers] = [:]
    private var heldMouseButtons: Set<MouseButton> = []
    private var gyroProcessor = GyroProcessor()
    private var flickStickProcessor = FlickStickProcessor()
    private var gyroActivation = GyroActivationState()
    private var previousReportInstant: ContinuousClock.Instant?

    public init() {}

    /// The bias the gyro pipeline is currently using, or `nil` before it has seen a sample.
    public var gyroBias: SIMD3<Float> { gyroProcessor.currentBias }

    /// Buttons, triggers, sticks, chords, and keyboard/mouse-button bindings — everything
    /// except trackpad/stick continuous pointer motion (see `applyPointerMotion`). Split
    /// out so a caller can suppress just the pointer half (e.g. while a "hold to use the
    /// local cursor instead" modifier is held) without losing button/gamepad forwarding.
    public mutating func applyDiscreteControls(profile: ControllerMappingProfile,
                                                snapshot: ControllerInputSnapshot,
                                                deviceID: InputDeviceID,
                                                playerIndex: Int,
                                                now: ContinuousClock.Instant,
                                                timestamp: MediaTimestamp,
                                                includePointerMotion: Bool = true) -> ControllerBindingResult {
        var releases: [UserInputEvent] = []
        if let previousProfile, previousProfile != profile {
            releases = reset(deviceID: deviceID, playerIndex: playerIndex, timestamp: timestamp)
        }
        previousProfile = profile
        let active = ControllerControlState.active(in: snapshot)
        updateHoldInstants(active: active, now: now)
        let gyroOutput = processGyroMotion(profile: profile,
                                           snapshot: snapshot,
                                           activeControls: active,
                                           now: now)

        var pass = DiscretePass()
        let controlledButtons = profile.family.controls.reduce(into: GamepadButtons()) {
            if let button = $1.gamepadButton { $0.formUnion(button) }
        }
        pass.buttons = snapshot.buttons.subtracting(controlledButtons)
        if profile.family == .steam { pass.buttons.remove(.mode) }
        for control in profile.family.controls {
            apply(binding: profile.binding(for: control),
                  control: control,
                  isActive: active.contains(control),
                  wasActive: previousActiveControls.contains(control),
                  deviceID: deviceID,
                  now: now,
                  timestamp: timestamp,
                  into: &pass)
        }
        pass.events = releases + outputTransitions(keys: pass.keys, mouseButtons: pass.mouseButtons, deviceID: deviceID, timestamp: timestamp) + pass.events
        previousActiveControls = active

        let leftTrigger = pass.leftTriggerPulled ? 1 : (Self.consumesTrigger(profile.binding(for: .leftTrigger)) ? 0 : snapshot.leftTrigger)
        let rightTrigger = pass.rightTriggerPulled ? 1 : (Self.consumesTrigger(profile.binding(for: .rightTrigger)) ? 0 : snapshot.rightTrigger)
        let leftStickPassthrough = profile.leftStick.mode == .joystickPassthrough
        let rightStickPassthrough = profile.rightStick.mode == .joystickPassthrough

        if includePointerMotion, !gyroOutput.pointer.isEmpty {
            pass.events.append(contentsOf: Self.pointerEvents(gyroOutput.pointer, deviceID: deviceID, timestamp: timestamp))
        }

        // Gyro stick output is summed into the forwarded stick rather than replacing it: the two
        // share one axis on the wire, so a game must see their combined deflection or a physical
        // stick push would erase the gyro's contribution.
        let forwardedRightStickX = rightStickPassthrough ? snapshot.rightStickX : 0
        let forwardedRightStickY = rightStickPassthrough ? snapshot.rightStickY : 0

        pass.events.append(.gamepad(GamepadState(
            deviceID: deviceID,
            playerIndex: playerIndex,
            buttons: pass.buttons,
            leftTrigger: leftTrigger,
            rightTrigger: rightTrigger,
            leftStickX: leftStickPassthrough ? snapshot.leftStickX : 0,
            leftStickY: leftStickPassthrough ? snapshot.leftStickY : 0,
            rightStickX: Self.clampAxis(forwardedRightStickX + gyroOutput.stickX),
            rightStickY: Self.clampAxis(forwardedRightStickY + gyroOutput.stickY),
            timestamp: timestamp
        )))

        return ControllerBindingResult(events: pass.events, nextReapplyDelay: pass.nextReapplyDelay)
    }

    /// What one discrete pass accumulates while walking the controls.
    private struct DiscretePass {
        var buttons: GamepadButtons = []
        var leftTriggerPulled = false
        var rightTriggerPulled = false
        var nextReapplyDelay: Duration?
        var events: [UserInputEvent] = []
        var keys: [UInt16: KeyboardModifiers] = [:]
        var mouseButtons: Set<MouseButton> = []
    }

    /// Folds one control's binding into the pass.
    private func apply(binding: ControllerBindingTarget,
                       control: ControllerControl,
                       isActive: Bool,
                       wasActive: Bool,
                       deviceID: InputDeviceID,
                       now: ContinuousClock.Instant,
                       timestamp: MediaTimestamp,
                       into pass: inout DiscretePass) {
        switch binding {
        case .passthroughButton:
            if isActive, let bit = control.gamepadButton {
                pass.buttons.insert(bit)
            }

        case .disabled:
            break

        case .gamepadChord(let combo):
            guard isActive else { return }
            apply(chord: combo, control: control, now: now, into: &pass)

        case .keyboardKey(let keyCode, let modifiers):
            if isActive { pass.keys[keyCode, default: []].formUnion(modifiers) }

        case .mouseButton(let button):
            if isActive { pass.mouseButtons.insert(button) }

        case .mouseScroll(let delta):
            guard isActive, !wasActive else { return }
            pass.events.append(.mouse(.wheel(deviceID: deviceID, delta: delta, timestamp: timestamp)))
        }
    }

    /// A chord's modifiers go down first; the action buttons follow only once the modifier lead
    /// time has elapsed, and the caller is asked to reapply when it has not.
    private func apply(chord combo: ControllerButtonChord,
                       control: ControllerControl,
                       now: ContinuousClock.Instant,
                       into pass: inout DiscretePass) {
        let modifiers = combo.buttons.intersection(Self.chordModifierButtons)
        let actionButtons = combo.buttons.subtracting(modifiers)
        pass.buttons.formUnion(modifiers)
        pass.leftTriggerPulled = pass.leftTriggerPulled || combo.leftTrigger
        pass.rightTriggerPulled = pass.rightTriggerPulled || combo.rightTrigger
        guard !actionButtons.isEmpty else { return }
        let hasModifierPhase = combo.leftTrigger || combo.rightTrigger || !modifiers.isEmpty
        let held = holdInstants[control].map { now - $0 } ?? .zero
        if !hasModifierPhase || held >= Self.modifierLeadTime {
            pass.buttons.formUnion(actionButtons)
        } else {
            let remaining = Self.modifierLeadTime - held
            pass.nextReapplyDelay = pass.nextReapplyDelay.map { min($0, remaining) } ?? remaining
        }
    }

    /// Trackpad/stick continuous pointer motion (mouse-move or scroll-wheel), driven by
    /// each control's `ControllerPadSettings`. Stateful per pad/stick — call once per
    /// input report, same as `applyDiscreteControls`.
    public mutating func applyPointerMotion(profile: ControllerMappingProfile,
                                             snapshot: ControllerInputSnapshot,
                                             deviceID: InputDeviceID,
                                             timestamp: MediaTimestamp) -> [UserInputEvent] {
        var events: [UserInputEvent] = []
        if profile.family == .dualShock4 {
            events.append(contentsOf: Self.pointerEvents(
                touchpadTranslator.translate(snapshot.touchpad ?? ControllerTrackpadState(), settings: profile.touchpad),
                deviceID: deviceID, timestamp: timestamp
            ))
        }
        if profile.family == .steam {
            events.append(contentsOf: Self.pointerEvents(
                leftPadTranslator.translate(snapshot.leftPad, settings: profile.leftPad),
                deviceID: deviceID, timestamp: timestamp
            ))
            events.append(contentsOf: Self.pointerEvents(
                rightPadTranslator.translate(snapshot.rightPad, settings: profile.rightPad),
                deviceID: deviceID, timestamp: timestamp
            ))
        }
        if profile.leftStick.mode != .joystickPassthrough {
            events.append(contentsOf: Self.pointerEvents(
                leftStickTranslator.translate(x: snapshot.leftStickX, y: snapshot.leftStickY, settings: profile.leftStick),
                deviceID: deviceID, timestamp: timestamp
            ))
        }
        switch profile.rightStick.mode {
        case .flickStick:
            events.append(contentsOf: Self.pointerEvents(
                flickStickProcessor.process(stickX: snapshot.rightStickX,
                                            stickY: snapshot.rightStickY,
                                            settings: profile.gyro),
                deviceID: deviceID, timestamp: timestamp
            ))
        case .joystickPassthrough, .disabled:
            break
        case .mouse, .scrollWheel:
            events.append(contentsOf: Self.pointerEvents(
                rightStickTranslator.translate(x: snapshot.rightStickX, y: snapshot.rightStickY, settings: profile.rightStick),
                deviceID: deviceID, timestamp: timestamp
            ))
        }
        return events
    }

    public mutating func apply(profile: ControllerMappingProfile,
                                snapshot: ControllerInputSnapshot,
                                deviceID: InputDeviceID,
                                playerIndex: Int,
                                now: ContinuousClock.Instant,
                                timestamp: MediaTimestamp) -> ControllerBindingResult {
        var result = applyDiscreteControls(profile: profile, snapshot: snapshot, deviceID: deviceID, playerIndex: playerIndex, now: now, timestamp: timestamp)
        result.events.append(contentsOf: applyPointerMotion(profile: profile, snapshot: snapshot, deviceID: deviceID, timestamp: timestamp))
        return result
    }

    public mutating func reset(deviceID: InputDeviceID, playerIndex: Int, timestamp: MediaTimestamp) -> [UserInputEvent] {
        var events = outputTransitions(keys: [:], mouseButtons: [], deviceID: deviceID, timestamp: timestamp)
        events.append(.gamepad(GamepadState(deviceID: deviceID, playerIndex: playerIndex, buttons: [],
                                           leftTrigger: 0, rightTrigger: 0, leftStickX: 0, leftStickY: 0,
                                           rightStickX: 0, rightStickY: 0, timestamp: timestamp)))
        self = ControllerBindingEngine()
        return events
    }

    private mutating func outputTransitions(keys: [UInt16: KeyboardModifiers], mouseButtons: Set<MouseButton>,
                                             deviceID: InputDeviceID, timestamp: MediaTimestamp) -> [UserInputEvent] {
        var events: [UserInputEvent] = []
        for key in heldKeys.keys.sorted() where keys[key] != heldKeys[key] {
            events.append(.keyboard(KeyboardEvent(deviceID: deviceID, keyCode: key, scanCode: key,
                                                  modifiers: heldKeys[key] ?? [], isPressed: false, timestamp: timestamp)))
        }
        for key in keys.keys.sorted() where heldKeys[key] != keys[key] {
            events.append(.keyboard(KeyboardEvent(deviceID: deviceID, keyCode: key, scanCode: key,
                                                  modifiers: keys[key] ?? [], isPressed: true, timestamp: timestamp)))
        }
        for button in heldMouseButtons.subtracting(mouseButtons).sorted(by: { $0.rawValue < $1.rawValue }) {
            events.append(.mouse(.button(deviceID: deviceID, button: button, isPressed: false, timestamp: timestamp)))
        }
        for button in mouseButtons.subtracting(heldMouseButtons).sorted(by: { $0.rawValue < $1.rawValue }) {
            events.append(.mouse(.button(deviceID: deviceID, button: button, isPressed: true, timestamp: timestamp)))
        }
        heldKeys = keys
        heldMouseButtons = mouseButtons
        return events
    }

    private mutating func updateHoldInstants(active: Set<ControllerControl>, now: ContinuousClock.Instant) {
        for control in active where holdInstants[control] == nil {
            holdInstants[control] = now
        }
        for control in Array(holdInstants.keys) where !active.contains(control) {
            holdInstants.removeValue(forKey: control)
        }
    }

    /// Advances the gyro pipeline one report and returns both its halves.
    ///
    /// Runs even when gyro is off, because the activation latch and the filters must follow the
    /// input either way — otherwise switching gyro on mid-session would start from a stale latch.
    private mutating func processGyroMotion(profile: ControllerMappingProfile,
                                            snapshot: ControllerInputSnapshot,
                                            activeControls: Set<ControllerControl>,
                                            now: ContinuousClock.Instant) -> GyroMotionOutput {
        let settings = profile.gyro
        let deltaTime = reportDeltaTime(now: now)
        let isActive = gyroActivation.update(style: settings.activationStyle,
                                             source: settings.activationSource,
                                             snapshot: snapshot,
                                             activeControls: activeControls,
                                             deltaTime: deltaTime)
        return gyroProcessor.process(snapshot.motion,
                                     settings: settings,
                                     isActive: isActive,
                                     deltaTime: deltaTime)
    }

    private mutating func reportDeltaTime(now: ContinuousClock.Instant) -> Float {
        defer { previousReportInstant = now }
        guard let previous = previousReportInstant else { return Self.assumedReportInterval }
        let elapsed = now - previous
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return Float(min(max(seconds, 1.0 / 1000.0), 0.05))
    }

    private static func clampAxis(_ value: Float) -> Float {
        min(1, max(-1, value))
    }

    private static func consumesTrigger(_ target: ControllerBindingTarget) -> Bool {
        switch target {
        case .passthroughButton: false
        default: true
        }
    }

    private static func pointerEvents(_ actions: ControllerPointerActions, deviceID: InputDeviceID, timestamp: MediaTimestamp) -> [UserInputEvent] {
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
