//  MacForceNow
//
//  Created by OpenAI on 7/6/26.
//

import Combine
import Foundation
import GameController

enum ControllerInputDirection: Equatable {
    case up
    case down
    case left
    case right
}

enum ControllerInputCommand: Equatable {
    case move(ControllerInputDirection)
    case confirm
    case back
    case search
    case actions
    case menu
    case pageLeft
    case pageRight
}

struct ControllerInputGlyph: Equatable {
    let symbolName: String
    let fallbackText: String
    let accessibilityLabel: String

    static func keyboard(symbolName: String, fallbackText: String, accessibilityLabel: String) -> ControllerInputGlyph {
        ControllerInputGlyph(symbolName: symbolName, fallbackText: fallbackText, accessibilityLabel: accessibilityLabel)
    }
}

struct ControllerInputGlyphSet: Equatable {
    let deviceName: String
    let usesControllerGlyphs: Bool
    let up: ControllerInputGlyph
    let down: ControllerInputGlyph
    let left: ControllerInputGlyph
    let right: ControllerInputGlyph
    let confirm: ControllerInputGlyph
    let back: ControllerInputGlyph
    let search: ControllerInputGlyph
    let actions: ControllerInputGlyph
    let menu: ControllerInputGlyph
    let pageLeft: ControllerInputGlyph
    let pageRight: ControllerInputGlyph

    static let keyboard = ControllerInputGlyphSet(
        deviceName: "Keyboard",
        usesControllerGlyphs: false,
        up: .keyboard(symbolName: "arrow.up", fallbackText: "↑", accessibilityLabel: "Up Arrow"),
        down: .keyboard(symbolName: "arrow.down", fallbackText: "↓", accessibilityLabel: "Down Arrow"),
        left: .keyboard(symbolName: "arrow.left", fallbackText: "←", accessibilityLabel: "Left Arrow"),
        right: .keyboard(symbolName: "arrow.right", fallbackText: "→", accessibilityLabel: "Right Arrow"),
        confirm: .keyboard(symbolName: "return", fallbackText: "Return", accessibilityLabel: "Return"),
        back: .keyboard(symbolName: "escape", fallbackText: "Esc", accessibilityLabel: "Escape"),
        search: .keyboard(symbolName: "magnifyingglass", fallbackText: "F", accessibilityLabel: "F key"),
        actions: .keyboard(symbolName: "line.3.horizontal", fallbackText: "M", accessibilityLabel: "M key"),
        menu: .keyboard(symbolName: "sidebar.left", fallbackText: "Tab", accessibilityLabel: "Tab"),
        pageLeft: .keyboard(symbolName: "chevron.left", fallbackText: "[", accessibilityLabel: "Left Bracket"),
        pageRight: .keyboard(symbolName: "chevron.right", fallbackText: "]", accessibilityLabel: "Right Bracket")
    )
}

@MainActor
final class ControllerInputRouter: NSObject, ObservableObject {
    @Published private(set) var glyphs = ControllerInputGlyphSet.keyboard
    @Published private(set) var isControllerConnected = false

    var onCommand: ((ControllerInputCommand) -> Void)?

    private var activeController: GCController?
    private var thumbstickRepeatState: [ControllerInputDirection: Date] = [:]
    private let thumbstickRepeatInterval: TimeInterval = 0.18
    private let thumbstickDeadzone: Float = 0.45

    override init() {
        super.init()
        installNotifications()
        refreshControllers()
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        GCController.stopWirelessControllerDiscovery()
        Self.clearHandlersForConnectedControllers()
    }

    func sendKeyboardCommand(_ command: ControllerInputCommand) {
        glyphs = .keyboard
        onCommand?(command)
    }

