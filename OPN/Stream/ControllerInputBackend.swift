import Foundation

/// The user's app-wide choice of controller reader, which is not how any particular pad is read.
/// The per-pad truth is `ControllerInputSource`, and that is what the wire deadzone consults.
public enum ControllerInputBackend: String, CaseIterable, Sendable {
    case appleFramework
    case gamepadAPI

    public var label: String {
        switch self {
        case .appleFramework: "Apple Framework"
        case .gamepadAPI: "Gamepad API"
        }
    }

    public var toggled: ControllerInputBackend {
        switch self {
        case .appleFramework: .gamepadAPI
        case .gamepadAPI: .appleFramework
        }
    }
}

public enum ControllerInputBackendPreference {
    public static let key = "OpenNOW.Controller.InputBackend"

    public static func load(from storage: OPNAppPreferenceStorage = .standard) -> ControllerInputBackend {
        storage.string(forKey: key).flatMap(ControllerInputBackend.init(rawValue:)) ?? .appleFramework
    }

    public static func save(_ backend: ControllerInputBackend, to storage: OPNAppPreferenceStorage = .standard) {
        storage.set(backend.rawValue, forKey: key)
    }
}

/// One pad as it is read right now: its player slot, what it is, and through which path.
public struct ControllerInputPath: Equatable, Sendable {
    public let playerIndex: Int
    public let name: String
    public let source: ControllerInputSource
}
