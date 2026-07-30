import Foundation

public enum SteamControllerGripButton: String, Codable, CaseIterable, Identifiable, Sendable {
    case l4
    case l5
    case r4
    case r5

    public var id: String { rawValue }

    public var label: String { rawValue.uppercased() }

    public var gamepadButton: GamepadButtons {
        switch self {
        case .l4: .leftGrip
        case .l5: .leftGrip2
        case .r4: .rightGrip
        case .r5: .rightGrip2
        }
    }
}

public struct SteamControllerGripCombo: Codable, Equatable, Sendable {
    public var buttons: GamepadButtons
    public var leftTrigger: Bool
    public var rightTrigger: Bool

    public init(buttons: GamepadButtons = [], leftTrigger: Bool = false, rightTrigger: Bool = false) {
        self.buttons = buttons.intersection(SteamControllerGripComboTarget.assignableButtons)
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
    }

    public var isEmpty: Bool {
        buttons.isEmpty && !leftTrigger && !rightTrigger
    }

    public func contains(_ element: SteamControllerGripComboElement) -> Bool {
        switch element {
        case .button(let button): buttons.contains(button)
        case .leftTrigger: leftTrigger
        case .rightTrigger: rightTrigger
        }
    }

    public mutating func toggle(_ element: SteamControllerGripComboElement) {
        switch element {
        case .button(let button):
            if buttons.contains(button) {
                buttons.remove(button)
            } else {
                buttons.formUnion(button)
            }
        case .leftTrigger:
            leftTrigger.toggle()
        case .rightTrigger:
            rightTrigger.toggle()
        }
    }
}

public enum SteamControllerGripComboElement: Equatable, Sendable {
    case button(GamepadButtons)
    case leftTrigger
    case rightTrigger
}

public struct SteamControllerGripComboTarget: Equatable, Identifiable, Sendable {
    public let label: String
    public let element: SteamControllerGripComboElement

    public var id: String { label }

    public static let all: [SteamControllerGripComboTarget] = [
        SteamControllerGripComboTarget(label: "A", element: .button(.south)),
        SteamControllerGripComboTarget(label: "B", element: .button(.east)),
        SteamControllerGripComboTarget(label: "X", element: .button(.west)),
        SteamControllerGripComboTarget(label: "Y", element: .button(.north)),
        SteamControllerGripComboTarget(label: "L1", element: .button(.leftShoulder)),
        SteamControllerGripComboTarget(label: "R1", element: .button(.rightShoulder)),
        SteamControllerGripComboTarget(label: "L2", element: .leftTrigger),
        SteamControllerGripComboTarget(label: "R2", element: .rightTrigger),
        SteamControllerGripComboTarget(label: "L3", element: .button(.leftStick)),
        SteamControllerGripComboTarget(label: "R3", element: .button(.rightStick)),
        SteamControllerGripComboTarget(label: "D-Up", element: .button(.dpadUp)),
        SteamControllerGripComboTarget(label: "D-Down", element: .button(.dpadDown)),
        SteamControllerGripComboTarget(label: "D-Left", element: .button(.dpadLeft)),
        SteamControllerGripComboTarget(label: "D-Right", element: .button(.dpadRight)),
        SteamControllerGripComboTarget(label: "Start", element: .button(.start)),
        SteamControllerGripComboTarget(label: "Select", element: .button(.select)),
    ]

    public static let assignableButtons: GamepadButtons = all.reduce(into: []) { result, target in
        if case .button(let button) = target.element {
            result.formUnion(button)
        }
    }

    public static func comboLabel(for combo: SteamControllerGripCombo) -> String {
        let parts = all.filter { combo.contains($0.element) }.map(\.label)
        return parts.isEmpty ? "Unassigned" : parts.joined(separator: " + ")
    }
}

public struct SteamControllerGripProfile: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var combos: [SteamControllerGripButton: SteamControllerGripCombo]

    public init(id: UUID = UUID(), name: String, combos: [SteamControllerGripButton: SteamControllerGripCombo] = [:]) {
        self.id = id
        self.name = name
        self.combos = combos
    }

    public func combo(for grip: SteamControllerGripButton) -> SteamControllerGripCombo {
        combos[grip] ?? SteamControllerGripCombo()
    }
}

extension SteamControllerGripProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case combos
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let rawCombos: [String: SteamControllerGripCombo]
        if let current = try? container.decodeIfPresent([String: SteamControllerGripCombo].self, forKey: .combos) {
            rawCombos = current
        } else if let legacy = try? container.decodeIfPresent([String: GamepadButtons].self, forKey: .combos) {
            rawCombos = legacy.mapValues { SteamControllerGripCombo(buttons: $0) }
        } else {
            rawCombos = [:]
        }
        combos = rawCombos.reduce(into: [:]) { result, entry in
            guard let grip = SteamControllerGripButton(rawValue: entry.key), !entry.value.isEmpty else { return }
            result[grip] = entry.value
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        let rawCombos = Dictionary(uniqueKeysWithValues: combos.map { ($0.key.rawValue, $0.value) })
        try container.encode(rawCombos, forKey: .combos)
    }
}

public struct SteamControllerGripMapResult: Equatable, Sendable {
    public let buttons: GamepadButtons
    public let leftTriggerPulled: Bool
    public let rightTriggerPulled: Bool
    public let nextTransition: Duration?
}

public enum SteamControllerGripMapper {
    public static let modifierLeadTime: Duration = .milliseconds(50)
    public static let chordModifierButtons: GamepadButtons = [.leftShoulder, .rightShoulder]

    public static func apply(combos: [SteamControllerGripButton: SteamControllerGripCombo],
                             to buttons: GamepadButtons,
                             gripHoldDurations: [SteamControllerGripButton: Duration]) -> SteamControllerGripMapResult {
        var result = buttons
        var leftTriggerPulled = false
        var rightTriggerPulled = false
        var nextTransition: Duration?
        for (grip, combo) in combos where buttons.contains(grip.gamepadButton) {
            let modifiers = combo.buttons.intersection(Self.chordModifierButtons)
            let actions = combo.buttons.subtracting(modifiers)
            result.formUnion(modifiers)
            leftTriggerPulled = leftTriggerPulled || combo.leftTrigger
            rightTriggerPulled = rightTriggerPulled || combo.rightTrigger
            guard !actions.isEmpty else { continue }
            let hasModifierPhase = combo.leftTrigger || combo.rightTrigger || !modifiers.isEmpty
            let held = gripHoldDurations[grip] ?? .zero
            if !hasModifierPhase || held >= Self.modifierLeadTime {
                result.formUnion(actions)
            } else {
                let remaining = Self.modifierLeadTime - held
                nextTransition = nextTransition.map { min($0, remaining) } ?? remaining
            }
        }
        return SteamControllerGripMapResult(
            buttons: result,
            leftTriggerPulled: leftTriggerPulled,
            rightTriggerPulled: rightTriggerPulled,
            nextTransition: nextTransition
        )
    }
}
