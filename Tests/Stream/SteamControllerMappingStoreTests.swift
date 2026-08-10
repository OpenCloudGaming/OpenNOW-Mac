import Foundation
import Testing
@testable import MacForceNow

@MainActor
@Suite struct SteamControllerMappingStoreTests {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "SteamControllerMappingStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func freshInstallAutoActivatesADefaultPassthroughProfile() throws {
        let defaults = try makeDefaults()
        let store = SteamControllerMappingStore(defaults: defaults)
        #expect(store.profiles.count == 1)
        #expect(store.activeProfileID == store.profiles.first?.id)
        #expect(store.activeProfile?.rightPad.mode == .mouse)
        #expect(store.activeProfile?.binding(for: .rightPadClick) == .mouseButton(.left))
    }

    @Test func migratesLegacyGripComboAndDisabledTrackpad() throws {
        let defaults = try makeDefaults()
        let legacyProfile = SteamControllerGripProfile(name: "Legacy", combos: [
            .l4: SteamControllerGripCombo(buttons: [.south]),
        ])
        let data = try JSONEncoder().encode([legacyProfile])
        defaults.set(data, forKey: "MacForceNow.Input.SteamControllerGripProfiles")
        defaults.set(legacyProfile.id.uuidString, forKey: "MacForceNow.Input.SteamControllerGripActiveProfile")
        defaults.set(false, forKey: SteamControllerTrackpadMousePreference.key)

        let store = SteamControllerMappingStore(defaults: defaults)
        #expect(store.activeProfile?.binding(for: .leftGrip) == .gamepadChord(SteamControllerGripCombo(buttons: [.south])))
        #expect(store.activeProfile?.rightPad.mode == .disabled)
        #expect(store.activeProfile?.binding(for: .rightPadClick) == .disabled)
    }

    @Test func createUpdateAndDeletePersist() throws {
        let defaults = try makeDefaults()
        let store = SteamControllerMappingStore(defaults: defaults)
        let profile = store.createProfile(named: "Racing")
        var updated = profile
        updated.bindings[.faceA] = .keyboardKey(keyCode: 49, modifiers: [])
        store.updateProfile(updated)

        let reloaded = SteamControllerMappingStore(defaults: defaults)
        #expect(reloaded.activeProfileID == profile.id)
        #expect(reloaded.activeProfile?.binding(for: .faceA) == .keyboardKey(keyCode: 49, modifiers: []))

        reloaded.deleteProfile(profile.id)
        #expect(reloaded.profiles.contains(where: { $0.id == profile.id }) == false)
    }
}
