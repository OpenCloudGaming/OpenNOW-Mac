import Foundation
import Testing
@testable import OpenNOW

@MainActor
@Suite struct ControllerMappingStoreTests {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "ControllerMappingStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func freshInstallAutoActivatesADefaultPassthroughProfile() throws {
        let defaults = try makeDefaults()
        let store = ControllerMappingStore(defaults: defaults)
        #expect(store.profiles.count == 1)
        #expect(store.activeProfileID == store.profiles.first?.id)
        #expect(store.activeProfile?.rightPad.mode == .mouse)
        #expect(store.activeProfile?.binding(for: .rightPadClick) == .mouseButton(.left))
    }

    @Test func migratesLegacyGripComboAndDisabledTrackpad() throws {
        let defaults = try makeDefaults()
        let legacyProfile = SteamControllerGripProfile(name: "Legacy", combos: [
            .l4: ControllerButtonChord(buttons: [.south]),
        ])
        let data = try JSONEncoder().encode([legacyProfile])
        defaults.set(data, forKey: "OpenNOW.Input.SteamControllerGripProfiles")
        defaults.set(legacyProfile.id.uuidString, forKey: "OpenNOW.Input.SteamControllerGripActiveProfile")
        defaults.set(false, forKey: SteamControllerTrackpadMousePreference.key)

        let store = ControllerMappingStore(defaults: defaults)
        #expect(store.activeProfile?.binding(for: .leftGrip) == .gamepadChord(ControllerButtonChord(buttons: [.south])))
        #expect(store.activeProfile?.rightPad.mode == .disabled)
        #expect(store.activeProfile?.binding(for: .rightPadClick) == .disabled)
    }

    @Test func createUpdateAndDeletePersist() throws {
        let defaults = try makeDefaults()
        let store = ControllerMappingStore(defaults: defaults)
        let profile = store.createProfile(named: "Racing")
        var updated = profile
        updated.bindings[.faceA] = .keyboardKey(keyCode: 49, modifiers: [])
        store.updateProfile(updated)

        let reloaded = ControllerMappingStore(defaults: defaults)
        #expect(reloaded.activeProfileID == profile.id)
        #expect(reloaded.activeProfile?.binding(for: .faceA) == .keyboardKey(keyCode: 49, modifiers: []))

        reloaded.deleteProfile(profile.id)
        #expect(reloaded.profiles.contains(where: { $0.id == profile.id }) == false)
    }

    @Test func migratesAllSavedSteamProfilesWithoutChangingIDsOrBindings() throws {
        let defaults = try makeDefaults()
        let first = ControllerMappingProfile(name: "First", bindings: [.faceA: .keyboardKey(keyCode: 49, modifiers: [.shift])])
        var second = ControllerMappingProfile(name: "Second", bindings: [.leftGrip: .gamepadChord(ControllerButtonChord(buttons: [.north]))])
        second.rightPad = ControllerPadSettings(mode: .mouse, sensitivity: 2.5, invertY: true)
        let encoded = try JSONEncoder().encode([first, second])
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        for index in legacy.indices {
            legacy[index].removeValue(forKey: "family")
            legacy[index].removeValue(forKey: "touchpad")
        }
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "OpenNOW.Input.SteamControllerMappingProfiles")
        defaults.set(second.id.uuidString, forKey: "OpenNOW.Input.SteamControllerMappingActiveProfile")
        let migrated = ControllerMappingStore(defaults: defaults)
        #expect(migrated.profiles == [first, second])
        #expect(migrated.activeProfileID == second.id)
        #expect(defaults.data(forKey: ControllerMappingStore.profilesKey) != nil)
        #expect(ControllerMappingStore(defaults: defaults).profiles == [first, second])
    }

    // MARK: - Per-family defaults

    @Test func eachFamilyHoldsItsOwnDefaultAndItSurvivesRelaunch() throws {
        let defaults = try makeDefaults()
        let store = ControllerMappingStore(defaults: defaults)
        let steamDefault = try #require(store.activeProfileID)
        let ds4 = store.createProfile(named: "DS4 aim", family: .dualShock4)
        #expect(store.activeProfileID == steamDefault)
        #expect(store.defaultProfileID(for: .dualShock4) == ds4.id)
        #expect(store.profile(for: .steam)?.id == steamDefault)
        #expect(store.profile(for: .dualShock4)?.id == ds4.id)
        #expect(store.profile(for: .generic) == nil)

        let reopened = ControllerMappingStore(defaults: defaults)
        #expect(reopened.defaultProfileID(for: .dualShock4) == ds4.id)
        #expect(reopened.defaultProfileID(for: .steam) == steamDefault)
    }

    @Test func creatingAProfileMakesItThatFamilysDefault() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        let steamDefault = try #require(store.activeProfileID)
        let generic = store.createProfile(named: "Generic pad", family: .generic)
        #expect(store.defaultProfileID(for: .generic) == generic.id)
        // The steam default is untouched: creating for one family never reassigns another.
        #expect(store.activeProfileID == steamDefault)
    }

    @Test func clearingADefaultIsNotUndoneByARelaunch() throws {
        let defaults = try makeDefaults()
        let store = ControllerMappingStore(defaults: defaults)
        store.setDefaultProfile(nil, for: .steam)
        #expect(store.profile(for: .steam) == nil)
        let reopened = ControllerMappingStore(defaults: defaults)
        #expect(reopened.profile(for: .steam) == nil)
    }

    // MARK: - Resolution chain

    @Test func gameOverrideOutranksTheFamilyDefaultAndIsFamilyScoped() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        let familyDefault = store.createProfile(named: "Generic default", family: .generic)
        let racing = store.createProfile(named: "Racing", family: .generic)
        store.setDefaultProfile(familyDefault.id, for: .generic)
        store.beginSession(appId: "100", catalogIdentity: "game-100")
        #expect(store.profile(for: .generic)?.id == familyDefault.id)

        store.setGameOverride(profileID: racing.id, for: .generic)
        #expect(store.profile(for: .generic)?.id == racing.id, "level 1: enabled override")
        // A different type is unaffected by the generic override.
        #expect(store.profile(for: .dualShock4) == nil)

        store.endSession()
        #expect(store.profile(for: .generic)?.id == familyDefault.id, "level 2: type default")
    }

    @Test func aFamilyWithNoDefaultResolvesToBlankPassthrough() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        #expect(store.profile(for: .generic) == nil)
        store.beginSession(appId: "7", catalogIdentity: "game-7")
        #expect(store.profile(for: .generic) == nil)
    }

    @Test func disabledOverrideIsInertButRetained() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        let familyDefault = store.createProfile(named: "Generic default", family: .generic)
        let racing = store.createProfile(named: "Racing", family: .generic)
        store.setDefaultProfile(familyDefault.id, for: .generic)
        store.beginSession(appId: "100", catalogIdentity: "game-100")
        store.setGameOverride(profileID: racing.id, for: .generic)
        #expect(store.profile(for: .generic)?.id == racing.id)

        store.setGameOverrideEnabled(false, for: .generic)
        #expect(store.profile(for: .generic)?.id == familyDefault.id, "disabled override must not resolve")
        #expect(store.storedOverride(for: .generic)?.profileID == racing.id, "but it is retained")
        #expect(store.activeOverride(for: .generic) == nil)
    }

    @Test func anOverrideWhoseProfileIsAbsentLocallyFallsThrough() throws {
        let defaults = try makeDefaults()
        let seeded = ControllerMappingStore(defaults: defaults)
        let fallback = seeded.createProfile(named: "Fallback", family: .generic)
        seeded.setDefaultProfile(fallback.id, for: .generic)

        // A blob from another Mac naming a profile this Mac has never merged.
        let foreign = ControllerMappingGameOverrides(storage: [
            "game-100": ["generic": ControllerMappingGameOverride(profileID: UUID())],
        ])
        defaults.set(try JSONEncoder().encode(foreign), forKey: ControllerMappingStore.gameOverridesKey)

        let store = ControllerMappingStore(defaults: defaults)
        store.beginSession(appId: "100", catalogIdentity: "game-100")
        #expect(store.profile(for: .generic)?.id == fallback.id)
        #expect(store.activeOverride(for: .generic) == nil)
        #expect(store.storedOverride(for: .generic) != nil)
    }

    @Test func deletedProfileClearsEveryDefaultAndOverrideReferencingIt() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        let shared = store.createProfile(named: "Shared", family: .generic)
        store.setDefaultProfile(shared.id, for: .generic)
        store.beginSession(appId: "100", catalogIdentity: "game-100")
        store.setGameOverride(profileID: shared.id, for: .generic)
        store.beginSession(appId: "200", catalogIdentity: "game-200")
        store.setGameOverride(profileID: shared.id, for: .generic)

        store.deleteProfile(shared.id)
        #expect(store.defaultProfileID(for: .generic) == nil)
        #expect(store.gameOverrides.override(for: "game-100", family: .generic) == nil)
        #expect(store.gameOverrides.override(for: "game-200", family: .generic) == nil)
        #expect(store.gameOverrides.isEmpty)
    }

    @Test func overridesAreKeyedOnCatalogIdentityNotAppId() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        let racing = store.createProfile(named: "Racing", family: .generic)
        store.beginSession(appId: "100", catalogIdentity: "title-42")
        store.setGameOverride(profileID: racing.id, for: .generic)

        // A second storefront/app id for the same title resolves the same override.
        store.beginSession(appId: "200", catalogIdentity: "title-42")
        #expect(store.profile(for: .generic)?.id == racing.id)
        #expect(store.gameOverrides.override(for: "title-42", family: .generic) != nil)
        #expect(store.gameOverrides.override(for: "100", family: .generic) == nil)
    }

    // MARK: - Session / resume index

    @Test func aResumedSessionResolvesThroughTheAppIdIndex() throws {
        let defaults = try makeDefaults()
        let store = ControllerMappingStore(defaults: defaults)
        let familyDefault = store.createProfile(named: "Generic default", family: .generic)
        let racing = store.createProfile(named: "Racing", family: .generic)
        store.setDefaultProfile(familyDefault.id, for: .generic)
        store.beginSession(appId: "100", catalogIdentity: "title-42")
        store.setGameOverride(profileID: racing.id, for: .generic)

        // Resume: only the app id is known, exactly what `OPNActiveSessionEntry` carries.
        let resumed = ControllerMappingStore(defaults: defaults)
        resumed.beginSession(appId: "100", catalogIdentity: nil)
        #expect(resumed.profile(for: .generic)?.id == racing.id)

        // An unknown app id falls back to the type default rather than guessing.
        resumed.beginSession(appId: "999", catalogIdentity: nil)
        #expect(resumed.profile(for: .generic)?.id == familyDefault.id)
        #expect(resumed.activeOverride(for: .generic) == nil)
    }

    @Test func endingASessionReturnsToTheFamilyDefault() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        let defaultProfile = store.createProfile(named: "Generic default", family: .generic)
        let racing = store.createProfile(named: "Racing", family: .generic)
        store.setDefaultProfile(defaultProfile.id, for: .generic)
        store.beginSession(appId: "100", catalogIdentity: "game-100")
        store.setGameOverride(profileID: racing.id, for: .generic)
        #expect(store.profile(for: .generic)?.id == racing.id)

        store.endSession()
        #expect(store.profile(for: .generic)?.id == defaultProfile.id)
        #expect(store.hasCurrentGame == false)
    }

    // MARK: - Tolerance

    @Test func corruptDataInTheNewKeysIsIgnoredWithoutFailingStartup() throws {
        let defaults = try makeDefaults()
        let profiles = ControllerMappingStore(defaults: defaults)
        let profile = try #require(profiles.activeProfile)
        defaults.set(Data("not json".utf8), forKey: ControllerMappingStore.gameOverridesKey)
        defaults.set(Data("not json".utf8), forKey: ControllerMappingStore.defaultProfilesKey)
        defaults.set(Data("not json".utf8), forKey: ControllerMappingStore.appIdIdentityIndexKey)

        let store = ControllerMappingStore(defaults: defaults)
        #expect(store.profiles.contains(profile))
        #expect(store.gameOverrides.isEmpty)
        #expect(store.activeProfileID == profile.id, "a corrupt default key falls back to the first Steam profile")
        store.beginSession(appId: "100", catalogIdentity: nil)
        #expect(store.hasCurrentGame == false)
        #expect(store.profile(for: .steam)?.id == profile.id)
    }

    @Test func legacySteamOnlyDefaultMigratesIntoThePerFamilyMap() throws {
        let defaults = try makeDefaults()
        let first = ControllerMappingProfile(name: "First")
        let second = ControllerMappingProfile(name: "Second")
        defaults.set(try JSONEncoder().encode([first, second]), forKey: ControllerMappingStore.profilesKey)
        defaults.set(second.id.uuidString, forKey: ControllerMappingStore.legacyActiveProfileKey)
        #expect(defaults.data(forKey: ControllerMappingStore.defaultProfilesKey) == nil)

        let store = ControllerMappingStore(defaults: defaults)
        #expect(store.activeProfileID == second.id)
        #expect(defaults.data(forKey: ControllerMappingStore.defaultProfilesKey) != nil)
        // Read once: the superseded key carries nothing once the new one owns the default.
        #expect(defaults.string(forKey: ControllerMappingStore.legacyActiveProfileKey) == nil)
    }
}
