import Foundation
import Testing
@testable import OpenNOW

/// The iCloud backup's pure logic: which preferences travel, how a conflict is decided, how account
/// namespaces are built, and how the screenshot mirror treats an already-present file.
@Suite struct OPNCloudSyncTests {
    private func entry(_ value: Any, updatedAt: Date, device: String = "A") -> OPNCloudSyncSettingsEntry {
        OPNCloudSyncSettingsEntry(plist: OPNCloudSyncPlist.encode(value) ?? Data(), updatedAt: updatedAt, deviceID: device)
    }

    // MARK: - Registry

    @Test func theRegistryExportsPreferencesAndRefusesSecrets() {
        // Preferences under an allowed prefix travel.
        #expect(OPNCloudSyncSettingsRegistry.isSyncable("OpenNOW.Interface.Appearance"))
        #expect(OPNCloudSyncSettingsRegistry.isSyncable("OpenNOW.Stream.Fps"))
        #expect(OPNCloudSyncSettingsRegistry.isSyncable("OpenNOW.Input.ControllerMappingProfiles"))
        #expect(OPNCloudSyncSettingsRegistry.isSyncable(KeybindingAction.takeScreenshot.rawValue))
        #expect(OPNCloudSyncSettingsRegistry.isSyncable(OPNUpdatePreferences.automaticUpdateChecksEnabledKey))

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

    // MARK: - Catalog merge

    @Test func catalogContentEqualityIgnoresWhenItWasWritten() {
        let collections = [OPNUserCollection(id: "a", name: "Finished")]
        let older = OPNCloudSyncCatalogFile(generatedAt: .distantPast, deviceID: "A", collectionsByAccount: ["ns": collections], railOrder: ["x"], railsHidden: ["y"])
        let newer = OPNCloudSyncCatalogFile(generatedAt: Date(), deviceID: "B", collectionsByAccount: ["ns": collections], railOrder: ["x"], railsHidden: ["y"])
        #expect(OPNCloudSyncCatalogCodec.isContentEqual(older, newer))
        let different = OPNCloudSyncCatalogFile(generatedAt: Date(), deviceID: "B", collectionsByAccount: [:], railOrder: [], railsHidden: [])
        #expect(!OPNCloudSyncCatalogCodec.isContentEqual(older, different))
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

        let first = try OPNCloudSyncScreenshotMirror.mirror(from: source, to: destination)
        #expect(first.copied == 2)
        #expect(!fileManager.fileExists(atPath: destination.appendingPathComponent("readme.txt").path))

        let second = try OPNCloudSyncScreenshotMirror.mirror(from: source, to: destination)
        #expect(second.copied == 0)
        #expect(second.skipped == 2)
    }
}
