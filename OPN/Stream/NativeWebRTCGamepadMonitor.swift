@preconcurrency import Foundation
import Combine
import GameController
import CoreHaptics

public struct NativeWebRTCGamepadTopology: Equatable, Sendable {
    public let playerIndices: [Int]
    public let hapticPlayerIndices: [Int]
    public let registrationBitmap: UInt16
    public let connectedPlayerBitmap: UInt8
    public let hapticPlayerBitmap: UInt8
    public var hapticsEnabled: Bool { hapticPlayerBitmap != 0 }

    public init(playerIndices: [Int], hapticPlayerIndices: [Int] = []) {
        let normalizedPlayerIndices = Array(Set(playerIndices.filter { (0..<4).contains($0) })).sorted()
        let normalizedHapticPlayerIndices = Array(Set(hapticPlayerIndices.filter { normalizedPlayerIndices.contains($0) })).sorted()
        self.playerIndices = normalizedPlayerIndices
        self.hapticPlayerIndices = normalizedHapticPlayerIndices
        registrationBitmap = normalizedPlayerIndices.reduce(0) { bitmap, index in
            bitmap | UInt16(1 << index) | UInt16(1 << (index + 8))
        }
        connectedPlayerBitmap = normalizedPlayerIndices.reduce(0) { $0 | UInt8(1 << $1) }
        hapticPlayerBitmap = normalizedHapticPlayerIndices.reduce(0) { $0 | UInt8(1 << $1) }
    }
}

enum NativeNVSTHapticLocality: Equatable, Sendable {
    case leftHandle
    case rightHandle
    case `default`
}

struct NativeNVSTHapticRoute: Equatable, Sendable {
    let locality: NativeNVSTHapticLocality
    let intensity: UInt16
}

enum NativeNVSTHapticRouter {
    static func routes(for command: NativeNVSTHapticCommand, supportsHandles: Bool) -> [NativeNVSTHapticRoute] {
        if supportsHandles {
            return [
                NativeNVSTHapticRoute(locality: .leftHandle, intensity: command.lowFrequency),
                NativeNVSTHapticRoute(locality: .rightHandle, intensity: command.highFrequency),
            ]
        }
        return [NativeNVSTHapticRoute(locality: .default, intensity: max(command.lowFrequency, command.highFrequency))]
    }
}

struct NativeWebRTCGamepadSlotMap<Identifier: Hashable> {
    private(set) var slots: [Identifier: Int] = [:]

    mutating func update(identifiers: [Identifier], maximumSlots: Int = 4) -> [(identifier: Identifier, playerIndex: Int)] {
        let activeIdentifiers = Set(identifiers)
        let removed = slots.compactMap { identifier, playerIndex in
            activeIdentifiers.contains(identifier) ? nil : (identifier, playerIndex)
        }.sorted { $0.1 < $1.1 }
        slots = slots.filter { activeIdentifiers.contains($0.key) }
        var availableSlots = Array(0..<maximumSlots).filter { !slots.values.contains($0) }
        for identifier in identifiers where slots[identifier] == nil && !availableSlots.isEmpty {
            slots[identifier] = availableSlots.removeFirst()
        }
        return removed
    }
}

public struct ControllerBatteryInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let level: Int
    public let charging: Bool

    /// Current battery info for every connected controller: Steam Controllers first
    /// (via the HID monitor), then GameController-framework pads, relabeled P1…Pn.
    @MainActor
    public static func currentSnapshot() -> [ControllerBatteryInfo] {
        var batteries: [ControllerBatteryInfo] = []
        let steamLevels = SteamControllerHIDMonitor.shared.batteryLevels
        let steamCharging = SteamControllerHIDMonitor.shared.batteryCharging
        let activeIDs = SteamControllerHIDMonitor.shared.activeDeviceIDs
        for (index, deviceID) in activeIDs.enumerated() {
            let level = steamLevels[deviceID].map { Int($0) } ?? -1
            let charging = steamCharging[deviceID] ?? false
            batteries.append(ControllerBatteryInfo(id: deviceID.rawValue, label: "P\(index + 1)", level: level, charging: charging))
        }
        let nativeControllers = GCController.controllers().filter { $0.extendedGamepad != nil }
        let steamCount = activeIDs.count
        for (index, controller) in nativeControllers.enumerated() {
            let percent = controller.battery.map { Int(($0.batteryLevel * 100).rounded()) } ?? -1
            let charging = controller.battery?.batteryState == .charging
            batteries.append(ControllerBatteryInfo(id: "native-\(ObjectIdentifier(controller).hashValue)", label: "P\(steamCount + index + 1)", level: percent, charging: charging))
        }
        let sorted = batteries.sorted { $0.label < $1.label }
        return sorted.enumerated().map { index, info in
            ControllerBatteryInfo(id: info.id, label: "P\(index + 1)", level: info.level, charging: info.charging)
        }
    }
}

