@preconcurrency import Foundation
import GameController

@MainActor
public final class NativeWebRTCGamepadMonitor {
    public var onInputEvent: ((UserInputEvent) -> Void)?
    nonisolated(unsafe) private var timer: Timer?
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []
    private var controllerSlots: [ObjectIdentifier: Int] = [:]

    public init() {
        observerTokens = [
            NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshControllerSlots() }
            },
            NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshControllerSlots() }
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
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollControllers() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        WebRTCMediaTelemetry.capture("webrtc.input.gamepad.monitor.start", level: .info, message: "Gamepad monitor started.", attributes: ["connected": String(Self.connectedGamepadCount())])
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        WebRTCMediaTelemetry.capture("webrtc.input.gamepad.monitor.stop", level: .info, message: "Gamepad monitor stopped.")
    }

    private func refreshControllerSlots() {
        controllerSlots.removeAll()
        for (index, controller) in GCController.controllers().filter({ $0.extendedGamepad != nil }).prefix(4).enumerated() {
            controllerSlots[ObjectIdentifier(controller)] = index
        }
        WebRTCMediaTelemetry.capture("webrtc.input.gamepad.controllers", level: .info, message: "Detected \(controllerSlots.count) controller(s).", attributes: ["connected": String(controllerSlots.count)])
    }

    private func pollControllers() {
        let controllers = GCController.controllers().filter { $0.extendedGamepad != nil }
        if controllers.count != controllerSlots.count { refreshControllerSlots() }
        for controller in controllers {
            guard let gamepad = controller.extendedGamepad,
                  let playerIndex = controllerSlots[ObjectIdentifier(controller)] else { continue }
            onInputEvent?(.gamepad(GamepadState(
                deviceID: InputDeviceID(controller.vendorName ?? "controller-\(playerIndex)"),
                playerIndex: playerIndex,
                buttons: buttons(from: gamepad),
                leftTrigger: gamepad.leftTrigger.value,
                rightTrigger: gamepad.rightTrigger.value,
                leftStickX: gamepad.leftThumbstick.xAxis.value,
                leftStickY: -gamepad.leftThumbstick.yAxis.value,
                rightStickX: gamepad.rightThumbstick.xAxis.value,
                rightStickY: -gamepad.rightThumbstick.yAxis.value,
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
