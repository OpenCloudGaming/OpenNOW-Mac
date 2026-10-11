import Foundation
import Testing
@testable import OpenNOW

@Suite struct ControllerStreamSelectionTests {
    private func device(_ id: InputDeviceID, _ name: String = "Pad") -> ControllerStreamSelection.Device {
        ControllerStreamSelection.Device(id: id, name: name)
    }

    // MARK: Assignment (global order A–E)

    @Test func enabledSubsetTakesCompactedSlotsInSharedOrder() {
        var selection = ControllerStreamSelection()
        selection.beginSession(devices: [device("a"), device("b"), device("c"), device("d"), device("e")])
        for id: InputDeviceID in ["b", "d"] { selection.setEnabled(false, for: id) }
        #expect(selection.activeDeviceIDs == ["a", "c", "e"])
        #expect(selection.playerIndices == ["a": 0, "c": 1, "e": 2])
    }

    @Test func disablingAMiddleDevicePromotesTheWaitingDevice() {
        var selection = ControllerStreamSelection()
        selection.beginSession(devices: [device("a"), device("b"), device("c"), device("d"), device("e")])
        #expect(selection.playerIndices == ["a": 0, "b": 1, "c": 2, "d": 3])
        #expect(selection.rows.first { $0.id == "e" }?.state == .waiting)
        selection.setEnabled(false, for: "b")
        #expect(selection.activeDeviceIDs == ["a", "c", "d", "e"])
        #expect(selection.playerIndices == ["a": 0, "c": 1, "d": 2, "e": 3])
        #expect(selection.rows.first { $0.id == "e" }?.state == .active(playerIndex: 3))
        #expect(selection.rows.first { $0.id == "b" }?.state == .disabled)
        #expect(selection.rows.first { $0.id == "b" }?.playerIndex == nil)
    }

    @Test func reEnablingSendsTheLastDeviceBackToWaiting() {
        var selection = ControllerStreamSelection()
        let order = [device("a"), device("b"), device("c"), device("d"), device("e")]
        selection.beginSession(devices: order)
        selection.setEnabled(false, for: "b")
        selection.setEnabled(true, for: "b")
        #expect(selection.playerIndices == ["a": 0, "b": 1, "c": 2, "d": 3])
        #expect(selection.rows.first { $0.id == "e" }?.state == .waiting)
        #expect(selection.rows.first { $0.id == "e" }?.isEnabled == true)
    }

    @Test func reorderRecomputesSlotsWithoutChangingSelections() {
        var selection = ControllerStreamSelection()
        selection.beginSession(devices: [device("a"), device("b"), device("c")])
        selection.setEnabled(false, for: "b")
        #expect(selection.playerIndices == ["a": 0, "c": 1])
        selection.synchronize(devices: [device("c"), device("a"), device("b")])
        #expect(selection.playerIndices == ["c": 0, "a": 1])
        #expect(!selection.isEnabled("b"))
        #expect(selection.isEnabled("c"))
        #expect(selection.rows.map(\.id) == ["c", "a", "b"])
    }

    // MARK: Admission and lifecycle

    @Test func midStreamArrivalIsAdmittedDisabledUntilEnabled() {
        var selection = ControllerStreamSelection()
        selection.beginSession(devices: [device("a")])
        let arrivals = selection.synchronize(devices: [device("a"), device("b")])
        #expect(arrivals.map(\.id) == ["b"])
        #expect(selection.rows.first { $0.id == "b" }?.state == .newlyIdentified)
        #expect(selection.rows.first { $0.id == "b" }?.isEnabled == false)
        #expect(selection.playerIndex(for: "b") == nil)
        selection.setEnabled(true, for: "b")
        #expect(selection.rows.first { $0.id == "b" }?.state == .active(playerIndex: 1))
        #expect(!selection.isNewlyIdentified("b"))
    }

    @Test func disconnectCompactsTheRemainingEnabledPlayers() {
        var selection = ControllerStreamSelection()
        selection.beginSession(devices: [device("a"), device("b"), device("c")])
        _ = selection.synchronize(devices: [device("a"), device("c")])
        #expect(selection.activeDeviceIDs == ["a", "c"])
        #expect(selection.playerIndices == ["a": 0, "c": 1])
        let history = selection.rows.first { $0.id == "b" }
        #expect(history?.state == .disconnected)
        #expect(history?.isEnabled == true)
        #expect(history?.playerIndex == nil)
        #expect(selection.rows.map(\.id) == ["a", "c", "b"])
    }

