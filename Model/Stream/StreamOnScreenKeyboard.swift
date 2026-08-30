import Foundation

/// A single key on the stream on-screen keyboard. Characters are delivered to the
/// remote session as UTF-8 text events; control keys become macOS keycode press/release
/// pairs, matching the physical keyboard passthrough convention.
public enum StreamOSKKey: Equatable, Sendable {
    case character(String)
    case space
    case backspace
    case enter
    case shift
    case symbols
    case position
    case dismiss
}

public enum StreamOSKPosition: Equatable, Sendable {
    case bottom
    case top

    public mutating func toggle() {
        self = self == .bottom ? .top : .bottom
    }
}

/// What activating a key produced. The host turns outputs into `UserInputEvent`s for
/// whichever transport is active (WebRTC data channel or native NVST).
public enum StreamOSKOutput: Equatable, Sendable {
    case text(String)
    case keyPress(UInt16)
}

public enum StreamOSKEffect: Equatable, Sendable {
    case output(StreamOSKOutput)
    case dismiss
    case none
}

/// Grid geometry and key tables. The grid is 10 columns × 4 rows, split down the
/// middle so each Steam Controller/Deck trackpad owns one half (left pad columns
/// 0–4, right pad columns 5–9), like SteamOS. A bottom bar with layer toggle, space,
/// and dismiss sits below the grid and is reachable by the grid cursor and mouse.
public enum StreamOSKLayout {
    public static let columnCount = 10
    public static let columnsPerHalf = 5
    public static let rowCount = 4
    public static let barRowIndex = 4

    public static let letterRows: [[StreamOSKKey]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"].map(StreamOSKKey.character),
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"].map(StreamOSKKey.character),
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"].map(StreamOSKKey.character) + [.backspace],
        [.shift] + ["z", "x", "c", "v", "b", "n", "m", "."].map(StreamOSKKey.character) + [.enter],
    ]

    public static let symbolRows: [[StreamOSKKey]] = [
        ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")"].map(StreamOSKKey.character),
        ["`", "~", "'", "\"", "-", "_", "+", "=", ":", ";"].map(StreamOSKKey.character),
        ["[", "{", "<", "/", "?", "\\", ">", "}", "]"].map(StreamOSKKey.character) + [.backspace],
        [.shift] + ["§", "°", "…", "·", "€", "£", "¥", "¢"].map(StreamOSKKey.character) + [.enter],
    ]

    public static let barItems: [StreamOSKKey] = [.symbols, .space, .position, .dismiss]

    public static func rows(for layer: StreamOSKState.Layer) -> [[StreamOSKKey]] {
        layer == .letters ? letterRows : symbolRows
    }

    public static func key(row: Int, column: Int, layer: StreamOSKState.Layer) -> StreamOSKKey? {
        let rows = rows(for: layer)
        guard row >= 0, row < rows.count, column >= 0, column < rows[row].count else { return nil }
        return rows[row][column]
    }

    /// macOS virtual keycodes, matching what `NativeWebRTCStreamView` forwards for
    /// physical keyboard events.
    public static let backspaceKeyCode: UInt16 = 51
    public static let enterKeyCode: UInt16 = 36

    public static func label(for key: StreamOSKKey, shiftLatched: Bool, layer: StreamOSKState.Layer) -> String {
        switch key {
        case .character(let value):
            shiftLatched && layer == .letters ? value.uppercased() : value
        case .space: "space"
        case .backspace: "delete.left"
        case .enter: "return"
        case .shift: "shift"
        case .symbols: layer == .letters ? "number" : "abc"
        case .position: "arrow.up.and.down"
        case .dismiss: "checkmark"
        }
    }

    public static func labelIsSymbol(_ key: StreamOSKKey) -> Bool {
        switch key {
        case .character, .space: false
        case .backspace, .enter, .shift, .symbols, .position, .dismiss: true
        }
    }
}

