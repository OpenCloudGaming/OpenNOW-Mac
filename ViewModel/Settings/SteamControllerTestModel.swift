//
//  SteamControllerTestModel.swift
//  OpenNOW
//
//  Live Steam Controller input for the settings test pane and the binding recorder: it turns the
//  HID monitor on while a view needs it and publishes the raw snapshot.
//
//  Moved out of `SteamControllerTestView`: it is the state two different views share, so it is not
//  the test view's private business.
//

import Combine
import Foundation

@MainActor
final class SteamControllerTestModel: ObservableObject {
    @Published var snapshot = SteamControllerInputSnapshot()
    @Published var deviceID: String = ""
    @Published var isConnected = false
    @Published var batteryLevel: UInt8?
    @Published var isCharging: Bool = false

    private var consumerKey: ObjectIdentifier?
    private var monitorWasEnabled = false

    func start() {
        monitorWasEnabled = SteamControllerPreference.isEnabled
        if !monitorWasEnabled {
            SteamControllerHIDMonitor.shared.setEnabled(true)
        }

        consumerKey = ObjectIdentifier(self)
        SteamControllerHIDMonitor.shared.beginInputCapture(self)
        SteamControllerHIDMonitor.shared.register(
            self,
            onControllersChanged: { [weak self] in self?.refreshConnection() },
            onInputState: { [weak self] deviceID, snapshot in
                guard let self else { return }
                self.deviceID = deviceID.rawValue
                self.snapshot = snapshot
                if !self.isConnected { self.isConnected = true }
            },
            onBatteryLevel: { [weak self] _, level in
                guard let self else { return }
                self.batteryLevel = level
            }
        )
        refreshConnection()
    }

    func stop() {
        if let consumerKey {
            SteamControllerHIDMonitor.shared.unregister(key: consumerKey)
            SteamControllerHIDMonitor.shared.endInputCapture(key: consumerKey)
        }
        consumerKey = nil

        if !monitorWasEnabled {
            SteamControllerHIDMonitor.shared.setEnabled(false)
        }
    }

    private func refreshConnection() {
        let ids = SteamControllerHIDMonitor.shared.activeDeviceIDs
        if let first = ids.first {
            isConnected = true
            deviceID = first.rawValue
            batteryLevel = SteamControllerHIDMonitor.shared.batteryLevels[first]
            isCharging = SteamControllerHIDMonitor.shared.batteryCharging[first] ?? false
            if let snap = SteamControllerHIDMonitor.shared.snapshot(for: first) {
                snapshot = snap
            }
        } else {
            isConnected = false
            deviceID = ""
            batteryLevel = nil
            isCharging = false
            snapshot = SteamControllerInputSnapshot()
        }
    }
}
