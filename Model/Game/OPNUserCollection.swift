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
    /// How long a deleted collection's tombstone travels before it may be pruned, so a Mac left
    /// offline across a delete still learns of it instead of re-adding the collection.
    public static let tombstoneRetention: TimeInterval = 60 * 60 * 24 * 30

    public let id: String
    public let name: String
    public let gameIds: [String]
    /// The glyph this collection draws. Nil means the catalog's default, which keeps an old payload
    /// that predates icons decoding to the same object it always was.
    public let icon: OPNCollectionIcon?
    /// When this record last changed. Two Macs resolve a collection they both carry by the newest
    /// write, so this is what lets an edit travel. Nil is a payload written before timestamps existed.
    public let updatedAt: Date?
    /// When this collection was deleted. Nil is a live collection; a value is a tombstone that keeps
    /// another Mac from resurrecting a collection this one deliberately removed.
    public let deletedAt: Date?

    public init(
        id: String,
        name: String,
        gameIds: [String] = [],
        icon: OPNCollectionIcon? = nil,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.gameIds = gameIds
        self.icon = icon
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// Whether this record is the tombstone of a deleted collection rather than a live one.
    public var isDeleted: Bool { deletedAt != nil }

    /// The instant this record was last written. A payload that predates timestamps sorts oldest, so
    /// any stamped write beats it.
    public var modificationDate: Date { updatedAt ?? deletedAt ?? .distantPast }

    public func contains(_ gameIdentity: String) -> Bool {
        gameIds.contains(gameIdentity)
    }

    /// The glyph to draw: the chosen icon when it is still valid, the catalog default otherwise.
    public var resolvedIcon: OPNCollectionIcon {
        icon?.validated ?? .fallback
    }

    /// A copy stamped as written now, so a peer resolves this write over the record it replaces.
    public func stamped(at date: Date) -> OPNUserCollection {
        OPNUserCollection(id: id, name: name, gameIds: gameIds, icon: icon, updatedAt: date, deletedAt: deletedAt)
    }

    /// The tombstone of this collection. Membership and icon are dropped: only the identity, the
    /// last name, and the deletion instant need to travel.
    public func deleting(at date: Date) -> OPNUserCollection {
        OPNUserCollection(id: id, name: name, gameIds: [], icon: nil, updatedAt: date, deletedAt: date)
    }

    /// A copy with a new name. Callers store only the `validated` result and re-stamp it.
    public func renamed(_ name: String) -> OPNUserCollection {
        OPNUserCollection(id: id, name: name, gameIds: gameIds, icon: icon, updatedAt: updatedAt, deletedAt: deletedAt)
    }

    /// A copy with a new icon. Callers store only the `validated` result and re-stamp it.
    public func withIcon(_ icon: OPNCollectionIcon?) -> OPNUserCollection {
        OPNUserCollection(id: id, name: name, gameIds: gameIds, icon: icon, updatedAt: updatedAt, deletedAt: deletedAt)
    }

    /// A copy with membership toggled. Removing drops every matching entry so a legacy duplicate
    /// cannot linger, and adding keeps the newest member last. Callers re-stamp the result.
    public func toggling(_ gameIdentity: String) -> OPNUserCollection {
        guard gameIds.contains(gameIdentity) else {
            return OPNUserCollection(id: id, name: name, gameIds: gameIds + [gameIdentity], icon: icon, updatedAt: updatedAt, deletedAt: deletedAt)
        }
        return OPNUserCollection(id: id, name: name, gameIds: gameIds.filter { $0 != gameIdentity }, icon: icon, updatedAt: updatedAt, deletedAt: deletedAt)
    }

    /// A storable copy of this collection, or nil when it cannot be stored. Trims the name and
    /// members, drops blank, oversized and duplicate members, and caps the member count.
    public var validated: OPNUserCollection? { validated(requiringName: !isDeleted) }

    /// A tombstone only needs a usable id: its name is kept so a prompt can name it but is not
    /// required, so a malformed name can never strand a deletion and let the collection return.
    private func validated(requiringName: Bool) -> OPNUserCollection? {
        let identifier = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, identifier.count <= Self.maximumIdentifierLength else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requiringName || Self.isUsableName(trimmedName) else { return nil }
        var seen = Set<String>()
        let members = gameIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= Self.maximumIdentifierLength }
            .filter { seen.insert($0).inserted }
        return OPNUserCollection(
            id: identifier,
            name: trimmedName,
            gameIds: Array(members.prefix(Self.maximumGameCount)),
            icon: icon?.validated,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    private static func isUsableName(_ name: String) -> Bool {
        (Self.minimumNameLength...Self.maximumNameLength).contains(name.count)
    }
}
