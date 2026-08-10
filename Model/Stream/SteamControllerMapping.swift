import Foundation

/// Every physical control on the controller that can be bound to a keyboard key, mouse
/// action, or gamepad-button chord. Continuous controls (trackpads, sticks) additionally
/// get a `SteamControllerPadSettings` behavior instead of (or alongside) a discrete
/// binding — see `SteamControllerMappingProfile`.
public enum SteamControllerControl: String, Codable, CaseIterable, Identifiable, Sendable {
    case faceA, faceB, faceX, faceY
    case leftShoulder, rightShoulder
    case leftTrigger, rightTrigger
    case leftStickClick, rightStickClick
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case leftGrip, leftGrip2, rightGrip, rightGrip2
    case select, start
    case leftPadClick, rightPadClick

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .faceA: "A"
        case .faceB: "B"
        case .faceX: "X"
        case .faceY: "Y"
        case .leftShoulder: "L1"
        case .rightShoulder: "R1"
        case .leftTrigger: "L2"
        case .rightTrigger: "R2"
        case .leftStickClick: "L3"
        case .rightStickClick: "R3"
        case .dpadUp: "D-Up"
        case .dpadDown: "D-Down"
        case .dpadLeft: "D-Left"
        case .dpadRight: "D-Right"
        case .leftGrip: "L4"
        case .leftGrip2: "L5"
        case .rightGrip: "R4"
        case .rightGrip2: "R5"
        case .select: "Select"
        case .start: "Start"
        case .leftPadClick: "L. Pad Click"
        case .rightPadClick: "R. Pad Click"
        }
    }

    public var category: SteamControllerMappingCategory {
        switch self {
        case .faceA, .faceB, .faceX, .faceY, .leftShoulder, .rightShoulder,
             .leftGrip, .leftGrip2, .rightGrip, .rightGrip2, .select, .start:
            .buttons
        case .dpadUp, .dpadDown, .dpadLeft, .dpadRight:
            .dpad
        case .leftTrigger, .rightTrigger:
            .triggers
        case .leftStickClick, .rightStickClick:
            .joysticks
        case .leftPadClick, .rightPadClick:
            .trackpads
        }
    }

    /// The native bit this control forwards when its binding is `.passthroughButton`.
    /// `nil` for triggers (analog passthrough instead) and pad clicks (no native bit —
    /// see the migration defaults in `SteamControllerMappingProfile`).
    public var gamepadButton: GamepadButtons? {
        switch self {
        case .faceA: .south
        case .faceB: .east
        case .faceX: .west
        case .faceY: .north
        case .leftShoulder: .leftShoulder
        case .rightShoulder: .rightShoulder
        case .leftStickClick: .leftStick
        case .rightStickClick: .rightStick
        case .dpadUp: .dpadUp
        case .dpadDown: .dpadDown
        case .dpadLeft: .dpadLeft
        case .dpadRight: .dpadRight
        case .leftGrip: .leftGrip
        case .leftGrip2: .leftGrip2
        case .rightGrip: .rightGrip
        case .rightGrip2: .rightGrip2
        case .select: .select
        case .start: .start
        case .leftTrigger, .rightTrigger, .leftPadClick, .rightPadClick:
            nil
        }
    }
}

public enum SteamControllerMappingCategory: String, CaseIterable, Identifiable, Sendable {
    case buttons, dpad, triggers, joysticks, trackpads

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .buttons: "Buttons"
        case .dpad: "D-Pad"
        case .triggers: "Triggers"
        case .joysticks: "Joysticks"
        case .trackpads: "Trackpads"
        }
    }

    public var systemImage: String {
        switch self {
        case .buttons: "circle.grid.2x2"
        case .dpad: "plus.square"
        case .triggers: "arrow.down.to.line"
        case .joysticks: "circle.circle"
        case .trackpads: "rectangle.on.rectangle"
        }
    }
}

