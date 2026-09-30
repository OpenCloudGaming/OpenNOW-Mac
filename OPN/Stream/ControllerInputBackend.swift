import Foundation

/// The user's app-wide choice of controller reader.
///
/// This is a *preference*, not a description of how any particular pad is read: one session can
/// read several pads through several paths at once. Anything that needs the per-pad truth takes a
/// `ControllerInputSource` instead — see `ControllerInputSource.appliesClientDeadzone`, which is
/// what the wire deadzone decision consults.
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

    public static func load(from storage: OPNAppPreferenceStorage = .standard) -> ControllerInputBackend {
        storage.string(forKey: key).flatMap(ControllerInputBackend.init(rawValue:)) ?? .appleFramework
    }

    public static func save(_ backend: ControllerInputBackend, to storage: OPNAppPreferenceStorage = .standard) {
        storage.set(backend.rawValue, forKey: key)
    }
}

/// One pad as it is actually being read right now: which player slot, what it is, and through which
/// path — the value the HUD shows and the one the deadzone decision is derived from.
public struct ControllerInputPath: Equatable, Sendable {
    public let playerIndex: Int
    public let name: String
    public let source: ControllerInputSource
}
