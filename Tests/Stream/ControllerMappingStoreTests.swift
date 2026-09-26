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

    @Test func aFreshInstallActivatesTheDefaultPassthroughProfile() throws {
        let defaults = try makeDefaults()
        let store = ControllerMappingStore(defaults: defaults)
        #expect(store.profiles.count == 1)
        #expect(store.defaultProfileID(for: .steam) == store.profiles.first?.id)
        #expect(store.activeProfile?.rightPad.mode == .mouse)
        #expect(store.activeProfile?.binding(for: .rightPadClick) == .mouseButton(.left))
    }

    @Test func legacyGripProfileFoldsIntoTheFirstProfile() throws {
        let defaults = try makeDefaults()
        let legacyProfile = SteamControllerGripProfile(name: "Legacy", combos: [
            .l4: ControllerButtonChord(buttons: [.south]),
        ])
        defaults.set(try JSONEncoder().encode([legacyProfile]), forKey: "OpenNOW.Input.SteamControllerGripProfiles")
        defaults.set(legacyProfile.id.uuidString, forKey: "OpenNOW.Input.SteamControllerGripActiveProfile")
        defaults.set(false, forKey: SteamControllerTrackpadMousePreference.key)

        let store = ControllerMappingStore(defaults: defaults)
        #expect(store.activeProfile?.binding(for: .leftGrip) == .gamepadChord(ControllerButtonChord(buttons: [.south])))
        #expect(store.activeProfile?.rightPad.mode == .disabled)
        #expect(store.activeProfile?.binding(for: .rightPadClick) == .disabled)
    }

    @Test func profileEditsPersistAcrossReload() throws {
        let defaults = try makeDefaults()
        let store = ControllerMappingStore(defaults: defaults)
        let racingProfile = store.createProfile(named: "Racing")
        var editedProfile = racingProfile
        editedProfile.bindings[.faceA] = .keyboardKey(keyCode: 49, modifiers: [])
        store.updateProfile(editedProfile)

        let reloadedStore = ControllerMappingStore(defaults: defaults)
        #expect(reloadedStore.defaultProfileID(for: .steam) == racingProfile.id)
        #expect(reloadedStore.activeProfile?.binding(for: .faceA) == .keyboardKey(keyCode: 49, modifiers: []))

        reloadedStore.deleteProfile(racingProfile.id)
        #expect(reloadedStore.profiles.contains(where: { $0.id == racingProfile.id }) == false)
    }

    @Test func migrationPreservesExistingSteamProfiles() throws {
        let defaults = try makeDefaults()
        let firstProfile = ControllerMappingProfile(name: "First", bindings: [.faceA: .keyboardKey(keyCode: 49, modifiers: [.shift])])
        var secondProfile = ControllerMappingProfile(name: "Second", bindings: [.leftGrip: .gamepadChord(ControllerButtonChord(buttons: [.north]))])
        secondProfile.rightPad = ControllerPadSettings(mode: .mouse, sensitivity: 2.5, invertY: true)
        let encodedProfiles = try JSONEncoder().encode([firstProfile, secondProfile])
        var legacyProfiles = try #require(JSONSerialization.jsonObject(with: encodedProfiles) as? [[String: Any]])
        for index in legacyProfiles.indices {
            legacyProfiles[index].removeValue(forKey: "family")
            legacyProfiles[index].removeValue(forKey: "touchpad")
        }
        defaults.set(try JSONSerialization.data(withJSONObject: legacyProfiles), forKey: "OpenNOW.Input.SteamControllerMappingProfiles")
        defaults.set(secondProfile.id.uuidString, forKey: ControllerMappingStore.legacySteamDefaultKey)

        let migratedStore = ControllerMappingStore(defaults: defaults)
        #expect(migratedStore.profiles == [firstProfile, secondProfile])
        #expect(migratedStore.defaultProfileID(for: .steam) == secondProfile.id)
        #expect(defaults.data(forKey: ControllerMappingStore.profilesKey) != nil)
        #expect(ControllerMappingStore(defaults: defaults).profiles == [firstProfile, secondProfile])
    }

    // MARK: - Per-family defaults

    @Test func eachFamilyKeepsItsOwnDefaultAcrossRelaunch() throws {
        let defaults = try makeDefaults()
        let store = ControllerMappingStore(defaults: defaults)
        let steamDefaultID = try #require(store.defaultProfileID(for: .steam))
        let dualShockProfile = store.createProfile(named: "DS4 aim", family: .dualShock4)
        #expect(store.defaultProfileID(for: .steam) == steamDefaultID)
        #expect(store.defaultProfileID(for: .dualShock4) == dualShockProfile.id)
        #expect(store.profile(for: .steam)?.id == steamDefaultID)
        #expect(store.profile(for: .dualShock4)?.id == dualShockProfile.id)
        #expect(store.profile(for: .generic) == nil)

        let reopenedStore = ControllerMappingStore(defaults: defaults)
        #expect(reopenedStore.defaultProfileID(for: .dualShock4) == dualShockProfile.id)
        #expect(reopenedStore.defaultProfileID(for: .steam) == steamDefaultID)
    }

    @Test func creatingAProfileMakesItThatFamilysDefault() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        let steamDefaultID = try #require(store.defaultProfileID(for: .steam))
        let genericProfile = store.createProfile(named: "Generic pad", family: .generic)
        #expect(store.defaultProfileID(for: .generic) == genericProfile.id)
        // Creating for one family never reassigns another family's default.
        #expect(store.defaultProfileID(for: .steam) == steamDefaultID)
    }

    @Test func clearingADefaultSurvivesRelaunch() throws {
        let defaults = try makeDefaults()
        let store = ControllerMappingStore(defaults: defaults)
        store.setDefaultProfile(nil, for: .steam)
        #expect(store.profile(for: .steam) == nil)
        let reopenedStore = ControllerMappingStore(defaults: defaults)
        #expect(reopenedStore.profile(for: .steam) == nil)
    }

    // MARK: - Resolution chain

    @Test func aGameOverrideOutranksTheFamilyDefault() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        let familyDefaultProfile = store.createProfile(named: "Generic default", family: .generic)
        let racingProfile = store.createProfile(named: "Racing", family: .generic)
        store.setDefaultProfile(familyDefaultProfile.id, for: .generic)
        store.beginSession(appId: "100", catalogIdentity: "game-100")
        #expect(store.profile(for: .generic)?.id == familyDefaultProfile.id)

        store.setGameOverride(profileID: racingProfile.id, for: .generic)
        #expect(store.profile(for: .generic)?.id == racingProfile.id)
    }

    @Test func aGameOverrideLeavesOtherFamiliesUntouched() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        let racingProfile = store.createProfile(named: "Racing", family: .generic)
        store.beginSession(appId: "100", catalogIdentity: "game-100")
        store.setGameOverride(profileID: racingProfile.id, for: .generic)
        #expect(store.profile(for: .dualShock4) == nil)
    }

    @Test func aFamilyWithoutADefaultResolvesToBlankPassthrough() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        #expect(store.profile(for: .generic) == nil)
        store.beginSession(appId: "7", catalogIdentity: "game-7")
        #expect(store.profile(for: .generic) == nil)
    }

    @Test func aDisabledOverrideIsRetainedYetInert() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        let familyDefaultProfile = store.createProfile(named: "Generic default", family: .generic)
        let racingProfile = store.createProfile(named: "Racing", family: .generic)
        store.setDefaultProfile(familyDefaultProfile.id, for: .generic)
        store.beginSession(appId: "100", catalogIdentity: "game-100")
        store.setGameOverride(profileID: racingProfile.id, for: .generic)
        #expect(store.profile(for: .generic)?.id == racingProfile.id)

        store.setGameOverrideEnabled(false, for: .generic)
        #expect(store.profile(for: .generic)?.id == familyDefaultProfile.id)
        #expect(store.storedOverride(for: .generic)?.profileID == racingProfile.id)
        #expect(store.activeOverride(for: .generic) == nil)
    }

    @Test func anOverrideWithoutALocalProfileFallsThrough() throws {
        let defaults = try makeDefaults()
        let seededStore = ControllerMappingStore(defaults: defaults)
        let fallbackProfile = seededStore.createProfile(named: "Fallback", family: .generic)
        seededStore.setDefaultProfile(fallbackProfile.id, for: .generic)

        // A blob from another Mac naming a profile this Mac has never merged.
        let foreignOverrides = ControllerMappingGameOverrides(overridesByGameIdentity: [
            "game-100": ["generic": ControllerMappingGameOverride(profileID: UUID())],
        ])
        defaults.set(try JSONEncoder().encode(foreignOverrides), forKey: ControllerMappingStore.gameOverridesKey)

        let store = ControllerMappingStore(defaults: defaults)
        store.beginSession(appId: "100", catalogIdentity: "game-100")
        #expect(store.profile(for: .generic)?.id == fallbackProfile.id)
        #expect(store.activeOverride(for: .generic) == nil)
        #expect(store.storedOverride(for: .generic) != nil)
    }

    @Test func deletingAProfileClearsEveryReference() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        let sharedProfile = store.createProfile(named: "Shared", family: .generic)
        store.setDefaultProfile(sharedProfile.id, for: .generic)
        store.beginSession(appId: "100", catalogIdentity: "game-100")
        store.setGameOverride(profileID: sharedProfile.id, for: .generic)
        store.beginSession(appId: "200", catalogIdentity: "game-200")
        store.setGameOverride(profileID: sharedProfile.id, for: .generic)

        store.deleteProfile(sharedProfile.id)
        #expect(store.defaultProfileID(for: .generic) == nil)
        #expect(store.gameOverrides.override(forGameIdentity: "game-100", family: .generic) == nil)
        #expect(store.gameOverrides.override(forGameIdentity: "game-200", family: .generic) == nil)
        #expect(store.gameOverrides.isEmpty)
    }

    @Test func overridesResolveByCatalogIdentityAcrossStorefronts() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        let racingProfile = store.createProfile(named: "Racing", family: .generic)
        store.beginSession(appId: "100", catalogIdentity: "title-42")
        store.setGameOverride(profileID: racingProfile.id, for: .generic)

        // A second storefront's app id for the same title resolves the same override.
        store.beginSession(appId: "200", catalogIdentity: "title-42")
        #expect(store.profile(for: .generic)?.id == racingProfile.id)
        #expect(store.gameOverrides.override(forGameIdentity: "title-42", family: .generic) != nil)
        #expect(store.gameOverrides.override(forGameIdentity: "100", family: .generic) == nil)
    }

    // MARK: - Session and resume index

    @Test func aResumedSessionResolvesThroughTheAppIdIndex() throws {
        let defaults = try makeDefaults()
        let store = ControllerMappingStore(defaults: defaults)
        let familyDefaultProfile = store.createProfile(named: "Generic default", family: .generic)
        let racingProfile = store.createProfile(named: "Racing", family: .generic)
        store.setDefaultProfile(familyDefaultProfile.id, for: .generic)
        store.beginSession(appId: "100", catalogIdentity: "title-42")
        store.setGameOverride(profileID: racingProfile.id, for: .generic)

        // Resume carries only the app id, exactly what `OPNActiveSessionEntry` exposes.
        let resumedStore = ControllerMappingStore(defaults: defaults)
        resumedStore.beginSession(appId: "100", catalogIdentity: nil)
        #expect(resumedStore.profile(for: .generic)?.id == racingProfile.id)

        // An unknown app id falls back to the type default rather than guessing.
        resumedStore.beginSession(appId: "999", catalogIdentity: nil)
        #expect(resumedStore.profile(for: .generic)?.id == familyDefaultProfile.id)
        #expect(resumedStore.activeOverride(for: .generic) == nil)
    }

    @Test func aCatalogLaunchRecordsTheGamesTitleForLaterReads() throws {
        let defaults = try makeDefaults()
        let store = ControllerMappingStore(defaults: defaults)
        store.beginSession(appId: "100", catalogIdentity: "title-42", title: "Racing Game")
        #expect(store.gameTitle(forGameIdentity: "title-42") == "Racing Game")

        // A resume carries no title, but the identity and its name survive the relaunch.
        let resumedStore = ControllerMappingStore(defaults: defaults)
        resumedStore.beginSession(appId: "100", catalogIdentity: nil)
        #expect(resumedStore.currentGameIdentity == "title-42")
        #expect(resumedStore.gameTitle(forGameIdentity: "title-42") == "Racing Game")
    }

    @Test func anAppIdFallbackTitleIsNotRecorded() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        // The resume path's own fallback ("App ID 123") arrives with no catalog identity, so it must
        // not overwrite the real title or invent one.
        store.beginSession(appId: "123", catalogIdentity: nil, title: "App ID 123")
        #expect(store.gameTitle(forGameIdentity: "123") == nil)
    }

    @Test func overrideCountReportsWhatDeletingAProfileWouldDrop() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        let sharedProfile = store.createProfile(named: "Shared", family: .generic)
        store.beginSession(appId: "100", catalogIdentity: "game-100")
        store.setGameOverride(profileID: sharedProfile.id, for: .generic)
        store.beginSession(appId: "200", catalogIdentity: "game-200")
        store.setGameOverride(profileID: sharedProfile.id, for: .generic)
        #expect(store.overrideCount(referencingProfile: sharedProfile.id) == 2)
        #expect(store.overrideCount(referencingProfile: UUID()) == 0)
    }

    @Test func endingASessionReturnsToTheFamilyDefault() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        let familyDefaultProfile = store.createProfile(named: "Generic default", family: .generic)
        let racingProfile = store.createProfile(named: "Racing", family: .generic)
        store.setDefaultProfile(familyDefaultProfile.id, for: .generic)
        store.beginSession(appId: "100", catalogIdentity: "game-100")
        store.setGameOverride(profileID: racingProfile.id, for: .generic)
        #expect(store.profile(for: .generic)?.id == racingProfile.id)

        store.endSession()
        #expect(store.profile(for: .generic)?.id == familyDefaultProfile.id)
        #expect(store.isCurrentGameKnown == false)
    }

    // MARK: - Tolerance

    @Test func corruptStoredDataIsIgnoredAtStartup() throws {
        let defaults = try makeDefaults()
        let seededStore = ControllerMappingStore(defaults: defaults)
        let seededProfile = try #require(seededStore.activeProfile)
        defaults.set(Data("not json".utf8), forKey: ControllerMappingStore.gameOverridesKey)
        defaults.set(Data("not json".utf8), forKey: ControllerMappingStore.familyDefaultsKey)
        defaults.set(Data("not json".utf8), forKey: ControllerMappingStore.appIdIdentityIndexKey)

        let store = ControllerMappingStore(defaults: defaults)
        #expect(store.profiles.contains(seededProfile))
        #expect(store.gameOverrides.isEmpty)
        #expect(store.defaultProfileID(for: .steam) == seededProfile.id)
        store.beginSession(appId: "100", catalogIdentity: nil)
        #expect(store.isCurrentGameKnown == false)
        #expect(store.profile(for: .steam)?.id == seededProfile.id)
    }

    @Test func legacySteamDefaultMigratesIntoTheFamilyMap() throws {
        let defaults = try makeDefaults()
        let firstProfile = ControllerMappingProfile(name: "First")
        let secondProfile = ControllerMappingProfile(name: "Second")
        defaults.set(try JSONEncoder().encode([firstProfile, secondProfile]), forKey: ControllerMappingStore.profilesKey)
        defaults.set(secondProfile.id.uuidString, forKey: ControllerMappingStore.legacySteamDefaultKey)
        #expect(defaults.data(forKey: ControllerMappingStore.familyDefaultsKey) == nil)

        let store = ControllerMappingStore(defaults: defaults)
        #expect(store.defaultProfileID(for: .steam) == secondProfile.id)
        #expect(defaults.data(forKey: ControllerMappingStore.familyDefaultsKey) != nil)
        // Read once: the superseded key carries nothing once the new key owns the default.
        #expect(defaults.string(forKey: ControllerMappingStore.legacySteamDefaultKey) == nil)
    }
}
