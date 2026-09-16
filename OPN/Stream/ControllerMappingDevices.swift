import Combine
import Foundation
import GameController

struct ControllerMappingDevice: Equatable, Identifiable, Sendable {
    let id: InputDeviceID
    let name: String
    let family: ControllerFamily
    let hasTouchpad: Bool

    var controls: [ControllerControl] {
        family.controls.filter { $0 != .touchpadClick || hasTouchpad }
    }
}

/// GameController supplies no stable hardware identity. Native IDs last only for this connection.
@MainActor
final class ControllerMappingDevices: ObservableObject {
    static let shared = ControllerMappingDevices()
    @Published private(set) var devices: [ControllerMappingDevice] = []
    private var identities = ControllerConnectionIDs()
    private var nativeIDs: [ObjectIdentifier: InputDeviceID] = [:]
    private var controllers: [InputDeviceID: GCController] = [:]
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init() {
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func refresh() {
        let native = NativeWebRTCGamepadMonitor.availableNativeControllers()
        nativeIDs = identities.update(native.map(ObjectIdentifier.init))
        controllers.removeAll()
        var next = SteamControllerHIDMonitor.shared.activeDeviceIDs.enumerated().map { index, id in
            ControllerMappingDevice(id: id, name: "Steam Controller \(index + 1)", family: .steam, hasTouchpad: false)
        }
        for (index, controller) in native.enumerated() {
            guard let gamepad = controller.extendedGamepad else { continue }
            let key = ObjectIdentifier(controller)
            guard let id = nativeIDs[key] else { continue }
            controllers[id] = controller
            let family: ControllerFamily = NativeGamepadShell(controller: controller, gamepad: gamepad) == .dualShock4 ? .dualShock4 : .generic
            next.append(ControllerMappingDevice(id: id, name: "\(controller.vendorName ?? controller.productCategory) · \(index + 1)",
                                                family: family, hasTouchpad: gamepad is GCDualShockGamepad))
        }
        if devices != next { devices = next }
        ControllerMappingStore.shared.removeDisconnectedAssignments(connectedIDs: Set(next.map(\.id)))
    }

    func id(for controller: GCController) -> InputDeviceID? { nativeIDs[ObjectIdentifier(controller)] }
    func controller(for id: InputDeviceID) -> GCController? { controllers[id] }
}
