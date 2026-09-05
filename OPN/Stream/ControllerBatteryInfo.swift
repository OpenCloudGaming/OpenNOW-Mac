//  One controller's battery as the HUD and the low-battery alert see it, and the tracker that decides
//  when an alert fires. Split from NativeWebRTCGamepadMonitor.swift for size.
//

import Foundation
import GameController

public struct ControllerBatteryInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let level: Int
    public let charging: Bool
    /// What the pad is ("Steam Controller", "Xbox Wireless Controller"), for the HUD row.
    public let name: String

    public init(id: String, label: String, level: Int, charging: Bool, name: String = "Controller") {
        self.id = id
        self.label = label
        self.level = level
        self.charging = charging
        self.name = name
    }

    /// Current battery info for every connected controller: Steam Controllers first
    /// (via the HID monitor), then GameController-framework pads, relabeled P1…Pn.
    @MainActor
    public static func currentSnapshot() -> [ControllerBatteryInfo] {
        var batteries = collapsed(SteamControllerHIDMonitor.shared.batteryPresences)
        let nativeControllers = NativeWebRTCGamepadMonitor.availableNativeControllers()
        for controller in nativeControllers {
            let percent = controller.battery.map { Int(($0.batteryLevel * 100).rounded()) } ?? -1
            let charging = controller.battery?.batteryState == .charging
            let name = controller.vendorName?.trimmingCharacters(in: .whitespaces).isEmpty == false ? controller.vendorName! : "Controller"
            batteries.append(ControllerBatteryInfo(id: "native-\(ObjectIdentifier(controller).hashValue)", label: "", level: percent, charging: charging, name: name))
        }
        return batteries.enumerated().map { index, info in
            ControllerBatteryInfo(id: info.id, label: "P\(index + 1)", level: info.level, charging: info.charging, name: info.name)
        }
    }

    /// One entry per physical pad: slots of the same receiver reporting the same level and charge
    /// state are one controller seen through several interfaces, not several controllers.
    /// Different readings under one receiver are kept — that is two pads on one dongle.
    public static func collapsed(_ presences: [SteamControllerHIDMonitor.BatteryPresence]) -> [ControllerBatteryInfo] {
        var seen = Set<String>()
        var result: [ControllerBatteryInfo] = []
        for presence in presences {
            let key = "\(presence.hostID)|\(presence.level.map(String.init) ?? "-")|\(presence.charging)"
            guard seen.insert(key).inserted else { continue }
            result.append(ControllerBatteryInfo(id: presence.deviceID.rawValue,
                                                label: "",
                                                level: presence.level.map { Int($0) } ?? -1,
                                                charging: presence.charging,
                                                name: presence.model == .triton ? "Steam Controller 2" : "Steam Controller"))
        }
        return result
    }
}

/// Edge-triggers one low-battery message per threshold per controller, and
/// re-arms once that controller charges back above the highest threshold.
/// A reference type on purpose: the stream views hold it across re-renders.
@MainActor
public final class ControllerBatteryAlertTracker {
    private static let thresholds = [20, 10, 5]
    private var firedThresholds: [String: Set<Int>] = [:]

    public init() {}

    public func messages(for batteries: [ControllerBatteryInfo]) -> [String] {
        var messages: [String] = []
        var currentIDs = Set<String>()
        for battery in batteries {
            currentIDs.insert(battery.id)
            let level = battery.level
            guard level >= 0 else { continue }
            var fired = firedThresholds[battery.id] ?? []
            for threshold in Self.thresholds where level <= threshold && !fired.contains(threshold) {
                fired.insert(threshold)
                let severity = threshold <= 5 ? "critical" : "low"
                messages.append("\(battery.label) \(severity) battery — \(level)%")
            }
            if level > Self.thresholds[0] {
                fired.removeAll()
            }
            firedThresholds[battery.id] = fired
        }
        for removedID in Set(firedThresholds.keys).subtracting(currentIDs) {
            firedThresholds.removeValue(forKey: removedID)
        }
        return messages
    }

    public func reset() {
        firedThresholds.removeAll()
    }
}
