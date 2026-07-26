@preconcurrency import Foundation
import Combine
import GameController

public struct ControllerBatteryInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let level: Int
    public let charging: Bool
}

@MainActor
public final class NativeWebRTCGamepadMonitor {
    public var onInputEvent: ((UserInputEvent) -> Void)?
    @Published public private(set) var nativeBatteryLevels: [ControllerBatteryInfo] = []
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private var pollState = GamepadPollState()
    private let pollingQueue = DispatchQueue(label: "com.macforce-now.gamepad-poll", qos: .userInteractive)
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
        pollingQueue.sync { pollState.stopPolling() }
        observerTokens.forEach(NotificationCenter.default.removeObserver)
        let consumerKey = ObjectIdentifier(self)
        Task { @MainActor in
            SteamControllerHIDMonitor.shared.unregister(key: consumerKey)
            SteamControllerHIDMonitor.shared.endInputCapture(key: consumerKey)
        }
    }

    public nonisolated static func connectedGamepadCount() -> Int {
        let nativeCount = GCController.controllers().filter { $0.extendedGamepad != nil }.count
        return min(4, nativeCount + SteamControllerHIDMonitor.connectedControllerCount)
    }

    public func start() {
        pollingAllowed = true
        SteamControllerHIDMonitor.shared.setEnabled(SteamControllerPreference.isEnabled)
        SteamControllerHIDMonitor.shared.beginInputCapture(self)
        SteamControllerHIDMonitor.shared.register(
            self,
            onControllersChanged: { [weak self] in self?.refreshControllerSlots() },
            onInputState: { [weak self] deviceID, snapshot in self?.handleSteamControllerInput(deviceID, snapshot: snapshot) },
            onBatteryLevel: { [weak self] deviceID, level in
                let charging = SteamControllerHIDMonitor.shared.batteryCharging[deviceID] ?? false
                self?.handleSteamControllerBattery(deviceID, level: level, charging: charging)
            }
        )
        refreshControllerSlots()
        WebRTCMediaTelemetry.capture("webrtc.input.gamepad.monitor.start", level: .info, message: "Gamepad monitor started.", attributes: ["connected": String(Self.connectedGamepadCount())])
    }

    public func stop() {
        pollingAllowed = false
        SteamControllerHIDMonitor.shared.unregister(self)
        SteamControllerHIDMonitor.shared.endInputCapture(self)
        stopPollingTimer()
        WebRTCMediaTelemetry.capture("webrtc.input.gamepad.monitor.stop", level: .info, message: "Gamepad monitor stopped.")
    }

    private func refreshControllerSlots() {
        let previousSteamSlots = pollState.steamControllerSlots
        let previousOccupiedSlots = Set(pollState.controllerSlots.values).union(pollState.steamControllerSlots.values)
        let cachedControllers = Array(GCController.controllers().filter { $0.extendedGamepad != nil }.prefix(4))
        var newControllerSlots: [ObjectIdentifier: Int] = [:]
        for (index, controller) in cachedControllers.enumerated() {
            newControllerSlots[ObjectIdentifier(controller)] = index
        }
        var newSteamSlots: [InputDeviceID: Int] = [:]
        var nextSlot = cachedControllers.count
        for deviceID in SteamControllerHIDMonitor.shared.activeDeviceIDs where nextSlot < 4 {
            newSteamSlots[deviceID] = nextSlot
            nextSlot += 1
        }
        pollingQueue.sync {
            pollState.controllerSlots = newControllerSlots
            pollState.steamControllerSlots = newSteamSlots
            pollState.cachedControllers = cachedControllers
            pollState.lastStates.removeAll()
        }
        if pollingAllowed {
            emitSlotTransitions(previousSteamSlots: previousSteamSlots, previousOccupiedSlots: previousOccupiedSlots)
            newControllerSlots.isEmpty ? stopPollingTimer() : startPollingTimer()
        }
        let validBatteryIDs = Set(pollState.cachedControllers.prefix(4).map { "native-\(ObjectIdentifier($0).hashValue)" }).union(Set(newSteamSlots.keys.map { $0.rawValue }))
        nativeBatteryLevels.removeAll { !validBatteryIDs.contains($0.id) }
        let totalSlots = newControllerSlots.count + newSteamSlots.count
        WebRTCMediaTelemetry.capture("webrtc.input.gamepad.controllers", level: .info, message: "Detected \(totalSlots) controller(s).", attributes: ["connected": String(totalSlots), "steam": String(newSteamSlots.count)])
    }

    private func emitSlotTransitions(previousSteamSlots: [InputDeviceID: Int], previousOccupiedSlots: Set<Int>) {
        let currentSteamSlots = pollState.steamControllerSlots
        let currentControllerSlots = pollState.controllerSlots
        for (deviceID, slot) in currentSteamSlots where previousSteamSlots[deviceID] != slot {
            guard let snapshot = SteamControllerHIDMonitor.shared.snapshot(for: deviceID),
                  snapshot != SteamControllerInputSnapshot() else { continue }
            emitSteamState(deviceID: deviceID, playerIndex: slot, snapshot: snapshot)
        }
        let occupiedSlots = Set(currentControllerSlots.values).union(currentSteamSlots.values)
        for slot in previousOccupiedSlots.subtracting(occupiedSlots) {
            emitSteamState(deviceID: InputDeviceID("released-controller-\(slot)"), playerIndex: slot, snapshot: SteamControllerInputSnapshot())
        }
    }

    private func startPollingTimer() {
        pollingQueue.async { [weak self] in
            guard let self else { return }
            self.pollState.startPolling(on: self.pollingQueue, onEvents: { [weak self] events in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for event in events {
                        self.onInputEvent?(event)
                    }
                }
            }, onBatteryChange: { [weak self] changes in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    self?.applyNativeBatteryChanges(changes)
                }
            })
        }
    }

    private func stopPollingTimer() {
        pollingQueue.sync {
            pollState.stopPolling()
        }
        nativeBatteryLevels.removeAll()
    }

    private func handleSteamControllerInput(_ deviceID: InputDeviceID, snapshot: SteamControllerInputSnapshot) {
        guard pollingAllowed, let playerIndex = pollState.steamControllerSlots[deviceID] else { return }
        emitSteamState(deviceID: deviceID, playerIndex: playerIndex, snapshot: snapshot)
    }

    private func applyNativeBatteryChanges(_ changes: [ControllerBatteryInfo]) {
        var updated = nativeBatteryLevels
        for change in changes {
            if let index = updated.firstIndex(where: { $0.id == change.id }) {
                updated[index] = change
            } else {
                updated.append(change)
            }
        }
        let currentNativeIDs = Set(pollState.cachedControllers.prefix(4).map { "native-\(ObjectIdentifier($0).hashValue)" })
        updated.removeAll { !currentNativeIDs.contains($0.id) }
        nativeBatteryLevels = updated
    }

    private func handleSteamControllerBattery(_ deviceID: InputDeviceID, level: UInt8, charging: Bool) {
        guard let playerIndex = pollState.steamControllerSlots[deviceID] else { return }
        let info = ControllerBatteryInfo(id: deviceID.rawValue, label: "P\(playerIndex + 1)", level: Int(level), charging: charging)
        if let index = nativeBatteryLevels.firstIndex(where: { $0.id == deviceID.rawValue }) {
            nativeBatteryLevels[index] = info
        } else {
            nativeBatteryLevels.append(info)
        }
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

    nonisolated static func buttons(from gamepad: GCExtendedGamepad) -> GamepadButtons {
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

private final class GamepadPollState {
    var controllerSlots: [ObjectIdentifier: Int] = [:]
    var steamControllerSlots: [InputDeviceID: Int] = [:]
    var cachedControllers: [GCController] = []
    var lastStates: [ObjectIdentifier: GamepadControlSnapshot] = [:]
    var lastBatteryLevels: [ObjectIdentifier: Int] = [:]
    private var timer: DispatchSourceTimer?

    func startPolling(on queue: DispatchQueue, onEvents: @escaping @Sendable ([UserInputEvent]) -> Void, onBatteryChange: @escaping @Sendable ([ControllerBatteryInfo]) -> Void) {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.pollAndEmit(onEvents: onEvents, onBatteryChange: onBatteryChange)
        }
        self.timer = timer
        timer.resume()
    }

    func stopPolling() {
        timer?.cancel()
        timer = nil
    }

    private func pollAndEmit(onEvents: @escaping @Sendable ([UserInputEvent]) -> Void, onBatteryChange: @escaping @Sendable ([ControllerBatteryInfo]) -> Void) {
        if NativeWebRTCGamepadMonitor.connectedGamepadCount() != controllerSlots.count + steamControllerSlots.count {
            return
        }
        var events: [UserInputEvent] = []
        var batteryChanges: [ControllerBatteryInfo] = []
        for controller in cachedControllers {
            guard let gamepad = controller.extendedGamepad,
                  let playerIndex = controllerSlots[ObjectIdentifier(controller)] else { continue }
            let identifier = ObjectIdentifier(controller)
            let buttons = NativeWebRTCGamepadMonitor.buttons(from: gamepad)
            let snapshot = GamepadControlSnapshot(
                buttons: buttons,
                leftTrigger: gamepad.leftTrigger.value,
                rightTrigger: gamepad.rightTrigger.value,
                leftStickX: gamepad.leftThumbstick.xAxis.value,
                leftStickY: gamepad.leftThumbstick.yAxis.value,
                rightStickX: gamepad.rightThumbstick.xAxis.value,
                rightStickY: gamepad.rightThumbstick.yAxis.value
            )
            if lastStates[identifier] != snapshot {
                lastStates[identifier] = snapshot
                events.append(.gamepad(GamepadState(
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
            if let battery = controller.battery {
                let percent = Int((battery.batteryLevel * 100).rounded())
                let bucketedLevel = (percent / 5) * 5
                if lastBatteryLevels[identifier] != bucketedLevel {
                    lastBatteryLevels[identifier] = bucketedLevel
                    let label = "P\(playerIndex + 1)"
                    batteryChanges.append(ControllerBatteryInfo(id: "native-\(identifier.hashValue)", label: label, level: percent, charging: battery.batteryState == .charging))
                }
            }
        }
        let currentIDs = Set(cachedControllers.prefix(4).map { ObjectIdentifier($0) })
        let staleIDs = lastBatteryLevels.keys.filter { !currentIDs.contains($0) }
        for staleID in staleIDs {
            lastBatteryLevels.removeValue(forKey: staleID)
        }
        if !events.isEmpty {
            onEvents(events)
        }
        if !batteryChanges.isEmpty {
            onBatteryChange(batteryChanges)
        }
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
