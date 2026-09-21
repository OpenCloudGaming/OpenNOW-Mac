import Foundation

/// Decides which `UserDefaults` keys travel through iCloud. An allow-list of prefixes plus a short
/// deny-list: a preference added under an allowed prefix syncs by default, and removing a secret
/// from the deny-list has to be a deliberate act.
enum OPNCloudSyncSettingsRegistry {
    static let allowedPrefixes: [String] = [
        "OpenNOW.Interface.",
        "OpenNOW.Stream.",
        "OpenNOW.Launch.",
        "OpenNOW.Window.",
        "OpenNOW.MenuBar.",
        "OpenNOW.Input.",
        "OpenNOW.Controller.",
    ]

    /// Keys outside every prefix that still carry a preference worth syncing. Keybindings store
    /// themselves under their action's raw value with no prefix, so they are named here.
    static let allowedKeys: Set<String> = Set(KeybindingAction.allCases.map(\.rawValue)).union([
        OPNUpdatePreferences.automaticUpdateChecksEnabledKey,
    ])

    /// Matches an allowed prefix but must stay local: secrets, runtime state, values bound to this
    /// Mac, and the catalog keys the catalog codec carries under its own file.
    static let deniedKeys: Set<String> = [
        OPNInterfacePreferences.uiScaleKey,
        OPNHomeCustomization.orderKey,
        OPNHomeCustomization.hiddenKey,
        "OpenNOW.Launch.AtLogin",
        "OpenNOW.Stream.ActiveSessionId",
        "OpenNOW.Stream.SessionLimitStartedAtEpochSeconds",
    ]

    /// Whole namespaces that never travel, so a proxy key added later cannot slip through by not
    /// being listed above. The session proxy's settings and its migration markers are per-Mac.
    static let deniedPrefixes: [String] = [
        "OpenNOW.Stream.SessionProxy",
    ]

    static func isDenied(_ key: String) -> Bool {
        deniedKeys.contains(key) || deniedPrefixes.contains { key.hasPrefix($0) }
    }

    static func isSyncable(_ key: String) -> Bool {
        guard !isDenied(key) else { return false }
        if allowedKeys.contains(key) { return true }
        return allowedPrefixes.contains { key.hasPrefix($0) }
    }

    /// The syncable preferences currently stored on this Mac, as raw property-list values.
    static func snapshot() -> [String: Any] {
        OPNAppPreferenceStorage.standard.dictionaryRepresentation()
            .filter { isSyncable($0.key) }
    }

    // MARK: - Baseline

    /// What this Mac last saw in the shared file. Without it a value written here earlier cannot be
    /// told apart from one another Mac changed after this one went quiet.
    static let baselineKey = "OpenNOW.CloudSync.SettingsBaseline"

    static func loadBaseline() -> [String: OPNCloudSyncSettingsEntry] {
        guard let data = OPNAppPreferenceStorage.standard.data(forKey: baselineKey),
              let file = try? OPNCloudSyncJSON.decoder.decode(OPNCloudSyncSettingsFile.self, from: data) else {
            return [:]
        }
        return file.entries
    }

    static func saveBaseline(_ entries: [String: OPNCloudSyncSettingsEntry]) {
        guard let data = try? OPNCloudSyncJSON.encoder.encode(OPNCloudSyncSettingsFile(entries: entries)) else { return }
        OPNAppPreferenceStorage.standard.set(data, forKey: baselineKey)
    }

    /// Writes reconciled values back into local storage. Property lists carry exactly the types
    /// `UserDefaults` stores, so a remote value cannot arrive as an unexpected type.
    static func apply(_ values: [String: Any]) {
        let storage = OPNAppPreferenceStorage.standard
        for (key, value) in values where isSyncable(key) {
            storage.set(value, forKey: key)
        }
    }

    // MARK: - Merge

    /// What reconciling one Mac's preferences with the shared file produced.
    struct MergeResult {
        var file: OPNCloudSyncSettingsFile
        var appliedValues: [String: Any]
    }

    /// Reconciles local and shared preferences with per-key last-writer-wins: a remote entry newer
    /// than the baseline is imported, and a local value that differs from the baseline is exported.
    static func merge(
        local: [String: Any],
        remote: OPNCloudSyncSettingsFile,
        baseline: [String: OPNCloudSyncSettingsEntry],
        device: String,
        now: Date = Date()
    ) -> MergeResult {
        var file = remote
        // Drop any entry that must never travel: an older build may have written one before the
        // deny-list grew, and it would otherwise sit in iCloud Drive forever.
        file.entries = file.entries.filter { !isDenied($0.key) }

        let appliedValues = remoteValuesToApply(remote: file, baseline: baseline)
        let isFirstSync = baseline.isEmpty && !file.entries.isEmpty
        guard !isFirstSync else {
            return MergeResult(file: file, appliedValues: appliedValues)
        }

        file.entries = exportedEntries(
            into: file.entries,
            local: local,
            baseline: baseline,
            appliedValues: appliedValues,
            device: device,
            now: now
        )
        return MergeResult(file: file, appliedValues: appliedValues)
    }

    /// The remote values newer than what this Mac has already seen.
    private static func remoteValuesToApply(
        remote: OPNCloudSyncSettingsFile,
        baseline: [String: OPNCloudSyncSettingsEntry]
    ) -> [String: Any] {
        var appliedValues: [String: Any] = [:]
        for (key, entry) in remote.entries where isSyncable(key) {
            guard let value = OPNCloudSyncPlist.decode(entry.plist) else { continue }
            guard isRemoteNewer(entry: entry, baseline: baseline[key]) else { continue }
            appliedValues[key] = value
        }
        return appliedValues
    }

    private static func isRemoteNewer(entry: OPNCloudSyncSettingsEntry, baseline: OPNCloudSyncSettingsEntry?) -> Bool {
        guard let baseline else { return true }
        return entry.updatedAt > baseline.updatedAt
    }

    /// Local values that changed since the baseline and are not what this pass is importing.
    private static func exportedEntries(
        into entries: [String: OPNCloudSyncSettingsEntry],
        local: [String: Any],
        baseline: [String: OPNCloudSyncSettingsEntry],
        appliedValues: [String: Any],
        device: String,
        now: Date
    ) -> [String: OPNCloudSyncSettingsEntry] {
        var result = entries
        for (key, value) in local {
            guard let encoded = OPNCloudSyncPlist.encode(value) else { continue }
            guard isLocallyChanged(key: key, value: value, baseline: baseline) else { continue }
            guard !isValueAlreadyApplied(key: key, value: value, appliedValues: appliedValues) else { continue }
            result[key] = OPNCloudSyncSettingsEntry(plist: encoded, updatedAt: now, deviceID: device)
        }
        return result
    }

    private static func isLocallyChanged(key: String, value: Any, baseline: [String: OPNCloudSyncSettingsEntry]) -> Bool {
        guard let baselineEntry = baseline[key], let baselineValue = OPNCloudSyncPlist.decode(baselineEntry.plist) else {
            return true
        }
        return !OPNCloudSyncPlist.equal(baselineValue, value)
    }

    private static func isValueAlreadyApplied(key: String, value: Any, appliedValues: [String: Any]) -> Bool {
        guard let appliedValue = appliedValues[key] else { return false }
        return OPNCloudSyncPlist.equal(appliedValue, value)
    }
}
