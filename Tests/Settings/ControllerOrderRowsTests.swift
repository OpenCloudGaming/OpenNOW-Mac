import Foundation
import Testing
@testable import OpenNOW

/// What the controller panel actually shows. These are the strings and states a player reads off the
/// HUD, so they are asserted here rather than left to a rendered snapshot.
@Suite struct ControllerOrderRowsTests {
    private func streamRow(_ id: InputDeviceID, _ name: String = "Pad", isEnabled: Bool,
                           state: ControllerStreamSelection.RowState) -> ControllerStreamSelection.Row {
        ControllerStreamSelection.Row(id: id, name: name, isEnabled: isEnabled, state: state)
    }

    @Test func activeEnabledDeviceShowsOnWithItsEffectivePlayerNumber() {
        let rows = ControllerOrderRows.stream([streamRow("a", "DualSense", isEnabled: true, state: .active(playerIndex: 1))],
                                              families: ["a": .dualShock4])
        #expect(rows.first?.slotLabel == "PLAYER 2")
        #expect(rows.first?.statusDetail == ControllerFamily.dualShock4.label)
        #expect(rows.first?.isEnabled == true)
        #expect(rows.first?.isEnableToggleShown == true)
        #expect(rows.first?.isDimmed == false)
    }

    @Test func enabledOverflowDeviceShowsWaiting() {
        let rows = ControllerOrderRows.stream([streamRow("e", isEnabled: true, state: .waiting)], families: [:])
        #expect(rows.first?.slotLabel == "WAITING")
        #expect(rows.first?.statusDetail == "Waiting — four players already active")
        #expect(rows.first?.isEnabled == true)
    }

    @Test func connectedDisabledDeviceShowsOffWithoutAPlayerNumber() {
        let rows = ControllerOrderRows.stream([streamRow("b", isEnabled: false, state: .disabled)], families: [:])
        #expect(rows.first?.slotLabel == "OFF")
        #expect(rows.first?.statusDetail == "Disabled in this stream")
        #expect(rows.first?.isEnabled == false)
        #expect(rows.first?.isEnableToggleShown == true)
    }

    @Test func anArrivalTheStreamHadNoSlotForShowsTheNewDevicePrompt() {
        let rows = ControllerOrderRows.stream([streamRow("n", isEnabled: false, state: .newlyIdentified)], families: [:])
        #expect(rows.first?.slotLabel == "NEW")
        #expect(rows.first?.statusDetail == "New controller — enable in this stream")
        #expect(rows.first?.isEnabled == false)
    }

    @Test func disconnectedDeviceStaysDimmedWithTheRememberedChoice() {
        let rows = ControllerOrderRows.stream([streamRow("old", "Xbox Controller", isEnabled: true, state: .disconnected)], families: [:])
        #expect(rows.first?.slotLabel == "OFFLINE")
        #expect(rows.first?.statusDetail == "Disconnected — remembered for this session")
        #expect(rows.first?.name == "Xbox Controller")
        #expect(rows.first?.isEnabled == true)
        #expect(rows.first?.isEnableToggleShown == false)
        #expect(rows.first?.isDimmed == true)
    }

    @Test func settingsRowsKeepTheGlobalOrderWithoutAStreamToggle() {
        let devices = [
            ControllerMappingDevice(id: "a", name: "Steam Controller 1", family: .steam, hasTouchpad: false),
            ControllerMappingDevice(id: "b", name: "DualSense", family: .dualShock4, hasTouchpad: true),
        ]
        let rows = ControllerOrderRows.order(devices)
        #expect(rows.map(\.slotLabel) == ["PLAYER 1", "PLAYER 2"])
        #expect(rows.allSatisfy { $0.isEnableToggleShown == false && $0.isEnabled })
    }
}
