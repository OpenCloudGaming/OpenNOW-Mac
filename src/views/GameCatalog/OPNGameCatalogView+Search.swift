import AppKit

extension OPNGameCatalogView: NSSearchFieldDelegate {
    public func controlTextDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === searchField else { return }
        searchQuery = searchField.stringValue
        searchGeneration += 1
        searchDebounceTimer?.invalidate()
        searchDebounceTimer = nil
        if !OPNGameCatalogSearchSupport.normalizedString(searchQuery).isEmpty {
            searchDebounceTimer = Timer.scheduledTimer(timeInterval: OPNGameCatalogLayoutSupport.storeSearchDebounceInterval, target: self, selector: #selector(performAsyncSearchTimerFired(_:)), userInfo: nil, repeats: false)
            return
        }
        scheduleAsyncSearchForCurrentQuery()
    }

    @objc func scheduleAsyncSearchForCurrentQuery() {
        searchDebounceTimer?.invalidate()
        searchDebounceTimer = nil
        let query = searchQuery
        let normalizedQuery = OPNGameCatalogSearchSupport.normalizedString(query)
        searchGeneration += 1
        let generation = searchGeneration

        guard !normalizedQuery.isEmpty else {
            searchInFlight = false
            completedSearchQuery = ""
            renderingVisibleLibraryGameObjects = Self.visibleLibraryGames(from: heroOwnedLibraryGameObjects)
            renderingVisiblePanelObjects = heroPanelObjects
            resetSearchRenderState(generation: generation)
            return
        }

        searchInFlight = true
        let libraryGames = heroOwnedLibraryGameObjects.map(\.swiftValue)
        let panels = heroPanelObjects.map(\.swiftValue)
        searchQueue.async { [weak self] in
            let filteredLibraryGames = OPNCatalogSearchFilter.scoredGames(libraryGames, query: query)
            let filteredPanels = OPNCatalogSearchFilter.filteredPanels(panels, query: query)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.searchGeneration else { return }
                self.searchInFlight = false
                self.completedSearchQuery = query
                self.renderingVisibleLibraryGameObjects = OPNCatalogSearchFilter.visibleLibraryGames(from: filteredLibraryGames).map(OPNCatalogGameObject.init)
                self.renderingVisiblePanelObjects = filteredPanels.map(OPNCatalogPanelObject.init)
                self.resetSearchRenderState(generation: generation)
            }
        }
    }

    @objc func performAsyncSearchTimerFired(_ timer: Timer) {
        searchDebounceTimer = nil
        scheduleAsyncSearchForCurrentQuery()
    }

    private func resetSearchRenderState(generation: Int) {
        currentHeroIndex = 0
        initialHeroReady = false
        initialHeroPreloadInFlight = false
        initialHeroPreloadGeneration += 1
        initialHeroImage = nil
        initialHeroIdentity = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.searchGeneration else { return }
            self.renderStoreWhenInitialHeroReady()
        }
    }

}

private enum OPNCatalogSearchFilter {
    static func scoredGames(_ games: [OPNGameInfo], query: String) -> [OPNGameInfo] {
        games
            .map { game in (score: OPNGameCatalogSearchSupport.score(forTitle: game.title, query: query), game: game) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .map(\.game)
    }

    static func filteredPanels(_ panels: [OPNPanelResult], query: String) -> [OPNPanelResult] {
        panels.compactMap { panel in
            let sections = panel.sections.compactMap { section -> OPNPanelSection? in
                let games = scoredGames(section.games, query: query)
                guard !games.isEmpty else { return nil }
                return OPNPanelSection(id: section.id, title: section.title, typename: section.typename, games: games)
            }
            guard !sections.isEmpty else { return nil }
            return OPNPanelResult(id: panel.id, title: panel.title, typename: panel.typename, sections: sections)
        }
    }

    static func visibleLibraryGames(from games: [OPNGameInfo]) -> [OPNGameInfo] {
        var seen = Set<String>()
        var result: [OPNGameInfo] = []
        for game in games {
            guard hasAccessibleVariants(game) else { continue }
            let catalogGame = gameWithAccessibleVariants(game)
            let identity = gameIdentity(catalogGame)
            if !identity.isEmpty {
                guard seen.insert(identity).inserted else { continue }
            }
            result.append(catalogGame)
        }
        return result
    }

    private static func hasAccessibleVariants(_ game: OPNGameInfo) -> Bool {
        if game.isInLibrary { return true }
        if game.variants.contains(where: variantIsLibrarySelected) { return true }
        return game.variants.isEmpty
    }

    private static func gameWithAccessibleVariants(_ game: OPNGameInfo) -> OPNGameInfo {
        var catalogGame = game
        catalogGame.isInLibrary = true
        let variants = game.variants.filter(variantIsLibrarySelected).map { variant -> OPNGameVariant in
            var copy = variant
            copy.inLibrary = true
            return copy
        }
        if !variants.isEmpty { catalogGame.variants = variants }
        return catalogGame
    }

    private static func variantIsLibrarySelected(_ variant: OPNGameVariant) -> Bool {
        OPNGameCatalogMetadataSupport.variantIsLibrarySelected(librarySelected: variant.librarySelected, inLibrary: variant.inLibrary, serviceStatus: variant.serviceStatus)
    }

    private static func gameIdentity(_ game: OPNGameInfo) -> String {
        if !game.id.isEmpty { return game.id }
        if !game.uuid.isEmpty { return game.uuid }
        if !game.launchAppId.isEmpty { return game.launchAppId }
        return game.title
    }
}
