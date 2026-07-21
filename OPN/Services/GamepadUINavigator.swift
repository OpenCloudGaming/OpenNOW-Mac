import Combine
import Foundation
import GameController

@MainActor
final class GamepadUINavigator: ObservableObject {
    static let steamControllerDeviceName = "Steam Controller"
    static let thumbstickDeadzone: Float = 0.45
    static let thumbstickRepeatInterval: TimeInterval = 0.18

    @Published private(set) var isSteamControllerConnected = false
    @Published private(set) var connectedDeviceName = ""
    @Published private(set) var glyphs = ControllerInputGlyphSet.keyboard

    var onCommand: ((ControllerInputCommand) -> Void)?

    private var lastButtons: [InputDeviceID: GamepadButtons] = [:]
    private var thumbstickRepeatState: [ControllerInputDirection: Date] = [:]

    init() {}

    func start() {
        SteamControllerHIDMonitor.shared.register(
            self,
            onControllersChanged: { [weak self] in
                MainActor.assumeIsolated { self?.refreshConnectedState() }
            },
            onInputState: { [weak self] deviceID, snapshot in
                MainActor.assumeIsolated { self?.processSnapshot(deviceID: deviceID, snapshot: snapshot, isActiveOverride: nil) }
            }
        )
        refreshConnectedState()
        seedInitialButtonStates()
    }

    func stop() {
        SteamControllerHIDMonitor.shared.unregister(self)
        isSteamControllerConnected = false
        connectedDeviceName = ""
        glyphs = .keyboard
        lastButtons.removeAll()
        thumbstickRepeatState.removeAll()
    }

    deinit {
        let consumerKey = ObjectIdentifier(self)
        Task { @MainActor in
            SteamControllerHIDMonitor.shared.unregister(key: consumerKey)
        }
    }

    private func seedInitialButtonStates() {
        for deviceID in SteamControllerHIDMonitor.shared.activeDeviceIDs {
            if let snapshot = SteamControllerHIDMonitor.shared.snapshot(for: deviceID) {
                lastButtons[deviceID] = snapshot.buttons
            }
        }
    }

    private func refreshConnectedState() {
        let activeIDs = SteamControllerHIDMonitor.shared.activeDeviceIDs
        let isConnected = !activeIDs.isEmpty
        isSteamControllerConnected = isConnected
        connectedDeviceName = isConnected ? Self.steamControllerDeviceName : ""
        glyphs = isConnected ? Self.makeGlyphs() : .keyboard
        if !isConnected {
            thumbstickRepeatState.removeAll()
        }
        let knownIDs = Set(lastButtons.keys)
        let lingering = knownIDs.subtracting(Set(activeIDs))
        for deviceID in lingering {
            lastButtons.removeValue(forKey: deviceID)
        }
    }

    func processSnapshot(deviceID: InputDeviceID, snapshot: SteamControllerInputSnapshot, isActiveOverride: Bool? = nil) {
        let activeIDs = SteamControllerHIDMonitor.shared.activeDeviceIDs
        let isActive = isActiveOverride ?? activeIDs.contains(deviceID)
        defer { lastButtons[deviceID] = snapshot.buttons }

        guard isActive else {
            thumbstickRepeatState.removeAll()
            return
        }

        let previous = lastButtons[deviceID] ?? snapshot.buttons
        let newlyPressed = snapshot.buttons.subtracting(previous)
        for button in Self.navigableButtons where newlyPressed.contains(button) {
            guard let command = Self.command(for: button) else { continue }
            emit(command)
        }

        handleThumbstick(deviceID: deviceID, x: snapshot.leftStickX, y: snapshot.leftStickY)
    }

    private func handleThumbstick(deviceID: InputDeviceID, x: Float, y: Float) {
        let horizontal = abs(x) > Self.thumbstickDeadzone ? x : 0
        let vertical = abs(y) > Self.thumbstickDeadzone ? y : 0
        guard horizontal != 0 || vertical != 0 else {
            thumbstickRepeatState.removeAll()
            return
        }
        let isFirstActive = thumbstickRepeatState.isEmpty
        if abs(horizontal) > abs(vertical) {
            emitRepeatedMove(x > 0 ? .right : .left, force: isFirstActive)
        } else {
            emitRepeatedMove(y > 0 ? .up : .down, force: isFirstActive)
        }
        _ = deviceID
    }

    private func emitRepeatedMove(_ direction: ControllerInputDirection, force: Bool) {
        let now = Date()
        if !force, let lastDate = thumbstickRepeatState[direction], now.timeIntervalSince(lastDate) < Self.thumbstickRepeatInterval {
            return
        }
        thumbstickRepeatState[direction] = now
        for otherDirection in thumbstickRepeatState.keys where otherDirection != direction {
            thumbstickRepeatState.removeValue(forKey: otherDirection)
        }
        emit(.move(direction))
    }

    private func emit(_ command: ControllerInputCommand) {
        onCommand?(command)
    }

    static func command(for button: GamepadButtons) -> ControllerInputCommand? {
        switch button {
        case .dpadUp: return .move(.up)
        case .dpadDown: return .move(.down)
        case .dpadLeft: return .move(.left)
        case .dpadRight: return .move(.right)
        case .south: return .confirm
        case .east: return .back
        case .west: return .search
        case .north: return .actions
        case .start: return .menu
        case .select: return .actions
        case .leftShoulder: return .pageLeft
        case .rightShoulder: return .pageRight
        default: return nil
        }
    }

    private static let navigableButtons: [GamepadButtons] = [
        .dpadUp, .dpadDown, .dpadLeft, .dpadRight,
        .south, .east, .west, .north,
        .start, .select,
        .leftShoulder, .rightShoulder,
    ]


    private static func makeGlyphs() -> ControllerInputGlyphSet {
        ControllerInputGlyphSet(
            deviceName: steamControllerDeviceName,
            usesControllerGlyphs: true,
            up: ControllerInputGlyph(symbolName: "dpad.up.fill", fallbackText: "D-Up", accessibilityLabel: "D-pad Up"),
            down: ControllerInputGlyph(symbolName: "dpad.down.fill", fallbackText: "D-Down", accessibilityLabel: "D-pad Down"),
            left: ControllerInputGlyph(symbolName: "dpad.left.fill", fallbackText: "D-Left", accessibilityLabel: "D-pad Left"),
            right: ControllerInputGlyph(symbolName: "dpad.right.fill", fallbackText: "D-Right", accessibilityLabel: "D-pad Right"),
            confirm: ControllerInputGlyph(symbolName: "a.circle.fill", fallbackText: "A", accessibilityLabel: "A button on Steam Controller"),
            back: ControllerInputGlyph(symbolName: "b.circle.fill", fallbackText: "B", accessibilityLabel: "B button on Steam Controller"),
            search: ControllerInputGlyph(symbolName: "x.circle.fill", fallbackText: "X", accessibilityLabel: "X button on Steam Controller"),
            actions: ControllerInputGlyph(symbolName: "y.circle.fill", fallbackText: "Y", accessibilityLabel: "Y button on Steam Controller"),
            menu: ControllerInputGlyph(symbolName: "line.3.horizontal.circle", fallbackText: "Menu", accessibilityLabel: "Menu button on Steam Controller"),
            pageLeft: ControllerInputGlyph(symbolName: "l1.button.roundedbottom.horizontal", fallbackText: "LB", accessibilityLabel: "Left shoulder on Steam Controller"),
            pageRight: ControllerInputGlyph(symbolName: "r1.button.roundedbottom.horizontal", fallbackText: "RB", accessibilityLabel: "Right shoulder on Steam Controller")
        )
    }
}
