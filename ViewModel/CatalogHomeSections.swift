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
        _ = (mainPanels, catalogGames, libraryGames, favoriteGames, searchQuery, selectedFilterIds, isJumpBackInEnabled, recentlyPlayed, userCollections)
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
        // The reader's own collections sit just after My Library / My Favorites and before the
        // vendor rails; empty ones are skipped, and overflow past the 10-rail cap stays in the menu.
        if !isBrowseMode {
            let insertionIndex = sections.firstIndex { $0.kind == .library }.map { $0 + 1 } ?? min(sections.count, 1)
            var offset = 0
            for collection in sortedUserCollections {
                let resolved = resolvedMembers(of: collection)
                guard !resolved.games.isEmpty else { continue }
                let rail = CatalogSectionModel(
                    id: OPNHomeCustomization.userCollectionRailID(collection.id),
                    title: collection.name,
                    games: resolved.games,
                    kind: .userCollection(id: collection.id)
                )
                sections.insert(rail, at: min(insertionIndex + offset, sections.count))
                offset += 1
            }
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
        _ = (baseCatalogSections, homeRailArrangement)
        if let cachedCatalogSections { return cachedCatalogSections }
        let base = baseCatalogSections
        let pinned = base.filter { $0.kind == .catalog }
        let arrangeable = base.filter { $0.kind != .catalog }
        let orderedIDs = OPNHomeCustomization.orderedIdentities(arrangeable.map(\.id), by: homeRailArrangement.order)
        let sectionsByID = sectionsIndexedByID(arrangeable)
        let arranged = orderedIDs.compactMap { sectionsByID[$0] }
        let visible = arranged.filter { !homeRailArrangement.hidden.contains($0.id) }
        let result = Array((pinned + visible).prefix(Self.maximumHomeRailCount))
        cachedCatalogSections = result
        return result
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
        // An empty collection draws no home rail yet, so `baseCatalogSections` omits it. It still
        // belongs here: order or hide it the moment it exists, without adding a game first. Walk
        // the name-sorted collections rather than the lookup's keys: `Dictionary` iteration order
        // is unspecified, so appending from `collectionTitles.keys` reshuffled every existing
        // collection row whenever the set changed underneath a re-render.
        let collectionTitles = Dictionary(
            sortedUserCollections.map { (OPNHomeCustomization.userCollectionRailID($0.id), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        for collection in sortedUserCollections {
            let id = OPNHomeCustomization.userCollectionRailID(collection.id)
            if !canonicalOrder.contains(id) {
                canonicalOrder.append(id)
            }
        }
        let orderedIDs = OPNHomeCustomization.orderedIdentities(canonicalOrder, by: homeRailArrangement.order)
        return orderedIDs.map { id in
            CatalogHomeRail(
                id: id,
                title: railsByID[id]?.title ?? collectionTitles[id] ?? OPNHomeCustomization.fixedRailTitle(for: id) ?? id,
                isVisible: isHomeRailVisible(id)
            )
        }
    }

    func isHomeRailVisible(_ id: String) -> Bool {
        if id == OPNHomeCustomization.jumpBackInRailID { return isJumpBackInEnabled }
        return !homeRailArrangement.hidden.contains(id)
    }

    /// iCloud sync writes the arrangement into `UserDefaults` from a background actor, so without
    /// this the model keeps what it read at launch. Reload only when the stored value differs.
    func observeHomeArrangementChanges() {
        guard deinitHandle.homeArrangementObserver == nil else { return }
        deinitHandle.homeArrangementObserver = NotificationCenter.default.addObserver(
            forName: OPNHomeCustomization.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let stored = OPNHomeCustomization.arrangement
                guard stored != self.homeRailArrangement else { return }
                self.homeRailArrangement = stored
            }
        }
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
        _ = (isJumpBackInEnabled, recentlyPlayed)
        guard isJumpBackInEnabled, !recentlyPlayed.games.isEmpty else { return [] }
        _ = allKnownGames
        if let cachedJumpBackInGames { return cachedJumpBackInGames }
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
        cachedJumpBackInGames = resolved
        return resolved
    }

    private func catalogGame(matching entry: CatalogRecentlyPlayedGame, in knownGames: [OPNCatalogGameObject]) -> OPNCatalogGameObject? {
        if !entry.appId.isEmpty, let match = knownGames.first(where: { Self.game($0, matchesApplicationID: entry.appId) }) {
            return match
        }
        return knownGames.first(where: { !$0.title.isEmpty && $0.title.caseInsensitiveCompare(entry.title) == .orderedSame })
    }
}

// The derived game lists, memoized against the same invalidation as the rails above. They live here
// rather than in the view model's class body: they are read from many bodies, and a cached getter
// reads its inputs on the cached path so Observation still registers the dependency.
extension CatalogViewModel {
    var visibleFilterGroups: [OPNCatalogFilterGroupObject] {
        _ = filterGroups
        if let cachedVisibleFilterGroups { return cachedVisibleFilterGroups }
        let groups = filterGroups.filter { !$0.options.isEmpty }
        cachedVisibleFilterGroups = groups
        return groups
    }

    var showsCatalogLoadingIndicator: Bool {
        (isLoading && !catalogGames.isEmpty) || isLoadingMoreCatalog
    }

    var isRefetchingCatalog: Bool {
        isLoading && !catalogGames.isEmpty
    }

    var allKnownGames: [OPNCatalogGameObject] {
        _ = (marqueeGames, catalogGames, libraryGames, favoriteGames, mainPanelGames)
        if let cachedAllKnownGames { return cachedAllKnownGames }
        let games = marqueeGames + catalogGames + libraryGames + favoriteGames + mainPanelGames
        cachedAllKnownGames = games
        return games
    }

    var mainPanelGames: [OPNCatalogGameObject] {
        _ = mainPanels
        if let cachedMainPanelGames { return cachedMainPanelGames }
        let games = mainPanels.flatMap { panel in panel.sections.flatMap(\.games) }
        cachedMainPanelGames = games
        return games
    }

    /// Everything the catalog knows, keyed by canonical identity, first writer wins. Rebuilt only
    /// when the underlying game lists change, so resolving a collection's members is a dictionary
    /// lookup per member rather than a full catalog scan.
    var catalogGamesByIdentity: [String: OPNCatalogGameObject] {
        _ = (allKnownGames, jumpBackInGames)
        if let cachedCatalogGamesByIdentity { return cachedCatalogGamesByIdentity }
        var byIdentity: [String: OPNCatalogGameObject] = [:]
        for game in allKnownGames + jumpBackInGames {
            let identity = Self.identity(for: game)
            if !identity.isEmpty, byIdentity[identity] == nil { byIdentity[identity] = game }
        }
        cachedCatalogGamesByIdentity = byIdentity
        return byIdentity
    }
}
