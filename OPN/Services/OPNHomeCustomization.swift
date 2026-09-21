//  The home page's rails, arranged by the reader: which categories draw and in what order, held
//  apart from the catalog so the arrangement survives the vendor returning them differently.
//

import Foundation

enum OPNHomeCustomization {
    /// The fixed rails keep their shipping order ahead of every vendor category the home page draws.
    /// Their identities match the section ids the catalog builder already uses.
    static let jumpBackInRailID = "jump-back-in"
    static let favoritesRailID = "remote-favorites"
    static let libraryRailID = "my-library"
    static let fixedRailOrder = [jumpBackInRailID, favoritesRailID, libraryRailID]

    /// The rail identity for a user collection. Prefixed so a collection id can never collide with
    /// a fixed rail id or a vendor section id.
    static func userCollectionRailID(_ collectionID: String) -> String {
        "user-collection-\(collectionID)"
    }

    /// The reader's arrangement: `order` is every rail identity they have arranged, `hidden` is the
    /// subset switched off. Jump Back In is excluded from `hidden`; it keeps its own preference.
    struct Arrangement: Equatable, Sendable {
        var order: [String]
        var hidden: Set<String>

        static let `default` = Arrangement(order: [], hidden: [])

        var isCustom: Bool { !order.isEmpty || !hidden.isEmpty }
    }

    static let orderKey = "OpenNOW.Interface.HomeRailOrder"
    static let hiddenKey = "OpenNOW.Interface.HomeRailsHidden"

    static var arrangement: Arrangement {
        get {
            Arrangement(
                order: uniqueIdentities(OPNAppPreferenceStorage.standard.array(forKey: orderKey) as? [String] ?? []),
                hidden: Set(OPNAppPreferenceStorage.standard.array(forKey: hiddenKey) as? [String] ?? [])
            )
        }
        set {
            OPNAppPreferenceStorage.standard.set(newValue.order, forKey: orderKey)
            OPNAppPreferenceStorage.standard.set(Array(newValue.hidden).sorted(), forKey: hiddenKey)
        }
    }

    /// The shipping title of a fixed rail, so Settings can name one the catalog has not sent yet.
    static func fixedRailTitle(for id: String) -> String? {
        switch id {
        case jumpBackInRailID: "Jump Back In"
        case favoritesRailID: "My Favorites"
        case libraryRailID: "My Library"
        default: nil
        }
    }

    /// The identities in arrangement order: the arranged ones first, then the unseen, which keep the
    /// order the caller offers them. A stored identity the caller no longer offers is dropped here.
    static func orderedIdentities(_ identities: [String], by order: [String]) -> [String] {
        guard !order.isEmpty else { return identities }
        var rank: [String: Int] = [:]
        for (index, id) in order.enumerated() where rank[id] == nil { rank[id] = index }
        let arranged = identities
            .filter { rank[$0] != nil }
            .sorted { rank[$0, default: 0] < rank[$1, default: 0] }
        let unseen = identities.filter { rank[$0] == nil }
        return arranged + unseen
    }

    /// Moves `id` to sit where `targetID` sits, matching `move(fromOffsets:toOffset:)`: a downward
    /// move passes the target, an upward move lands before it. Nil when either rail is absent.
    static func moving(_ id: String, to targetID: String, in identities: [String]) -> [String]? {
        guard id != targetID,
              let from = identities.firstIndex(of: id),
              let target = identities.firstIndex(of: targetID) else { return nil }
        let toOffset = target > from ? target + 1 : target
        var result = identities
        result.remove(at: from)
        let insertionIndex = toOffset > from ? toOffset - 1 : toOffset
        result.insert(id, at: min(max(insertionIndex, 0), result.count))
        return result
    }

    private static func uniqueIdentities(_ identities: [String]) -> [String] {
        var seen = Set<String>()
        return identities.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
