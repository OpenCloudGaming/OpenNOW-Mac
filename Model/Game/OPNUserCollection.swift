//  A user-defined group of catalog games. Unlike My Library and My Favorites, a user collection
//  exists only on this Mac: nothing is sent to NVIDIA and the reader keeps their own backup.

import Foundation

/// One locally-owned collection of catalog games. Membership is stored as `catalogIdentity`
/// strings, so it matches how favorites and recently-played already identify games.
public struct OPNUserCollection: Codable, Equatable, Sendable, Identifiable {
    /// The most collections one account may keep. Deliberately small: each collection contributes a
    /// home rail and a settings row, and a very long list is both unwieldy and a rendering cost.
    public static let maximumCount = 20
    /// The most games one collection may hold.
    public static let maximumGameCount = 10_000
    /// The most characters allowed in a collection id or a member's game identity.
    public static let maximumIdentifierLength = 128
    /// The name bounds, measured after trimming whitespace.
    public static let minimumNameLength = 1
    public static let maximumNameLength = 80

    public let id: String
    public let name: String
    public let gameIds: [String]
    /// The glyph this collection draws. Nil means the catalog's default, which keeps an old payload
    /// that predates icons decoding to the same object it always was.
    public let icon: OPNCollectionIcon?

    public init(id: String, name: String, gameIds: [String] = [], icon: OPNCollectionIcon? = nil) {
        self.id = id
        self.name = name
        self.gameIds = gameIds
        self.icon = icon
    }

    public func contains(_ gameIdentity: String) -> Bool {
        gameIds.contains(gameIdentity)
    }

    /// The glyph to draw: the chosen icon when it is still valid, the catalog default otherwise.
    public var resolvedIcon: OPNCollectionIcon {
        icon?.validated ?? .fallback
    }

    /// A copy with a new name. Callers store only the `validated` result.
    public func renamed(_ name: String) -> OPNUserCollection {
        OPNUserCollection(id: id, name: name, gameIds: gameIds, icon: icon)
    }

    /// A copy with a new icon. Callers store only the `validated` result.
    public func withIcon(_ icon: OPNCollectionIcon?) -> OPNUserCollection {
        OPNUserCollection(id: id, name: name, gameIds: gameIds, icon: icon)
    }

    /// A copy with membership toggled. Removing drops every matching entry so a legacy duplicate
    /// cannot linger, and adding keeps the newest member last.
    public func toggling(_ gameIdentity: String) -> OPNUserCollection {
        guard gameIds.contains(gameIdentity) else {
            return OPNUserCollection(id: id, name: name, gameIds: gameIds + [gameIdentity], icon: icon)
        }
        return OPNUserCollection(id: id, name: name, gameIds: gameIds.filter { $0 != gameIdentity }, icon: icon)
    }

    /// A storable copy of this collection, or nil when it cannot be stored. Trims the name and
    /// members, drops blank, oversized and duplicate members, and caps the member count.
    public var validated: OPNUserCollection? {
        let identifier = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, identifier.count <= Self.maximumIdentifierLength else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.count >= Self.minimumNameLength, trimmedName.count <= Self.maximumNameLength else { return nil }
        var seen = Set<String>()
        let members = gameIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= Self.maximumIdentifierLength }
            .filter { seen.insert($0).inserted }
        return OPNUserCollection(
            id: identifier,
            name: trimmedName,
            gameIds: Array(members.prefix(Self.maximumGameCount)),
            icon: icon?.validated
        )
    }
}