    private func installNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(controllerDidConnectNotification(_:)), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerDidDisconnectNotification(_:)), name: .GCControllerDidDisconnect, object: nil)
    }

    @objc private func controllerDidConnectNotification(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        controllerDidConnect(controller)
    }

    @objc private func controllerDidDisconnectNotification(_ notification: Notification) {
        refreshControllers()
    }

    private func controllerDidConnect(_ controller: GCController) {
        activeController = controller
        configureHandlers(for: controller)
        refreshGlyphs()
    }

    private func refreshControllers() {
        Self.clearHandlersForConnectedControllers()
        let controllers = GCController.controllers()
        isControllerConnected = !controllers.isEmpty
        activeController = controllers.first
        for controller in controllers {
            configureHandlers(for: controller)
        }
        refreshGlyphs()
    }

    nonisolated private static func clearHandlersForConnectedControllers() {
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
            controller.extendedGamepad?.dpad.valueChangedHandler = nil
            controller.extendedGamepad?.leftThumbstick.valueChangedHandler = nil
            controller.microGamepad?.valueChangedHandler = nil
            controller.microGamepad?.dpad.valueChangedHandler = nil
        }
    }

    private func configureHandlers(for controller: GCController) {
        if let gamepad = controller.extendedGamepad {
            configureButton(gamepad.buttonA, command: .confirm, controller: controller)
            configureButton(gamepad.buttonB, command: .back, controller: controller)
            configureButton(gamepad.buttonX, command: .search, controller: controller)
            configureButton(gamepad.buttonY, command: .actions, controller: controller)
            configureButton(gamepad.buttonMenu, command: .menu, controller: controller)
            configureButton(gamepad.buttonOptions, command: .actions, controller: controller)
            configureButton(gamepad.leftShoulder, command: .pageLeft, controller: controller)
            configureButton(gamepad.rightShoulder, command: .pageRight, controller: controller)
            configureDirectionalButtons(gamepad.dpad, controller: controller)
            configureThumbstick(gamepad.leftThumbstick, controller: controller)
            return
        }

        if let gamepad = controller.microGamepad {
            configureButton(gamepad.buttonA, command: .confirm, controller: controller)
            configureButton(gamepad.buttonX, command: .back, controller: controller)
            configureButton(gamepad.buttonMenu, command: .menu, controller: controller)
            configureDirectionalButtons(gamepad.dpad, controller: controller)
        }
    }

    private func configureButton(_ button: GCControllerButtonInput?, command: ControllerInputCommand, controller: GCController) {
        guard let button else { return }
        button.pressedChangedHandler = { [weak self, weak controller] _, _, pressed in
            guard pressed, let controller else { return }
            Task { @MainActor in self?.emit(command, controller: controller) }
        }
    }

    private func configureDirectionalButtons(_ dpad: GCControllerDirectionPad, controller: GCController) {
        configureButton(dpad.up, command: .move(.up), controller: controller)
        configureButton(dpad.down, command: .move(.down), controller: controller)
        configureButton(dpad.left, command: .move(.left), controller: controller)
        configureButton(dpad.right, command: .move(.right), controller: controller)
    }

    private func configureThumbstick(_ thumbstick: GCControllerDirectionPad, controller: GCController) {
        thumbstick.valueChangedHandler = { [weak self, weak controller] _, xValue, yValue in
            guard let controller else { return }
            Task { @MainActor in self?.handleThumbstick(xValue: xValue, yValue: yValue, controller: controller) }
        }
    }

    private func handleThumbstick(xValue: Float, yValue: Float, controller: GCController) {
        let horizontal = abs(xValue) > thumbstickDeadzone ? xValue : 0
        let vertical = abs(yValue) > thumbstickDeadzone ? yValue : 0
        guard horizontal != 0 || vertical != 0 else {
            thumbstickRepeatState.removeAll()
            return
        }

        if abs(horizontal) > abs(vertical) {
            emitRepeatedMove(horizontal > 0 ? .right : .left, controller: controller)
        } else {
            emitRepeatedMove(vertical > 0 ? .up : .down, controller: controller)
        }
    }

    private func emitRepeatedMove(_ direction: ControllerInputDirection, controller: GCController) {
        let now = Date()
        if let lastDate = thumbstickRepeatState[direction], now.timeIntervalSince(lastDate) < thumbstickRepeatInterval { return }
        thumbstickRepeatState[direction] = now
        emit(.move(direction), controller: controller)
    }

    private func emit(_ command: ControllerInputCommand, controller: GCController) {
        activeController = controller
        refreshGlyphs()
        onCommand?(command)
    }

    private func refreshGlyphs() {
        guard let controller = activeController else {
            isControllerConnected = false
            glyphs = .keyboard
            return
        }
        isControllerConnected = true
        glyphs = makeGlyphSet(for: controller)
    }

    private func makeGlyphSet(for controller: GCController) -> ControllerInputGlyphSet {
        let deviceName = controller.vendorName ?? "Controller"
        if let gamepad = controller.extendedGamepad {
            return ControllerInputGlyphSet(
                deviceName: deviceName,
                usesControllerGlyphs: true,
                up: glyph(for: gamepad.dpad.up, fallbackSymbol: "dpad.up.fill", fallbackText: "D-Up", accessibilityLabel: "D-pad Up"),
                down: glyph(for: gamepad.dpad.down, fallbackSymbol: "dpad.down.fill", fallbackText: "D-Down", accessibilityLabel: "D-pad Down"),
                left: glyph(for: gamepad.dpad.left, fallbackSymbol: "dpad.left.fill", fallbackText: "D-Left", accessibilityLabel: "D-pad Left"),
                right: glyph(for: gamepad.dpad.right, fallbackSymbol: "dpad.right.fill", fallbackText: "D-Right", accessibilityLabel: "D-pad Right"),
                confirm: glyph(for: gamepad.buttonA, fallbackSymbol: fallbackFaceSymbol(deviceName: deviceName, button: "A"), fallbackText: fallbackFaceText(deviceName: deviceName, button: "A"), accessibilityLabel: gamepad.buttonA.localizedName ?? "Primary button"),
                back: glyph(for: gamepad.buttonB, fallbackSymbol: fallbackFaceSymbol(deviceName: deviceName, button: "B"), fallbackText: fallbackFaceText(deviceName: deviceName, button: "B"), accessibilityLabel: gamepad.buttonB.localizedName ?? "Back button"),
                search: glyph(for: gamepad.buttonX, fallbackSymbol: fallbackFaceSymbol(deviceName: deviceName, button: "X"), fallbackText: fallbackFaceText(deviceName: deviceName, button: "X"), accessibilityLabel: gamepad.buttonX.localizedName ?? "Search button"),
                actions: glyph(for: gamepad.buttonY, fallbackSymbol: fallbackFaceSymbol(deviceName: deviceName, button: "Y"), fallbackText: fallbackFaceText(deviceName: deviceName, button: "Y"), accessibilityLabel: gamepad.buttonY.localizedName ?? "Actions button"),
                menu: glyph(for: gamepad.buttonMenu, fallbackSymbol: "line.3.horizontal.circle", fallbackText: "Menu", accessibilityLabel: gamepad.buttonMenu.localizedName ?? "Menu button"),
                pageLeft: glyph(for: gamepad.leftShoulder, fallbackSymbol: "l1.button.roundedbottom.horizontal", fallbackText: "LB", accessibilityLabel: gamepad.leftShoulder.localizedName ?? "Left shoulder"),
                pageRight: glyph(for: gamepad.rightShoulder, fallbackSymbol: "r1.button.roundedbottom.horizontal", fallbackText: "RB", accessibilityLabel: gamepad.rightShoulder.localizedName ?? "Right shoulder")
            )
        }

        if let gamepad = controller.microGamepad {
            return ControllerInputGlyphSet(
                deviceName: deviceName,
                usesControllerGlyphs: true,
                up: glyph(for: gamepad.dpad.up, fallbackSymbol: "dpad.up.fill", fallbackText: "D-Up", accessibilityLabel: "D-pad Up"),
                down: glyph(for: gamepad.dpad.down, fallbackSymbol: "dpad.down.fill", fallbackText: "D-Down", accessibilityLabel: "D-pad Down"),
                left: glyph(for: gamepad.dpad.left, fallbackSymbol: "dpad.left.fill", fallbackText: "D-Left", accessibilityLabel: "D-pad Left"),
                right: glyph(for: gamepad.dpad.right, fallbackSymbol: "dpad.right.fill", fallbackText: "D-Right", accessibilityLabel: "D-pad Right"),
                confirm: glyph(for: gamepad.buttonA, fallbackSymbol: fallbackFaceSymbol(deviceName: deviceName, button: "A"), fallbackText: fallbackFaceText(deviceName: deviceName, button: "A"), accessibilityLabel: gamepad.buttonA.localizedName ?? "Primary button"),
                back: glyph(for: gamepad.buttonX, fallbackSymbol: fallbackFaceSymbol(deviceName: deviceName, button: "B"), fallbackText: fallbackFaceText(deviceName: deviceName, button: "B"), accessibilityLabel: gamepad.buttonX.localizedName ?? "Back button"),
                search: ControllerInputGlyph(symbolName: "magnifyingglass", fallbackText: "Search", accessibilityLabel: "Search"),
                actions: ControllerInputGlyph(symbolName: "line.3.horizontal", fallbackText: "Actions", accessibilityLabel: "Actions"),
                menu: glyph(for: gamepad.buttonMenu, fallbackSymbol: "line.3.horizontal.circle", fallbackText: "Menu", accessibilityLabel: gamepad.buttonMenu.localizedName ?? "Menu button"),
                pageLeft: ControllerInputGlyph(symbolName: "chevron.left", fallbackText: "Prev", accessibilityLabel: "Previous rail"),
                pageRight: ControllerInputGlyph(symbolName: "chevron.right", fallbackText: "Next", accessibilityLabel: "Next rail")
            )
        }

        return .keyboard
    }

    private func glyph(for element: GCControllerElement?, fallbackSymbol: String, fallbackText: String, accessibilityLabel: String) -> ControllerInputGlyph {
        let symbolName = element?.sfSymbolsName ?? element?.unmappedSfSymbolsName ?? fallbackSymbol
        let text = element?.localizedName ?? fallbackText
        return ControllerInputGlyph(symbolName: symbolName, fallbackText: text, accessibilityLabel: accessibilityLabel)
    }

    private func fallbackFaceSymbol(deviceName: String, button: String) -> String {
        let normalized = deviceName.lowercased()
        if normalized.contains("playstation") || normalized.contains("dualshock") || normalized.contains("dualsense") {
            switch button {
            case "A": return "xmark.circle.fill"
            case "B": return "circle.circle.fill"
            case "X": return "square.fill"
            case "Y": return "triangle.fill"
            default: return "circle"
            }
        }
        return "\(button.lowercased()).circle.fill"
    }

    private func fallbackFaceText(deviceName: String, button: String) -> String {
        let normalized = deviceName.lowercased()
        if normalized.contains("playstation") || normalized.contains("dualshock") || normalized.contains("dualsense") {
            switch button {
            case "A": return "Cross"
            case "B": return "Circle"
            case "X": return "Square"
            case "Y": return "Triangle"
            default: return button
            }
        }
        if normalized.contains("nintendo") || normalized.contains("joy-con") || normalized.contains("switch") {
            switch button {
            case "A": return "B"
            case "B": return "A"
            case "X": return "Y"
            case "Y": return "X"
            default: return button
            }
        }
        return button
    }
}