public struct StreamOSKCursor: Equatable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// Pure keyboard state: cursors, shift latch, active layer, and a short echo of
/// recently typed text (the remote field content is unknowable, so the echo gives
/// the user local feedback despite stream latency). All mutation goes through
/// methods returning `StreamOSKEffect`, which keeps the type trivially testable.
public struct StreamOSKState: Equatable, Sendable {
    public enum Layer: Equatable, Sendable {
        case letters
        case symbols
    }

    public enum PadSide: Equatable, Sendable {
        case left
        case right
    }

    public static let echoLimit = 42

    public private(set) var layer: Layer = .letters
    public private(set) var position: StreamOSKPosition = .bottom
    public private(set) var shiftLatched = false
    public private(set) var leftPadCursor: StreamOSKCursor?
    public private(set) var rightPadCursor: StreamOSKCursor?
    public private(set) var gridCursor = StreamOSKCursor(row: 1, column: 0)
    public private(set) var gridCursorInBar = false
    public private(set) var barIndex = 0
    public private(set) var echo = ""
    private var gridCursorBeforeBar = StreamOSKCursor(row: 1, column: 0)

    public init() {}

    public mutating func reset() {
        self = StreamOSKState()
    }

    /// Trackpad coordinates arrive normalized to [-1, 1] with +y up. The pad maps
    /// absolutely onto its half of the grid; the cursor persists after the finger
    /// lifts so a following trigger pull still types the aimed key.
    public mutating func updatePadCursor(_ side: PadSide, x: Float, y: Float) {
        let normalizedX = min(1, max(0, (x + 1) / 2))
        let normalizedY = min(1, max(0, (y + 1) / 2))
        let halfColumn = min(StreamOSKLayout.columnsPerHalf - 1, Int(normalizedX * Float(StreamOSKLayout.columnsPerHalf)))
        let row = min(StreamOSKLayout.rowCount - 1, max(0, StreamOSKLayout.rowCount - 1 - Int(normalizedY * Float(StreamOSKLayout.rowCount))))
        let column = side == .left ? halfColumn : halfColumn + StreamOSKLayout.columnsPerHalf
        switch side {
        case .left: leftPadCursor = StreamOSKCursor(row: row, column: column)
        case .right: rightPadCursor = StreamOSKCursor(row: row, column: column)
        }
    }

    public mutating func clearPadCursor(_ side: PadSide) {
        switch side {
        case .left: leftPadCursor = nil
        case .right: rightPadCursor = nil
        }
    }

    public mutating func activatePadCursor(_ side: PadSide) -> StreamOSKEffect {
        let cursor = side == .left ? leftPadCursor : rightPadCursor
        guard let cursor, let key = StreamOSKLayout.key(row: cursor.row, column: cursor.column, layer: layer) else { return .none }
        return activateKey(key)
    }

    public mutating func moveGridCursor(dx: Int, dy: Int) {
        if gridCursorInBar {
            if dy < 0 {
                gridCursorInBar = false
                gridCursor = gridCursorBeforeBar
            } else {
                barIndex = min(StreamOSKLayout.barItems.count - 1, max(0, barIndex + dx))
            }
            return
        }
        let column = min(StreamOSKLayout.columnCount - 1, max(0, gridCursor.column + dx))
        if dy > 0, gridCursor.row + dy >= StreamOSKLayout.rowCount {
            gridCursorBeforeBar = StreamOSKCursor(row: gridCursor.row, column: column)
            gridCursorInBar = true
            barIndex = min(StreamOSKLayout.barItems.count - 1, column * StreamOSKLayout.barItems.count / StreamOSKLayout.columnCount)
            return
        }
        let row = min(StreamOSKLayout.rowCount - 1, max(0, gridCursor.row + dy))
        gridCursor = StreamOSKCursor(row: row, column: min(column, StreamOSKLayout.rows(for: layer)[row].count - 1))
    }