/// What a discrete control does when it's pressed. `.passthroughButton` reproduces
/// today's default (forward the control's own native bit, or its raw analog value for
/// triggers); every other case consumes the press instead of forwarding it.
public enum SteamControllerBindingTarget: Equatable, Sendable {
    case passthroughButton
    case gamepadChord(SteamControllerGripCombo)
    case keyboardKey(keyCode: UInt16, modifiers: KeyboardModifiers)
    case mouseButton(MouseButton)
    case mouseScroll(Int16)
    case disabled
}

extension SteamControllerBindingTarget: Codable {
    private enum Kind: String, Codable {
        case passthroughButton, gamepadChord, keyboardKey, mouseButton, mouseScroll, disabled
    }

    private enum CodingKeys: String, CodingKey {
        case kind, combo, keyCode, modifiers, mouseButton, scrollDelta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .passthroughButton:
            self = .passthroughButton
        case .gamepadChord:
            self = .gamepadChord(try container.decode(SteamControllerGripCombo.self, forKey: .combo))
        case .keyboardKey:
            self = .keyboardKey(
                keyCode: try container.decode(UInt16.self, forKey: .keyCode),
                modifiers: try container.decodeIfPresent(KeyboardModifiers.self, forKey: .modifiers) ?? []
            )
        case .mouseButton:
            self = .mouseButton(try container.decode(MouseButton.self, forKey: .mouseButton))
        case .mouseScroll:
            self = .mouseScroll(try container.decode(Int16.self, forKey: .scrollDelta))
        case .disabled:
            self = .disabled
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .passthroughButton:
            try container.encode(Kind.passthroughButton, forKey: .kind)
        case .gamepadChord(let combo):
            try container.encode(Kind.gamepadChord, forKey: .kind)
            try container.encode(combo, forKey: .combo)
        case .keyboardKey(let keyCode, let modifiers):
            try container.encode(Kind.keyboardKey, forKey: .kind)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifiers, forKey: .modifiers)
        case .mouseButton(let button):
            try container.encode(Kind.mouseButton, forKey: .kind)
            try container.encode(button, forKey: .mouseButton)
        case .mouseScroll(let delta):
            try container.encode(Kind.mouseScroll, forKey: .kind)
            try container.encode(delta, forKey: .scrollDelta)
        case .disabled:
            try container.encode(Kind.disabled, forKey: .kind)
        }
    }
}

/// Continuous-motion behavior for a trackpad or stick.
public enum SteamControllerPointerMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Sticks only: forward the raw analog axis to the game, unchanged (today's default).
    case joystickPassthrough
    case mouse
    case scrollWheel
    case disabled

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .joystickPassthrough: "Joystick"
        case .mouse: "Mouse"
        case .scrollWheel: "Scroll Wheel"
        case .disabled: "Disabled"
        }
    }
}

public struct SteamControllerPadSettings: Equatable, Codable, Sendable {
    public var mode: SteamControllerPointerMode
    public var sensitivity: Float
    public var invertY: Bool

    public init(mode: SteamControllerPointerMode, sensitivity: Float = 1.0, invertY: Bool = false) {
        self.mode = mode
        self.sensitivity = max(0.1, min(4.0, sensitivity))
        self.invertY = invertY
    }
}

