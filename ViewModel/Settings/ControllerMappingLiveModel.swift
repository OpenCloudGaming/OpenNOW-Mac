import Combine
import Foundation
import GameController

@MainActor
final class ControllerMappingLiveModel: ObservableObject {
    /// The cadence this model republishes at, and therefore the step one calibration sample
    /// represents. Exposed so the gyro editor's capture integrates over the same interval the
    /// snapshots arrive on instead of carrying a second copy of the same number.
    static let pollInterval: Duration = .milliseconds(33)
    static let sampleInterval: Float = 0.033

    @Published private(set) var snapshot = ControllerInputSnapshot()
    var selectedDeviceID: InputDeviceID? {
        didSet { snapshot = ControllerInputSnapshot() }
    }
    private var task: Task<Void, Never>?
    private var monitorWasEnabled = false

    func start() {
        guard task == nil else { return }
        monitorWasEnabled = SteamControllerPreference.isEnabled
        let monitor = SteamControllerHIDMonitor.shared
        if !monitorWasEnabled { monitor.setEnabled(true) }
        monitor.beginInputCapture(self)
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        let monitor = SteamControllerHIDMonitor.shared
        monitor.endInputCapture(self)
        if !monitorWasEnabled { monitor.setEnabled(false) }
    }

    private func poll() {
        let registry = ControllerMappingDevices.shared
        registry.refresh()
        let id = selectedDeviceID ?? SteamControllerHIDMonitor.shared.activeDeviceIDs.first
        var next = ControllerInputSnapshot()
        if let id {
            if let gamepad = registry.controller(for: id)?.extendedGamepad {
                next = ControllerInputSnapshot(gamepad: gamepad)
            } else if let steam = SteamControllerHIDMonitor.shared.snapshot(for: id) {
                next = steam
            }
        }
        if snapshot != next { snapshot = next }
    }
}
