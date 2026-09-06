//  Features that are switched off, on trial, and not yet anybody's default.
//
//  The registry is deliberately a list rather than a scattering of `UserDefaults` reads: a trial
//  feature has to be findable and switchable in one place, and it has to be able to disappear
//  cleanly once it graduates or dies. An empty registry means the Labs destination does not exist,
//  which is what a permanently empty page taught us to avoid.

import Foundation

struct OpenNOWLabsFlag: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// What the flag actually turns on, and what is unfinished about it. Written for someone
    /// deciding whether to risk it, not for whoever implemented it.
    let summary: String
    /// The release it went on trial in, so a flag nobody promoted is visible as stale.
    let since: String

    var storageKey: String { "OpenNOW.Labs.\(id)" }
}

@MainActor
enum OpenNOWLabs {
    /// Every trial in flight. Empty is the normal state, and the Settings rail drops the Labs
    /// destination while it is.
    static let flags: [OpenNOWLabsFlag] = []

    static var hasFlags: Bool { !flags.isEmpty }

    static func isEnabled(_ flag: OpenNOWLabsFlag) -> Bool {
        OPNAppPreferenceStorage.standard.bool(forKey: flag.storageKey)
    }

    static func setEnabled(_ flag: OpenNOWLabsFlag, _ enabled: Bool) {
        OPNAppPreferenceStorage.standard.set(enabled, forKey: flag.storageKey)
        OpenNOWLog.info(.app, "Labs flag \(flag.id) \(enabled ? "enabled" : "disabled")")
    }

    /// Reads a flag by id for code that cannot see the registry entry, returning false for an id
    /// that has been retired. A graduated feature must stop asking rather than linger behind a
    /// switch nobody can find.
    static func isEnabled(id: String) -> Bool {
        guard let flag = flags.first(where: { $0.id == id }) else { return false }
        return isEnabled(flag)
    }
}
