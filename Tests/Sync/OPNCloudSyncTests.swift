import Foundation
import Testing
@testable import OpenNOW

/// The iCloud backup's pure logic: which preferences travel, how a conflict is decided, how account
/// namespaces are built, and how the screenshot mirror treats an already-present file.
@Suite(.serialized) struct OPNCloudSyncTests {
    private func entry(_ value: Any, updatedAt: Date, device: String = "A") -> OPNCloudSyncSettingsEntry {
        OPNCloudSyncSettingsEntry(plist: OPNCloudSyncPlist.encode(value) ?? Data(), updatedAt: updatedAt, deviceID: device)
    }

    // MARK: - Registry

    @Test func theRegistryExportsPreferencesAndRefusesSecrets() {
        // Preferences under an allowed prefix travel.
        #expect(OPNCloudSyncSettingsRegistry.isSyncable("OpenNOW.Interface.Appearance"))
        #expect(OPNCloudSyncSettingsRegistry.isSyncable("OpenNOW.Stream.Fps"))
        #expect(OPNCloudSyncSettingsRegistry.isSyncable("OpenNOW.Input.ControllerMappingProfiles"))
        // Per-game controller mapping: the override blob, the per-family defaults and the
        // `appId → catalogIdentity` resume index are all machine-independent, so they must travel
        // with the settings. Pinned by name so a later prefix change cannot silently drop them.
        for key in [ControllerMappingStore.gameOverridesKey,
                    ControllerMappingStore.defaultProfilesKey,
                    ControllerMappingStore.appIdIdentityIndexKey] {
            #expect(OPNCloudSyncSettingsRegistry.isSyncable(key), "\(key) must travel with the settings")
        }
        // A keybinding's stored key is its prefix plus the action, not the bare raw value.
        #expect(OPNCloudSyncSettingsRegistry.isSyncable("\(OPNKeybindings.storageKeyPrefix)\(KeybindingAction.takeScreenshot.rawValue)"))
        #expect(!OPNCloudSyncSettingsRegistry.isSyncable(KeybindingAction.takeScreenshot.rawValue))
        #expect(OPNCloudSyncSettingsRegistry.isSyncable(OPNUpdatePreferences.automaticUpdateChecksEnabledKey))

        // The Instant Replay settings travel with the stream settings, storage budget included. The
        // allow-list is prefix-based, so this pins the family against a rename that drops the prefix.
        for key in ["OpenNOW.Stream.RecordingMode",
                    "OpenNOW.Stream.RecordingReplayBufferWindowSeconds",
                    "OpenNOW.Stream.RecordingReplayClipSeconds",
                    "OpenNOW.Stream.RecordingReplayQualityIndex",
                    "OpenNOW.Stream.RecordingReplayStorageBudgetGB"] {
            #expect(OPNCloudSyncSettingsRegistry.isSyncable(key), "\(key) must travel with the settings")
        }

        // Credentials, runtime state, and machine-bound values stay local even though they match a prefix.
        for key in OPNCloudSyncSettingsRegistry.deniedKeys {
            #expect(!OPNCloudSyncSettingsRegistry.isSyncable(key), "\(key) must never sync")
        }
        #expect(!OPNCloudSyncSettingsRegistry.isSyncable("OpenNOW.RemoteCoOp.AblyKeyName"))
        #expect(!OPNCloudSyncSettingsRegistry.isSyncable("OpenNOW.Catalog.Favorites.abc"))
        #expect(!OPNCloudSyncSettingsRegistry.isSyncable("AppleLanguages"))
    }

    @Test func theRegistryDeniesTheSessionProxyPasswordEvenAfterAPrefixMatch() {
        #expect(!OPNCloudSyncSettingsRegistry.isSyncable("OpenNOW.Stream.SessionProxyPassword"))
        #expect(!OPNCloudSyncSettingsRegistry.isSyncable("OpenNOW.Stream.ActiveSessionId"))
        // A proxy key added after the deny-list was written still stays local through the prefix rule.
        #expect(!OPNCloudSyncSettingsRegistry.isSyncable("OpenNOW.Stream.SessionProxyLegacyKeychainPurged"))
        #expect(OPNCloudSyncSettingsRegistry.isDenied("OpenNOW.Stream.SessionProxyLegacyKeychainPurged"))
    }

