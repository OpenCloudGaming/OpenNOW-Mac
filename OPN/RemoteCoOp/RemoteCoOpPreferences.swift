import Foundation

public enum OPNRemoteCoOpPreferencesStore {
    private static let storage = OPNAppPreferenceStorage.standard
    private static let alphaOptInKey = "MacForceNow.RemoteCoOp.AlphaOptIn"
    private static let enabledKey = "MacForceNow.RemoteCoOp.Enabled"
    private static let reservedGuestSlotsKey = "MacForceNow.RemoteCoOp.ReservedGuestSlots"
    private static let transportModeKey = "MacForceNow.RemoteCoOp.TransportMode"
    private static let qualityPresetKey = "MacForceNow.RemoteCoOp.QualityPreset"
    private static let latencyModeKey = "MacForceNow.RemoteCoOp.LatencyMode"
    private static let lowLatencyDefaultMigrationVersionKey = "MacForceNow.RemoteCoOp.LowLatencyDefaultMigrationVersion"
    private static let lowLatencyDefaultMigrationVersion = 1
    private static let requireHostApprovalKey = "MacForceNow.RemoteCoOp.RequireHostApproval"
    private static let signalingServerURLKey = "MacForceNow.RemoteCoOp.SignalingServerURL"
    private static let guestJoinBaseURLKey = "MacForceNow.RemoteCoOp.GuestJoinBaseURL"
    private static let hideGuestInviteDetailsKey = "MacForceNow.RemoteCoOp.HideGuestInviteDetails"

    public static var isAlphaOptedIn: Bool {
        bool(storage.object(forKey: alphaOptInKey), defaultValue: false)
    }

    public static func load() -> OPNRemoteCoOpPreferences {
        let latencyMode = migratedLatencyMode()
        return OPNRemoteCoOpPreferences(
            isAlphaOptedIn: isAlphaOptedIn,
            isEnabled: bool(storage.object(forKey: enabledKey), defaultValue: false),
            reservedGuestSlots: int(storage.object(forKey: reservedGuestSlotsKey), defaultValue: 1),
            transportMode: OPNRemoteCoOpTransportMode(rawValue: string(storage.object(forKey: transportModeKey))) ?? .automatic,
            qualityPreset: OPNRemoteCoOpQualityPreset(rawValue: string(storage.object(forKey: qualityPresetKey))) ?? .p720f60,
            latencyMode: latencyMode,
            requireHostApproval: bool(storage.object(forKey: requireHostApprovalKey), defaultValue: true),
            signalingServerURL: OPNRemoteCoOpPreferences.migratedSignalingServerURL(string(storage.object(forKey: signalingServerURLKey), defaultValue: OPNRemoteCoOpPreferences.defaultSignalingServerURL)),
            guestJoinBaseURL: OPNRemoteCoOpPreferences.migratedGuestJoinBaseURL(string(storage.object(forKey: guestJoinBaseURLKey), defaultValue: OPNRemoteCoOpPreferences.defaultGuestJoinBaseURL)),
            hideGuestInviteDetails: bool(storage.object(forKey: hideGuestInviteDetailsKey), defaultValue: false)
        )
    }

    public static func save(_ preferences: OPNRemoteCoOpPreferences) {
        storage.set(preferences.isAlphaOptedIn, forKey: alphaOptInKey)
        storage.set(preferences.isEnabled, forKey: enabledKey)
        storage.set(OPNRemoteCoOpPreferences.clampedGuestSlots(preferences.reservedGuestSlots), forKey: reservedGuestSlotsKey)
        storage.set(preferences.transportMode.rawValue, forKey: transportModeKey)
        storage.set(preferences.qualityPreset.rawValue, forKey: qualityPresetKey)
        storage.set(preferences.latencyMode.rawValue, forKey: latencyModeKey)
        storage.set(lowLatencyDefaultMigrationVersion, forKey: lowLatencyDefaultMigrationVersionKey)
        storage.set(preferences.requireHostApproval, forKey: requireHostApprovalKey)
        storage.set(preferences.signalingServerURL, forKey: signalingServerURLKey)
        storage.set(preferences.guestJoinBaseURL, forKey: guestJoinBaseURLKey)
        storage.set(preferences.hideGuestInviteDetails, forKey: hideGuestInviteDetailsKey)
        storage.synchronize()
    }

    public static func setAlphaOptedIn(_ optedIn: Bool) {
        var preferences = load()
        preferences.isAlphaOptedIn = optedIn
        if !optedIn { preferences.isEnabled = false }
        save(preferences)
    }

    public static func setEnabled(_ enabled: Bool) {
        guard isAlphaOptedIn else { return }
        var preferences = load()
        preferences.isEnabled = enabled
        save(preferences)
    }

    public static func setReservedGuestSlots(_ slots: Int) {
        guard isAlphaOptedIn else { return }
        var preferences = load()
        preferences.reservedGuestSlots = OPNRemoteCoOpPreferences.clampedGuestSlots(slots)
        save(preferences)
    }

    public static func setTransportMode(_ mode: OPNRemoteCoOpTransportMode) {
        guard isAlphaOptedIn else { return }
        var preferences = load()
        preferences.transportMode = mode
        save(preferences)
    }

    public static func setQualityPreset(_ preset: OPNRemoteCoOpQualityPreset) {
        guard isAlphaOptedIn else { return }
        var preferences = load()
        preferences.qualityPreset = preset
        save(preferences)
    }

    public static func setLatencyMode(_ mode: OPNRemoteCoOpLatencyMode) {
        guard isAlphaOptedIn else { return }
        var preferences = load()
        preferences.latencyMode = mode
        save(preferences)
    }

    public static func setRequireHostApproval(_ required: Bool) {
        guard isAlphaOptedIn else { return }
        var preferences = load()
        preferences.requireHostApproval = required
        save(preferences)
    }

    public static func setSignalingServerURL(_ url: String) {
        guard isAlphaOptedIn else { return }
        var preferences = load()
        preferences.signalingServerURL = OPNRemoteCoOpPreferences.normalizedURLString(url, fallback: OPNRemoteCoOpPreferences.defaultSignalingServerURL)
        save(preferences)
    }

    public static func setGuestJoinBaseURL(_ url: String) {
        guard isAlphaOptedIn else { return }
        var preferences = load()
        preferences.guestJoinBaseURL = OPNRemoteCoOpPreferences.normalizedURLString(url, fallback: OPNRemoteCoOpPreferences.defaultGuestJoinBaseURL)
        save(preferences)
    }

    public static func setHideGuestInviteDetails(_ hidden: Bool) {
        guard isAlphaOptedIn else { return }
        var preferences = load()
        preferences.hideGuestInviteDetails = hidden
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

    private static func migratedLatencyMode() -> OPNRemoteCoOpLatencyMode {
        let storedValue = string(storage.object(forKey: latencyModeKey))
        let storedMode = OPNRemoteCoOpLatencyMode(rawValue: storedValue)
        let migrationVersion = int(storage.object(forKey: lowLatencyDefaultMigrationVersionKey), defaultValue: 0)
        guard migrationVersion < lowLatencyDefaultMigrationVersion else { return storedMode ?? .lowLatency }

        storage.set(OPNRemoteCoOpLatencyMode.lowLatency.rawValue, forKey: latencyModeKey)
        storage.set(lowLatencyDefaultMigrationVersion, forKey: lowLatencyDefaultMigrationVersionKey)
        storage.synchronize()
        return .lowLatency
    }
}
