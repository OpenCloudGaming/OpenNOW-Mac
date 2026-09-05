//  Navigating the catalog: destinations, Show All, the browse query and its sort and filters,
//  and paging through the results. Split out of CatalogViewModel.swift.
//

import Foundation
import Observation

extension CatalogViewModel {
    func showGames() {
        selectedMainPage = .games
        selectedCatalogDestination = .home
    }

    func showCatalogDestination(_ destination: CatalogDestination) {
        selectedMainPage = .games
        selectedCatalogDestination = destination
        selectedGame = nil
        selectedSectionId = ""
        selectedShowAllSection = nil
        searchQuery = ""
        selectedFilterIds = []
        selectedSortId = "a_to_z"
        browseGeneration += 1
        isLoading = false
        if destination == .home {
            catalogGames = []
            totalCatalogCount = 0
            hasMoreCatalogResults = false
            isLoadingMoreCatalog = false
            catalogEndCursor = ""
        }
    }

    func openBrowseFromSearch() {
        guard selectedShowAllSection == nil else { return }
        selectedShowAllSection = CatalogSectionModel(
            id: "search-browse",
            title: "Search Results",
            games: [],
            kind: .catalog,
            seeMoreFilterIds: [],
            seeMoreSortId: "relevance",
            seeMoreTitle: ""
        )
        selectedGame = nil
        selectedSectionId = ""
        selectedSortId = "relevance"
        selectedFilterIds = []
        browseCatalog()
    }

    func openShowAll(_ section: CatalogSectionModel) {
        OpenNOWLog.info(.catalog, "Show All opened section=\(section.id) title=\(section.title) games=\(section.games.count) canLoadFullList=\(section.canLoadFullList) seeMoreFilterIds=\(section.seeMoreFilterIds) seeMoreSortId=\(section.seeMoreSortId)")
        // My Library / My Favorites are server-side catalog filters (the `collections` filter
        // group), so every Show All page is the same browse with a different seed filter.
        let seededFilterIds: [String]
        switch section.kind {
        case .library:
            seededFilterIds = [OPNGameService.libraryCatalogFilterId]
        case .favorites:
            seededFilterIds = [OPNGameService.favoritesCatalogFilterId]
        case .catalog, .panel:
            seededFilterIds = section.seeMoreFilterIds
        }
        selectedShowAllSection = section
        selectedGame = nil
        selectedSectionId = ""
        selectedSortId = section.seeMoreSortId.isEmpty ? "a_to_z" : section.seeMoreSortId
        selectedFilterIds = seededFilterIds
        searchQuery = ""
        browseCatalog()
    }

    func closeShowAll() {
        launchErrorMessage = ""
        selectedShowAllSection = nil
        selectedGame = nil
        selectedSectionId = ""
        searchQuery = ""
        selectedFilterIds = []
        selectedSortId = "a_to_z"
        catalogGames = []
        totalCatalogCount = 0
        hasMoreCatalogResults = false
        isLoading = false
        isLoadingMoreCatalog = false
        catalogEndCursor = ""
    }

    func showSettings(_ group: CatalogSettingsGroup = .account) {
        selectedMainPage = .settings
        selectedSettingsGroup = group
        loadSettingsPreferences()
    }

    func browseCatalog() {
        browseCatalog(forceRefresh: false)
    }

