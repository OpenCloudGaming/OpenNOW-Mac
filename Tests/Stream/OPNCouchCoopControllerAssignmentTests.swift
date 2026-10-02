import Foundation
import Testing
@testable import OpenNOW

@Suite struct OPNCouchCoopControllerAssignmentTests {
    private let descriptors = ["Xbox#0", "Xbox#1", "steam-controller-9"]

    private func assignment(_ overrides: [String: OPNCouchCoopPadTarget] = [:], instances: [Int] = [1, 2]) -> OPNCouchCoopControllerAssignment {
        OPNCouchCoopControllerAssignment(overrides: overrides, instances: instances)
    }

    @Test func nativeDescriptorsCountPadsOfTheSameName() {
        #expect(OPNCouchCoopControllerAssignment.nativeDescriptors(vendorNames: ["Xbox", "DualSense", "Xbox"]) == ["Xbox#0", "DualSense#0", "Xbox#1"])
    }

    @Test func nativePadsComeBeforeSteamPads() {
        #expect(OPNCouchCoopControllerAssignment.orderedDescriptors(native: ["Xbox#0"], steam: ["steam-controller-1"]) == ["Xbox#0", "steam-controller-1"])
    }

    @Test func connectionOrderGivesPadNToInstanceNAndLeavesExtrasOff() {
        let resolved = assignment().resolve(descriptors: descriptors)
        #expect(resolved == ["Xbox#0": .instance(1), "Xbox#1": .instance(2), "steam-controller-9": .off])
    }

    @Test func eachInstanceOwnsOnlyItsOwnPads() {
        func owned(by instance: Int) -> [String] {
            OPNCouchCoopControllerAssignment.owned(descriptors: descriptors, overrides: [:], instances: [1, 2], isActive: true, instance: instance)
        }
        #expect(owned(by: 1) == ["Xbox#0"])
        #expect(owned(by: 2) == ["Xbox#1"])
    }

    @Test func aSingleInstanceKeepsEveryPadWhileCoOpIsInactive() {
        let owned = OPNCouchCoopControllerAssignment.owned(descriptors: descriptors, overrides: [:], instances: [1, 2], isActive: false, instance: 2)
        #expect(owned == descriptors)
    }

    @Test func anOverrideMovesAPadAndTheRestFillTheFreeInstance() {
        let resolved = assignment(["Xbox#0": .instance(2)]).resolve(descriptors: descriptors)
        #expect(resolved["Xbox#0"] == .instance(2))
        #expect(resolved["Xbox#1"] == .instance(1))
    }

    @Test func anOffOverrideStaysOffAndFreesItsSeat() {
        let resolved = assignment(["Xbox#0": .off]).resolve(descriptors: descriptors)
        #expect(resolved["Xbox#0"] == .off)
        #expect(resolved["Xbox#1"] == .instance(1))
        #expect(resolved["steam-controller-9"] == .instance(2))
    }

    @Test func anOverrideForAnAbsentInstanceIsIgnored() {
        let resolved = assignment(["Xbox#0": .instance(3)]).resolve(descriptors: ["Xbox#0"])
        #expect(resolved == ["Xbox#0": .instance(1)])
    }

    @Test func instancesNeedNotStartAtOne() {
        let resolved = assignment(instances: [2, 3]).resolve(descriptors: ["a", "b"])
        #expect(resolved == ["a": .instance(2), "b": .instance(3)])
    }

    @Test func aReconnectingPadGoesToTheInstanceWithoutAPad() {
        let pinned = assignment().pinned(descriptors: ["Xbox#0", "Xbox#1"])
        let afterFirstLeaves = assignment(pinned).pinned(descriptors: ["Xbox#1"])
        #expect(afterFirstLeaves == ["Xbox#1": .instance(2)])
        let afterReturn = assignment(afterFirstLeaves).resolve(descriptors: ["Xbox#1", "Xbox#0"])
        #expect(afterReturn["Xbox#1"] == .instance(2))
        #expect(afterReturn["Xbox#0"] == .instance(1))
    }

    @Test func pinningDoesNotFreezeAnImplicitOff() {
        #expect(assignment().pinned(descriptors: descriptors)["steam-controller-9"] == nil)
    }

    @Test func swapTradesTheTwoPlayersPads() {
        let swapped = assignment().swapped(descriptors: ["Xbox#0", "Xbox#1"])
        #expect(swapped == ["Xbox#0": .instance(2), "Xbox#1": .instance(1)])
    }

    @Test func swapMovesALonePadToTheOtherPlayer() {
        #expect(assignment().swapped(descriptors: ["Xbox#0"]) == ["Xbox#0": .instance(2)])
    }

    @Test func swapNeedsTwoInstances() {
        #expect(assignment(instances: [1]).swapped(descriptors: ["Xbox#0"]) == ["Xbox#0": .instance(1)])
    }

    @Test func cyclingWalksPlayersThenOffThenBack() {
        let first = assignment().cycled("Xbox#0", descriptors: descriptors)
        #expect(first["Xbox#0"] == .instance(2))
        let second = assignment(first).cycled("Xbox#0", descriptors: descriptors)
        #expect(second["Xbox#0"] == .off)
        let third = assignment(second).cycled("Xbox#0", descriptors: descriptors)
        #expect(third["Xbox#0"] == .instance(1))
    }

    @Test func aPadCycledToOffStaysOffAcrossReconciliation() {
        let off = assignment(["Xbox#0": .instance(1)]).cycled("Xbox#0", descriptors: ["Xbox#0"])
        let twice = assignment(off).cycled("Xbox#0", descriptors: ["Xbox#0"])
        #expect(twice["Xbox#0"] == .instance(1))
        let offAgain = assignment(["Xbox#0": .instance(2)]).cycled("Xbox#0", descriptors: ["Xbox#0"])
        #expect(offAgain["Xbox#0"] == .off)
        #expect(assignment(offAgain).pinned(descriptors: ["Xbox#0"])["Xbox#0"] == .off)
    }

    @Test func cyclingAnUnknownPadChangesNothing() {
        #expect(assignment().cycled("missing", descriptors: ["Xbox#0"]) == assignment().pinned(descriptors: ["Xbox#0"]))
    }

    @Test func overridesSurviveTheirPayload() {
        let overrides: [String: OPNCouchCoopPadTarget] = ["Xbox#0": .instance(2), "steam-controller-9": .off]
        let payload = OPNCouchCoopControllerAssignment.payload(from: overrides)
        #expect(OPNCouchCoopControllerAssignment.overrides(fromPayload: payload) == overrides)
    }

    @Test func aMalformedPayloadYieldsNoOverrides() {
        #expect(OPNCouchCoopControllerAssignment.overrides(fromPayload: nil).isEmpty)
        #expect(OPNCouchCoopControllerAssignment.overrides(fromPayload: "not json").isEmpty)
        #expect(OPNCouchCoopControllerAssignment.overrides(fromPayload: "{\"Xbox#0\":-4}").isEmpty)
    }

    @Test func targetsRoundTripThroughTheirCode() {
        #expect(OPNCouchCoopPadTarget(code: OPNCouchCoopPadTarget.instance(2).code) == .instance(2))
        #expect(OPNCouchCoopPadTarget(code: OPNCouchCoopPadTarget.off.code) == .off)
        #expect(OPNCouchCoopPadTarget(code: -1) == nil)
    }
}
