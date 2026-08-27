import Foundation
import Testing
@testable import OpenNOW

/// `SteamControllerGripCombo`/`Target` stay live — reused by `SteamControllerBindingTarget
/// .gamepadChord`. `SteamControllerGripProfile` stays live too, as the one-time migration
/// input for `SteamControllerMappingStore`. Only the grip-only mapper/store they used to
/// back were retired (see `SteamControllerBindingEngineTests`/`SteamControllerMappingStoreTests`).
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

    @Test func gripLabelsMatchHardwareNaming() {
        #expect(SteamControllerGripButton.l4.gamepadButton == .leftGrip)
        #expect(SteamControllerGripButton.l5.gamepadButton == .leftGrip2)
        #expect(SteamControllerGripButton.r4.gamepadButton == .rightGrip)
        #expect(SteamControllerGripButton.r5.gamepadButton == .rightGrip2)
    }
}
