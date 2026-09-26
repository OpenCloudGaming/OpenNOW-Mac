import Foundation

/// A saved profile bound to one (game, controller type) pair, by UUID so editing the profile
/// updates every game that references it.
public struct ControllerMappingGameOverride: Equatable, Codable, Sendable {
    public var profileID: UUID
    /// A disabled override is retained, stays visible in Settings, and is inert in resolution.
    public var isEnabled: Bool

    public init(profileID: UUID, isEnabled: Bool = true) {
        self.profileID = profileID
        self.isEnabled = isEnabled
    }
}

/// One stored override, addressed by game identity and controller family.
public struct ControllerMappingGameOverrideEntry: Equatable, Sendable {
    public let gameIdentity: String
    public let family: ControllerFamily
    public let gameOverride: ControllerMappingGameOverride
}

/// The persisted (catalog identity × controller family) override map. String-keyed internally so
/// the JSON stays `{ "catalogIdentity": { "steam": … } }` on every Mac.
public struct ControllerMappingGameOverrides: Equatable, Codable, Sendable {
    private var overridesByGameIdentity: [String: [String: ControllerMappingGameOverride]]

    public init(overridesByGameIdentity: [String: [String: ControllerMappingGameOverride]] = [:]) {
        self.overridesByGameIdentity = overridesByGameIdentity
    }

    public var isEmpty: Bool { overridesByGameIdentity.isEmpty }

    public func override(forGameIdentity gameIdentity: String, family: ControllerFamily) -> ControllerMappingGameOverride? {
        overridesByGameIdentity[gameIdentity]?[family.rawValue]
    }

    /// Setting `nil` removes that family's override and drops the game once it has none left.
    public mutating func setOverride(_ gameOverride: ControllerMappingGameOverride?, forGameIdentity gameIdentity: String, family: ControllerFamily) {
        guard !gameIdentity.isEmpty else { return }
        var overridesByFamily = overridesByGameIdentity[gameIdentity] ?? [:]
        overridesByFamily[family.rawValue] = gameOverride
        guard !overridesByFamily.isEmpty else {
            overridesByGameIdentity.removeValue(forKey: gameIdentity)
            return
        }
        overridesByGameIdentity[gameIdentity] = overridesByFamily
    }

    public func overriddenFamilies(forGameIdentity gameIdentity: String) -> [ControllerFamily] {
        let overridesByFamily = overridesByGameIdentity[gameIdentity] ?? [:]
        return ControllerFamily.allCases.filter { overridesByFamily[$0.rawValue] != nil }
    }

    /// Every stored override, ordered by game identity then family, so Settings renders stably.
    public var allOverrides: [ControllerMappingGameOverrideEntry] {
        overridesByGameIdentity.keys.sorted().flatMap { gameIdentity in
            overriddenFamilies(forGameIdentity: gameIdentity).compactMap { family in
                override(forGameIdentity: gameIdentity, family: family).map {
                    ControllerMappingGameOverrideEntry(gameIdentity: gameIdentity, family: family, gameOverride: $0)
                }
            }
        }
    }

    /// Drops every override pointing at a deleted profile; a game with none left loses its entry.
    public mutating func removeOverrides(referencingProfile profileID: UUID) {
        for gameIdentity in Array(overridesByGameIdentity.keys) {
            for family in overriddenFamilies(forGameIdentity: gameIdentity) {
                guard override(forGameIdentity: gameIdentity, family: family)?.profileID == profileID else { continue }
                setOverride(nil, forGameIdentity: gameIdentity, family: family)
            }
        }
    }
}
