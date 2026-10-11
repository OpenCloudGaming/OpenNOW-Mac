import Foundation
import Testing
@testable import OpenNOW

/// What the controller panel actually shows. These are the strings and states a player reads off the
/// HUD, so they are asserted here rather than left to a rendered snapshot.
@Suite struct ControllerOrderRowsTests {
    private func streamRow(_ id: InputDeviceID, _ name: String = "Pad", enabled: Bool,
                           state: ControllerStreamSelection.RowState) -> ControllerStreamSelection.Row {
        ControllerStreamSelection.Row(id: id, name: name, isEnabled: enabled, state: state)
    }

    @Test func activeEnabledDeviceShowsOnWithItsEffectivePlayerNumber() {
        let rows = ControllerOrderRows.stream([streamRow("a", "DualSense", enabled: true, state: .active(playerIndex: 1))],
                                              families: ["a": .dualShock4])
        #expect(rows.first?.slotLabel == "PLAYER 2")
        #expect(rows.first?.detail == ControllerFamily.dualShock4.label)
        #expect(rows.first?.isEnabled == true)
        #expect(rows.first?.showsEnableToggle == true)
        #expect(rows.first?.isDimmed == false)
    }

    @Test func enabledOverflowDeviceShowsWaiting() {
        let rows = ControllerOrderRows.stream([streamRow("e", enabled: true, state: .waiting)], families: [:])
        #expect(rows.first?.slotLabel == "WAITING")
        #expect(rows.first?.detail == "Waiting — four players already active")
        #expect(rows.first?.isEnabled == true)
    }

    @Test func connectedDisabledDeviceShowsOffAndNoPlayerNumber() {
        let rows = ControllerOrderRows.stream([streamRow("b", enabled: false, state: .disabled)], families: [:])
        #expect(rows.first?.slotLabel == "OFF")
        #expect(rows.first?.detail == "Disabled in this stream")
        #expect(rows.first?.isEnabled == false)
        #expect(rows.first?.showsEnableToggle == true)
    }

    @Test func unknownMidStreamArrivalShowsTheNewDevicePrompt() {
        let rows = ControllerOrderRows.stream([streamRow("n", enabled: false, state: .newlyIdentified)], families: [:])
        #expect(rows.first?.slotLabel == "NEW")
        #expect(rows.first?.detail == "New controller — enable in this stream")
        #expect(rows.first?.isEnabled == false)
    }

    @Test func disconnectedDeviceStaysDimmedAndReadOnlyWithTheRememberedChoice() {
        let rows = ControllerOrderRows.stream([streamRow("old", "Xbox Controller", enabled: true, state: .disconnected)], families: [:])
        #expect(rows.first?.slotLabel == "OFFLINE")
        #expect(rows.first?.detail == "Disconnected — remembered for this session")
        #expect(rows.first?.name == "Xbox Controller")
        #expect(rows.first?.isEnabled == true)
        #expect(rows.first?.showsEnableToggle == false)
        #expect(rows.first?.isDimmed == true)
    }

    @Test func settingsRowsKeepTheGlobalOrderAndOfferNoStreamToggle() {
        let devices = [
            ControllerMappingDevice(id: "a", name: "Steam Controller 1", family: .steam, hasTouchpad: false),
            ControllerMappingDevice(id: "b", name: "DualSense", family: .dualShock4, hasTouchpad: true),
        ]
        let rows = ControllerOrderRows.order(devices)
        #expect(rows.map(\.slotLabel) == ["PLAYER 1", "PLAYER 2"])
        #expect(rows.allSatisfy { $0.showsEnableToggle == false && $0.isEnabled })
    }
}
