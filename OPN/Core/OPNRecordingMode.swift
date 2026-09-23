import Foundation

/// What a stream captures while it runs. The three are mutually exclusive, the way Steam's Game
/// Recording modes are: a manual recording and a rolling replay window are never both on.
public enum OPNRecordingMode: String, CaseIterable, Sendable {
    /// Nothing is captured. The default.
    case off
    /// A rolling window of the most recent minutes, saved on demand. Also carries the manual
    /// record and screenshot actions, so nothing is lost by choosing it.
    case instantReplay = "replay"
    /// Records only between the start and stop actions. No rolling window.
    case manual

    public var label: String {
        switch self {
        case .off: return "Off"
        case .instantReplay: return "Instant Replay"
        case .manual: return "Manual"
        }
    }

    /// The one-line explanation the settings picker shows for the current choice.
    public var subtitle: String {
        switch self {
        case .off:
            return "Nothing is captured while a stream runs."
        case .instantReplay:
            return "Keeps the most recent minutes of every stream on disk, ready to save as a clip. Manual recording and screenshots still work."
        case .manual:
            return "Records only while you are recording. Nothing is kept in the background."
        }
    }
}
