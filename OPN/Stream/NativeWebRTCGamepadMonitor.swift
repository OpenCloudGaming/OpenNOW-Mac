@preconcurrency import Foundation
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

@MainActor
public final class NativeWebRTCGamepadMonitor {
    public var onInputEvent: ((UserInputEvent) -> Void)?
    public var onTopologyChanged: ((NativeWebRTCGamepadTopology) -> Void)? {
        didSet { onTopologyChanged?(topology) }
    }
    nonisolated(unsafe) private var timer: Timer?
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []
    private var controllerSlots = NativeWebRTCGamepadSlotMap<ObjectIdentifier>()
    private var cachedControllers: [GCController] = []
    private var lastStates: [ObjectIdentifier: GamepadControlSnapshot] = [:]
    private var lastGamepadStates: [ObjectIdentifier: GamepadState] = [:]
    private var hapticStates: [ObjectIdentifier: ControllerHapticState] = [:]
    private var pollingAllowed = false
    public private(set) var topology = NativeWebRTCGamepadTopology(playerIndices: [])

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
        stopHaptics()
        WebRTCMediaTelemetry.capture("webrtc.input.gamepad.monitor.stop", level: .info, message: "Gamepad monitor stopped.")
    }

    public func playHaptic(_ command: NativeNVSTHapticCommand) {
        guard let controller = cachedControllers.first(where: { controllerSlots.slots[ObjectIdentifier($0)] == command.playerIndex }),
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
        lastStates.removeAll()
        if pollingAllowed { pollControllers() }
    }

    private func refreshControllerSlots() {
        let connectedControllers = GCController.controllers().filter { $0.extendedGamepad != nil }
        let connectedIdentifiers = connectedControllers.map(ObjectIdentifier.init)
        let activeIdentifiers = Set(connectedIdentifiers)
        let previousControllers = Dictionary(uniqueKeysWithValues: cachedControllers.map { (ObjectIdentifier($0), $0) })
        let removed = controllerSlots.slots.compactMap { identifier, playerIndex in
            activeIdentifiers.contains(identifier) ? nil : (identifier, playerIndex)
        }.sorted { $0.1 < $1.1 }
        let timestamp = MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
        for assignment in removed {
            hapticStates.removeValue(forKey: assignment.0)?.stop()
            let priorState = lastGamepadStates[assignment.0]
            let deviceID = priorState?.deviceID ?? InputDeviceID(previousControllers[assignment.0]?.vendorName ?? "controller-\(assignment.1)")
            onInputEvent?(.gamepad(GamepadState(deviceID: deviceID, playerIndex: assignment.1, timestamp: timestamp)))
        }
        _ = controllerSlots.update(identifiers: connectedIdentifiers)
        cachedControllers = connectedControllers.filter { controllerSlots.slots[ObjectIdentifier($0)] != nil }
            .sorted { controllerSlots.slots[ObjectIdentifier($0), default: 0] < controllerSlots.slots[ObjectIdentifier($1), default: 0] }
        let monitoredIdentifiers = Set(cachedControllers.map(ObjectIdentifier.init))
        lastStates = lastStates.filter { monitoredIdentifiers.contains($0.key) }
        lastGamepadStates = lastGamepadStates.filter { monitoredIdentifiers.contains($0.key) }
        let hapticPlayerIndices = cachedControllers.compactMap { controller in
            controller.haptics == nil ? nil : controllerSlots.slots[ObjectIdentifier(controller)]
        }
        let newTopology = NativeWebRTCGamepadTopology(playerIndices: Array(controllerSlots.slots.values), hapticPlayerIndices: hapticPlayerIndices)
        if topology != newTopology {
            topology = newTopology
            onTopologyChanged?(newTopology)
        }
        if pollingAllowed {
            controllerSlots.slots.isEmpty ? stopPollingTimer() : startPollingTimer()
        }
        WebRTCMediaTelemetry.capture("webrtc.input.gamepad.controllers", level: .info, message: "Detected \(controllerSlots.slots.count) controller(s).", attributes: ["connected": String(controllerSlots.slots.count), "slots": topology.playerIndices.map(String.init).joined(separator: ",")])
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
        let connectedIdentifiers = Set(GCController.controllers().filter { $0.extendedGamepad != nil }.map(ObjectIdentifier.init))
        if connectedIdentifiers != Set(controllerSlots.slots.keys) { refreshControllerSlots() }
        for controller in cachedControllers {
            guard let gamepad = controller.extendedGamepad,
                  let playerIndex = controllerSlots.slots[ObjectIdentifier(controller)] else { continue }
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
            let state = GamepadState(
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
            )
            lastGamepadStates[identifier] = state
            onInputEvent?(.gamepad(state))
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