/// Edge-triggers one low-battery message per threshold per controller, and
/// re-arms once that controller charges back above the highest threshold.
/// A reference type on purpose: the stream views hold it across re-renders.
@MainActor
public final class ControllerBatteryAlertTracker {
    private static let thresholds = [20, 10, 5]
    private var firedThresholds: [String: Set<Int>] = [:]

    public init() {}

    public func messages(for batteries: [ControllerBatteryInfo]) -> [String] {
        var messages: [String] = []
        var currentIDs = Set<String>()
        for battery in batteries {
            currentIDs.insert(battery.id)
            let level = battery.level
            guard level >= 0 else { continue }
            var fired = firedThresholds[battery.id] ?? []
            for threshold in Self.thresholds where level <= threshold && !fired.contains(threshold) {
                fired.insert(threshold)
                let severity = threshold <= 5 ? "critical" : "low"
                messages.append("\(battery.label) \(severity) battery — \(level)%")
            }
            if level > Self.thresholds[0] {
                fired.removeAll()
            }
            firedThresholds[battery.id] = fired
        }
        for removedID in Set(firedThresholds.keys).subtracting(currentIDs) {
            firedThresholds.removeValue(forKey: removedID)
        }
        return messages
    }

    public func reset() {
        firedThresholds.removeAll()
    }
}

@MainActor
public final class NativeWebRTCGamepadMonitor {
    public var onInputEvent: ((UserInputEvent) -> Void)?
    @Published public private(set) var nativeBatteryLevels: [ControllerBatteryInfo] = []
    public var onTopologyChanged: ((NativeWebRTCGamepadTopology) -> Void)? {
        didSet { onTopologyChanged?(topology) }
    }
    public private(set) var topology = NativeWebRTCGamepadTopology(playerIndices: [])
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private var pollState = GamepadPollState()
    private let pollingQueue = DispatchQueue(label: "com.opennow.gamepad-poll", qos: .userInteractive)
    private var pollingAllowed = false
    private let bindingClock = ContinuousClock()
    private var bindingEngines: [InputDeviceID: SteamControllerBindingEngine] = [:]
    private var reapplyTasks: [InputDeviceID: Task<Void, Never>] = [:]
    private var localCursorModeHeld: Set<InputDeviceID> = []
    private var chordTracker = StreamOSKChordTracker()
    private var onScreenKeyboardCapturedDevices: Set<InputDeviceID> = []
    private var hapticStates: [ObjectIdentifier: ControllerHapticState] = [:]
    private var accessibilityPromptShown = false

    /// Controller chords: the `...` quick-access button toggles the HUD, and
    /// Steam+X toggles the on-screen keyboard. Fired for every Steam Controller
    /// report, including while the keyboard captures the device.
    public var onChordCommand: ((StreamOSKChordCommand) -> Void)?
    /// Returning true hands the raw snapshot to the on-screen keyboard instead of
    /// the binding engine. The keyboard also owns button navigation while active.
    public var onScreenKeyboardCapture: ((InputDeviceID, SteamControllerInputSnapshot) -> Bool)?

    private let mappingProvider: any SteamControllerMappingProviding

    init(mappingProvider: any SteamControllerMappingProviding = SteamControllerMappingStore.shared) {
        self.mappingProvider = mappingProvider
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
        reapplyTasks.values.forEach { $0.cancel() }
        reapplyTasks.removeAll()
        bindingEngines.removeAll()
        chordTracker.reset()
        onScreenKeyboardCapturedDevices.removeAll()
        if !localCursorModeHeld.isEmpty {
            localCursorModeHeld.removeAll()
            SteamControllerLocalCursorInjector.shared.reset()
        }
        stopPollingTimer()
        stopHaptics()
        WebRTCMediaTelemetry.capture("webrtc.input.gamepad.monitor.stop", level: .info, message: "Gamepad monitor stopped.")
    }

    public func playHaptic(_ command: NativeNVSTHapticCommand) {
        guard let controller = pollState.cachedControllers.first(where: { pollState.controllerSlots[ObjectIdentifier($0)] == command.playerIndex }),
              controller.haptics != nil else { return }
        let identifier = ObjectIdentifier(controller)
        let state = hapticStates[identifier] ?? ControllerHapticState(controller: controller)
        hapticStates[identifier] = state
        do {
            try state.play(command)
        } catch {
            state.stop()
            hapticStates.removeValue(forKey: identifier)
        }
    }

    public func stopHaptics() {
        hapticStates.values.forEach { $0.stop() }
        hapticStates.removeAll()
    }