    // MARK: - Property-list round trip

    @Test func aStoredValueSurvivesThePropertyListRoundTrip() throws {
        let values: [String: Any] = [
            "bool": true,
            "int": 42,
            "double": 1.5,
            "string": "balanced",
            "data": Data([0x01, 0x02, 0x03]),
            "array": ["a", "b", 3],
            "dictionary": ["key": "value", "nested": ["x": 1]],
        ]
        for (name, value) in values {
            let encoded = try #require(OPNCloudSyncPlist.encode(value), "\(name) failed to encode")
            let decoded = try #require(OPNCloudSyncPlist.decode(encoded), "\(name) failed to decode")
            #expect(OPNCloudSyncPlist.equal(decoded, value), "\(name) did not round-trip")
        }
    }

    @Test func aBooleanIsNotEqualToAnInteger() {
        #expect(!OPNCloudSyncPlist.equal(true, 1))
        #expect(!OPNCloudSyncPlist.equal("1", 1))
        #expect(OPNCloudSyncPlist.equal(2, 2))
    }

    // MARK: - Settings merge

    @Test func aRemoteValueNewerThanTheBaselineIsImported() throws {
        let key = "OpenNOW.Interface.Appearance"
        let now = Date()
        let remote = OPNCloudSyncSettingsFile(entries: [key: entry("dark", updatedAt: now, device: "B")])
        let baseline = [key: entry("light", updatedAt: now.addingTimeInterval(-60))]
        let result = OPNCloudSyncSettingsRegistry.merge(
            local: [key: "light"],
            remote: remote,
            baseline: baseline,
            device: "A"
        )
        let applied = try #require(result.appliedValues[key] as? String)
        #expect(applied == "dark")
    }

    @Test func aLocalChangeIsExportedAndNotOverwritten() throws {
        let key = "OpenNOW.Interface.Accent"
        let now = Date()
        let remote = OPNCloudSyncSettingsFile(entries: [key: entry("blue", updatedAt: now.addingTimeInterval(-60), device: "B")])
        let baseline = [key: entry("blue", updatedAt: now.addingTimeInterval(-60))]
        let result = OPNCloudSyncSettingsRegistry.merge(
            local: [key: "red"],
            remote: remote,
            baseline: baseline,
            device: "A",
            now: now
        )
        #expect(result.appliedValues[key] == nil)
        let written = try #require(result.file.entries[key])
        #expect(OPNCloudSyncPlist.equal(OPNCloudSyncPlist.decode(written.plist) ?? "", "red"))
        #expect(written.deviceID == "A")
    }

    @Test func aFreshInstallRestoresRatherThanOverwrites() {
        let key = "OpenNOW.Interface.HomeLayout"
        let remote = OPNCloudSyncSettingsFile(entries: [key: entry("poster", updatedAt: Date(), device: "B")])
        let result = OPNCloudSyncSettingsRegistry.merge(
            local: [key: "classic"],
            remote: remote,
            baseline: [:],
            device: "A"
        )
        #expect(result.appliedValues[key] as? String == "poster")
        // The untouched local value must not be pushed over the backup.
        #expect(result.file.entries[key]?.deviceID == "B")
    }

    @Test func anUnchangedLocalValueKeepsTheRemoteTimestamp() throws {
        let key = "OpenNOW.Stream.Fps"
        let created = Date().addingTimeInterval(-3600)
        let remote = OPNCloudSyncSettingsFile(entries: [key: entry(60, updatedAt: created, device: "B")])
        let baseline = [key: entry(60, updatedAt: created)]
        let result = OPNCloudSyncSettingsRegistry.merge(local: [key: 60], remote: remote, baseline: baseline, device: "A")
        #expect(result.appliedValues.isEmpty)
        #expect(result.file.entries[key]?.updatedAt == created)
    }

