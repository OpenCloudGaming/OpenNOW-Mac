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
    /// The in-stream clipboard history: copy in a stream, read the frame's text on this Mac, and
    /// copy it back out from the HUD. Off by default — whole-frame OCR picks up game-HUD clutter and
    /// Control-C is a common gameplay binding, so the flag is the reader opting into that trade.
    static let clipboardCapture = OPNLabsFlag(
        id: "streamClipboardCapture",
        title: "In-Stream Clipboard History",
        summary: "Command-C or Control-C in a stream reads the current frame's text on this Mac and files it in a clipboard history you can copy from the HUD.",
        since: "0.15"
    )

    /// Every trial in flight. Empty is the normal state, and the Settings rail drops the Labs
    /// destination while it is.
    static let flags: [OPNLabsFlag] = [clipboardCapture]

    /// Whether the in-stream clipboard history is switched on. Read at every point the feature is
    /// offered — the HUD panel, the Settings card, the binding and the capture path itself.
    static var isClipboardCaptureEnabled: Bool { isEnabled(clipboardCapture) }

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
