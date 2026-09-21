//  The home page's rails: the derived catalog sections both layouts read, plus the Jump Back In
//  rail. The base list is everything the catalog offers; `catalogSections` is that list arranged.
//

import Foundation

extension CatalogViewModel {
    /// The most rails the home page draws at once. The arrangement is applied first, so hiding a
    /// rail lets the one behind it into view instead of leaving a gap.
    static let maximumHomeRailCount = 10

    /// Every rail the catalog currently offers, in the catalog's own order, including the ones the
    /// reader has hidden. The customization card lists this; the home page draws `catalogSections`.
    var baseCatalogSections: [CatalogSectionModel] {
        _ = (mainPanels, catalogGames, libraryGames, favoriteGames, searchQuery, selectedFilterIds, isJumpBackInEnabled, recentlyPlayed)
        if let cachedBaseCatalogSections { return cachedBaseCatalogSections }
        var sections: [CatalogSectionModel] = []
        var seenTitles = Set<String>()
        var seenIds = Set<String>()
        if let favorites = favoritesSection() {
            sections.append(favorites)
            seenTitles.insert("My Favorites")
            seenIds.insert(OPNHomeCustomization.favoritesRailID)
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
        if let library = librarySection() {
            let insertionIndex = sections.isEmpty ? 0 : min(sections.count, 1)
            sections.insert(library, at: insertionIndex)
        }
        // The most recent games come before every vendor rail, favorites included. Inserted after
        // the rest so it cannot displace the library/favorites slot bookkeeping above.
        if !isBrowseMode, !jumpBackInGames.isEmpty {
            sections.insert(fixedRail(id: OPNHomeCustomization.jumpBackInRailID, kind: .jumpBackIn, games: jumpBackInGames), at: 0)
        }
        cachedBaseCatalogSections = sections
        return sections
    }

    /// The rails the home page actually draws: the base list in the reader's order, with the hidden
    /// ones removed, capped at the number of rails home shows at once. A browse result stays pinned.
    var catalogSections: [CatalogSectionModel] {
        let base = baseCatalogSections
        let pinned = base.filter { $0.kind == .catalog }
        let arrangeable = base.filter { $0.kind != .catalog }
        let orderedIDs = OPNHomeCustomization.orderedIdentities(arrangeable.map(\.id), by: homeRailArrangement.order)
        let sectionsByID = sectionsIndexedByID(arrangeable)
        let arranged = orderedIDs.compactMap { sectionsByID[$0] }
        let visible = arranged.filter { !homeRailArrangement.hidden.contains($0.id) }
        return Array((pinned + visible).prefix(Self.maximumHomeRailCount))
    }

    /// Every home rail as the customization card sees it, in the arranged order and including the
    /// ones switched off. The three fixed rails are always present, so they can be arranged empty.
    var homeRailRows: [CatalogHomeRail] {
        let rails = baseCatalogSections.filter { $0.kind != .catalog }
        let railsByID = sectionsIndexedByID(rails)
        var canonicalOrder = OPNHomeCustomization.fixedRailOrder
        for rail in rails where !canonicalOrder.contains(rail.id) {
            canonicalOrder.append(rail.id)
        }
        let orderedIDs = OPNHomeCustomization.orderedIdentities(canonicalOrder, by: homeRailArrangement.order)
        return orderedIDs.map { id in
            CatalogHomeRail(
                id: id,
                title: railsByID[id]?.title ?? OPNHomeCustomization.fixedRailTitle(for: id) ?? id,
                isVisible: isHomeRailVisible(id)
            )
        }
    }

    func isHomeRailVisible(_ id: String) -> Bool {
        if id == OPNHomeCustomization.jumpBackInRailID { return isJumpBackInEnabled }
        return !homeRailArrangement.hidden.contains(id)
    }

    /// True when the home rails differ from their shipping order and visibility, so the card can
    /// offer a reset. Jump Back In counts through its own preference.
    var isHomeCustomized: Bool {
        homeRailArrangement.isCustom || !isJumpBackInEnabled
    }

    /// Moves one rail to sit where another sits, promoting every rail the card currently lists into
    /// the stored order so a later catalog load cannot reshuffle them.
    func moveHomeRail(_ id: String, to targetID: String) {
        let ids = homeRailRows.map(\.id)
        guard let order = OPNHomeCustomization.moving(id, to: targetID, in: ids) else { return }
        homeRailArrangement.order = order
    }

    /// Moves one rail one place earlier or later, the pad's equivalent of dragging it a row. No-op
    /// at either end.
    func shiftHomeRail(_ id: String, by offset: Int) {
        let ids = homeRailRows.map(\.id)
        guard offset != 0, let index = ids.firstIndex(of: id) else { return }
        let destinationIndex = index + offset
        guard ids.indices.contains(destinationIndex) else { return }
        guard let order = OPNHomeCustomization.moving(id, to: ids[destinationIndex], in: ids) else { return }
        homeRailArrangement.order = order
    }

    /// Switches one rail on or off. Jump Back In keeps its own preference, which predates this card
    /// and is read elsewhere, so its toggle writes through to that instead.
    func setHomeRailVisible(_ id: String, isVisible: Bool) {
        guard id != OPNHomeCustomization.jumpBackInRailID else {
            isJumpBackInEnabled = isVisible
            OPNThemePreferences.isJumpBackInEnabled = isVisible
            return
        }
        var hidden = homeRailArrangement.hidden
        hidden.remove(id)
        if !isVisible {
            hidden.insert(id)
        }
        homeRailArrangement.hidden = hidden
    }

    func resetHomeRailCustomization() {
        homeRailArrangement = .default
        isJumpBackInEnabled = true
        OPNThemePreferences.isJumpBackInEnabled = true
    }

    private func sectionsIndexedByID(_ sections: [CatalogSectionModel]) -> [String: CatalogSectionModel] {
        Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func favoritesSection() -> CatalogSectionModel? {
        guard !isBrowseMode else { return nil }
        if !favoriteGames.isEmpty {
            return fixedRail(id: OPNHomeCustomization.favoritesRailID, kind: .favorites, games: favoriteGames)
        }
        guard isLoadingFavorites else { return nil }
        return fixedRail(id: OPNHomeCustomization.favoritesRailID, kind: .favorites, games: [], isPlaceholder: true)
    }

    private func librarySection() -> CatalogSectionModel? {
        guard !isBrowseMode else { return nil }
        if !libraryGames.isEmpty {
            return fixedRail(id: OPNHomeCustomization.libraryRailID, kind: .library, games: libraryGames)
        }
        guard isLoadingLibrary else { return nil }
        return fixedRail(id: OPNHomeCustomization.libraryRailID, kind: .library, games: [], isPlaceholder: true)
    }

    private func fixedRail(id: String, kind: CatalogSectionModel.Kind, games: [OPNCatalogGameObject], isPlaceholder: Bool = false) -> CatalogSectionModel {
        CatalogSectionModel(
            id: id,
            title: OPNHomeCustomization.fixedRailTitle(for: id) ?? id,
            games: games,
            kind: kind,
            isPlaceholder: isPlaceholder
        )
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