    @Test func aDeniedEntryIsPrunedFromTheSharedFile() {
        let key = "OpenNOW.Stream.SessionProxyLegacyKeychainPurged"
        let remote = OPNCloudSyncSettingsFile(entries: [key: entry(true, updatedAt: Date(), device: "B")])
        let result = OPNCloudSyncSettingsRegistry.merge(local: [:], remote: remote, baseline: [:], device: "A")
        #expect(result.file.entries[key] == nil)
    }

    // MARK: - Account namespace

    @Test func theAccountNamespaceIsStableAndOpaque() {
        let email = "person@example.com"
        let hashed = OPNCloudSyncAccountNamespace.hash(email)
        #expect(hashed == OPNCloudSyncAccountNamespace.hash(email))
        #expect(hashed.count == 64)
        #expect(!hashed.contains("@"))
        #expect(!hashed.contains("person"))
        #expect(hashed != OPNCloudSyncAccountNamespace.hash("other@example.com"))
    }

    @Test func theAccountNamespaceNormalizesCase() {
        #expect(OPNCloudSyncAccountNamespace.normalized("  RVu9-ABC  ") == "rvu9-abc")
        #expect(OPNCloudSyncAccountNamespace.namespace(for: "RVu9-ABC") == OPNCloudSyncAccountNamespace.namespace(for: "rvu9-abc"))
        // The raw hash is still distinct: it is what a pre-normalization file carries.
        #expect(OPNCloudSyncAccountNamespace.hash("RVu9-ABC") != OPNCloudSyncAccountNamespace.hash("rvu9-abc"))
    }

    // MARK: - Catalog merge

    @Test func catalogContentEqualityIgnoresWhenItWasWritten() {
        let collections = [OPNUserCollection(id: "a", name: "Finished")]
        let older = OPNCloudSyncCatalogFile(generatedAt: .distantPast, deviceID: "A", collectionsByAccount: ["ns": collections], railOrder: ["x"], railsHidden: ["y"])
        let newer = OPNCloudSyncCatalogFile(generatedAt: Date(), deviceID: "B", collectionsByAccount: ["ns": collections], railOrder: ["x"], railsHidden: ["y"])
        #expect(OPNCloudSyncCatalogCodec.isContentEqual(older, newer))
        let different = OPNCloudSyncCatalogFile(generatedAt: Date(), deviceID: "B", collectionsByAccount: [:], railOrder: [], railsHidden: [])
        #expect(!OPNCloudSyncCatalogCodec.isContentEqual(older, different))
    }

    @Test func theCatalogMergeReKeysAPreNormalizationNamespace() {
        let raw = "Alias-\(UUID().uuidString)"
        let normalized = raw.lowercased()
        let carried = [OPNUserCollection(id: "remote", name: "Remote")]
        let priorArrangement = OPNHomeCustomization.arrangement
        CatalogCollectionsStore(collections: [OPNUserCollection(id: "local", name: "Local")]).save(accountIdentifier: raw)
        defer {
            OPNAppPreferenceStorage.syncStore.removeObject(forKey: CatalogCollectionsStore.storageKey(accountIdentifier: raw))
            OPNAppPreferenceStorage.syncStore.removeObject(forKey: CatalogCollectionsStore.storageKey(accountIdentifier: normalized))
            OPNHomeCustomization.arrangement = priorArrangement
        }

        let aliasNamespace = OPNCloudSyncAccountNamespace.hash(raw)
        let normalizedNamespace = OPNCloudSyncAccountNamespace.namespace(for: raw)
        let remote = OPNCloudSyncCatalogFile(generatedAt: .distantPast, deviceID: "B", collectionsByAccount: [aliasNamespace: carried])

        let result = OPNCloudSyncCatalogCodec.merge(remote: remote, device: "A")

        #expect(result.file.collectionsByAccount[aliasNamespace] == nil)
        // The alias's collections are folded into the normalized namespace beside this Mac's own,
        // rather than overwriting them: a re-key must not discard either side.
        let reKeyed = result.file.collectionsByAccount[normalizedNamespace]?.map(\.id).sorted()
        #expect(reKeyed == ["local", "remote"])
    }

