@preconcurrency import Foundation
import GameController

@MainActor
public final class NativeWebRTCGamepadMonitor {
    public var onInputEvent: ((UserInputEvent) -> Void)?
    nonisolated(unsafe) private var timer: Timer?
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []
    private var controllerSlots: [ObjectIdentifier: Int] = [:]
    private var steamControllerSlots: [InputDeviceID: Int] = [:]
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
        let consumerKey = ObjectIdentifier(self)
        Task { @MainActor in
            SteamControllerHIDMonitor.shared.unregister(key: consumerKey)
        }
    }

    public nonisolated static func connectedGamepadCount() -> Int {
        let nativeCount = GCController.controllers().filter { $0.extendedGamepad != nil }.count
        return min(4, nativeCount + SteamControllerHIDMonitor.connectedControllerCount)
    }

    public func start() {
        pollingAllowed = true
        SteamControllerHIDMonitor.shared.setEnabled(SteamControllerPreference.isEnabled)
        SteamControllerHIDMonitor.shared.register(
            self,
            onControllersChanged: { [weak self] in self?.refreshControllerSlots() },
            onInputState: { [weak self] deviceID, snapshot in self?.handleSteamControllerInput(deviceID, snapshot: snapshot) }
        )
        refreshControllerSlots()
        WebRTCMediaTelemetry.capture("webrtc.input.gamepad.monitor.start", level: .info, message: "Gamepad monitor started.", attributes: ["connected": String(Self.connectedGamepadCount())])
    }

    public func stop() {
        pollingAllowed = false
        SteamControllerHIDMonitor.shared.unregister(self)
        stopPollingTimer()
        WebRTCMediaTelemetry.capture("webrtc.input.gamepad.monitor.stop", level: .info, message: "Gamepad monitor stopped.")
    }

    private func refreshControllerSlots() {
        let previousSteamSlots = steamControllerSlots
        let previousOccupiedSlots = Set(controllerSlots.values).union(steamControllerSlots.values)
        controllerSlots.removeAll()
        steamControllerSlots.removeAll()
        cachedControllers = Array(GCController.controllers().filter { $0.extendedGamepad != nil }.prefix(4))
        lastStates.removeAll()
        for (index, controller) in cachedControllers.enumerated() {
            controllerSlots[ObjectIdentifier(controller)] = index
        }
        var nextSlot = cachedControllers.count
        for deviceID in SteamControllerHIDMonitor.shared.activeDeviceIDs where nextSlot < 4 {
            steamControllerSlots[deviceID] = nextSlot
            nextSlot += 1
        }
        if pollingAllowed {
            emitSlotTransitions(previousSteamSlots: previousSteamSlots, previousOccupiedSlots: previousOccupiedSlots)
            controllerSlots.isEmpty ? stopPollingTimer() : startPollingTimer()
        }
        let totalSlots = controllerSlots.count + steamControllerSlots.count
        WebRTCMediaTelemetry.capture("webrtc.input.gamepad.controllers", level: .info, message: "Detected \(totalSlots) controller(s).", attributes: ["connected": String(totalSlots), "steam": String(steamControllerSlots.count)])
    }

    private func emitSlotTransitions(previousSteamSlots: [InputDeviceID: Int], previousOccupiedSlots: Set<Int>) {
        for (deviceID, slot) in steamControllerSlots where previousSteamSlots[deviceID] != slot {
            guard let snapshot = SteamControllerHIDMonitor.shared.snapshot(for: deviceID),
                  snapshot != SteamControllerInputSnapshot() else { continue }
            emitSteamState(deviceID: deviceID, playerIndex: slot, snapshot: snapshot)
        }
        let occupiedSlots = Set(controllerSlots.values).union(steamControllerSlots.values)
        for slot in previousOccupiedSlots.subtracting(occupiedSlots) {
            emitSteamState(deviceID: InputDeviceID("released-controller-\(slot)"), playerIndex: slot, snapshot: SteamControllerInputSnapshot())
        }
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

    private func handleSteamControllerInput(_ deviceID: InputDeviceID, snapshot: SteamControllerInputSnapshot) {
        guard pollingAllowed, let playerIndex = steamControllerSlots[deviceID] else { return }
        emitSteamState(deviceID: deviceID, playerIndex: playerIndex, snapshot: snapshot)
    }

    private func emitSteamState(deviceID: InputDeviceID, playerIndex: Int, snapshot: SteamControllerInputSnapshot) {
        onInputEvent?(.gamepad(GamepadState(
            deviceID: deviceID,
            playerIndex: playerIndex,
            buttons: snapshot.buttons,
            leftTrigger: snapshot.leftTrigger,
            rightTrigger: snapshot.rightTrigger,
            leftStickX: snapshot.leftStickX,
            leftStickY: snapshot.leftStickY,
            rightStickX: snapshot.rightStickX,
            rightStickY: snapshot.rightStickY,
            timestamp: MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
        )))
    }

    private func pollControllers() {
        if Self.connectedGamepadCount() != controllerSlots.count + steamControllerSlots.count { refreshControllerSlots() }
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
