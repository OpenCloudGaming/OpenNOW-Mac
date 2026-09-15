//  Live input for the generic branch of the controller tester: a GameController pad's buttons,
//  sticks, and triggers, polled while a view needs them.
//
//  Deliberately read-only. `GCController` exposes one handler slot per element for the whole
//  process, and the catalog's navigator and the stream's gamepad monitor own those slots; a tester
//  that installed handlers would silence them for as long as its sheet is open. Polling reads the
//  element values without touching a single slot.
//

import Combine
import Foundation
import GameController

/// One frame of a GameController pad, holding the parts of `SteamControllerInputSnapshot` a
/// non-Steam pad actually has.
struct GenericControllerInputSnapshot: Equatable {
    var buttons: GamepadButtons = []
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0
    var leftStickX: Float = 0
    var leftStickY: Float = 0
    var rightStickX: Float = 0
    var rightStickY: Float = 0

    init() {}

    init(gamepad: GCExtendedGamepad) {
        buttons = NativeWebRTCGamepadMonitor.buttons(from: gamepad)
        leftTrigger = gamepad.leftTrigger.value
        rightTrigger = gamepad.rightTrigger.value
        leftStickX = gamepad.leftThumbstick.xAxis.value
        leftStickY = gamepad.leftThumbstick.yAxis.value
        rightStickX = gamepad.rightThumbstick.xAxis.value
        rightStickY = gamepad.rightThumbstick.yAxis.value
    }
}

@MainActor
final class GenericControllerTestModel: ObservableObject {
    static let pollIntervalMilliseconds = 33

    @Published private(set) var snapshot = GenericControllerInputSnapshot()
    @Published private(set) var isConnected = false
    @Published private(set) var deviceName = ""
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var isCharging = false

    private var controller: GCController?
    private var observerTokens: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?

    func start() {
        stop()
        observerTokens = [
            NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshController() }
            },
            NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshController() }
            },
        ]
        refreshController()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshSnapshot()
                try? await Task.sleep(for: .milliseconds(Self.pollIntervalMilliseconds))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        for token in observerTokens { NotificationCenter.default.removeObserver(token) }
        observerTokens = []
        controller = nil
        isConnected = false
        deviceName = ""
        batteryPercent = nil
        isCharging = false
        snapshot = GenericControllerInputSnapshot()
    }

    /// `availableNativeControllers()` is the same filter the stream's gamepad monitor uses: extended
    /// pads only, and no pad that is really a Steam Controller republished by GameController.
    private func refreshController() {
        guard let controller = NativeWebRTCGamepadMonitor.availableNativeControllers().first else {
            self.controller = nil
            isConnected = false
            deviceName = ""
            batteryPercent = nil
            isCharging = false
            snapshot = GenericControllerInputSnapshot()
            return
        }
        self.controller = controller
        isConnected = true
        deviceName = controller.vendorName ?? controller.productCategory
        refreshSnapshot()
    }

    private func refreshSnapshot() {
        guard let controller, let gamepad = controller.extendedGamepad else { return }
        let next = GenericControllerInputSnapshot(gamepad: gamepad)
        if next != snapshot { snapshot = next }
        refreshBattery(controller)
    }

    private func refreshBattery(_ controller: GCController) {
        guard let battery = controller.battery,
              let percent = ControllerBatteryInfo.percentage(level: battery.batteryLevel, state: battery.batteryState) else {
            if batteryPercent != nil { batteryPercent = nil }
            if isCharging { isCharging = false }
            return
        }
        let charging = battery.batteryState == .charging || battery.batteryState == .full
        if percent != batteryPercent { batteryPercent = percent }
        if charging != isCharging { isCharging = charging }
    }
}
