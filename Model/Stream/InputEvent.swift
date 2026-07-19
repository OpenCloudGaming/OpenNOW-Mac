import Foundation

public struct InputDeviceID: Codable, Equatable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}

public enum InputDeviceKind: String, Codable, Equatable, Hashable, Sendable {
    case keyboard
    case mouse
    case gamepad
}

public struct InputDevice: Codable, Equatable, Hashable, Sendable {
    public let id: InputDeviceID
    public let kind: InputDeviceKind
    public let name: String
    public let isDefault: Bool
    public let metadata: [String: String]

    public init(id: InputDeviceID,
                kind: InputDeviceKind,
                name: String,
                isDefault: Bool = false,
                metadata: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.name = name
        self.isDefault = isDefault
        self.metadata = metadata
    }
}

public struct KeyboardModifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let shift = KeyboardModifiers(rawValue: 1 << 0)
    public static let control = KeyboardModifiers(rawValue: 1 << 1)
    public static let option = KeyboardModifiers(rawValue: 1 << 2)
    public static let command = KeyboardModifiers(rawValue: 1 << 3)
    public static let capsLock = KeyboardModifiers(rawValue: 1 << 4)
    public static let numericPad = KeyboardModifiers(rawValue: 1 << 5)
}

public struct KeyboardEvent: Codable, Equatable, Hashable, Sendable {
    public let deviceID: InputDeviceID
    public let keyCode: UInt16
    public let scanCode: UInt16
    public let modifiers: KeyboardModifiers
    public let isPressed: Bool
    public let timestamp: MediaTimestamp

    public init(deviceID: InputDeviceID,
                keyCode: UInt16,
                scanCode: UInt16,
                modifiers: KeyboardModifiers = [],
                isPressed: Bool,
                timestamp: MediaTimestamp) {
        self.deviceID = deviceID
        self.keyCode = keyCode
        self.scanCode = scanCode
        self.modifiers = modifiers
        self.isPressed = isPressed
        self.timestamp = timestamp
    }
}

public enum MouseButton: UInt8, Codable, Equatable, Hashable, Sendable {
    case left = 1
    case right = 2
    case middle = 3
    case back = 4
    case forward = 5
}

public enum MouseEvent: Codable, Equatable, Hashable, Sendable {
    case moved(deviceID: InputDeviceID, deltaX: Int16, deltaY: Int16, timestamp: MediaTimestamp)
    case button(deviceID: InputDeviceID, button: MouseButton, isPressed: Bool, timestamp: MediaTimestamp)
    case wheel(deviceID: InputDeviceID, delta: Int16, timestamp: MediaTimestamp)

    public var deviceID: InputDeviceID {
        switch self {
        case .moved(let deviceID, _, _, _),
             .button(let deviceID, _, _, _),
             .wheel(let deviceID, _, _):
            deviceID
        }
    }

    public var timestamp: MediaTimestamp {
        switch self {
        case .moved(_, _, _, let timestamp),
             .button(_, _, _, let timestamp),
             .wheel(_, _, let timestamp):
            timestamp
        }
    }
}

public struct GamepadButtons: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let rawValue = try? container.decode(UInt32.self) {
            self.init(rawValue: rawValue)
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        self.init(rawValue: try keyed.decode(UInt32.self, forKey: .rawValue))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    public static let south = GamepadButtons(rawValue: 1 << 0)
    public static let east = GamepadButtons(rawValue: 1 << 1)
    public static let west = GamepadButtons(rawValue: 1 << 2)
    public static let north = GamepadButtons(rawValue: 1 << 3)
    public static let leftShoulder = GamepadButtons(rawValue: 1 << 4)
    public static let rightShoulder = GamepadButtons(rawValue: 1 << 5)
    public static let select = GamepadButtons(rawValue: 1 << 6)
    public static let start = GamepadButtons(rawValue: 1 << 7)
    public static let leftStick = GamepadButtons(rawValue: 1 << 8)
    public static let rightStick = GamepadButtons(rawValue: 1 << 9)
    public static let dpadUp = GamepadButtons(rawValue: 1 << 10)
    public static let dpadDown = GamepadButtons(rawValue: 1 << 11)
    public static let dpadLeft = GamepadButtons(rawValue: 1 << 12)
    public static let dpadRight = GamepadButtons(rawValue: 1 << 13)
    public static let leftGrip = GamepadButtons(rawValue: 1 << 14)
    public static let rightGrip = GamepadButtons(rawValue: 1 << 15)
    public static let leftGrip2 = GamepadButtons(rawValue: 1 << 16)
    public static let rightGrip2 = GamepadButtons(rawValue: 1 << 17)
    public static let mode = GamepadButtons(rawValue: 1 << 18)
    public static let quickAccess = GamepadButtons(rawValue: 1 << 19)
}

public struct GamepadState: Codable, Equatable, Hashable, Sendable {
    public let deviceID: InputDeviceID
    public let playerIndex: Int
    public let buttons: GamepadButtons
    public let leftTrigger: Float
    public let rightTrigger: Float
    public let leftStickX: Float
    public let leftStickY: Float
    public let rightStickX: Float
    public let rightStickY: Float
    public let timestamp: MediaTimestamp

    public init(deviceID: InputDeviceID,
                playerIndex: Int,
                buttons: GamepadButtons = [],
                leftTrigger: Float = 0,
                rightTrigger: Float = 0,
                leftStickX: Float = 0,
                leftStickY: Float = 0,
                rightStickX: Float = 0,
                rightStickY: Float = 0,
                timestamp: MediaTimestamp) {
        self.deviceID = deviceID
        self.playerIndex = max(0, playerIndex)
        self.buttons = buttons
        self.leftTrigger = Self.clampUnit(leftTrigger)
        self.rightTrigger = Self.clampUnit(rightTrigger)
        self.leftStickX = Self.clampSignedUnit(leftStickX)
        self.leftStickY = Self.clampSignedUnit(leftStickY)
        self.rightStickX = Self.clampSignedUnit(rightStickX)
        self.rightStickY = Self.clampSignedUnit(rightStickY)
        self.timestamp = timestamp
    }

    private static func clampUnit(_ value: Float) -> Float {
        min(1, max(0, value))
    }

    private static func clampSignedUnit(_ value: Float) -> Float {
        min(1, max(-1, value))
    }
}

public enum UserInputEvent: Codable, Equatable, Hashable, Sendable {
    case keyboard(KeyboardEvent)
    case mouse(MouseEvent)
    case text(deviceID: InputDeviceID, value: String, timestamp: MediaTimestamp)
    case gamepad(GamepadState)

    public var deviceID: InputDeviceID {
        switch self {
        case .keyboard(let event):
            event.deviceID
        case .mouse(let event):
            event.deviceID
        case .text(let deviceID, _, _):
            deviceID
        case .gamepad(let state):
            state.deviceID
        }
    }

    public var timestamp: MediaTimestamp {
        switch self {
        case .keyboard(let event):
            event.timestamp
        case .mouse(let event):
            event.timestamp
        case .text(_, _, let timestamp):
            timestamp
        case .gamepad(let state):
            state.timestamp
        }
    }
}

public protocol InputDeviceProvider: Sendable {
    func availableInputDevices() async throws -> [InputDevice]
    func events(from deviceID: InputDeviceID) async throws -> AsyncStream<UserInputEvent>
}

public protocol InputEventReceiver: Sendable {
    func receive(_ event: UserInputEvent) async
}

public protocol InputEventTransmitter: Sendable {
    func transmit(_ event: UserInputEvent) async throws
}
