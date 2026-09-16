import Combine
import Foundation

@MainActor
final class SteamControllerTestModel: ObservableObject {
    @Published private(set) var snapshot = ControllerInputSnapshot()
    @Published private(set) var deviceID = ""
    @Published private(set) var isConnected = false
    @Published private(set) var batteryLevel: UInt8?
    @Published private(set) var isCharging = false
    @Published private(set) var rumbleInFlight: RumbleTarget?
    @Published var rumbleIntensityPercent = 100

    enum RumbleTarget: Equatable { case left, right, both }

    private var selectedDeviceID: InputDeviceID?
    private var consumerKey: ObjectIdentifier?
    private var monitorWasEnabled = false
    private var rumbleResetTask: Task<Void, Never>?

    func selectDevice(_ id: InputDeviceID?) {
        if selectedDeviceID != id {
            stopRumble()
            selectedDeviceID = id
            clearTelemetry()
        }
        refreshConnection()
    }

    func receiveSnapshot(_ snapshot: ControllerInputSnapshot, from id: InputDeviceID) {
        guard id == selectedDeviceID else { return }
        deviceID = id.rawValue
        self.snapshot = snapshot
        isConnected = true
    }

    func receiveBattery(_ level: UInt8?, charging: Bool, from id: InputDeviceID) {
        guard id == selectedDeviceID else { return }
        batteryLevel = level
        isCharging = charging
    }

    func rumbleDeviceID(connectedIDs: [InputDeviceID]) -> InputDeviceID? {
        guard isConnected, let selectedDeviceID, connectedIDs.contains(selectedDeviceID) else { return nil }
        return selectedDeviceID
    }

    func testRumble(_ target: RumbleTarget) {
        guard let id = rumbleDeviceID(connectedIDs: SteamControllerHIDMonitor.shared.activeDeviceIDs) else { return }
        let amplitude = UInt16(clamping: Int(Double(UInt16.max) * Double(min(max(rumbleIntensityPercent, 0), 100)) / 100))
        let left: UInt16 = target == .right ? 0 : amplitude
        let right: UInt16 = target == .left ? 0 : amplitude
        rumbleResetTask?.cancel()
        rumbleInFlight = target
        ControllerRumbleTester.pulseSteamController(id, left: left, right: right)
        rumbleResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(ControllerRumbleTester.pulseMilliseconds))
            guard !Task.isCancelled else { return }
            self?.rumbleInFlight = nil
            self?.rumbleResetTask = nil
        }
    }

    func start() {
        guard consumerKey == nil else { return }
        monitorWasEnabled = SteamControllerPreference.isEnabled
        if !monitorWasEnabled {
            SteamControllerHIDMonitor.shared.setEnabled(true)
        }
        consumerKey = ObjectIdentifier(self)
        SteamControllerHIDMonitor.shared.beginInputCapture(self)
        SteamControllerHIDMonitor.shared.register(
            self,
            onControllersChanged: { [weak self] in self?.refreshConnection() },
            onInputState: { [weak self] id, snapshot in self?.receiveSnapshot(snapshot, from: id) },
            onBatteryLevel: { [weak self] id, level in
                self?.receiveBattery(level, charging: SteamControllerHIDMonitor.shared.batteryCharging[id] ?? false, from: id)
            }
        )
        refreshConnection()
    }

    func stop() {
        stopRumble()
        selectedDeviceID = nil
        clearTelemetry()
        guard let consumerKey else { return }
        SteamControllerHIDMonitor.shared.unregister(key: consumerKey)
        SteamControllerHIDMonitor.shared.endInputCapture(key: consumerKey)
        self.consumerKey = nil
        if !monitorWasEnabled {
            SteamControllerHIDMonitor.shared.setEnabled(false)
        }
    }

    private func stopRumble() {
        rumbleResetTask?.cancel()
        rumbleResetTask = nil
        if rumbleInFlight != nil, let selectedDeviceID {
            ControllerRumbleTester.stopSteamControllerPulse(selectedDeviceID)
        }
        rumbleInFlight = nil
    }

    private func clearTelemetry() {
        isConnected = false
        deviceID = ""
        batteryLevel = nil
        isCharging = false
        snapshot = ControllerInputSnapshot()
    }

    private func refreshConnection() {
        let monitor = SteamControllerHIDMonitor.shared
        guard let selectedDeviceID, monitor.activeDeviceIDs.contains(selectedDeviceID) else {
            stopRumble()
            clearTelemetry()
            return
        }
        isConnected = true
        deviceID = selectedDeviceID.rawValue
        receiveBattery(monitor.batteryLevels[selectedDeviceID], charging: monitor.batteryCharging[selectedDeviceID] ?? false, from: selectedDeviceID)
        if let snapshot = monitor.snapshot(for: selectedDeviceID) {
            receiveSnapshot(snapshot, from: selectedDeviceID)
        }
    }
}