    @Test func aTombstoneBeatsAStalePeerCopy() {
        // The peer still carries the collection, but this Mac deleted it later. The deletion wins, so
        // the merged result is the tombstone and there is no live collection left to draw.
        let live = OPNUserCollection(id: "x", name: "X", updatedAt: Date(timeIntervalSince1970: 1_000))
        let tombstone = live.deleting(at: Date(timeIntervalSince1970: 2_000))

        let merged = OPNCloudSyncCatalogCodec.mergedRecords(
            local: [tombstone],
            remote: [live],
            now: Date(timeIntervalSince1970: 2_001)
        )

        #expect(merged.map(\.id) == ["x"])
        let everyRecordIsATombstone = merged.allSatisfy(\.isDeleted)
        #expect(everyRecordIsATombstone)
    }

    @Test func aNewerWriteBeatsAnOlderTombstone() {
        // A genuine re-add after the delete is a newer write, so it wins instead of being swallowed.
        let tombstone = OPNUserCollection(
            id: "x",
            name: "X",
            updatedAt: Date(timeIntervalSince1970: 1_000),
            deletedAt: Date(timeIntervalSince1970: 1_000)
        )
        let readded = OPNUserCollection(id: "x", name: "X again", updatedAt: Date(timeIntervalSince1970: 3_000))

        let merged = OPNCloudSyncCatalogCodec.mergedRecords(
            local: [tombstone],
            remote: [readded],
            now: Date(timeIntervalSince1970: 3_001)
        )

        #expect(merged.map(\.id) == ["x"])
        #expect(merged.first?.isDeleted == false)
    }

    @Test func anAgedOutTombstoneIsPrunedOnceEveryPeerHasHadLongEnough() {
        let old = Date(timeIntervalSince1970: 0)
        let tombstone = OPNUserCollection(id: "x", name: "X", updatedAt: old, deletedAt: old)

        let merged = OPNCloudSyncCatalogCodec.mergedRecords(
            local: [tombstone],
            remote: [],
            now: old.addingTimeInterval(OPNUserCollection.tombstoneRetention + 1)
        )

        #expect(merged.isEmpty)
    }

    @Test func aFreshMacsEmptyArrangementDoesNotOverwriteTheBackup() {
        let priorArrangement = OPNHomeCustomization.arrangement
        defer { OPNHomeCustomization.arrangement = priorArrangement }
        OPNHomeCustomization.arrangement = .default

        let remote = OPNCloudSyncCatalogFile(deviceID: "B", railOrder: ["x"], railsHidden: ["y"])
        let result = OPNCloudSyncCatalogCodec.merge(remote: remote, device: "A")

        #expect(result.file.railOrder == ["x"])
        #expect(result.file.railsHidden == ["y"])
    }

    @Test func restoringDropsCollectionsTheBackupDoesNotCarry() {
        let account = "collections-restore-a"
        let namespace = OPNCloudSyncAccountNamespace.namespace(for: account)
        let backup = OPNCloudSyncCatalogFile(
            deviceID: "B",
            collectionsByAccount: [namespace: [OPNUserCollection(id: "remote", name: "From backup")]]
        )

        let replacements = OPNCloudSyncCatalogCodec.replacementRecords(for: backup, accounts: [namespace: account])
        #expect(replacements[account]?.map(\.id) == ["remote"])

        // An account the backup does not carry is emptied, not left holding a local-only collection.
        let absentAccount = "collections-restore-b"
        let absentNamespace = OPNCloudSyncAccountNamespace.namespace(for: absentAccount)
        let withAbsent = OPNCloudSyncCatalogCodec.replacementRecords(for: backup, accounts: [namespace: account, absentNamespace: absentAccount])
        #expect(withAbsent[absentAccount] == [])
    }

    @Test func anAliasIdentifierResolvesToTheAccountNamespace() {
        let canonical = "collections-canonical-\(UUID().uuidString.lowercased())"
        let alias = "collections-alias-\(UUID().uuidString.lowercased())@example.com"
        OPNCloudSyncAccountNamespace.registerCurrentAccount(canonical, candidates: [alias])
        defer { removeRegisteredAccounts(canonical: canonical, alias: alias) }

        let aliasNamespace = OPNCloudSyncAccountNamespace.hash(alias)
        #expect(OPNCloudSyncAccountNamespace.importableAccounts()[aliasNamespace] == canonical)
        #expect(OPNCloudSyncAccountNamespace.aliasNormalizations()[aliasNamespace] == OPNCloudSyncAccountNamespace.namespace(for: canonical))
    }

