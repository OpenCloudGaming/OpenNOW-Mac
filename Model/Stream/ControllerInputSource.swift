import Foundation

/// How one pad's values are actually being read on this Mac, which is not the app-wide preference.
public enum ControllerInputSource: String, CaseIterable, Codable, Equatable, Sendable {
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

    /// Whether the client must apply its own radial deadzone to this pad's sticks. Only the Gamepad
    /// API reader hands us a raw report; the Steam Controller applies no deadzone of its own.
    public var isClientDeadzoneRequired: Bool { self != .gamepadAPI }
}
