import Foundation
import Testing
@testable import MacForceNow

private let settled: [SteamControllerGripButton: Duration] = [
    .l4: .seconds(1), .l5: .seconds(1), .r4: .seconds(1), .r5: .seconds(1),
]

@Suite struct SteamControllerGripMapperTests {
    @Test func emptyCombosLeaveButtonsUnchanged() {
        let buttons: GamepadButtons = [.south, .leftGrip]
        let result = SteamControllerGripMapper.apply(combos: [:], to: buttons, gripHoldDurations: [:])
        #expect(result.buttons == buttons)
        #expect(!result.leftTriggerPulled)
        #expect(!result.rightTriggerPulled)
        #expect(result.nextTransition == nil)
    }

    @Test func heldGripUnionsItsCombo() {
        let combos: [SteamControllerGripButton: SteamControllerGripCombo] = [
            .l4: SteamControllerGripCombo(buttons: [.rightShoulder, .south]),
        ]
        let result = SteamControllerGripMapper.apply(combos: combos, to: [.leftGrip], gripHoldDurations: settled)
        #expect(result.buttons.contains(.rightShoulder))
        #expect(result.buttons.contains(.south))
        #expect(result.buttons.contains(.leftGrip))
    }

    @Test func releasedGripDoesNotApplyCombo() {
        let combos: [SteamControllerGripButton: SteamControllerGripCombo] = [
            .r5: SteamControllerGripCombo(buttons: [.north], rightTrigger: true),
        ]
        let result = SteamControllerGripMapper.apply(combos: combos, to: [.south], gripHoldDurations: [:])
        #expect(result.buttons == [.south])
        #expect(!result.rightTriggerPulled)
        #expect(result.nextTransition == nil)
    }

    @Test func overlappingCombosFromMultipleGripsUnion() {
        let combos: [SteamControllerGripButton: SteamControllerGripCombo] = [
            .l4: SteamControllerGripCombo(buttons: [.rightShoulder, .south]),
            .r4: SteamControllerGripCombo(buttons: [.rightShoulder, .east]),
        ]
        let result = SteamControllerGripMapper.apply(combos: combos, to: [.leftGrip, .rightGrip], gripHoldDurations: settled)
        #expect(result.buttons.contains(.rightShoulder))
        #expect(result.buttons.contains(.south))
        #expect(result.buttons.contains(.east))
    }

    @Test func heldGripPullsMappedTriggers() {
        let combos: [SteamControllerGripButton: SteamControllerGripCombo] = [
            .l5: SteamControllerGripCombo(buttons: [.south], leftTrigger: true),
            .r4: SteamControllerGripCombo(rightTrigger: true),
        ]
        let both = SteamControllerGripMapper.apply(combos: combos, to: [.leftGrip2, .rightGrip], gripHoldDurations: settled)
        #expect(both.leftTriggerPulled)
        #expect(both.rightTriggerPulled)
        #expect(both.buttons.contains(.south))

        let leftOnly = SteamControllerGripMapper.apply(combos: combos, to: [.leftGrip2], gripHoldDurations: settled)
        #expect(leftOnly.leftTriggerPulled)
        #expect(!leftOnly.rightTriggerPulled)
    }

    @Test func freshGripPressLeadsWithModifiersAndWithholdsActions() {
        let combos: [SteamControllerGripButton: SteamControllerGripCombo] = [
            .l5: SteamControllerGripCombo(buttons: [.south], rightTrigger: true),
        ]
        let fresh = SteamControllerGripMapper.apply(combos: combos, to: [.leftGrip2], gripHoldDurations: [.l5: .zero])
        #expect(fresh.rightTriggerPulled)
        #expect(!fresh.buttons.contains(.south))
        #expect(fresh.nextTransition == SteamControllerGripMapper.modifierLeadTime)

        let partway = SteamControllerGripMapper.apply(combos: combos, to: [.leftGrip2], gripHoldDurations: [.l5: .milliseconds(30)])
        #expect(!partway.buttons.contains(.south))
        #expect(partway.nextTransition == .milliseconds(20))

        let elapsed = SteamControllerGripMapper.apply(combos: combos, to: [.leftGrip2], gripHoldDurations: [.l5: SteamControllerGripMapper.modifierLeadTime])
        #expect(elapsed.buttons.contains(.south))
        #expect(elapsed.rightTriggerPulled)
        #expect(elapsed.nextTransition == nil)
    }

    @Test func shoulderButtonsLeadLikeTriggers() {
        let combos: [SteamControllerGripButton: SteamControllerGripCombo] = [
            .r4: SteamControllerGripCombo(buttons: [.leftShoulder, .east]),
        ]
        let fresh = SteamControllerGripMapper.apply(combos: combos, to: [.rightGrip], gripHoldDurations: [.r4: .zero])
        #expect(fresh.buttons.contains(.leftShoulder))
        #expect(!fresh.buttons.contains(.east))
        #expect(fresh.nextTransition != nil)
    }

    @Test func pureChordWithoutModifiersPressesImmediately() {
        let combos: [SteamControllerGripButton: SteamControllerGripCombo] = [
            .l4: SteamControllerGripCombo(buttons: [.south, .east]),
        ]
        let fresh = SteamControllerGripMapper.apply(combos: combos, to: [.leftGrip], gripHoldDurations: [.l4: .zero])
        #expect(fresh.buttons.contains(.south))
        #expect(fresh.buttons.contains(.east))
        #expect(fresh.nextTransition == nil)
    }

