import Foundation

public enum OPNRemoteCoOpPreferencesStore {
    static let storage = OPNAppPreferenceStorage.standard
    private static let enabledKey = "OpenNOW.RemoteCoOp.Enabled"
    private static let reservedGuestSlotsKey = "OpenNOW.RemoteCoOp.ReservedGuestSlots"
    private static let transportModeKey = "OpenNOW.RemoteCoOp.TransportMode"
    private static let qualityPresetKey = "OpenNOW.RemoteCoOp.QualityPreset"
    private static let latencyModeKey = "OpenNOW.RemoteCoOp.LatencyMode"
    private static let lowLatencyDefaultMigrationVersionKey = "OpenNOW.RemoteCoOp.LowLatencyDefaultMigrationVersion"
    private static let lowLatencyDefaultMigrationVersion = 1
    private static let requireHostApprovalKey = "OpenNOW.RemoteCoOp.RequireHostApproval"
    private static let hideGuestInviteDetailsKey = "OpenNOW.RemoteCoOp.HideGuestInviteDetails"
    private static let publicAddressKey = "OpenNOW.RemoteCoOp.PublicAddress"
    private static let hostedGuestPageURLKey = "OpenNOW.RemoteCoOp.HostedGuestPageURL"
    /// Where a fresh install points a host who never sets their own: this repo's own Pages deploy of
    /// `Resources/RemoteCoOp/browser`, kept in lockstep with it by the same CI that publishes it.
    /// A host who clears the field explicitly gets an empty string back, not this - see `load()`.
    public static let defaultHostedGuestPageURL = "https://opencloudgaming.github.io/OpenNOW-Mac/"

    /// `relayOnly` is gone with the broker that ran the relay, but it is still sitting in the
    /// defaults of anyone who chose it. Falling through to `.automatic` silently turned STUN back on
    /// for the one setting whose whole point was not disclosing this Mac's public address, so it
    /// lands on the mode that still offers only local candidates.
    static func migratedTransportMode(_ rawValue: String) -> OPNRemoteCoOpTransportMode {
        if let mode = OPNRemoteCoOpTransportMode(rawValue: rawValue) { return mode }
        return rawValue == "relayOnly" ? .directOnly : .automatic
    }

    /// Whether the launched stream is on the transport Remote Co-Op needs.
    ///
    /// The WebRTC path decodes inside libwebrtc and exposes no frame tap comparable to the native
    /// decoder's, so hosting there meant re-rendering the guest's picture: a second decode and encode
    /// per frame on the host, for a stream guests found sluggish. NVST hands over the decoder's own
    /// `CVPixelBuffer`, which is what makes the relay cheap enough to be worth having at all.
    ///
    /// Read from the same preference the stream itself uses, so this can never disagree with the
    /// transport that actually launches.
    public static var isNativeTransportSelected: Bool {
        OPNStreamPreferences.loadProfile().transportMode.value == "nvst"
    }

    public static func load() -> OPNRemoteCoOpPreferences {
        let latencyMode = migratedLatencyMode()
        return OPNRemoteCoOpPreferences(
            isEnabled: bool(storage.object(forKey: enabledKey), defaultValue: false),
            reservedGuestSlots: int(storage.object(forKey: reservedGuestSlotsKey), defaultValue: 1),
            transportMode: migratedTransportMode(string(storage.object(forKey: transportModeKey))),
            qualityPreset: OPNRemoteCoOpQualityPreset(rawValue: string(storage.object(forKey: qualityPresetKey))) ?? .p720f60,
            latencyMode: latencyMode,
            requireHostApproval: bool(storage.object(forKey: requireHostApprovalKey), defaultValue: true),
            hideGuestInviteDetails: bool(storage.object(forKey: hideGuestInviteDetailsKey), defaultValue: false),
            publicAddress: string(storage.object(forKey: publicAddressKey)),
            // Distinguished from an explicit clear: a saved empty string means the host chose local
            // serving, and only "never saved anything" gets the shipped default.
            hostedGuestPageURL: storage.object(forKey: hostedGuestPageURLKey) == nil
                ? defaultHostedGuestPageURL
                : string(storage.object(forKey: hostedGuestPageURLKey))
        )
    }

    public static func save(_ preferences: OPNRemoteCoOpPreferences) {
        storage.set(preferences.isEnabled, forKey: enabledKey)
        storage.set(OPNRemoteCoOpPreferences.clampedGuestSlots(preferences.reservedGuestSlots), forKey: reservedGuestSlotsKey)
        storage.set(preferences.transportMode.rawValue, forKey: transportModeKey)
        storage.set(preferences.qualityPreset.rawValue, forKey: qualityPresetKey)
        storage.set(preferences.latencyMode.rawValue, forKey: latencyModeKey)
        storage.set(lowLatencyDefaultMigrationVersion, forKey: lowLatencyDefaultMigrationVersionKey)
        storage.set(preferences.requireHostApproval, forKey: requireHostApprovalKey)
        storage.set(preferences.hideGuestInviteDetails, forKey: hideGuestInviteDetailsKey)
        storage.set(preferences.publicAddress, forKey: publicAddressKey)
        storage.set(preferences.hostedGuestPageURL, forKey: hostedGuestPageURLKey)
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

    public static func setLatencyMode(_ mode: OPNRemoteCoOpLatencyMode) {
        var preferences = load()
        preferences.latencyMode = mode
        save(preferences)
    }

    public static func setRequireHostApproval(_ required: Bool) {
        var preferences = load()
        preferences.requireHostApproval = required
        save(preferences)
    }

    public static func setPublicAddress(_ address: String) {
        var preferences = load()
        preferences.publicAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        save(preferences)
    }

    public static func setHostedGuestPageURL(_ url: String) {
        var preferences = load()
        preferences.hostedGuestPageURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        save(preferences)
    }

    public static func setHideGuestInviteDetails(_ hidden: Bool) {
        var preferences = load()
        preferences.hideGuestInviteDetails = hidden
        save(preferences)
    }

    public static func reservedControllerSlotsForLaunch() -> Int {
        load().effectiveReservedGuestSlots
    }

    static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    static func string(_ value: Any?, defaultValue: String) -> String {
        OPNRemoteCoOpPreferences.normalizedURLString(string(value), fallback: defaultValue)
    }

    static func int(_ value: Any?, defaultValue: Int) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String, let parsed = Int(value) { return parsed }
        return defaultValue
    }

    static func bool(_ value: Any?, defaultValue: Bool) -> Bool {
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
