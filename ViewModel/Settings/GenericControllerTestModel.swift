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

/// Which shell art the native (non-Steam) branch of the tester draws.
///
/// GameController hands out a `GCDualShockGamepad` for a DualShock 4 and a plain
/// `GCExtendedGamepad` for every other pad, including a DualSense - so detection is the runtime
/// profile class first, and the device identity second, for a pad that arrives bridged through a
/// virtual driver as a plain extended gamepad.
enum NativeGamepadShell: Equatable {
    case dualShock4
    case generic

    init(controller: GCController, gamepad: GCExtendedGamepad) {
        if gamepad is GCDualShockGamepad {
            self = .dualShock4
            return
        }
        let identity = "\(controller.vendorName ?? "") \(controller.productCategory)".lowercased()
        self = identity.contains(GCProductCategoryDualShock4.lowercased()) || identity.contains("dualshock")
            ? .dualShock4
            : .generic
    }
}

/// A DualShock 4 touchpad frame: the finger's position in -1...1, whether a finger is on the
/// surface, and whether the touchpad itself is clicked. GameController reports both fingers
/// through `touchpadPrimary`/`touchpadSecondary`; a diagram draws one tracking dot, so the
/// primary finger is the one held here.
struct ControllerTouchpadState: Equatable {
    var x: Float = 0
    var y: Float = 0
    var touched = false
    var pressed = false
}

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
    /// Only a pad with a touchpad fills this; every other GameController pad leaves it `nil`.
    var touchpad: ControllerTouchpadState?

    init() {}

    init(gamepad: GCExtendedGamepad) {
        buttons = NativeWebRTCGamepadMonitor.buttons(from: gamepad)
        leftTrigger = gamepad.leftTrigger.value
        rightTrigger = gamepad.rightTrigger.value
        leftStickX = gamepad.leftThumbstick.xAxis.value
        leftStickY = gamepad.leftThumbstick.yAxis.value
        rightStickX = gamepad.rightThumbstick.xAxis.value
        rightStickY = gamepad.rightThumbstick.yAxis.value
        if let dualShock = gamepad as? GCDualShockGamepad {
            let x = dualShock.touchpadPrimary.xAxis.value
            let y = dualShock.touchpadPrimary.yAxis.value
            touchpad = ControllerTouchpadState(
                x: x,
                y: y,
                // Capacitive touch rides the touchpad button element. A lifted finger parks the
                // axes at centre, so a live position is the fallback for a pad that does not
                // report touch on the button at all.
                touched: dualShock.touchpadButton.isTouched || abs(x) > 0.02 || abs(y) > 0.02,
                pressed: dualShock.touchpadButton.isPressed
            )
        }
    }
}

@MainActor
final class GenericControllerTestModel: ObservableObject {
    static let pollIntervalMilliseconds = 33

    @Published private(set) var snapshot = GenericControllerInputSnapshot()
    @Published private(set) var isConnected = false
    @Published private(set) var deviceName = ""
    /// Which shell the tester should draw for the attached pad.
    @Published private(set) var padShell: NativeGamepadShell = .generic
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
        padShell = .generic
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
            padShell = .generic
            batteryPercent = nil
            isCharging = false
            snapshot = GenericControllerInputSnapshot()
            return
        }
        self.controller = controller
        isConnected = true
        deviceName = controller.vendorName ?? controller.productCategory
        if let gamepad = controller.extendedGamepad {
            padShell = NativeGamepadShell(controller: controller, gamepad: gamepad)
        }
        refreshSnapshot()
    }

    private func refreshSnapshot() {
        guard let controller, let gamepad = controller.extendedGamepad else { return }
        let next = GenericControllerInputSnapshot(gamepad: gamepad)
        if next != snapshot { snapshot = next }
        refreshBattery(controller)
    }

    private func refreshBattery(_ controller: GCController) {
        let percent = controller.battery.flatMap {
            ControllerBatteryInfo.percentage(level: $0.batteryLevel, state: $0.batteryState)
        }
        let charging = controller.battery?.batteryState == .charging
        if percent != batteryPercent { batteryPercent = percent }
        if charging != isCharging { isCharging = charging }
    }
}
