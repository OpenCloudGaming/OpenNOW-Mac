import Foundation
import Testing
@testable import OpenNOW

@Suite struct OPNControllerOwnershipTests {
    @Test func everyPadIsOwnedWhileCoOpIsInactive() {
        let ownership = OPNControllerOwnership()
        #expect(ownership.owns(descriptor: "Xbox#0"))
        #expect(ownership.owns(steamDeviceID: "steam-controller-1"))
        #expect(ownership.connectedGamepadCount(unfiltered: 3) == 3)
    }

    @Test func onlyOwnedPadsCountAndPassWhileCoOpIsActive() {
        let ownership = OPNControllerOwnership()
        ownership.update(isActive: true, ownedDescriptors: ["Xbox#0", "steam-controller-1"])
        #expect(ownership.owns(descriptor: "Xbox#0"))
        #expect(!ownership.owns(descriptor: "Xbox#1"))
        #expect(ownership.owns(steamDeviceID: "steam-controller-1"))
        #expect(!ownership.owns(steamDeviceID: "steam-controller-2"))
        #expect(ownership.connectedGamepadCount(unfiltered: 4) == 2)
    }

    @Test func goingInactiveReleasesTheFilter() {
        let ownership = OPNControllerOwnership()
        ownership.update(isActive: true, ownedDescriptors: ["Xbox#0"])
        ownership.update(isActive: false, ownedDescriptors: ["Xbox#0"])
        #expect(ownership.owns(descriptor: "Xbox#1"))
        #expect(ownership.connectedGamepadCount(unfiltered: 2) == 2)
    }

    @Test func updateReportsOnlyRealChanges() {
        let ownership = OPNControllerOwnership()
        #expect(!ownership.update(isActive: false, ownedDescriptors: []))
        #expect(ownership.update(isActive: true, ownedDescriptors: ["Xbox#0"]))
        #expect(!ownership.update(isActive: true, ownedDescriptors: ["Xbox#0"]))
        #expect(ownership.update(isActive: true, ownedDescriptors: ["Xbox#1"]))
    }

    @Test func aPadThatMovedOwnerIsNoLongerCounted() {
        let ownership = OPNControllerOwnership()
        ownership.update(isActive: true, ownedDescriptors: ["Xbox#0"])
        ownership.update(isActive: true, ownedDescriptors: [])
        #expect(ownership.connectedGamepadCount(unfiltered: 1) == 0)
    }

    @Test func theStreamOrderKeepsOnlyOwnedPadsAsTheLowestSlots() {
        var order = ControllerPlayerOrder()
        order.update(connectedIDs: ["first", "second", "steam"])
        let restricted = order.restricted(to: ["second", "steam"])
        #expect(restricted.deviceIDs == ["second", "steam"])
        #expect(restricted.playerIndices == ["second": 0, "steam": 1])
        #expect(order.deviceIDs == ["first", "second", "steam"])
    }

    @Test func anOwnedNativePadIsSlotZeroOfItsOwnSession() {
        let first = NSObject()
        let second = NSObject()
        let natives: [InputDeviceID: ObjectIdentifier] = ["first": ObjectIdentifier(first), "second": ObjectIdentifier(second)]
        var order = ControllerPlayerOrder()
        order.update(connectedIDs: ["first", "second"])
        let assignments = ControllerSlotAssignments(order: order.restricted(to: ["second"]), steamIDs: [], nativeIDs: natives)
        #expect(assignments.native == [ObjectIdentifier(second): 0])
    }

    @Test func aRestrictedOrderKeepsItsCustomFlag() {
        var order = ControllerPlayerOrder()
        order.update(connectedIDs: ["a", "b", "c"])
        order.move("a", direction: .later)
        #expect(order.restricted(to: ["a", "c"]).isCustom)
    }
}
