import Foundation
import Testing
@testable import OpenNOW

@Suite struct ControllerPlayerOrderTests {
    @Test func defaultOrderTracksDiscoveryAndDeduplicates() {
        var order = ControllerPlayerOrder()
        order.update(connectedIDs: ["steam", "native", "native"])
        #expect(order.deviceIDs == ["steam", "native"])
        #expect(order.playerIndices == ["steam": 0, "native": 1])
        order.update(connectedIDs: ["new-steam", "steam", "native"])
        #expect(order.deviceIDs == ["new-steam", "steam", "native"])
        #expect(!order.isCustom)
    }

    @Test func customOrderSurvivesRefreshAndAppendsNewConnections() {
        var order = ControllerPlayerOrder()
        order.update(connectedIDs: ["steam", "ds4", "generic"])
        order.move("ds4", direction: .earlier)
        #expect(order.deviceIDs == ["ds4", "steam", "generic"])
        order.update(connectedIDs: ["new-steam", "steam", "ds4", "generic"])
        #expect(order.deviceIDs == ["ds4", "steam", "generic", "new-steam"])
        order.update(connectedIDs: ["new-steam", "steam", "generic"])
        #expect(order.deviceIDs == ["steam", "generic", "new-steam"])
        #expect(order.isCustom)
    }

    @Test func resetAndAllDisconnectedRestoreAutomaticOrdering() {
        var order = ControllerPlayerOrder()
        order.update(connectedIDs: ["steam", "native"])
        order.move("native", direction: .earlier)
        order.reset(connectedIDs: ["steam", "native"])
        #expect(order.deviceIDs == ["steam", "native"])
        #expect(!order.isCustom)
        order.move("native", direction: .earlier)
        order.update(connectedIDs: [])
        #expect(order.deviceIDs.isEmpty)
        #expect(!order.isCustom)
    }

    @Test func invalidMovesDoNotChangeOrder() {
        var order = ControllerPlayerOrder()
        order.update(connectedIDs: ["first", "last"])
        let original = order
        order.move("first", direction: .earlier)
        order.move("last", direction: .later)
        order.move("missing", direction: .earlier)
        #expect(order == original)
    }

    @Test func waitingControllerCanBePromotedWithoutIncreasingPlayerCount() {
        var order = ControllerPlayerOrder()
        order.update(connectedIDs: ["a", "b", "c", "d", "e"])
        #expect(order.playerIndices["e"] == nil)
        order.move("e", direction: .earlier)
        #expect(order.playerIndices["e"] == 3)
        #expect(order.playerIndices["d"] == nil)
        #expect(Set(order.playerIndices.values) == [0, 1, 2, 3])
    }

    @Test func mixedControllerAssignmentsFollowCustomOrder() {
        let first = NSObject()
        let second = NSObject()
        let natives: [InputDeviceID: ObjectIdentifier] = ["first": ObjectIdentifier(first), "second": ObjectIdentifier(second)]
        var order = ControllerPlayerOrder()
        order.update(connectedIDs: ["steam", "first", "second"])
        order.move("first", direction: .earlier)
        let assignments = ControllerSlotAssignments(order: order, steamIDs: ["steam"], nativeIDs: natives)
        #expect(assignments.steam == ["steam": 1])
        #expect(assignments.native[ObjectIdentifier(first)] == 0)
        #expect(assignments.native[ObjectIdentifier(second)] == 2)
        let topology = StreamGamepadTopology(playerIndices: Array(assignments.steam.values) + Array(assignments.native.values),
                                             hapticPlayerIndices: [assignments.native[ObjectIdentifier(first)] ?? -1])
        #expect(topology.hapticPlayerIndices == [0])
        #expect(topology.playerIndices == [0, 1, 2])
    }
}
