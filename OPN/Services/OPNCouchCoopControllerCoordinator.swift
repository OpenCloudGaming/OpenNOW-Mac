import Combine
import Foundation
import GameController

struct OPNCouchCoopPad: Equatable, Identifiable, Sendable {
    let descriptor: String
    let deviceID: InputDeviceID
    let name: String
    let target: OPNCouchCoopPadTarget

    var id: String { descriptor }
}

@MainActor
final class OPNCouchCoopControllerCoordinator: ObservableObject {
    static let shared = OPNCouchCoopControllerCoordinator()
    static let pressThreshold: Float = 0.3

    @Published private(set) var pads: [OPNCouchCoopPad] = []
    @Published private(set) var instanceNumbers: [Int] = []

    private let presence: OPNCouchCoopPresence
    private let devices: ControllerMappingDevices
    private let ownership: OPNControllerOwnership
    private let instance: OPNAppInstance
    private var subscription: AnyCancellable?

    init(presence: OPNCouchCoopPresence = .shared,
         devices: ControllerMappingDevices = .shared,
         ownership: OPNControllerOwnership = .shared,
         instance: OPNAppInstance = OPNAppInstance.current) {
        self.presence = presence
        self.devices = devices
        self.ownership = ownership
        self.instance = instance
    }

    var isActive: Bool { presence.isActive }

    static func playerLabel(for target: OPNCouchCoopPadTarget) -> String {
        switch target {
        case .instance(let number): "Player \(number)"
        case .off: "Off"
        }
    }

    func start() {
        guard OPNLabs.isCouchCoopEnabled, subscription == nil else { return }
        subscription = Publishers.MergeMany(
            presence.$isActive.map { _ in () }.eraseToAnyPublisher(),
            presence.$roster.map { _ in () }.eraseToAnyPublisher(),
            presence.$assignmentOverrides.map { _ in () }.eraseToAnyPublisher(),
            devices.$devices.map { _ in () }.eraseToAnyPublisher(),
            devices.$descriptors.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        reconcile()
    }

    func reconcile() {
        let descriptors = devices.assignableDescriptors
        let active = presence.isActive
        let instances = currentInstanceNumbers
        var overrides = presence.primaryAssignmentOverrides
        if instance.isPrimary {
            let pinned = active
                ? OPNCouchCoopControllerAssignment(overrides: overrides, instances: instances).pinned(descriptors: descriptors)
                : [:]
            if pinned != overrides {
                presence.setAssignmentOverrides(pinned)
                overrides = pinned
            }
        }
        let owned = OPNCouchCoopControllerAssignment.owned(
            descriptors: descriptors,
            overrides: overrides,
            instances: instances,
            isActive: active,
            instance: instance.number
        )
        let changed = ownership.update(isActive: active, ownedDescriptors: Set(owned))
        GCController.shouldMonitorBackgroundEvents = active
        if changed {
            devices.ownershipDidChange()
            SteamControllerHIDMonitor.shared.applyOwnership()
            NotificationCenter.default.post(name: .opnControllerOwnershipDidChange, object: nil)
        }
        publishPads(descriptors: descriptors, assignment: OPNCouchCoopControllerAssignment(overrides: overrides, instances: instances))
    }

    func cycleTarget(of descriptor: String) {
        let descriptors = devices.assignableDescriptors
        presence.requestAssignmentOverrides(currentAssignment.cycled(descriptor, descriptors: descriptors))
    }

    func swapPlayers() {
        presence.requestAssignmentOverrides(currentAssignment.swapped(descriptors: devices.assignableDescriptors))
    }

    func identify(_ descriptor: String) {
        guard let pad = pads.first(where: { $0.descriptor == descriptor }) else { return }
        ControllerRumbleTester.pulseController(pad.deviceID)
    }

    func pressedDescriptors() -> Set<String> {
        var pressed: Set<String> = []
        for pad in pads where isPressed(pad.deviceID) {
            pressed.insert(pad.descriptor)
        }
        return pressed
    }

    private var currentInstanceNumbers: [Int] {
        Array(Set(presence.roster.instanceNumbers + [instance.number])).sorted()
    }

    private var currentAssignment: OPNCouchCoopControllerAssignment {
        OPNCouchCoopControllerAssignment(overrides: presence.primaryAssignmentOverrides, instances: currentInstanceNumbers)
    }

    private func publishPads(descriptors: [String], assignment: OPNCouchCoopControllerAssignment) {
        let resolved = assignment.resolve(descriptors: descriptors)
        let idsByDescriptor = Dictionary(devices.descriptors.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let namesByID = Dictionary(uniqueKeysWithValues: devices.devices.map { ($0.id, $0.name) })
        let next = descriptors.compactMap { descriptor -> OPNCouchCoopPad? in
            guard let id = idsByDescriptor[descriptor] else { return nil }
            return OPNCouchCoopPad(descriptor: descriptor, deviceID: id, name: namesByID[id] ?? descriptor, target: resolved[descriptor] ?? .off)
        }
        if pads != next { pads = next }
        if instanceNumbers != assignment.instances { instanceNumbers = assignment.instances }
    }

    private func isPressed(_ deviceID: InputDeviceID) -> Bool {
        if deviceID.rawValue.hasPrefix(OPNCouchCoopControllerAssignment.steamDescriptorPrefix) {
            guard let snapshot = SteamControllerHIDMonitor.shared.snapshot(for: deviceID) else { return false }
            return !snapshot.buttons.isEmpty || snapshot.leftTrigger > Self.pressThreshold || snapshot.rightTrigger > Self.pressThreshold
        }
        guard let gamepad = devices.controller(for: deviceID)?.extendedGamepad else { return false }
        return !NativeGamepadMonitor.buttons(from: gamepad).isEmpty
            || gamepad.leftTrigger.value > Self.pressThreshold
            || gamepad.rightTrigger.value > Self.pressThreshold
    }
}