    @Test func theArrangementSignatureIgnoresWhenAndWhereItWasWritten() {
        // Only the arrangement is signed: collections always merge per identity and never conflict.
        let older = OPNCloudSyncCatalogFile(generatedAt: .distantPast, deviceID: "A", deviceName: "Old Mac", collectionsByAccount: ["ns": [OPNUserCollection(id: "a", name: "Finished")]], railOrder: ["x"], railsHidden: ["y"])
        let newer = OPNCloudSyncCatalogFile(generatedAt: Date(), deviceID: "B", deviceName: "New Mac", collectionsByAccount: ["ns": [OPNUserCollection(id: "b", name: "Other")]], railOrder: ["x"], railsHidden: ["y"])
        #expect(OPNCloudSyncCatalogCodec.arrangementSignature(older) == OPNCloudSyncCatalogCodec.arrangementSignature(newer))

        let different = OPNCloudSyncCatalogFile(generatedAt: Date(), deviceID: "B", railOrder: [], railsHidden: [])
        #expect(OPNCloudSyncCatalogCodec.arrangementSignature(older) != OPNCloudSyncCatalogCodec.arrangementSignature(different))
    }

    @Test func collectionEditsNeverRaiseAConflict() {
        // A collection changed on both Macs since the baseline is a merge, not a decision: the
        // newest write wins, so no prompt is raised for collections alone.
        let agreed = OPNCloudSyncCatalogFile(deviceID: "A", collectionsByAccount: ["ns": [OPNUserCollection(id: "a", name: "One")]])
        let baseline = OPNCloudSyncCatalogCodec.SignatureBaseline(
            local: OPNCloudSyncCatalogCodec.arrangementSignature(agreed),
            remote: OPNCloudSyncCatalogCodec.arrangementSignature(agreed)
        )
        let localEdit = OPNCloudSyncCatalogFile(deviceID: "A", collectionsByAccount: ["ns": [OPNUserCollection(id: "a", name: "Local edit", updatedAt: Date(timeIntervalSince1970: 2_000))]])
        let remoteEdit = OPNCloudSyncCatalogFile(deviceID: "B", collectionsByAccount: ["ns": [OPNUserCollection(id: "a", name: "Remote edit", updatedAt: Date(timeIntervalSince1970: 1_000))]])

        #expect(OPNCloudSyncCatalogCodec.detectConflict(remote: remoteEdit, baseline: baseline, local: localEdit) == nil)
    }

    @Test func aConflictNeedsBothSidesToChangeTheArrangementFromTheBaseline() {
        let agreed = OPNCloudSyncCatalogFile(deviceID: "A", railOrder: ["a"], railsHidden: [])
        let baseline = OPNCloudSyncCatalogCodec.SignatureBaseline(
            local: OPNCloudSyncCatalogCodec.arrangementSignature(agreed),
            remote: OPNCloudSyncCatalogCodec.arrangementSignature(agreed)
        )
        let localEdit = OPNCloudSyncCatalogFile(deviceID: "A", railOrder: ["a", "b"], railsHidden: [])
        let remoteEdit = OPNCloudSyncCatalogFile(deviceID: "B", deviceName: "Studio Mac", railOrder: ["b", "a"], railsHidden: [])

        // Only local moved: it exports. Only remote moved: it imports. Neither is a conflict.
        #expect(OPNCloudSyncCatalogCodec.detectConflict(remote: agreed, baseline: baseline, local: localEdit) == nil)
        #expect(OPNCloudSyncCatalogCodec.detectConflict(remote: remoteEdit, baseline: baseline, local: agreed) == nil)

        let conflict = OPNCloudSyncCatalogCodec.detectConflict(remote: remoteEdit, baseline: baseline, local: localEdit)
        #expect(conflict?.remoteDeviceID == "B")
        #expect(conflict?.remoteDeviceName == "Studio Mac")
        #expect(conflict?.remoteDisplayName == "Studio Mac")

        // Before any settled sync there is no baseline, so the first merge runs unattended.
        #expect(OPNCloudSyncCatalogCodec.detectConflict(remote: remoteEdit, baseline: nil, local: localEdit) == nil)
    }

