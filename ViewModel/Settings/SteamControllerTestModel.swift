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
    /// Which motor the tester is currently pulsing, for the button highlight.
    @Published var rumbleInFlight: RumbleTarget?
    /// Motor amplitude for the test pulse, percent of full scale. Lets the controller's own
    /// intensity curve be felt without a game in the loop.
    @Published var rumbleIntensityPercent = 100

    enum RumbleTarget: Equatable { case left, right, both }

    /// Drives the connected controller's motors the way a seat rumble command would, for
    /// `ControllerRumbleTester.pulseMilliseconds`, then clears them.
    func testRumble(_ target: RumbleTarget) {
        guard let deviceID = SteamControllerHIDMonitor.shared.activeDeviceIDs.first(where: { $0.rawValue == self.deviceID })
                ?? SteamControllerHIDMonitor.shared.activeDeviceIDs.first else { return }
        let amplitude = UInt16(clamping: Int(Double(UInt16.max) * Double(min(max(rumbleIntensityPercent, 0), 100)) / 100))
        let left: UInt16 = target == .right ? 0 : amplitude
        let right: UInt16 = target == .left ? 0 : amplitude
        rumbleInFlight = target
        ControllerRumbleTester.pulseSteamController(deviceID, left: left, right: right)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(ControllerRumbleTester.pulseMilliseconds))
            if self?.rumbleInFlight == target { self?.rumbleInFlight = nil }
        }
    }

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
