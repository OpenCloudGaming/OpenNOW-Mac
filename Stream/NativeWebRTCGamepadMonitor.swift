@preconcurrency import Foundation
import GameController

@MainActor
public final class NativeWebRTCGamepadMonitor {
    public var onInputEvent: ((UserInputEvent) -> Void)?
    nonisolated(unsafe) private var timer: Timer?
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []
    private var controllerSlots: [ObjectIdentifier: Int] = [:]
    private var cachedControllers: [GCController] = []
    private var lastStates: [ObjectIdentifier: GamepadControlSnapshot] = [:]
    private var pollingAllowed = false

    public init() {
        observerTokens = [
            NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshControllerSlots() }
            },
            NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshControllerSlots() }
            },
        ]
        refreshControllerSlots()
    }

    deinit {
        timer?.invalidate()
        observerTokens.forEach(NotificationCenter.default.removeObserver)
    }

    public nonisolated static func connectedGamepadCount() -> Int {
        min(4, GCController.controllers().filter { $0.extendedGamepad != nil }.count)
    }

    public func start() {
        pollingAllowed = true
        if Self.connectedGamepadCount() > 0 { startPollingTimer() }
        WebRTCMediaTelemetry.capture("webrtc.input.gamepad.monitor.start", level: .info, message: "Gamepad monitor started.", attributes: ["connected": String(Self.connectedGamepadCount())])
    }

    public func stop() {
        pollingAllowed = false
        stopPollingTimer()
        WebRTCMediaTelemetry.capture("webrtc.input.gamepad.monitor.stop", level: .info, message: "Gamepad monitor stopped.")
    }

    private func refreshControllerSlots() {
        controllerSlots.removeAll()
        cachedControllers = Array(GCController.controllers().filter { $0.extendedGamepad != nil }.prefix(4))
        let activeIdentifiers = Set(cachedControllers.map(ObjectIdentifier.init))
        lastStates = lastStates.filter { activeIdentifiers.contains($0.key) }
        for (index, controller) in cachedControllers.enumerated() {
            controllerSlots[ObjectIdentifier(controller)] = index
        }
        if pollingAllowed {
            controllerSlots.isEmpty ? stopPollingTimer() : startPollingTimer()
        }
        WebRTCMediaTelemetry.capture("webrtc.input.gamepad.controllers", level: .info, message: "Detected \(controllerSlots.count) controller(s).", attributes: ["connected": String(controllerSlots.count)])
    }

    private func startPollingTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollControllers() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPollingTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func pollControllers() {
        if Self.connectedGamepadCount() != controllerSlots.count { refreshControllerSlots() }
        for controller in cachedControllers {
            guard let gamepad = controller.extendedGamepad,
                  let playerIndex = controllerSlots[ObjectIdentifier(controller)] else { continue }
            let buttons = buttons(from: gamepad)
            let snapshot = GamepadControlSnapshot(
                buttons: buttons,
                leftTrigger: gamepad.leftTrigger.value,
                rightTrigger: gamepad.rightTrigger.value,
                leftStickX: gamepad.leftThumbstick.xAxis.value,
                leftStickY: gamepad.leftThumbstick.yAxis.value,
                rightStickX: gamepad.rightThumbstick.xAxis.value,
                rightStickY: gamepad.rightThumbstick.yAxis.value
            )
            let identifier = ObjectIdentifier(controller)
            guard lastStates[identifier] != snapshot else { continue }
            lastStates[identifier] = snapshot
            onInputEvent?(.gamepad(GamepadState(
                deviceID: InputDeviceID(controller.vendorName ?? "controller-\(playerIndex)"),
                playerIndex: playerIndex,
                buttons: buttons,
                leftTrigger: gamepad.leftTrigger.value,
                rightTrigger: gamepad.rightTrigger.value,
                leftStickX: gamepad.leftThumbstick.xAxis.value,
                leftStickY: gamepad.leftThumbstick.yAxis.value,
                rightStickX: gamepad.rightThumbstick.xAxis.value,
                rightStickY: gamepad.rightThumbstick.yAxis.value,
                timestamp: MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
            )))
        }
    }

    private func buttons(from gamepad: GCExtendedGamepad) -> GamepadButtons {
        var buttons: GamepadButtons = []
        if gamepad.buttonA.isPressed { buttons.insert(.south) }
        if gamepad.buttonB.isPressed { buttons.insert(.east) }
        if gamepad.buttonX.isPressed { buttons.insert(.west) }
        if gamepad.buttonY.isPressed { buttons.insert(.north) }
        if gamepad.leftShoulder.isPressed { buttons.insert(.leftShoulder) }
        if gamepad.rightShoulder.isPressed { buttons.insert(.rightShoulder) }
        if gamepad.leftThumbstickButton?.isPressed == true { buttons.insert(.leftStick) }
        if gamepad.rightThumbstickButton?.isPressed == true { buttons.insert(.rightStick) }
        if gamepad.dpad.up.isPressed { buttons.insert(.dpadUp) }
        if gamepad.dpad.down.isPressed { buttons.insert(.dpadDown) }
        if gamepad.dpad.left.isPressed { buttons.insert(.dpadLeft) }
        if gamepad.dpad.right.isPressed { buttons.insert(.dpadRight) }
        if gamepad.buttonOptions?.isPressed == true { buttons.insert(.select) }
        if gamepad.buttonMenu.isPressed { buttons.insert(.start) }
        return buttons
    }
}

private struct GamepadControlSnapshot: Equatable {
    let buttons: GamepadButtons
    let leftTrigger: Float
    let rightTrigger: Float
    let leftStickX: Float
    let leftStickY: Float
    let rightStickX: Float
    let rightStickY: Float
}
