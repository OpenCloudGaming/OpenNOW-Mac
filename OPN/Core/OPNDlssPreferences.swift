//  Where the cloud DLSS override preference and the membership entitlements that gate it live.
//
//  Two separate keys on purpose. The override is what the reader asked for and is kept even when
//  access lapses; the entitlements are what the account currently includes and are re-read on every
//  account change. Nothing joins them here — `DlssOverrides.applyingAccess` is what decides the
//  object that may leave the Mac.

import Foundation

extension OPNStreamPreferences {
    /// The stored global override. Never normalized on read: the normalization is applied where the
    /// value is used, so a later rule change also fixes preferences already on disk.
    public static func loadDlssOverrides() -> DlssOverrides {
        DlssOverrides(stored: storage.object(forKey: k.dlssOverrides) as? [String: Any])
    }

    public static func saveDlssOverrides(_ overrides: DlssOverrides) {
        storage.set(overrides.storedDictionary, forKey: k.dlssOverrides)
        storage.synchronize()
    }

    /// The membership entitlements the launch path filters against, remembered so a session request
    /// does not need a subscription fetch on its own path.
    public static func loadDlssEntitlements() -> DlssEntitlements {
        guard let dictionary = storage.object(forKey: k.dlssEntitlements) as? [String: Any] else { return .none }
        return DlssEntitlements(
            superResolution: capability(dictionary, "superResolution"),
            frameGeneration: capability(dictionary, "frameGeneration"),
            rayReconstruction: capability(dictionary, "rayReconstruction"),
            frameGenerationMultipliers: (dictionary["frameGenerationMultipliers"] as? [Any])?.compactMap { $0 as? Int } ?? []
        )
    }

    public static func saveDlssEntitlements(_ entitlements: DlssEntitlements) {
        let dictionary: [String: Any] = [
            "superResolution": ["isEntitled": entitlements.superResolution.isEntitled, "isUpsell": entitlements.superResolution.isUpsell],
            "frameGeneration": ["isEntitled": entitlements.frameGeneration.isEntitled, "isUpsell": entitlements.frameGeneration.isUpsell],
            "rayReconstruction": ["isEntitled": entitlements.rayReconstruction.isEntitled, "isUpsell": entitlements.rayReconstruction.isUpsell],
            "frameGenerationMultipliers": entitlements.frameGenerationMultipliers,
        ]
        storage.set(dictionary, forKey: k.dlssEntitlements)
        storage.synchronize()
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

    private static func capability(_ dictionary: [String: Any], _ key: String) -> DlssCapability {
        guard let value = dictionary[key] as? [String: Any] else { return DlssCapability() }
        return DlssCapability(
            isEntitled: (value["isEntitled"] as? Bool) ?? false,
            isUpsell: (value["isUpsell"] as? Bool) ?? false
        )
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
        if case let .loaded(entitlements) = self { return entitlements }
        return .none
    }

    public var isLoading: Bool {
        self == .loading
    }

    public var isSignedOut: Bool {
        self == .signedOut
    }
}