    public mutating func activateGridCursor() -> StreamOSKEffect {
        if gridCursorInBar {
            return activateKey(StreamOSKLayout.barItems[barIndex])
        }
        guard let key = StreamOSKLayout.key(row: gridCursor.row, column: gridCursor.column, layer: layer) else { return .none }
        return activateKey(key)
    }

    /// Mouse activation: moves the grid cursor so a following gamepad confirm repeats
    /// the clicked key, then activates it.
    public mutating func activateGridKey(row: Int, column: Int) -> StreamOSKEffect {
        guard let key = StreamOSKLayout.key(row: row, column: column, layer: layer) else { return .none }
        gridCursorInBar = false
        gridCursor = StreamOSKCursor(row: row, column: column)
        return activateKey(key)
    }

    public mutating func activateBarItem(_ index: Int) -> StreamOSKEffect {
        guard index >= 0, index < StreamOSKLayout.barItems.count else { return .none }
        gridCursorInBar = true
        barIndex = index
        return activateKey(StreamOSKLayout.barItems[index])
    }

    public mutating func activateKey(_ key: StreamOSKKey) -> StreamOSKEffect {
        switch key {
        case .character(let value):
            let output = shiftLatched && layer == .letters ? value.uppercased() : value
            shiftLatched = false
            appendEcho(output)
            return .output(.text(output))
        case .space:
            shiftLatched = false
            appendEcho(" ")
            return .output(.text(" "))
        case .backspace:
            if !echo.isEmpty { echo.removeLast() }
            return .output(.keyPress(StreamOSKLayout.backspaceKeyCode))
        case .enter:
            echo.removeAll()
            return .output(.keyPress(StreamOSKLayout.enterKeyCode))
        case .shift:
            shiftLatched.toggle()
            return .none
        case .symbols:
            layer = layer == .letters ? .symbols : .letters
            shiftLatched = false
            clampGridCursor()
            return .none
        case .position:
            position.toggle()
            return .none
        case .dismiss:
            return .dismiss
        }
    }

    private mutating func appendEcho(_ text: String) {
        echo.append(text)
        if echo.count > Self.echoLimit {
            echo.removeFirst(echo.count - Self.echoLimit)
        }
    }

    private mutating func clampGridCursor() {
        let rows = StreamOSKLayout.rows(for: layer)
        gridCursor.row = min(gridCursor.row, rows.count - 1)
        gridCursor.column = min(gridCursor.column, rows[gridCursor.row].count - 1)
    }
}

/// Gamepad actions the keyboard understands. Fed from both the raw Steam Controller
/// snapshot path (while the keyboard captures the device) and the regular
/// `GamepadState` path (all other controllers).
public enum StreamOSKNavAction: Equatable, Sendable {
    case move(dx: Int, dy: Int)
    case activate
    case backspace
    case space
    case shift
    case enter
    case dismiss
}

/// Turns button/stick state into edge-triggered keyboard actions: d-pad and left
/// stick move the grid cursor, south activates, east is backspace, west is space,
/// north toggles shift, start is enter, select dismisses. Edges only — no
/// auto-repeat while held.
public struct StreamOSKGamepadNavigator: Sendable {
    private static let stickThreshold: Float = 0.6

    private var lastButtons: [InputDeviceID: GamepadButtons] = [:]
    private var lastStickStep: [InputDeviceID: StreamOSKCursor] = [:]

    public init() {}

    public mutating func reset() {
        lastButtons.removeAll()
        lastStickStep.removeAll()
    }

    public mutating func removeDevice(_ deviceID: InputDeviceID) {
        lastButtons.removeValue(forKey: deviceID)
        lastStickStep.removeValue(forKey: deviceID)
    }