    public func refreshInputState() {
        refreshControllerSlots()
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
        for deviceID in bindingEngines.keys where newSteamSlots[deviceID] == nil {
            bindingEngines.removeValue(forKey: deviceID)
            reapplyTasks.removeValue(forKey: deviceID)?.cancel()
        }
        for deviceID in previousSteamSlots.keys where newSteamSlots[deviceID] == nil {
            chordTracker.removeDevice(deviceID)
            onScreenKeyboardCapturedDevices.remove(deviceID)
        }
        let staleCursorDeviceIDs = localCursorModeHeld.filter { newSteamSlots[$0] == nil }
        if !staleCursorDeviceIDs.isEmpty {
            localCursorModeHeld.subtract(staleCursorDeviceIDs)
            SteamControllerLocalCursorInjector.shared.reset()
        }
        if pollingAllowed {
            emitSlotTransitions(previousSteamSlots: previousSteamSlots, previousOccupiedSlots: previousOccupiedSlots)
            newControllerSlots.isEmpty ? stopPollingTimer() : startPollingTimer()
        }
        let validBatteryIDs = Set(pollState.cachedControllers.prefix(4).map { "native-\(ObjectIdentifier($0).hashValue)" }).union(Set(newSteamSlots.keys.map { $0.rawValue }))
        nativeBatteryLevels.removeAll { !validBatteryIDs.contains($0.id) }
        let hapticPlayerIndices = pollState.cachedControllers.compactMap { controller in
            controller.haptics == nil ? nil : newControllerSlots[ObjectIdentifier(controller)]
        }
        let allPlayerIndices = Array(newControllerSlots.values) + Array(newSteamSlots.values)
        let newTopology = NativeWebRTCGamepadTopology(playerIndices: allPlayerIndices, hapticPlayerIndices: hapticPlayerIndices)
        if topology != newTopology {
            topology = newTopology
            onTopologyChanged?(newTopology)
        }
        let totalSlots = newControllerSlots.count + newSteamSlots.count
        WebRTCMediaTelemetry.capture("webrtc.input.gamepad.controllers", level: .info, message: "Detected \(totalSlots) controller(s).", attributes: ["connected": String(totalSlots), "steam": String(newSteamSlots.count)])
    }

