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

public struct SteamControllerGripProfile: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var combos: [SteamControllerGripButton: ControllerButtonChord]

    public init(id: UUID = UUID(), name: String, combos: [SteamControllerGripButton: ControllerButtonChord] = [:]) {
        self.id = id
        self.name = name
        self.combos = combos
    }

    public func combo(for grip: SteamControllerGripButton) -> ControllerButtonChord {
        combos[grip] ?? ControllerButtonChord()
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
        let rawCombos: [String: ControllerButtonChord]
        if let current = try? container.decodeIfPresent([String: ControllerButtonChord].self, forKey: .combos) {
            rawCombos = current
        } else if let legacy = try? container.decodeIfPresent([String: GamepadButtons].self, forKey: .combos) {
            rawCombos = legacy.mapValues { ControllerButtonChord(buttons: $0) }
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