    public mutating func action(deviceID: InputDeviceID, buttons: GamepadButtons, leftStickX: Float, leftStickY: Float) -> StreamOSKNavAction? {
        let previous = lastButtons[deviceID] ?? []
        lastButtons[deviceID] = buttons
        let pressed = buttons.subtracting(previous)

        let stickDX = leftStickX > Self.stickThreshold ? 1 : (leftStickX < -Self.stickThreshold ? -1 : 0)
        let stickDY = leftStickY < -Self.stickThreshold ? 1 : (leftStickY > Self.stickThreshold ? -1 : 0)
        let previousStep = lastStickStep[deviceID] ?? StreamOSKCursor(row: 0, column: 0)
        lastStickStep[deviceID] = StreamOSKCursor(row: stickDY, column: stickDX)

        let dpadDX = (pressed.contains(.dpadRight) ? 1 : 0) - (pressed.contains(.dpadLeft) ? 1 : 0)
        let dpadDY = (pressed.contains(.dpadDown) ? 1 : 0) - (pressed.contains(.dpadUp) ? 1 : 0)
        if dpadDX != 0 || dpadDY != 0 { return .move(dx: dpadDX, dy: dpadDY) }

        let edgeDX = stickDX != 0 && previousStep.column == 0 ? stickDX : 0
        let edgeDY = stickDY != 0 && previousStep.row == 0 ? stickDY : 0
        if edgeDX != 0 || edgeDY != 0 { return .move(dx: edgeDX, dy: edgeDY) }

        if pressed.contains(.south) { return .activate }
        if pressed.contains(.east) { return .backspace }
        if pressed.contains(.west) { return .space }
        if pressed.contains(.north) { return .shift }
        if pressed.contains(.start) { return .enter }
        if pressed.contains(.select) { return .dismiss }
        return nil
    }
}

public enum StreamOSKChordCommand: Equatable, Sendable {
    case toggleUnifiedHUD
    case toggleOnScreenKeyboard
}

/// Steam Deck-style chord detection. The `...` quick-access button toggles the
/// unified HUD on press and never reaches the stream. The actual Steam button
/// (`mode` — `0x0001_0000` on Triton, bit 13 in Deck state, `0x20` on legacy) is
/// the chord modifier: Steam + X toggles the on-screen keyboard and consumes the
/// X so it never reaches the game. Steam alone keeps its existing role as the
/// local-cursor modifier, so it is never stripped and its release fires no
/// command. The tracker must see every report from a device — including while
/// the keyboard captures that device — which is why it lives in the gamepad
/// monitor, ahead of both the binding engine and the capture split.
public struct StreamOSKChordTracker: Sendable {
    public struct Result: Equatable, Sendable {
        public var buttons: GamepadButtons
        public var command: StreamOSKChordCommand?
    }

    struct DeviceState: Equatable, Sendable {
        var quickAccessHeld = false
        var steamHeld = false
        var westHeld = false
        var westConsumed = false
    }

    var devices: [InputDeviceID: DeviceState] = [:]

    public init() {}

    public mutating func reset() {
        devices.removeAll()
    }

    public mutating func removeDevice(_ deviceID: InputDeviceID) {
        devices.removeValue(forKey: deviceID)
    }

    public mutating func process(buttons: GamepadButtons, deviceID: InputDeviceID) -> Result {
        var state = devices[deviceID] ?? DeviceState()
        let quickAccess = buttons.contains(.quickAccess)
        let steam = buttons.contains(.mode)
        let west = buttons.contains(.west)
        var command: StreamOSKChordCommand?
        var stripped = buttons.subtracting(.quickAccess)

        if quickAccess, !state.quickAccessHeld { command = .toggleUnifiedHUD }
        state.quickAccessHeld = quickAccess

        if steam, !state.steamHeld {
            state.steamHeld = true
            state.westConsumed = false
            state.westHeld = west
        } else if steam {
            if west, !state.westHeld {
                command = .toggleOnScreenKeyboard
                state.westConsumed = true
            }
            if !west { state.westConsumed = false }
            state.westHeld = west
            if state.westConsumed { stripped.remove(.west) }
        } else if state.steamHeld {
            state.steamHeld = false
            state.westHeld = false
            state.westConsumed = false
        }

        devices[deviceID] = state
        return Result(buttons: stripped, command: command)
    }
}
