//  Where the cloud DLSS override preference and the membership entitlements that gate it live. Two
//  keys on purpose: the preference is what the reader asked for, the entitlements are the account's.

import Foundation

extension OPNStreamPreferences {
    /// The stored global override, never normalized on read: normalization is applied where the value
    /// is used, so a later rule change also fixes preferences already on disk.
    public static func loadDlssOverrides() -> DlssOverrides {
        DlssOverrides(stored: storage.object(forKey: k.dlssOverrides) as? [String: Any])
    }

    public static func saveDlssOverrides(_ overrides: DlssOverrides) {
        storage.set(overrides.storedDictionary, forKey: k.dlssOverrides)
        storage.synchronize()
    }

    /// The active browsing account's presentation mirror. Launches carry their own snapshot.
    public static func loadDlssEntitlements() -> DlssEntitlements {
        dlssEntitlements(from: storage.object(forKey: k.dlssEntitlements) as? [String: Any] ?? [:])
    }

    static func dlssEntitlements(from dictionary: [String: Any]) -> DlssEntitlements {
        return DlssEntitlements(
            superResolution: capability(from: dictionary, key: "superResolution"),
            frameGeneration: capability(from: dictionary, key: "frameGeneration"),
            rayReconstruction: capability(from: dictionary, key: "rayReconstruction"),
            frameGenerationMultipliers: multiplierValues(from: dictionary)
        )
    }

    public static func saveDlssEntitlements(_ entitlements: DlssEntitlements) {
        storage.set(dlssEntitlementsDictionary(entitlements), forKey: k.dlssEntitlements)
        storage.synchronize()
    }

    static func dlssEntitlementsDictionary(_ entitlements: DlssEntitlements) -> [String: Any] {
        [
            "superResolution": capabilityDictionary(entitlements.superResolution),
            "frameGeneration": capabilityDictionary(entitlements.frameGeneration),
            "rayReconstruction": capabilityDictionary(entitlements.rayReconstruction),
            "frameGenerationMultipliers": entitlements.frameGenerationMultipliers,
        ]
    }

    /// Signing out drops the stored entitlements, so a later launch cannot ask for an override the
    /// account that is no longer signed in used to include.
    public static func clearDlssEntitlements() {
        storage.removeObject(forKey: k.dlssEntitlements)
        storage.synchronize()
    }

    /// The override that may be requested right now: the saved preference with every unentitled
    /// feature forced back to the game's own setting.
    public static func effectiveDlssOverrides() -> DlssOverrides {
        loadDlssOverrides().applyingAccess(loadDlssEntitlements())
    }

    private static func capability(from dictionary: [String: Any], key: String) -> DlssCapability {
        guard let value = dictionary[key] as? [String: Any] else { return DlssCapability() }
        return DlssCapability(
            isEntitled: (value["isEntitled"] as? Bool) ?? false,
            isUpsell: (value["isUpsell"] as? Bool) ?? false
        )
    }

    private static func capabilityDictionary(_ capability: DlssCapability) -> [String: Any] {
        ["isEntitled": capability.isEntitled, "isUpsell": capability.isUpsell]
    }

    private static func multiplierValues(from dictionary: [String: Any]) -> [Int] {
        guard let values = dictionary["frameGenerationMultipliers"] as? [Any] else { return [] }
        return values.compactMap { $0 as? Int }
    }
}

/// What the app knows about the account's DLSS overrides. Kept apart from `DlssEntitlements` so a
/// membership that has not answered yet never renders as one that answered "no".
public enum DlssMembershipState: Equatable, Sendable {
    case signedOut
    case loading
    case loaded(DlssEntitlements)
    /// The membership lookup failed. Treated exactly like missing access: an unknown membership is
    /// never treated as an entitled one.
    case unavailable

    public var entitlements: DlssEntitlements {
        guard case let .loaded(entitlements) = self else { return .none }
        return entitlements
    }

    public var isLoading: Bool { self == .loading }

    public var isSignedOut: Bool { self == .signedOut }
}
