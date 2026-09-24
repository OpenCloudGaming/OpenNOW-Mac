import CryptoKit
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
        guard let data = OPNAppPreferenceStorage.syncStore.data(forKey: baselineKey),
              let file = try? OPNCloudSyncJSON.decoder.decode(OPNCloudSyncSettingsFile.self, from: data) else {
            return [:]
        }
        return file.entries
    }

    static func saveBaseline(_ entries: [String: OPNCloudSyncSettingsEntry]) {
        guard let data = try? OPNCloudSyncJSON.encoder.encode(OPNCloudSyncSettingsFile(entries: entries)) else { return }
        let storage = OPNAppPreferenceStorage.syncStore
        guard storage.data(forKey: baselineKey) != data else { return }
        storage.set(data, forKey: baselineKey)
    }

    /// Writes reconciled values back into local storage, skipping any already present so a pass that
    /// imported nothing writes nothing.
    static func apply(_ values: [String: Any]) {
        let storage = OPNAppPreferenceStorage.standard
        for (key, value) in values where isSyncable(key) {
            if let existing = storage.object(forKey: key), OPNCloudSyncPlist.equal(existing, value) { continue }
            storage.set(value, forKey: key)
        }
    }

    /// Every syncable value in a shared file, as raw property-list values.
    static func decodedValues(from file: OPNCloudSyncSettingsFile) -> [String: Any] {
        var values: [String: Any] = [:]
        for (key, entry) in file.entries where isSyncable(key) {
            guard let value = OPNCloudSyncPlist.decode(entry.plist) else { continue }
            values[key] = value
        }
        return values
    }

    /// Writes every value in a shared file back into local storage, the "use the other Mac" choice.
    static func apply(_ file: OPNCloudSyncSettingsFile) {
        apply(decodedValues(from: file))
    }

    /// This Mac's whole syncable preference set as a file, the "keep this Mac" choice.
    static func localFile(device: String, now: Date = Date()) -> OPNCloudSyncSettingsFile {
        var entries: [String: OPNCloudSyncSettingsEntry] = [:]
        for (key, value) in snapshot() {
            guard let encoded = OPNCloudSyncPlist.encode(value) else { continue }
            entries[key] = OPNCloudSyncSettingsEntry(plist: encoded, updatedAt: now, deviceID: device)
        }
        return OPNCloudSyncSettingsFile(deviceName: OPNCloudSyncDevice.name, entries: entries)
    }

    // MARK: - Conflict detection

    /// The last settings the two sides agreed on, as content signatures rather than per-key times:
    /// a signature says whether each side's whole setting set changed since, which is what separates
    /// a one-sided edit from a genuine conflict.
    struct SignatureBaseline: Codable, Equatable, Sendable {
        var local: String
        var remote: String
    }

    static let signatureBaselineKey = "OpenNOW.CloudSync.SettingsSignatureBaseline"

    static func loadSignatureBaseline() -> SignatureBaseline? {
        guard let data = OPNAppPreferenceStorage.syncStore.data(forKey: signatureBaselineKey) else { return nil }
        return try? OPNCloudSyncJSON.decoder.decode(SignatureBaseline.self, from: data)
    }

    static func saveSignatureBaseline(_ baseline: SignatureBaseline) {
        guard let data = try? OPNCloudSyncJSON.encoder.encode(baseline) else { return }
        let storage = OPNAppPreferenceStorage.syncStore
        guard storage.data(forKey: signatureBaselineKey) != data else { return }
        storage.set(data, forKey: signatureBaselineKey)
    }

    /// A deterministic digest of a whole setting set, keyed and encoded so two Macs holding the same
    /// values produce the same signature regardless of when either wrote them.
    static func contentSignature(values: [String: Any]) -> String {
        let parts = values.keys.sorted().compactMap { key -> String? in
            guard let value = values[key], let data = OPNCloudSyncPlist.encode(value) else { return nil }
            return "\(key)=\(data.base64EncodedString())"
        }
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The divergence to surface, or nil when one side can simply be folded over the other. Mirrors
    /// the catalog's rule: a settled baseline, both sides changed since it, and the two differing.
    static func detectConflict(
        local: [String: Any],
        remote: OPNCloudSyncSettingsFile,
        baseline: SignatureBaseline?
    ) -> OPNCloudSyncConflict? {
        guard let baseline else { return nil }
        let localSignature = contentSignature(values: local)
        let remoteSignature = contentSignature(values: decodedValues(from: remote))
        guard localSignature != baseline.local,
              remoteSignature != baseline.remote,
              localSignature != remoteSignature else { return nil }
        return OPNCloudSyncConflict(
            category: .settings,
            remoteDeviceID: remote.entries.values.map(\.deviceID).max() ?? "",
            remoteDeviceName: remote.deviceName,
            remoteGeneratedAt: remote.entries.values.map(\.updatedAt).max() ?? .distantPast
        )
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
        file.schemaVersion = OPNCloudSyncLayout.schemaVersion
        file.deviceName = OPNCloudSyncDevice.name
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
