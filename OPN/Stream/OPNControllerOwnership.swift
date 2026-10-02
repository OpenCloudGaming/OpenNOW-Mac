import Foundation
import GameController
import os

extension Notification.Name {
    static let opnControllerOwnershipDidChange = Notification.Name("OpenNOW.controllerOwnershipDidChange")
}

final class OPNControllerOwnership: Sendable {
    static let shared = OPNControllerOwnership()

    private struct State {
        var isCouchCoopActive = false
        var ownedDescriptors: Set<String> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isCouchCoopActive: Bool { state.withLock { $0.isCouchCoopActive } }

    @discardableResult
    func update(isActive: Bool, ownedDescriptors: Set<String>) -> Bool {
        state.withLock { current in
            let next = State(isCouchCoopActive: isActive, ownedDescriptors: isActive ? ownedDescriptors : [])
            let changed = current.isCouchCoopActive != next.isCouchCoopActive || current.ownedDescriptors != next.ownedDescriptors
            current = next
            return changed
        }
    }

    func owns(descriptor: String) -> Bool {
        state.withLock { !$0.isCouchCoopActive || $0.ownedDescriptors.contains(descriptor) }
    }

    func owns(steamDeviceID: InputDeviceID) -> Bool {
        owns(descriptor: steamDeviceID.rawValue)
    }

    nonisolated static func nativeDescriptors(for controllers: [GCController]) -> [ObjectIdentifier: String] {
        let extended = controllers.filter { $0.extendedGamepad != nil }
        let names = extended.map { $0.vendorName ?? $0.productCategory }
        let descriptors = OPNCouchCoopControllerAssignment.nativeDescriptors(vendorNames: names)
        return Dictionary(uniqueKeysWithValues: zip(extended.map(ObjectIdentifier.init), descriptors))
    }

    func owns(_ controller: GCController, among controllers: [GCController] = GCController.controllers()) -> Bool {
        guard isCouchCoopActive else { return true }
        guard let descriptor = Self.nativeDescriptors(for: controllers)[ObjectIdentifier(controller)] else { return true }
        return owns(descriptor: descriptor)
    }

    func connectedGamepadCount(unfiltered: Int) -> Int {
        state.withLock { $0.isCouchCoopActive ? min(4, $0.ownedDescriptors.count) : unfiltered }
    }
}
