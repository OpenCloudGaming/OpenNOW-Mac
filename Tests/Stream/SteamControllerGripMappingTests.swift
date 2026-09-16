import Foundation
import Testing
@testable import OpenNOW

/// `ControllerButtonChord`/`Target` stay live — reused by `ControllerBindingTarget
/// .gamepadChord`. `SteamControllerGripProfile` stays live too, as the one-time migration
/// input for `ControllerMappingStore`. Only the grip-only mapper/store they used to
/// back were retired (see `ControllerBindingEngineTests`/`ControllerMappingStoreTests`).
@Suite struct SteamControllerGripProfileCodecTests {
    @Test func roundTripsProfile() throws {
        let profile = SteamControllerGripProfile(
            name: "Shooter",
            combos: [
                .l4: ControllerButtonChord(buttons: [.rightShoulder, .south]),
                .r5: ControllerButtonChord(buttons: [.dpadUp], rightTrigger: true),
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
        #expect(decoded.combo(for: .l4) == ControllerButtonChord(buttons: [.south, .rightShoulder]))
        #expect(decoded.combos.count == 1)
    }

    @Test func comboInitDropsUnassignableButtons() {
        let combo = ControllerButtonChord(buttons: [.south, .leftGrip, .mode])
        #expect(combo.buttons == [.south])
    }

    @Test func comboLabelListsElementsInCanonicalOrder() {
        let combo = ControllerButtonChord(buttons: [.south, .rightShoulder], rightTrigger: true)
        #expect(ControllerChordTarget.comboLabel(for: combo) == "A + R1 + R2")
        #expect(ControllerChordTarget.comboLabel(for: ControllerButtonChord()) == "Unassigned")
    }

    @Test func gripLabelsMatchHardwareNaming() {
        #expect(SteamControllerGripButton.l4.gamepadButton == .leftGrip)
        #expect(SteamControllerGripButton.l5.gamepadButton == .leftGrip2)
        #expect(SteamControllerGripButton.r4.gamepadButton == .rightGrip)
        #expect(SteamControllerGripButton.r5.gamepadButton == .rightGrip2)
    }
}