public struct SteamControllerMappingProfile: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var bindings: [SteamControllerControl: SteamControllerBindingTarget]
    public var leftPad: SteamControllerPadSettings
    public var rightPad: SteamControllerPadSettings
    public var leftStick: SteamControllerPadSettings
    public var rightStick: SteamControllerPadSettings

    public init(id: UUID = UUID(),
                name: String,
                bindings: [SteamControllerControl: SteamControllerBindingTarget] = [:],
                leftPad: SteamControllerPadSettings = SteamControllerPadSettings(mode: .disabled),
                rightPad: SteamControllerPadSettings = SteamControllerPadSettings(mode: .disabled),
                leftStick: SteamControllerPadSettings = SteamControllerPadSettings(mode: .joystickPassthrough),
                rightStick: SteamControllerPadSettings = SteamControllerPadSettings(mode: .joystickPassthrough)) {
        self.id = id
        self.name = name
        self.bindings = bindings
        self.leftPad = leftPad
        self.rightPad = rightPad
        self.leftStick = leftStick
        self.rightStick = rightStick
    }

    public func binding(for control: SteamControllerControl) -> SteamControllerBindingTarget {
        bindings[control] ?? .passthroughButton
    }

    /// Whether either trackpad needs raw touch reports right now — the HID monitor uses
    /// this to decide whether to seize the vendor interface (blocking the firmware's own
    /// lizard-mode mouse emulation) during a stream.
    public var wantsRawTrackpadCapture: Bool {
        [leftPad.mode, rightPad.mode].contains(.mouse) || [leftPad.mode, rightPad.mode].contains(.scrollWheel)
    }

    /// Today's shipped defaults, reproduced exactly: every button/dpad/grip/stick-click
    /// passes through as-is; trackpads mirror whatever `SteamControllerTrackpadMousePreference`
    /// was set to (on by default — right pad moves the mouse, left pad scrolls, both pads
    /// click as mouse buttons); sticks pass through as real analog axes.
    public static func migratedDefault(legacyGrips: SteamControllerGripProfile?, legacyTrackpadMouseEnabled: Bool) -> SteamControllerMappingProfile {
        var bindings: [SteamControllerControl: SteamControllerBindingTarget] = [:]
        if let legacyGrips {
            for (grip, combo) in legacyGrips.combos where !combo.isEmpty {
                bindings[grip.control] = .gamepadChord(combo)
            }
        }
        bindings[.leftPadClick] = legacyTrackpadMouseEnabled ? .mouseButton(.middle) : .disabled
        bindings[.rightPadClick] = legacyTrackpadMouseEnabled ? .mouseButton(.left) : .disabled
        return SteamControllerMappingProfile(
            id: legacyGrips?.id ?? UUID(),
            name: legacyGrips?.name ?? "Default",
            bindings: bindings,
            leftPad: SteamControllerPadSettings(mode: legacyTrackpadMouseEnabled ? .scrollWheel : .disabled),
            rightPad: SteamControllerPadSettings(mode: legacyTrackpadMouseEnabled ? .mouse : .disabled)
        )
    }
}

extension SteamControllerGripButton {
    var control: SteamControllerControl {
        switch self {
        case .l4: .leftGrip
        case .l5: .leftGrip2
        case .r4: .rightGrip
        case .r5: .rightGrip2
        }
    }
}

extension SteamControllerMappingProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, bindings, leftPad, rightPad, leftStick, rightStick
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let rawBindings = try container.decodeIfPresent([String: SteamControllerBindingTarget].self, forKey: .bindings) ?? [:]
        bindings = rawBindings.reduce(into: [:]) { result, entry in
            guard let control = SteamControllerControl(rawValue: entry.key) else { return }
            result[control] = entry.value
        }
        leftPad = try container.decodeIfPresent(SteamControllerPadSettings.self, forKey: .leftPad) ?? SteamControllerPadSettings(mode: .disabled)
        rightPad = try container.decodeIfPresent(SteamControllerPadSettings.self, forKey: .rightPad) ?? SteamControllerPadSettings(mode: .disabled)
        leftStick = try container.decodeIfPresent(SteamControllerPadSettings.self, forKey: .leftStick) ?? SteamControllerPadSettings(mode: .joystickPassthrough)
        rightStick = try container.decodeIfPresent(SteamControllerPadSettings.self, forKey: .rightStick) ?? SteamControllerPadSettings(mode: .joystickPassthrough)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        let rawBindings = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        try container.encode(rawBindings, forKey: .bindings)
        try container.encode(leftPad, forKey: .leftPad)
        try container.encode(rightPad, forKey: .rightPad)
        try container.encode(leftStick, forKey: .leftStick)
        try container.encode(rightStick, forKey: .rightStick)
    }
}