    @Test func reliableReconnectRestoresEachStreamsOwnChoiceWithoutADuplicateRow() {
        var first = ControllerStreamSelection()
        var second = ControllerStreamSelection()
        first.beginSession(devices: [device("a")])
        second.beginSession(devices: [device("a")])
        second.setEnabled(false, for: "a")
        #expect(first.playerIndex(for: "a") == 0)
        #expect(second.playerIndex(for: "a") == nil)
        #expect(first.synchronize(devices: []).isEmpty)
        #expect(second.synchronize(devices: []).isEmpty)
        #expect(first.rows.map(\.state) == [.disconnected])
        // A trustworthy identity returns: the remembered choice is restored per stream, and the row
        // is the live one rather than a live row beside a stale history row.
        #expect(first.synchronize(devices: [device("a")]).isEmpty)
        #expect(second.synchronize(devices: [device("a")]).isEmpty)
        #expect(first.playerIndex(for: "a") == 0)
        #expect(second.rows.first { $0.id == "a" }?.state == .disabled)
        #expect(first.rows.count == 1)
        #expect(second.rows.count == 1)
    }

    @Test func reliableReconnectRecalculatesTheSlotFromTheCurrentOrder() {
        var selection = ControllerStreamSelection()
        selection.beginSession(devices: [device("a"), device("b"), device("c"), device("d")])
        _ = selection.synchronize(devices: [device("b"), device("c"), device("d")])
        _ = selection.synchronize(devices: [device("b"), device("c"), device("d"), device("e")])
        selection.setEnabled(true, for: "e")
        #expect(selection.playerIndices == ["b": 0, "c": 1, "d": 2, "e": 3])
        // The remembered device returns behind four enabled devices, so the current order makes it
        // Waiting rather than Active.
        _ = selection.synchronize(devices: [device("b"), device("c"), device("d"), device("e"), device("a")])
        #expect(selection.rows.first { $0.id == "a" }?.state == .waiting)
        #expect(selection.rows.first { $0.id == "a" }?.isEnabled == true)
        #expect(selection.rows.first { $0.id == "a" }?.playerIndex == nil)
    }

    @Test func changedIdentityStartsDisabledWithTheOldHistoryRetained() {
        var selection = ControllerStreamSelection()
        selection.beginSession(devices: [device("n1", "DualSense")])
        let arrivals = selection.synchronize(devices: [device("n2", "DualSense")])
        #expect(arrivals.map(\.id) == ["n2"])
        #expect(selection.rows.first { $0.id == "n2" }?.state == .newlyIdentified)
        #expect(selection.playerIndex(for: "n2") == nil)
        #expect(selection.rows.first { $0.id == "n1" }?.state == .disconnected)
        #expect(selection.rows.first { $0.id == "n1" }?.isEnabled == true)
        #expect(selection.rows.count == 2)
    }

    @Test func identicalLabelsNeverTransferSelection() {
        var selection = ControllerStreamSelection()
        selection.beginSession(devices: [device("n1", "Xbox Wireless Controller")])
        selection.setEnabled(false, for: "n1")
        _ = selection.synchronize(devices: [device("n1", "Xbox Wireless Controller"), device("n2", "Xbox Wireless Controller")])
        #expect(!selection.isEnabled("n1"))
        #expect(!selection.isEnabled("n2"))
        #expect(selection.rows.first { $0.id == "n2" }?.state == .newlyIdentified)
        #expect(selection.rows.count == 2)
    }

    @Test func newSessionDoesNotInheritSelection() {
        var previous = ControllerStreamSelection()
        previous.beginSession(devices: [device("a"), device("b")])
        previous.setEnabled(false, for: "a")
        _ = previous.synchronize(devices: [device("b")])
        var restarted = ControllerStreamSelection()
        restarted.beginSession(devices: [device("a")])
        #expect(restarted.isEnabled("a"))
        #expect(restarted.playerIndex(for: "a") == 0)
        #expect(restarted.rows.count == 1)
        #expect(restarted.rows.first?.state == .active(playerIndex: 0))
    }

    @Test func repeatDiscoveryChangesNothing() {
        var selection = ControllerStreamSelection()
        selection.beginSession(devices: [device("a"), device("b")])
        selection.setEnabled(false, for: "b")
        let before = selection
        #expect(selection.synchronize(devices: [device("a"), device("b")]).isEmpty)
        #expect(selection == before)
        #expect(selection.rows.count == 2)
    }

    @Test func everyDeviceDisabledLeavesNoActiveDevice() {
        var selection = ControllerStreamSelection()
        selection.beginSession(devices: [device("a"), device("b")])
        selection.setEnabled(false, for: "a")
        selection.setEnabled(false, for: "b")
        #expect(selection.activeDeviceIDs.isEmpty)
        #expect(selection.playerIndices.isEmpty)
        #expect(selection.rows.allSatisfy { $0.state == .disabled && !$0.isEnabled })
    }
}