    func browseCatalog(forceRefresh: Bool) {
        browseGeneration += 1
        let generation = browseGeneration
        let browseStartTime = CFAbsoluteTimeGetCurrent()
        isLoading = true
        isLoadingMoreCatalog = false
        catalogEndCursor = ""
        errorMessage = ""
        configureCatalogService()
        let query = searchQuery.trimmed
        let resultCount = catalogGames.count
        gameService.browseCatalogObject(
            searchQuery: query,
            sortId: selectedSortId.isEmpty ? "a_to_z" : selectedSortId,
            filterIds: selectedFilterIds,
            fetchCount: 200,
            forceRefresh: forceRefresh
        ) { [weak self] success, result, error in
            guard let self, generation == self.browseGeneration else { return }
            self.isLoading = false
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - browseStartTime) * 1000)
            guard success else {
                OpenNOWLog.warning(.catalog, "Show All browse failed elapsed=\(elapsedMs)ms error=\(error)")
                self.isLoadingMoreCatalog = false
                if self.refreshAuthIfNeeded(error: error) { return }
                self.errorMessage = error.isEmpty ? "Unable to browse the GeForce NOW catalog." : error
                return
            }
            let browseResult = result
            let newCount = browseResult.games.count
            let isPartialDelivery = newCount < browseResult.totalCount && browseResult.hasNextPage
            if isPartialDelivery {
                OpenNOWLog.info(.catalog, "Show All first page delivered elapsed=\(elapsedMs)ms games=\(newCount) total=\(browseResult.totalCount) hasNext=\(browseResult.hasNextPage)")
            } else {
                OpenNOWLog.info(.catalog, "Show All browse completed elapsed=\(elapsedMs)ms games=\(newCount) prevGames=\(resultCount) total=\(browseResult.totalCount)")
            }
            self.catalogGames = browseResult.games
            self.totalCatalogCount = browseResult.totalCount
            self.supportedCatalogCount = browseResult.numberSupported
            self.hasMoreCatalogResults = browseResult.hasNextPage
            self.catalogEndCursor = browseResult.endCursor
            self.isLoadingMoreCatalog = false
            // A browse is delivered more than once: the cached catalog arrives first, before the
            // filter/sort definitions have been read, and those early deliveries carry none. They
            // were being assigned anyway, which blanked the filter chips and dropped the sort chip
            // back to its "A-Z" placeholder - the difference between the Search page and a Show All
            // page was only ever which delivery had last landed.
            if !browseResult.filterGroups.isEmpty { self.filterGroups = browseResult.filterGroups }
            if !browseResult.sortOptions.isEmpty { self.sortOptions = browseResult.sortOptions }
            OpenNOWLog.info(.catalog, "Show All result applied games=\(newCount) filterGroups=\(browseResult.filterGroups.count) sortOptions=\(browseResult.sortOptions.count) isPartial=\(isPartialDelivery)")
            if !browseResult.selectedSortId.isEmpty { self.selectedSortId = browseResult.selectedSortId }
            self.selectedFilterIds = browseResult.selectedFilterIds
            self.schedulePatchingPollIfNeeded()
        }
    }

    func loadNextCatalogPage() {
        guard hasMoreCatalogResults, !catalogEndCursor.isEmpty, !isLoading, !isLoadingMoreCatalog else { return }
        let generation = browseGeneration
        isLoadingMoreCatalog = true
        OpenNOWLog.info(.catalog, "Show All loading next page cursor=\(catalogEndCursor)")
        gameService.browseCatalogObject(
            searchQuery: searchQuery.trimmed,
            sortId: selectedSortId.isEmpty ? "a_to_z" : selectedSortId,
            filterIds: selectedFilterIds,
            fetchCount: 200,
            forceRefresh: false,
            cursor: catalogEndCursor
        ) { [weak self] success, result, error in
            guard let self, generation == self.browseGeneration else { return }
            self.isLoadingMoreCatalog = false
            guard success else {
                OpenNOWLog.warning(.catalog, "Show All next page failed error=\(error)")
                return
            }
            let browseResult = result
            let existingIdentities = Set(self.catalogGames.map(\.catalogIdentity))
            let newGames = browseResult.games.filter { !existingIdentities.contains($0.catalogIdentity) }
            self.catalogGames.append(contentsOf: newGames)
            self.totalCatalogCount = max(self.totalCatalogCount, browseResult.totalCount)
            self.supportedCatalogCount = max(self.supportedCatalogCount, browseResult.numberSupported)
            self.hasMoreCatalogResults = browseResult.hasNextPage
            self.catalogEndCursor = browseResult.endCursor
            OpenNOWLog.info(.catalog, "Show All next page applied added=\(newGames.count) total=\(self.catalogGames.count) hasNext=\(browseResult.hasNextPage)")
            self.schedulePatchingPollIfNeeded()
        }
    }

    func games(for section: OPNCatalogPanelSectionObject, title: String, sectionId: String) -> [OPNCatalogGameObject] {
        guard isAllGamesPanelSection(section, title: title), !catalogGames.isEmpty else { return section.games }
        return catalogGames
    }

    func isAllGamesPanelSection(_ section: OPNCatalogPanelSectionObject, title: String) -> Bool {
        let normalizedTitle = Self.normalizedCatalogSectionIdentifier(title)
        let normalizedId = Self.normalizedCatalogSectionIdentifier(section.id)
        return normalizedTitle == "allgames" || normalizedId == "allgames" || normalizedId == "catalog" || normalizedId == "catalogresults"
    }

    static func normalizedCatalogSectionIdentifier(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    func setSort(_ sortId: String) {
        guard selectedSortId != sortId else { return }
        selectedSortId = sortId
        browseCatalog()
    }

    func toggleFilter(_ filterId: String) {
        if selectedFilterIds.contains(filterId) {
            selectedFilterIds.removeAll { $0 == filterId }
        } else {
            selectedFilterIds.append(filterId)
        }
        browseCatalog()
    }

    func clearFilters() {
        guard !selectedFilterIds.isEmpty else { return }
        selectedFilterIds = []
        browseCatalog()
    }

    func clearSearchAndFilters() {
        searchQuery = ""
        selectedFilterIds = []
        browseCatalog()
    }

    func openPanelTile(_ tile: OPNCatalogPanelTileObject) {
        if tile.kind == "filter", !tile.filterIds.isEmpty {
            selectedMainPage = .games
            selectedCatalogDestination = .home
            searchQuery = ""
            selectedFilterIds = tile.filterIds
            if !tile.sortId.isEmpty { selectedSortId = tile.sortId }
            browseCatalog()
            return
        }
        if let url = URL(string: tile.actionUrl), !tile.actionUrl.isEmpty {
            systemIntegration.open(url)
        }
    }

    func toggleSectionExpansion(_ sectionId: String) {
        if expandedSectionIds.contains(sectionId) {
            expandedSectionIds.remove(sectionId)
        } else {
            expandedSectionIds.insert(sectionId)
        }
    }
}
