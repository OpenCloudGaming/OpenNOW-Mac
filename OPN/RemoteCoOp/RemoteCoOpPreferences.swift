import Foundation

public enum OPNRemoteCoOpPreferencesStore {
    private static let storage = OPNAppPreferenceStorage.standard
    private static let enabledKey = "OpenNOW.RemoteCoOp.Enabled"
    private static let reservedGuestSlotsKey = "OpenNOW.RemoteCoOp.ReservedGuestSlots"
    private static let transportModeKey = "OpenNOW.RemoteCoOp.TransportMode"
    private static let qualityPresetKey = "OpenNOW.RemoteCoOp.QualityPreset"
    private static let requireHostApprovalKey = "OpenNOW.RemoteCoOp.RequireHostApproval"
    private static let signalingServerURLKey = "OpenNOW.RemoteCoOp.SignalingServerURL"
    private static let guestJoinBaseURLKey = "OpenNOW.RemoteCoOp.GuestJoinBaseURL"

    public static func load() -> OPNRemoteCoOpPreferences {
        OPNRemoteCoOpPreferences(
            isEnabled: bool(storage.object(forKey: enabledKey), defaultValue: false),
            reservedGuestSlots: int(storage.object(forKey: reservedGuestSlotsKey), defaultValue: 1),
            transportMode: OPNRemoteCoOpTransportMode(rawValue: string(storage.object(forKey: transportModeKey))) ?? .automatic,
            qualityPreset: OPNRemoteCoOpQualityPreset(rawValue: string(storage.object(forKey: qualityPresetKey))) ?? .p720f60,
            requireHostApproval: bool(storage.object(forKey: requireHostApprovalKey), defaultValue: true),
            signalingServerURL: string(storage.object(forKey: signalingServerURLKey), defaultValue: OPNRemoteCoOpPreferences.defaultSignalingServerURL),
            guestJoinBaseURL: string(storage.object(forKey: guestJoinBaseURLKey), defaultValue: OPNRemoteCoOpPreferences.defaultGuestJoinBaseURL)
        )
    }

    public static func save(_ preferences: OPNRemoteCoOpPreferences) {
        storage.set(preferences.isEnabled, forKey: enabledKey)
        storage.set(OPNRemoteCoOpPreferences.clampedGuestSlots(preferences.reservedGuestSlots), forKey: reservedGuestSlotsKey)
        storage.set(preferences.transportMode.rawValue, forKey: transportModeKey)
        storage.set(preferences.qualityPreset.rawValue, forKey: qualityPresetKey)
        storage.set(preferences.requireHostApproval, forKey: requireHostApprovalKey)
        storage.set(preferences.signalingServerURL, forKey: signalingServerURLKey)
        storage.set(preferences.guestJoinBaseURL, forKey: guestJoinBaseURLKey)
        storage.synchronize()
    }

    public static func setEnabled(_ enabled: Bool) {
        var preferences = load()
        preferences.isEnabled = enabled
        save(preferences)
    }

    public static func setReservedGuestSlots(_ slots: Int) {
        var preferences = load()
        preferences.reservedGuestSlots = OPNRemoteCoOpPreferences.clampedGuestSlots(slots)
        save(preferences)
    }

    public static func setTransportMode(_ mode: OPNRemoteCoOpTransportMode) {
        var preferences = load()
        preferences.transportMode = mode
        save(preferences)
    }

    public static func setQualityPreset(_ preset: OPNRemoteCoOpQualityPreset) {
        var preferences = load()
        preferences.qualityPreset = preset
        save(preferences)
    }

    public static func setRequireHostApproval(_ required: Bool) {
        var preferences = load()
        preferences.requireHostApproval = required
        save(preferences)
    }

    public static func setSignalingServerURL(_ url: String) {
        var preferences = load()
        preferences.signalingServerURL = OPNRemoteCoOpPreferences.normalizedURLString(url, fallback: OPNRemoteCoOpPreferences.defaultSignalingServerURL)
        save(preferences)
    }

    public static func setGuestJoinBaseURL(_ url: String) {
        var preferences = load()
        preferences.guestJoinBaseURL = OPNRemoteCoOpPreferences.normalizedURLString(url, fallback: OPNRemoteCoOpPreferences.defaultGuestJoinBaseURL)
        save(preferences)
    }

    public static func reservedControllerSlotsForLaunch() -> Int {
        load().effectiveReservedGuestSlots
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private static func string(_ value: Any?, defaultValue: String) -> String {
        OPNRemoteCoOpPreferences.normalizedURLString(string(value), fallback: defaultValue)
    }

    private static func int(_ value: Any?, defaultValue: Int) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String, let parsed = Int(value) { return parsed }
        return defaultValue
    }

    private static func bool(_ value: Any?, defaultValue: Bool) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame
        }
        return defaultValue
    }
}
