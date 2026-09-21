//  A user-defined group of catalog games. Unlike My Library and My Favorites, a user collection
//  exists only on this Mac: nothing is sent to NVIDIA and the reader keeps their own backup.

import Foundation

/// One locally-owned collection of catalog games. Membership is stored as `catalogIdentity`
/// strings, so it matches how favorites and recently-played already identify games.
public struct OPNUserCollection: Codable, Equatable, Sendable, Identifiable {
    /// The most collections one account may keep. The bounds mirror the upstream schema so a
    /// future import has a stable shape to validate against.
    public static let maximumCount = 100
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

    public init(id: String, name: String, gameIds: [String] = []) {
        self.id = id
        self.name = name
        self.gameIds = gameIds
    }

    public func contains(_ gameIdentity: String) -> Bool {
        gameIds.contains(gameIdentity)
    }

    /// A copy with a new name. Callers store only the `validated` result.
    public func renamed(_ name: String) -> OPNUserCollection {
        OPNUserCollection(id: id, name: name, gameIds: gameIds)
    }

    /// A copy with membership toggled. Removing drops every matching entry so a legacy duplicate
    /// cannot linger, and adding keeps the newest member last.
    public func toggling(_ gameIdentity: String) -> OPNUserCollection {
        guard gameIds.contains(gameIdentity) else {
            return OPNUserCollection(id: id, name: name, gameIds: gameIds + [gameIdentity])
        }
        return OPNUserCollection(id: id, name: name, gameIds: gameIds.filter { $0 != gameIdentity })
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
        return OPNUserCollection(id: identifier, name: trimmedName, gameIds: Array(members.prefix(Self.maximumGameCount)))
    }
}
