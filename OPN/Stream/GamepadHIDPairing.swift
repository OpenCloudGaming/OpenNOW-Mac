import Foundation

/// GameController exposes no HID identity, so a controller is matched to its raw device by family
/// when that is unambiguous, and otherwise by the button press both sources report.
struct GamepadHIDPairing<ControllerID: Hashable & Sendable, DeviceID: Hashable & Sendable>: Sendable {
    struct Controller: Sendable {
        let id: ControllerID
        let family: GamepadHIDFamily?
        let buttons: GamepadButtons
    }

    struct Device: Sendable {
        let id: DeviceID
        let family: GamepadHIDFamily
        let buttons: GamepadButtons
    }

    private(set) var pairs: [ControllerID: DeviceID] = [:]

    mutating func update(controllers: [Controller], devices: [Device]) {
        let controllerIDs = Set(controllers.map(\.id))
        let deviceIDs = Set(devices.map(\.id))
        pairs = pairs.filter { controllerIDs.contains($0.key) && deviceIDs.contains($0.value) }
        for family in GamepadHIDFamily.allCases {
            pair(controllers: controllers.filter { $0.family == family }, devices: devices.filter { $0.family == family })
        }
    }

    private mutating func pair(controllers: [Controller], devices: [Device]) {
        pairByPress(controllers: controllers, devices: devices)
        guard controllers.count == devices.count else { return }
        let pairedDevices = Set(pairs.values)
        let openControllers = controllers.filter { pairs[$0.id] == nil }
        let openDevices = devices.filter { !pairedDevices.contains($0.id) }
        guard openControllers.count == 1, openDevices.count == 1,
              let controller = openControllers.first, let device = openDevices.first else { return }
        pairs[controller.id] = device.id
    }

    private mutating func pairByPress(controllers: [Controller], devices: [Device]) {
        let pairedDevices = Set(pairs.values)
        let openControllers = controllers.filter { pairs[$0.id] == nil }
        let openDevices = devices.filter { !pairedDevices.contains($0.id) }
        for controller in openControllers {
            let pressed = Self.pairingButtons(controller.buttons)
            guard !pressed.isEmpty else { continue }
            guard openControllers.filter({ Self.pairingButtons($0.buttons) == pressed }).count == 1 else { continue }
            let matches = openDevices.filter { Self.pairingButtons($0.buttons) == pressed }
            guard matches.count == 1, let device = matches.first else { continue }
            pairs[controller.id] = device.id
        }
    }

    /// The system can swallow the home button before GameController sees it.
    private static func pairingButtons(_ buttons: GamepadButtons) -> GamepadButtons {
        buttons.subtracting(.mode)
    }
}
