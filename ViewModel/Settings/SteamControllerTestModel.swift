import Combine
import Foundation

/// What the tester's MOTION panel shows for the gyro readout: the configured mapping decides
/// whether there is anything to show and whether its activation source is currently engaged.
enum SteamControllerGyroReadout: Equatable {
    case notConfigured
    case waiting
    case active
}

@MainActor
final class SteamControllerTestModel: ObservableObject {
    @Published private(set) var snapshot = ControllerInputSnapshot()
    @Published private(set) var deviceID = ""
    @Published private(set) var isConnected = false
    @Published private(set) var batteryLevel: UInt8?
    @Published private(set) var isCharging = false
    @Published private(set) var rumbleInFlight: RumbleTarget?
    /// Whether the configured mapping enables gyro and whether its activation source is engaged.
    @Published private(set) var gyroReadout: SteamControllerGyroReadout = .notConfigured
    /// The activation source's name, shown while waiting so the tester says what to engage.
    @Published private(set) var gyroActivationHint = ""
    @Published var rumbleIntensityPercent = 100

    enum RumbleTarget: Equatable { case left, right, both }

    private var selectedDeviceID: InputDeviceID?
    private var consumerKey: ObjectIdentifier?
    private var monitorWasEnabled = false
    private var rumbleResetTask: Task<Void, Never>?
    private var gyroActivation = GyroActivationState()
    private var gyroStepTask: Task<Void, Never>?
    private var lastGyroStep: ContinuousClock.Instant?

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
        startGyroStepping()
    }

    func stop() {
        stopRumble()
        selectedDeviceID = nil
        clearTelemetry()
        gyroStepTask?.cancel()
        gyroStepTask = nil
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
        gyroReadout = .notConfigured
        gyroActivationHint = ""
        gyroActivation.reset()
        lastGyroStep = nil
    }

    /// Steps the mapping's gyro activation latch on a timer rather than on input deltas: the HID
    /// callback only fires when state changes, but the release debounce needs a time base to expire.
    private func startGyroStepping() {
        guard gyroStepTask == nil else { return }
        gyroStepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.stepGyroReadout()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stepGyroReadout() {
        guard let selectedDeviceID else {
            gyroReadout = .notConfigured
            gyroActivationHint = ""
            gyroActivation.reset()
            lastGyroStep = nil
            return
        }
        let now = ContinuousClock.now
        let deltaTime: Float
        if let lastGyroStep {
            let elapsed = now - lastGyroStep
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            deltaTime = Float(min(max(seconds, 1.0 / 1000.0), 0.05))
        } else {
            deltaTime = 1 / 60
        }
        lastGyroStep = now

        guard let settings = ControllerMappingStore.shared.profile(for: selectedDeviceID, family: .steam)?.gyro,
              settings.mode != .off else {
            gyroReadout = .notConfigured
            gyroActivationHint = ""
            gyroActivation.reset()
            return
        }
        gyroActivationHint = settings.activationSource.label
        let active = gyroActivation.update(style: settings.activationStyle,
                                           source: settings.activationSource,
                                           snapshot: snapshot,
                                           activeControls: ControllerControlState.active(in: snapshot),
                                           deltaTime: deltaTime)
        gyroReadout = active ? .active : .waiting
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
