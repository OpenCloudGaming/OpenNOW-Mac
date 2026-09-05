//  Battery readings grouped by physical controller.
//

import AppKit
import Combine
import Foundation
import IOKit
import IOKit.hid
import os

extension SteamControllerHIDMonitor {

    /// One battery reading per active slot, with the USB device it hangs off. A wireless receiver
    /// exposes one vendor interface per pairing slot, each with its own registry id, and a single
    /// pad's reports can light up more than one of them over a session — the HUD showed a new
    /// battery square each time. `hostID` lets the reader collapse slots of one receiver that
    /// report the same pad.
    public struct BatteryPresence: Equatable, Sendable {
        public let deviceID: InputDeviceID
        public let hostID: UInt64
        public let model: SteamControllerModel
        public let level: UInt8?
        public let charging: Bool
    }

    public var batteryPresences: [BatteryPresence] {
        var seen = Set<UInt64>()
        return devices.values
            .filter(\.isActive)
            .sorted { ($0.controllerID, $0.gamepadDevice == nil ? 1 : 0) < ($1.controllerID, $1.gamepadDevice == nil ? 1 : 0) }
            .filter { seen.insert($0.controllerID).inserted }
            .map { context in
                BatteryPresence(deviceID: context.deviceID,
                                hostID: usbDeviceRegistryID(of: context.device),
                                model: context.model,
                                level: batteryLevels[context.deviceID],
                                charging: batteryCharging[context.deviceID] ?? false)
            }
            .sorted { $0.deviceID.rawValue < $1.deviceID.rawValue }
    }
}