    @Test func theSettingsSignatureIgnoresKeyOrder() {
        let first: [String: Any] = ["k1": "v1", "k2": 2]
        let reordered: [String: Any] = ["k2": 2, "k1": "v1"]
        #expect(OPNCloudSyncSettingsRegistry.contentSignature(values: first) == OPNCloudSyncSettingsRegistry.contentSignature(values: reordered))
        #expect(OPNCloudSyncSettingsRegistry.contentSignature(values: first) != OPNCloudSyncSettingsRegistry.contentSignature(values: ["k1": "v1", "k2": 3]))
    }

    @Test func aSettingsConflictNeedsBothSidesChangedFromTheBaseline() {
        let key = "OpenNOW.Interface.Appearance"
        let agreed: [String: Any] = [key: "balanced"]
        let baseline = OPNCloudSyncSettingsRegistry.SignatureBaseline(
            local: OPNCloudSyncSettingsRegistry.contentSignature(values: agreed),
            remote: OPNCloudSyncSettingsRegistry.contentSignature(values: agreed)
        )
        let localEdit: [String: Any] = [key: "dark"]
        let unchangedRemote = OPNCloudSyncSettingsFile(entries: [key: entry("balanced", updatedAt: Date(), device: "B")])
        let changedRemote = OPNCloudSyncSettingsFile(deviceName: "Studio Mac", entries: [key: entry("light", updatedAt: Date(), device: "B")])

        // No baseline yet, or only one side moved: no conflict.
        #expect(OPNCloudSyncSettingsRegistry.detectConflict(local: localEdit, remote: changedRemote, baseline: nil) == nil)
        #expect(OPNCloudSyncSettingsRegistry.detectConflict(local: localEdit, remote: unchangedRemote, baseline: baseline) == nil)
        #expect(OPNCloudSyncSettingsRegistry.detectConflict(local: agreed, remote: changedRemote, baseline: baseline) == nil)

        let conflict = OPNCloudSyncSettingsRegistry.detectConflict(local: localEdit, remote: changedRemote, baseline: baseline)
        #expect(conflict?.category == .settings)
        #expect(conflict?.remoteDeviceName == "Studio Mac")
        #expect(conflict?.remoteDisplayName == "Studio Mac")
    }

    // MARK: - Screenshot mirror

    @Test func theScreenshotMirrorCopiesNewFilesAndSkipsIdenticalOnes() throws {
        let fileManager = FileManager.default
        let source = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? fileManager.removeItem(at: source)
            try? fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: source.appendingPathComponent("shot.png"))
        try Data("meta".utf8).write(to: source.appendingPathComponent("shot.json"))
        try Data("notes".utf8).write(to: source.appendingPathComponent("readme.txt"))

        let first = try OPNCloudSyncFileMirror.mirror(from: source, to: destination)
        #expect(first.copied == 2)
        #expect(!fileManager.fileExists(atPath: destination.appendingPathComponent("readme.txt").path))

        let second = try OPNCloudSyncFileMirror.mirror(from: source, to: destination)
        #expect(second.copied == 0)
        #expect(second.skipped == 2)
    }
}

/// Removes the alias/current-account entries a test registered, leaving any another test wrote.
private func removeRegisteredAccounts(canonical: String, alias: String) {
    let storage = OPNAppPreferenceStorage.syncStore
    var current = storage.array(forKey: OPNCloudSyncAccountNamespace.currentAccountsKey) as? [String] ?? []
    current.removeAll { $0 == OPNCloudSyncAccountNamespace.normalized(canonical) }
    storage.set(current, forKey: OPNCloudSyncAccountNamespace.currentAccountsKey)

    var aliases = storage.dictionary(forKey: OPNCloudSyncAccountNamespace.aliasesKey) as? [String: String] ?? [:]
    aliases.removeValue(forKey: OPNCloudSyncAccountNamespace.normalized(alias))
    storage.set(aliases, forKey: OPNCloudSyncAccountNamespace.aliasesKey)
}