    @Test func earliestPendingTransitionWins() {
        let combos: [SteamControllerGripButton: SteamControllerGripCombo] = [
            .l4: SteamControllerGripCombo(buttons: [.south], leftTrigger: true),
            .r4: SteamControllerGripCombo(buttons: [.east], rightTrigger: true),
        ]
        let result = SteamControllerGripMapper.apply(
            combos: combos,
            to: [.leftGrip, .rightGrip],
            gripHoldDurations: [.l4: .milliseconds(10), .r4: .milliseconds(40)]
        )
        #expect(result.nextTransition == .milliseconds(10))
    }

    @Test func gripLabelsMatchHardwareNaming() {
        #expect(SteamControllerGripButton.l4.gamepadButton == .leftGrip)
        #expect(SteamControllerGripButton.l5.gamepadButton == .leftGrip2)
        #expect(SteamControllerGripButton.r4.gamepadButton == .rightGrip)
        #expect(SteamControllerGripButton.r5.gamepadButton == .rightGrip2)
    }
}

@Suite struct SteamControllerGripProfileCodecTests {
    @Test func roundTripsProfile() throws {
        let profile = SteamControllerGripProfile(
            name: "Shooter",
            combos: [
                .l4: SteamControllerGripCombo(buttons: [.rightShoulder, .south]),
                .r5: SteamControllerGripCombo(buttons: [.dpadUp], rightTrigger: true),
            ]
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(SteamControllerGripProfile.self, from: data)
        #expect(decoded == profile)
    }

    @Test func decodesLegacyButtonOnlyCombos() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Legacy","combos":{"l4":\(GamepadButtons([.south, .rightShoulder]).rawValue),"pedal":\(GamepadButtons.north.rawValue)}}
        """
        let decoded = try JSONDecoder().decode(SteamControllerGripProfile.self, from: Data(json.utf8))
        #expect(decoded.combo(for: .l4) == SteamControllerGripCombo(buttons: [.south, .rightShoulder]))
        #expect(decoded.combos.count == 1)
    }

    @Test func comboInitDropsUnassignableButtons() {
        let combo = SteamControllerGripCombo(buttons: [.south, .leftGrip, .mode])
        #expect(combo.buttons == [.south])
    }

    @Test func comboLabelListsElementsInCanonicalOrder() {
        let combo = SteamControllerGripCombo(buttons: [.south, .rightShoulder], rightTrigger: true)
        #expect(SteamControllerGripComboTarget.comboLabel(for: combo) == "A + R1 + R2")
        #expect(SteamControllerGripComboTarget.comboLabel(for: SteamControllerGripCombo()) == "Unassigned")
    }
}

@MainActor
@Suite struct SteamControllerGripMappingStoreTests {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "SteamControllerGripMappingStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func createProfileActivatesAndPersists() throws {
        let defaults = try makeDefaults()
        let store = SteamControllerGripMappingStore(defaults: defaults)
        var profile = store.createProfile(named: "Racing")
        profile.combos[.r4] = SteamControllerGripCombo(buttons: [.east, .leftShoulder], leftTrigger: true)
        store.updateProfile(profile)

        let reloaded = SteamControllerGripMappingStore(defaults: defaults)
        #expect(reloaded.activeProfileID == profile.id)
        #expect(reloaded.activeProfile?.name == "Racing")
        #expect(reloaded.activeCombos[.r4] == SteamControllerGripCombo(buttons: [.east, .leftShoulder], leftTrigger: true))
    }

    @Test func updateProfileDropsEmptyCombosAndKeepsNameWhenBlank() throws {
        let defaults = try makeDefaults()
        let store = SteamControllerGripMappingStore(defaults: defaults)
        var profile = store.createProfile(named: "Test")
        profile.name = "   "
        profile.combos[.l5] = SteamControllerGripCombo()
        store.updateProfile(profile)
        #expect(store.activeProfile?.name == "Test")
        #expect(store.activeProfile?.combos.isEmpty == true)
        #expect(store.activeCombos.isEmpty)
    }

    @Test func deactivatingProfileClearsActiveCombos() throws {
        let defaults = try makeDefaults()
        let store = SteamControllerGripMappingStore(defaults: defaults)
        var profile = store.createProfile(named: "Test")
        profile.combos[.l4] = SteamControllerGripCombo(buttons: [.south])
        store.updateProfile(profile)
        store.setActiveProfile(nil)
        #expect(store.activeCombos.isEmpty)
        #expect(store.profiles.count == 1)

        let reloaded = SteamControllerGripMappingStore(defaults: defaults)
        #expect(reloaded.activeProfileID == nil)
        #expect(reloaded.profiles.count == 1)
    }

    @Test func deleteProfileClearsActiveSelection() throws {
        let defaults = try makeDefaults()
        let store = SteamControllerGripMappingStore(defaults: defaults)
        let profile = store.createProfile(named: "Doomed")
        store.deleteProfile(profile.id)
        #expect(store.profiles.isEmpty)
        #expect(store.activeProfileID == nil)
        #expect(store.activeCombos.isEmpty)
    }

    @Test func renameViaUpdateProfilePersists() throws {
        let defaults = try makeDefaults()
        let store = SteamControllerGripMappingStore(defaults: defaults)
        var profile = store.createProfile(named: "Old")
        profile.name = "New"
        store.updateProfile(profile)
        let reloaded = SteamControllerGripMappingStore(defaults: defaults)
        #expect(reloaded.activeProfile?.name == "New")
    }

    @Test func staleActiveProfileIDIsIgnored() throws {
        let defaults = try makeDefaults()
        defaults.set(UUID().uuidString, forKey: SteamControllerGripMappingStore.activeProfileKey)
        let store = SteamControllerGripMappingStore(defaults: defaults)
        #expect(store.activeProfileID == nil)
        #expect(store.activeCombos.isEmpty)
    }
}
