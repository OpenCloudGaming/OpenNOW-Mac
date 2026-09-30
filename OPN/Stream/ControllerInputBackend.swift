import Foundation

public enum ControllerInputBackend: String, CaseIterable, Sendable {
    case appleFramework
    case gamepadAPI

    public var label: String {
        switch self {
        case .appleFramework: "Apple Framework"
        case .gamepadAPI: "Gamepad API"
        }
    }
}

public enum ControllerInputBackendPreference {
    public static let key = "OpenNOW.Controller.InputBackend"

    public static func load() -> ControllerInputBackend {
        OPNAppPreferenceStorage.standard.string(forKey: key).flatMap(ControllerInputBackend.init(rawValue:)) ?? .appleFramework
    }

    public static func save(_ backend: ControllerInputBackend) {
        OPNAppPreferenceStorage.standard.set(backend.rawValue, forKey: key)
    }
}

public struct ControllerInputPath: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case appleFramework
        case gamepadAPI
        case steamHID

        public var label: String {
            switch self {
            case .appleFramework: "Apple Framework"
            case .gamepadAPI: "Gamepad API"
            case .steamHID: "Steam HID"
            }
        }
    }

    public let playerIndex: Int
    public let name: String
    public let source: Source
}
