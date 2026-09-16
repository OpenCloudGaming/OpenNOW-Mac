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

    @Test func nativeProfilesPersistButAssignmentsNeverLeakToAnotherConnection() throws {
        let defaults = try makeDefaults()
        let store = ControllerMappingStore(defaults: defaults)
        let steamID = store.activeProfileID
        let profile = store.createProfile(named: "Two identical pads", family: .generic)
        #expect(store.activeProfileID == steamID)
        #expect(store.profile(for: "native-one", family: .generic) == nil)
        store.assignProfile(profile.id, to: "native-one", family: .generic)
        #expect(store.profile(for: "native-one", family: .generic) == profile)
        #expect(store.profile(for: "native-two", family: .generic) == nil)
        store.assignProfile(profile.id, to: "dualshock", family: .dualShock4)
        #expect(store.profile(for: "dualshock", family: .dualShock4) == nil)
        let reopened = ControllerMappingStore(defaults: defaults)
        #expect(reopened.profiles.contains(profile))
        #expect(reopened.profile(for: "native-one", family: .generic) == nil)
        store.removeDisconnectedAssignments(connectedIDs: ["native-two"])
        #expect(store.profile(for: "native-one", family: .generic) == nil)
    }

    @Test func creatingPerDeviceSteamProfileNeverActivatesTheSharedDefault() throws {
        let defaults = try makeDefaults()
        let store = ControllerMappingStore(defaults: defaults)
        let original = store.activeProfile
        var observed: [UUID?] = []
        let subscription = store.revisionPublisher.sink { _ in observed.append(store.activeProfileID) }
        defer { subscription.cancel() }
        let profile = store.createProfile(named: "Only this Steam pad", family: .steam, activateSteamDefault: false)
        store.assignProfile(profile.id, to: "steam-first", family: .steam)
        #expect(store.profile(for: "steam-first", family: .steam) == profile)
        #expect(store.profile(for: "steam-second", family: .steam) == original)
        #expect(observed == Array(repeating: original?.id, count: observed.count))
        #expect(ControllerMappingStore(defaults: defaults).activeProfileID == original?.id)
        let global = store.createProfile(named: "All Steam pads")
        #expect(store.activeProfileID == global.id)
    }

    @Test func deletingAssignedProfileRestoresNativePassthrough() throws {
        let store = ControllerMappingStore(defaults: try makeDefaults())
        let profile = store.createProfile(named: "PS4", family: .dualShock4)
        store.assignProfile(profile.id, to: "native-ps4", family: .dualShock4)
        store.deleteProfile(profile.id)
        #expect(store.profile(for: "native-ps4", family: .dualShock4) == nil)
    }

}
