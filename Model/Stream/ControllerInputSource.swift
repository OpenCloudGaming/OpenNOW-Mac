import Foundation

/// How one pad's values are actually being read on this Mac.
///
/// This is deliberately a different type from `ControllerInputBackend`, which is only the user's
/// app-wide preference. One session reads several pads through several paths at once — a Steam
/// Controller through its own HID stack, a wired Xbox pad through GameController, a DualSense
/// through the Gamepad API HID reader — so a per-pad decision (the client deadzone) cannot be
/// expressed by the preference, and anything that needs the truth about one pad takes this type.
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

    /// Whether the client must apply its own radial deadzone to this pad's sticks.
    ///
    /// Only the Gamepad API reader hands us the pad's raw report, which is what the player opted
    /// into when they chose it — the deadzone is left to the game. Every other path keeps the
    /// filter, and for two different reasons: Apple's framework values are re-encoded here without
    /// the filter it would have applied, and the Steam Controller applies no deadzone of its own at
    /// all — its report writes raw axis values straight through, so this client deadzone is the
    /// only one its sticks ever get.
    public var appliesClientDeadzone: Bool { self != .gamepadAPI }
}
