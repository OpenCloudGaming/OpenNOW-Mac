import Foundation

/// One game's binding for one controller *type*: which saved profile a pad of that family uses
/// while the game is running. Bound by profile UUID, never a copy, so editing the profile updates
/// every game that references it.
///
/// `enabled` is retained rather than deleted when turned off: the override stays visible in
/// Settings and can be flipped back on, matching how the per-game streaming profile treats its own
/// `enabled` flag (`OPNStreamPreferences.setProfileEnabled(forGame:)`).
public struct ControllerMappingGameOverride: Equatable, Codable, Sendable {
    public var profileID: UUID
    public var enabled: Bool

    public init(profileID: UUID, enabled: Bool = true) {
        self.profileID = profileID
        self.enabled = enabled
    }
}

/// The persisted `(catalog identity × controller family)` override map.
///
/// Stored string-keyed internally so the JSON is `{ "catalogIdentity": { "steam": {…} } }` on every
/// Mac: a `ControllerFamily`-keyed dictionary would encode as an alternating array and pin the
/// shape to Swift's Codable rather than to the raw values that make it machine-independent.
public struct ControllerMappingGameOverrides: Equatable, Codable, Sendable {
    private var storage: [String: [String: ControllerMappingGameOverride]]

    public init(storage: [String: [String: ControllerMappingGameOverride]] = [:]) {
        self.storage = storage
    }

    public var isEmpty: Bool { storage.isEmpty }

    public func override(for catalogIdentity: String, family: ControllerFamily) -> ControllerMappingGameOverride? {
        storage[catalogIdentity]?[family.rawValue]
    }

    /// Passing `nil` removes that family's override, dropping the game's entry when it was the last.
    public mutating func set(_ override: ControllerMappingGameOverride?, for catalogIdentity: String, family: ControllerFamily) {
        guard !catalogIdentity.isEmpty else { return }
        var families = storage[catalogIdentity] ?? [:]
        families[family.rawValue] = override
        if families.isEmpty {
            storage.removeValue(forKey: catalogIdentity)
        } else {
            storage[catalogIdentity] = families
        }
    }

    public func families(for catalogIdentity: String) -> [ControllerFamily] {
        let raw = storage[catalogIdentity] ?? [:]
        return ControllerFamily.allCases.filter { raw[$0.rawValue] != nil }
    }

    /// Every stored override, ordered by identity then family, so a Settings list renders the same
    /// order on every read.
    public var entries: [(catalogIdentity: String, family: ControllerFamily, override: ControllerMappingGameOverride)] {
        storage.keys.sorted().flatMap { identity in
            families(for: identity).compactMap { family in
                override(for: identity, family: family).map { (identity, family, $0) }
            }
        }
    }

    /// Drops every override pointing at a deleted profile. A game with none left loses its entry.
    public mutating func removeProfile(_ id: UUID) {
        for identity in Array(storage.keys) {
            for family in families(for: identity) where storage[identity]?[family.rawValue]?.profileID == id {
                set(nil, for: identity, family: family)
            }
        }
    }
}