    private func emitSlotTransitions(previousSteamSlots: [InputDeviceID: Int], previousOccupiedSlots: Set<Int>) {
        let currentSteamSlots = pollState.steamControllerSlots
        let currentControllerSlots = pollState.controllerSlots
        for (deviceID, slot) in currentSteamSlots where previousSteamSlots[deviceID] != slot {
            guard let snapshot = SteamControllerHIDMonitor.shared.snapshot(for: deviceID),
                  snapshot != SteamControllerInputSnapshot() else { continue }
            processSteamSnapshot(deviceID: deviceID, playerIndex: slot, snapshot: snapshot)
        }
        let occupiedSlots = Set(currentControllerSlots.values).union(currentSteamSlots.values)
        for slot in previousOccupiedSlots.subtracting(occupiedSlots) {
            applyBindingEngine(deviceID: InputDeviceID("released-controller-\(slot)"), playerIndex: slot, snapshot: SteamControllerInputSnapshot(), includePointerMotion: true)
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
        processSteamSnapshot(deviceID: deviceID, playerIndex: playerIndex, snapshot: snapshot)
    }

    /// Single entry for every Steam Controller report — live or replayed — so the
    /// chord tracker and the on-screen keyboard capture observe the same stream of
    /// state. Chords are resolved first (Steam+X must keep working while the
    /// keyboard captures the device), then the capture split, then normal binding.
    /// The Steam button itself is left in the buttons — the local-cursor modifier
    /// below reads it.
    private func processSteamSnapshot(deviceID: InputDeviceID, playerIndex: Int, snapshot: SteamControllerInputSnapshot) {
        let chord = chordTracker.process(buttons: snapshot.buttons, deviceID: deviceID)
        var snapshot = snapshot
        snapshot.buttons = chord.buttons
        if let command = chord.command {
            onChordCommand?(command)
        }
        if onScreenKeyboardCapture?(deviceID, snapshot) == true {
            if onScreenKeyboardCapturedDevices.insert(deviceID).inserted {
                applyBindingEngine(deviceID: deviceID, playerIndex: playerIndex, snapshot: SteamControllerInputSnapshot(), includePointerMotion: true)
            }
            if localCursorModeHeld.remove(deviceID) != nil {
                SteamControllerLocalCursorInjector.shared.reset()
            }
            return
        }
        onScreenKeyboardCapturedDevices.remove(deviceID)
        applyBindingEngine(deviceID: deviceID, playerIndex: playerIndex, snapshot: snapshot, includePointerMotion: !snapshot.buttons.contains(.mode))
        if snapshot.buttons.contains(.mode) {
            let isRisingEdge = localCursorModeHeld.insert(deviceID).inserted
            if isRisingEdge, !SteamControllerLocalCursorInjector.hasAccessibilityPermission, !accessibilityPromptShown {
                accessibilityPromptShown = true
                SteamControllerLocalCursorInjector.requestAccessibilityPermission()
            }
            SteamControllerLocalCursorInjector.shared.update(pad: snapshot.rightPad)
            return
        }
        if localCursorModeHeld.remove(deviceID) != nil {
            SteamControllerLocalCursorInjector.shared.reset()
        }
    }

    /// While the Guide/Steam button is held, `includePointerMotion` is false — trackpad
    /// and stick pointer motion is suppressed here so `SteamControllerLocalCursorInjector`
    /// can drive the real macOS cursor from the right pad instead. Buttons/triggers/sticks
    /// keep forwarding normally either way.
    private func applyBindingEngine(deviceID: InputDeviceID, playerIndex: Int, snapshot: SteamControllerInputSnapshot, includePointerMotion: Bool) {
        reapplyTasks.removeValue(forKey: deviceID)?.cancel()
        let profile = mappingProvider.activeProfile ?? SteamControllerMappingProfile(name: "Default")
        let timestamp = MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
        var engine = bindingEngines[deviceID] ?? SteamControllerBindingEngine()
        var result = engine.applyDiscreteControls(profile: profile, snapshot: snapshot, deviceID: deviceID, playerIndex: playerIndex, now: bindingClock.now, timestamp: timestamp)
        if includePointerMotion {
            result.events.append(contentsOf: engine.applyPointerMotion(profile: profile, snapshot: snapshot, deviceID: deviceID, timestamp: timestamp))
        }
        bindingEngines[deviceID] = engine
        for event in result.events {
            onInputEvent?(event)
        }
        if let delay = result.nextReapplyDelay {
            scheduleReapply(deviceID: deviceID, playerIndex: playerIndex, after: delay)
        }
    }

    private func scheduleReapply(deviceID: InputDeviceID, playerIndex: Int, after delay: Duration) {
        reapplyTasks[deviceID] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.pollingAllowed else { return }
            self.reapplyTasks.removeValue(forKey: deviceID)
            guard self.pollState.steamControllerSlots[deviceID] == playerIndex,
                  let latest = SteamControllerHIDMonitor.shared.snapshot(for: deviceID) else { return }
            self.processSteamSnapshot(deviceID: deviceID, playerIndex: playerIndex, snapshot: latest)
        }
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
        if gamepad.buttonHome?.isPressed == true { buttons.insert(.mode) }
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

@MainActor
private final class ControllerHapticState {
    private let controller: GCController
    private var engines: [GCHapticsLocality: CHHapticEngine] = [:]
    private var players: [GCHapticsLocality: any CHHapticPatternPlayer] = [:]

    init(controller: GCController) {
        self.controller = controller
    }

    func play(_ command: NativeNVSTHapticCommand) throws {
        guard let haptics = controller.haptics else { return }
        let supportsHandles = haptics.supportedLocalities.contains(.leftHandle) && haptics.supportedLocalities.contains(.rightHandle)
        for route in NativeNVSTHapticRouter.routes(for: command, supportsHandles: supportsHandles) {
            let locality: GCHapticsLocality = switch route.locality {
            case .leftHandle: .leftHandle
            case .rightHandle: .rightHandle
            case .default: .default
            }
            try play(intensity: route.intensity, durationMilliseconds: command.durationMilliseconds, locality: locality, haptics: haptics)
        }
    }

    func stop() {
        for player in players.values { try? player.stop(atTime: 0) }
        players.removeAll()
        for engine in engines.values { engine.stop(completionHandler: nil) }
        engines.removeAll()
    }

    private func play(intensity: UInt16, durationMilliseconds: UInt16, locality: GCHapticsLocality, haptics: GCDeviceHaptics) throws {
        if let player = players.removeValue(forKey: locality) { try? player.stop(atTime: 0) }
        guard intensity > 0 else { return }
        let engine: CHHapticEngine
        if let existing = engines[locality] {
            engine = existing
        } else {
            guard let created = haptics.createEngine(withLocality: locality) else { return }
            created.isAutoShutdownEnabled = false
            try created.start()
            engines[locality] = created
            engine = created
        }
        let parameters = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(intensity) / Float(UInt16.max)),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
        ]
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: parameters,
            relativeTime: 0,
            duration: TimeInterval(durationMilliseconds) / 1_000
        )
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: 0)
        players[locality] = player
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
