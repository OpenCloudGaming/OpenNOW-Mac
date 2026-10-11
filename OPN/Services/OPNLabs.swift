//  Features that are switched off, on trial, and not yet anybody's default.
//
//  The registry is deliberately a list rather than a scattering of `UserDefaults` reads: a trial
//  feature has to be findable and switchable in one place, and it has to be able to disappear
//  cleanly once it graduates or dies. An empty registry means the Labs destination does not exist,
//  which is what a permanently empty page taught us to avoid.

import Foundation

struct OPNLabsFlag: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// What the flag actually turns on, and what is unfinished about it. Written for someone
    /// deciding whether to risk it, not for whoever implemented it.
    let summary: String
    /// The release it went on trial in, so a flag nobody promoted is visible as stale.
    let since: String

    var storageKey: String { "OpenNOW.Labs.\(id)" }
}

enum OPNLabs {
    /// The in-stream clipboard history: select text in a stream, copy, and the selection is read on
    /// this Mac and filed for copying back out from the HUD. Off by default — a selection is not
    /// always what Control-C is for in a game, so the flag is the reader opting into that trade.
    static let clipboardCapture = OPNLabsFlag(
        id: "streamClipboardCapture",
        title: "In-Stream Clipboard History",
        summary: "Command-C or Control-C in a stream reads the selected text on this Mac and files it in a clipboard history you can copy from the HUD.",
        since: "0.15"
    )

    /// Couch co-op on one Mac: extra accounts stream in their own windows, each window gets its own
    /// controllers, and the windows tile themselves. Off by default because it changes how the stream
    /// windows are placed and lets pads keep playing while another window has the keyboard focus.
    static let couchCoop = OPNLabsFlag(
        id: "couchCoop",
        title: "Couch Co-op",
        summary: "Adds Stream > Detach New Session, which opens a window for a second or third account. Each window takes its own controllers, plays while another window is in front, and the stream windows tile across your screens.",
        since: "0.15"
    )

    /// Every trial in flight. Empty is the normal state, and the Settings rail drops the Labs
    /// destination while it is.
    static let flags: [OPNLabsFlag] = [clipboardCapture, couchCoop]

    /// Whether the in-stream clipboard history is switched on. Read at every point the feature is
    /// offered — the HUD panel, the Settings card, the binding and the capture path itself.
    static var isClipboardCaptureEnabled: Bool { isEnabled(clipboardCapture) }

    static var isCouchCoopEnabled: Bool { isEnabled(couchCoop) }

    static var hasFlags: Bool { !flags.isEmpty }

    static func isEnabled(_ flag: OPNLabsFlag) -> Bool {
        OPNAppPreferenceStorage.standard.bool(forKey: flag.storageKey)
    }

    static func setEnabled(_ flag: OPNLabsFlag, _ enabled: Bool) {
        OPNAppPreferenceStorage.standard.set(enabled, forKey: flag.storageKey)
        OPNLog.info(.app, "Labs flag \(flag.id) \(enabled ? "enabled" : "disabled")")
    }

    /// Reads a flag by id for code that cannot see the registry entry, returning false for an id
    /// that has been retired. A graduated feature must stop asking rather than linger behind a
    /// switch nobody can find.
    static func isEnabled(id: String) -> Bool {
        guard let flag = flags.first(where: { $0.id == id }) else { return false }
        return isEnabled(flag)
    }
}
