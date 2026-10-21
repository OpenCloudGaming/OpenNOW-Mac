//  The note that a store edition without HDR is streaming SDR, and the history that keeps it to
//  once per game: a title somebody plays daily must not repeat it at every launch.

import Foundation

public enum OPNHdrDowngradeNotice {
    /// How many games the history remembers. Oldest first, so the newest is what survives.
    static let maximumRememberedGames = 200

    public static let message = "Streaming in SDR - this store edition has no HDR. Your HDR setting stays on."

    /// Whether this game has already shown the note. A session with no identity to remember never
    /// shows it, because it could not be kept to once.
    public static func hasBeenShown(forGame identity: String) -> Bool {
        guard !identity.isEmpty else { return true }
        return OPNStreamPreferences.loadHdrNoticeShownGames().contains(identity)
    }

    public static func recordShown(forGame identity: String) {
        guard !identity.isEmpty else { return }
        let alreadyShown = OPNStreamPreferences.loadHdrNoticeShownGames().filter { $0 != identity }
        OPNStreamPreferences.saveHdrNoticeShownGames(alreadyShown + [identity])
    }

    /// The newest distinct identities, capped: a hand-edited or older list cannot grow without
    /// bound, repeat an entry, or carry one that is too long to have been written here.
    static func normalized(_ identities: [String]) -> [String] {
        var kept: [String] = []
        for identity in identities.reversed() where !identity.isEmpty && identity.utf8.count <= maximumIdentityBytes {
            guard !kept.contains(identity) else { continue }
            kept.append(identity)
            guard kept.count < maximumRememberedGames else { break }
        }
        return Array(kept.reversed())
    }

    private static let maximumIdentityBytes = 256
}

extension OPNStreamPreferences {
    public static func loadHdrNoticeShownGames() -> [String] {
        let stored = (storage.array(forKey: k.hdrNoticeShownGames) ?? []).compactMap { $0 as? String }
        return OPNHdrDowngradeNotice.normalized(stored)
    }

    public static func saveHdrNoticeShownGames(_ identities: [String]) {
        storage.set(OPNHdrDowngradeNotice.normalized(identities), forKey: k.hdrNoticeShownGames)
        storage.synchronize()
    }
}
