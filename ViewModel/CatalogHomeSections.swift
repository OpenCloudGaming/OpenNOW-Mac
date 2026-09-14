//  The home page's rails: the derived catalog sections both layouts read, plus the Jump Back In
//  rail, whose recents are matched back onto the catalog so delisted titles drop out.
//

import Foundation

extension CatalogViewModel {
    var catalogSections: [CatalogSectionModel] {
        _ = (mainPanels, catalogGames, libraryGames, favoriteGames, searchQuery, selectedFilterIds, isJumpBackInEnabled, recentlyPlayed)
        if let cachedCatalogSections { return cachedCatalogSections }
        var sections: [CatalogSectionModel] = []
        var seenTitles = Set<String>()
        var seenIds = Set<String>()
        let remoteFavoriteGames = favoriteGames
        if !isBrowseMode, !remoteFavoriteGames.isEmpty {
            sections.append(CatalogSectionModel(id: "remote-favorites", title: "My Favorites", games: remoteFavoriteGames, kind: .favorites))
            seenTitles.insert("My Favorites")
            seenIds.insert("remote-favorites")
        } else if !isBrowseMode, isLoadingFavorites {
            sections.append(CatalogSectionModel(id: "remote-favorites", title: "My Favorites", games: [], kind: .favorites, isPlaceholder: true))
            seenTitles.insert("My Favorites")
            seenIds.insert("remote-favorites")
        }
        for panel in mainPanels {
            for section in panel.sections where !section.games.isEmpty {
                let title = section.title.isEmpty ? panel.title : section.title
                let resolvedTitle = title.isEmpty ? "Featured Games" : title
                guard !seenTitles.contains(resolvedTitle) else { continue }
                let sectionId = section.sectionIdentity(fallbackPanelId: panel.id)
                guard !seenIds.contains(sectionId) else { continue }
                seenTitles.insert(resolvedTitle)
                seenIds.insert(sectionId)
                sections.append(CatalogSectionModel(
                    id: sectionId,
                    title: resolvedTitle,
                    games: games(for: section, title: resolvedTitle, sectionId: sectionId),
                    kind: .panel,
                    tiles: section.tiles,
                    seeMoreFilterIds: section.seeMoreFilterIds,
                    seeMoreSortId: section.seeMoreSortId,
                    seeMoreTitle: section.seeMoreTitle
                ))
            }
        }
        if isBrowseMode, !catalogGames.isEmpty {
            sections.insert(CatalogSectionModel(id: "catalog-results", title: "Search Results", games: catalogGames, kind: .catalog), at: 0)
        }
        if !isBrowseMode, !libraryGames.isEmpty {
            let insertionIndex = sections.isEmpty ? 0 : min(sections.count, 1)
            sections.insert(CatalogSectionModel(id: "my-library", title: "My Library", games: libraryGames, kind: .library), at: insertionIndex)
        } else if !isBrowseMode, isLoadingLibrary {
            let insertionIndex = sections.isEmpty ? 0 : min(sections.count, 1)
            sections.insert(CatalogSectionModel(id: "my-library", title: "My Library", games: [], kind: .library, isPlaceholder: true), at: insertionIndex)
        }
        // The most recent games come before every vendor rail, favorites included. Inserted after
        // the rest so it cannot displace the library/favorites slot bookkeeping above.
        if !isBrowseMode, !jumpBackInGames.isEmpty {
            sections.insert(CatalogSectionModel(id: "jump-back-in", title: "Jump Back In", games: jumpBackInGames, kind: .jumpBackIn), at: 0)
        }
        let result = Array(sections.prefix(10))
        cachedCatalogSections = result
        return result
    }

    /// The recently played games the Jump Back In rail offers, newest first. The entry list is
    /// already capped and deduped by the store; this pass only drops titles the catalog no longer
    /// carries.
    var jumpBackInGames: [OPNCatalogGameObject] {
        guard isJumpBackInEnabled, !recentlyPlayed.games.isEmpty else { return [] }
        let knownGames = allKnownGames
        var resolved: [OPNCatalogGameObject] = []
        var seenIdentities = Set<String>()
        for entry in recentlyPlayed.games {
            guard let game = catalogGame(matching: entry, in: knownGames) else { continue }
            let identity = Self.identity(for: game)
            guard !identity.isEmpty, seenIdentities.insert(identity).inserted else { continue }
            resolved.append(game)
            if resolved.count == CatalogRecentlyPlayed.maximumGameCount { break }
        }
        return resolved
    }

    private func catalogGame(matching entry: CatalogRecentlyPlayedGame, in knownGames: [OPNCatalogGameObject]) -> OPNCatalogGameObject? {
        if !entry.appId.isEmpty, let match = knownGames.first(where: { Self.game($0, matchesApplicationID: entry.appId) }) {
            return match
        }
        return knownGames.first(where: { !$0.title.isEmpty && $0.title.caseInsensitiveCompare(entry.title) == .orderedSame })
    }
}
