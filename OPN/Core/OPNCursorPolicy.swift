import Foundation

/// Whose pointer the player sees while a stream is in absolute-cursor mode.
///
/// The seat can composite its own cursor into the encoded video, and macOS draws one of its own on
/// top of the window; when both happen at once the player sees two. Raw values are persisted and
/// carried across the stream transport, so they must stay stable. Append new cases rather than
/// renumbering.
@objc public enum OPNCursorPolicy: Int, CaseIterable, Sendable {
    /// Follow the seat: hide the Mac's pointer while the stream is drawing one of its own.
    case auto = 0
    /// Always draw the Mac's pointer, whatever the stream publishes.
    case local = 1
    /// Never draw the Mac's pointer over the video; the game's own cursor is the only one.
    case stream = 2

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .local: return "Local"
        case .stream: return "Stream"
        }
    }

    public static func from(_ rawValue: Int) -> OPNCursorPolicy {
        OPNCursorPolicy(rawValue: rawValue) ?? .auto
    }
}
