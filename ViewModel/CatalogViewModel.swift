//  CatalogViewModel.swift
//  MacForceNow
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import Foundation
import Observation

private final class CatalogWeakObject<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}

private extension OPNCatalogGameObject {
    func matchesGFNShortcutIdentifiers(_ identifiers: Set<String>) -> Bool {
        for value in [id, uuid, launchAppId, shortName] where identifiers.contains(value.lowercased()) {
            return true
        }
        return variants.contains { identifiers.contains($0.id.lowercased()) }
    }
}

private final class CatalogSendableValue<T>: @unchecked Sendable {
    nonisolated(unsafe) let value: T

    nonisolated init(_ value: T) {
        self.value = value
    }
}

private final class CatalogDeliveryGate: @unchecked Sendable {
    private var delivered = false

    func claimFirstDelivery() -> Bool {
        if delivered { return false }
        delivered = true
        return true
    }
}

private struct CatalogSettingsPreferencesSnapshot: Sendable {
    let capabilities: OPNStreamDeviceCapabilities
    let profile: OPNStreamPreferenceProfile
    let remoteCoOpPreferences: OPNRemoteCoOpPreferences
    let selectedRegionUrl: String
    let regionOptions: [OPNStreamRegionOption]
    let microphoneDeviceOptions: [OPNStreamMicrophoneDeviceOption]
}

@MainActor
enum CatalogLaunchFlowState: Equatable {
    case idle
    case checkingSession
    case activeSessionPrompt
    case stoppingSession
    case startingStream
}

@MainActor
enum CatalogOwnershipFlowStage: Equatable {
    case hidden
    case resyncing
    case storeSelection
    case manualMark
    case success
}

enum CatalogMainPage: String, CaseIterable, Identifiable {
    case games
    case recordings
    case settings

    var id: String { rawValue }
}

enum CatalogDestination: String, CaseIterable, Identifiable {
    case home
    case library
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Games"
        case .library: return "My Library"
        case .favorites: return "My Favorites"
        }
    }
}

enum CatalogSettingsGroup: String, CaseIterable, Identifiable {
    case account
    case streaming
    case connections
    case controller
    case general
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "Account"
        case .streaming: return "Streaming"
        case .connections: return "Connections"
        case .controller: return "Controller"
        case .general: return "General"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .account: return "Membership, profile, and current NVIDIA session details."
        case .streaming: return "Tune streaming quality, server location, and MetalFX upscaling."
        case .connections: return "Manage store accounts and Twitch broadcast settings."
        case .controller: return "Steam Controller support, permissions, input testing, and mapping."
        case .general: return "Interface mode, display scale, and experimental features."
        case .about: return "MacForce Now Mac runtime, system capability, and service identifiers."
        }
    }

    var icon: String {
        switch self {
        case .account: return "person.crop.circle.fill"
        case .streaming: return "play.tv.fill"
        case .connections: return "link"
        case .controller: return "gamecontroller.fill"
        case .general: return "gearshape.2.fill"
        case .about: return "info.circle.fill"
        }
    }
}

struct CatalogStreamAdPlayback: Identifiable, Equatable {
    let id: String
    let title: String
    let mediaUrl: String
    let durationMs: Int
}

@MainActor
@Observable
final class CatalogViewModel {
    var selectedMainPage = CatalogMainPage.games
    var selectedCatalogDestination = CatalogDestination.home
    var selectedShowAllSection: CatalogSectionModel? = nil
    var selectedSettingsGroup = CatalogSettingsGroup.account
    var searchQuery = "" {
        didSet {
            invalidateDerivedCatalogCaches()
            scheduleSearchDebounce()
        }
    }
    var selectedSortId = "a_to_z"
    var selectedFilterIds: [String] = [] {
        didSet { invalidateDerivedCatalogCaches() }
    }
    var isLoading = false
    var isLoadingMoreCatalog = false
    var isLoadingPanels = false
    private var catalogEndCursor = ""
    var errorMessage = ""
    var launchMessage = ""
    var actionMessage = ""
    var marqueePanels: [OPNCatalogPanelObject] = [] {
        didSet { invalidateDerivedCatalogCaches() }
    }
    var mainPanels: [OPNCatalogPanelObject] = [] {
        didSet { invalidateDerivedCatalogCaches() }
    }
    var catalogGames: [OPNCatalogGameObject] = [] {
        didSet { invalidateDerivedCatalogCaches() }
    }
    var libraryGames: [OPNCatalogGameObject] = [] {
        didSet { invalidateDerivedCatalogCaches() }
    }
    var filterGroups: [OPNCatalogFilterGroupObject] = []
    var sortOptions: [OPNCatalogSortOptionObject] = []
    var totalCatalogCount = 0
    var supportedCatalogCount = 0
    var hasMoreCatalogResults = false
    var accountStores: [CatalogStoreAccount] = []
    var storeDefinitions: [CatalogStoreDefinition] = []
    var selectedGame: OPNCatalogGameObject?
    var selectedSectionId = ""
    var selectedVariantIndex = -1
    var activeStreamConfiguration: StreamLaunchConfiguration?
    var activeStreamProgress: StreamProgress?
    var isActiveStreamLaunchOverlayVisible = false
    var launchFlowState = CatalogLaunchFlowState.idle
    var launchFlowTitle = ""
    var launchFlowMessage = ""
    var launchFlowError = ""
    var activeLaunchSession: OPNActiveStreamSessionDescriptor?
    var streamProfile = OPNStreamPreferenceProfile()
    var remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
    var streamCapabilities = OPNStreamDeviceCapabilities()
    var settingsRegionOptions: [OPNStreamRegionOption] = []
    var selectedSettingsRegionUrl = ""
    var unavailableSettingsRegionUrl = ""
    var isRefreshingSettingsRegions = false
    var microphoneDeviceOptions: [OPNStreamMicrophoneDeviceOption] = []
    var previousGameSession = CatalogPreviousGameSession.load()
    var playtimeStatistics = CatalogPlaytimeStatistics.empty
    var subscriptionStatus = CatalogSubscriptionStatus.unavailable
    var favoriteGameIdentities: Set<String> = []
    var favoriteGames: [OPNCatalogGameObject] = [] {
        didSet { invalidateDerivedCatalogCaches() }
    }
    var selectedGameRevealRequest: CatalogGameRevealRequest?
    var catalogImageCacheSummary = "Calculating"
    var isStorePickerVisible = false
    var ownershipFlowStage = CatalogOwnershipFlowStage.hidden
    var ownershipFlowMessage = ""
    var queuedPatchingLaunchGameTitle = ""
    private var fullSectionGames: [String: [OPNCatalogGameObject]] = [:]
    private var loadingFullSectionIds: Set<String> = []
    var expandedSectionIds: Set<String> = []
    var accountSubscriptions: [String] = []
    var subscriptionDefinitions: [CatalogSubscriptionDefinition] = []
    var activeStreamAdPlayback: CatalogStreamAdPlayback?

    let account: LoginAccount
    let session: LoginSession
    let onRefreshAuth: () async -> Bool

    var isFreeTierAccount: Bool {
        subscriptionStatus.isAvailable && subscriptionStatus.isFreeTierAccount
    }

    private var hasLoaded = false
    private var browseGeneration = 0
    private var authRefreshInFlight = false
    private var searchDebounceTask: Task<Void, Never>?
    private var pendingLaunchGame: OPNCatalogGameObject?
    private var pendingLaunchVariantIndex = -1
    private var activeDiscordPresence: DiscordGamePresence?
    private var activeSessionResumeConfiguration: StreamLaunchConfiguration?
    private var activeSessionReplacementConfiguration: StreamLaunchConfiguration?
    private var streamProgressGeneration = 0
    private var activeStreamAdContinuation: CheckedContinuation<Int, Error>?
    private var settingsPreferencesGeneration = 0
    private var selectedGameRevealSequence = 0
    private var settingsPreferencesTask: Task<Void, Never>?
    private var patchingPollInFlight = false
    private var queuedPatchingLaunchIdentity = ""
    private var queuedPatchingLaunchVariantIndex = -1
    private let deinitHandle = CatalogViewModelDeinitHandle()

    private var hasStarted = false

    init(account: LoginAccount, session: LoginSession, onRefreshAuth: @escaping () async -> Bool) {
        self.account = account
        self.session = session
        self.onRefreshAuth = onRefreshAuth
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let playtimeAccountIdentifier = Self.playtimeAccountIdentifier(account: account, session: session)
        playtimeStatistics = CatalogPlaytimeStatistics.load(accountIdentifier: playtimeAccountIdentifier)
    }

    private func scheduleSearchDebounce() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.browseCatalog()
        }
    }

    deinit {
        deinitHandle.patchingPollTask?.cancel()
    }

    // Derived catalog collections are rebuilt from the full catalog on every
    // access, and the catalog views read them many times per render, so they
    // are memoized until an input property changes. The caches must stay
    // invisible to Observation (@ObservationIgnored) while the getters still
    // read their inputs on the cached path, so views keep registering
    // dependencies and re-render when the underlying data changes.
    @ObservationIgnored private var cachedMarqueeGames: [OPNCatalogGameObject]?
    @ObservationIgnored private var cachedHeroRotationGames: [OPNCatalogGameObject]?
    @ObservationIgnored private var cachedCatalogSections: [CatalogSectionModel]?

    private func invalidateDerivedCatalogCaches() {
        cachedMarqueeGames = nil
        cachedHeroRotationGames = nil
        cachedCatalogSections = nil
    }

    var marqueeGames: [OPNCatalogGameObject] {
        _ = marqueePanels
        if let cachedMarqueeGames { return cachedMarqueeGames }
        var games: [OPNCatalogGameObject] = []
        var seen = Set<String>()
        for panel in marqueePanels {
            for section in panel.sections {
                for game in section.games {
                    let key = Self.identity(for: game)
                    guard !key.isEmpty, !seen.contains(key) else { continue }
                    seen.insert(key)
                    games.append(game)
                }
            }
        }
        cachedMarqueeGames = games
        return games
    }

    var heroRotationGames: [OPNCatalogGameObject] {
        _ = marqueePanels
        if let cachedHeroRotationGames { return cachedHeroRotationGames }
        let games = Self.dedupedByTitleGrouping(marqueeGames.filter(Self.hasMarqueeHeroArtwork))
        cachedHeroRotationGames = games
        return games
    }

    var catalogSections: [CatalogSectionModel] {
        _ = (mainPanels, catalogGames, libraryGames, favoriteGames, searchQuery, selectedFilterIds)
        if let cachedCatalogSections { return cachedCatalogSections }
        var sections: [CatalogSectionModel] = []
        var seenTitles = Set<String>()
        var seenIds = Set<String>()
        let remoteFavoriteGames = favoriteGames
        if !isBrowseMode, !remoteFavoriteGames.isEmpty {
            sections.append(CatalogSectionModel(id: "remote-favorites", title: "My Favorites", games: remoteFavoriteGames, kind: .favorites))
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
        }
        let result = Array(sections.prefix(10))
        cachedCatalogSections = result
        return result
    }

    var isBrowseMode: Bool {
        !searchQuery.trimmed.isEmpty || !selectedFilterIds.isEmpty
    }

    var isCatalogRefreshInProgress: Bool {
        isLoading || isLoadingPanels
    }

    var selectedSortLabel: String {
        sortOptions.first { $0.id == selectedSortId }?.label ?? "A-Z"
    }

    var visibleFilterGroups: [OPNCatalogFilterGroupObject] {
        filterGroups.filter { !$0.options.isEmpty }
    }

    var showsCatalogLoadingIndicator: Bool {
        (isLoading && !catalogGames.isEmpty) || isLoadingMoreCatalog
    }

    var isRefetchingCatalog: Bool {
        isLoading && !catalogGames.isEmpty
    }

    private var allKnownGames: [OPNCatalogGameObject] {
        marqueeGames + catalogGames + libraryGames + favoriteGames + mainPanelGames
    }

    private var mainPanelGames: [OPNCatalogGameObject] {
        mainPanels.flatMap { panel in panel.sections.flatMap(\.games) }
    }

    var selectedFilterCount: Int { selectedFilterIds.count }

    var resultSummary: String {
        let total = totalCatalogCount > 0 ? totalCatalogCount : catalogGames.count
        if searchQuery.trimmed.isEmpty, selectedFilterIds.isEmpty { return "" }
        if total == 1 { return "1 result" }
        return "\(total) results"
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard session.isExpired else {
            loadCatalogDataAfterProviderConfiguration()
            return
        }
        MacForceNowLog.info(.catalog, "Initial catalog load deferred until expired session refresh completes")
        Task { [weak self] in
            guard let self else { return }
            _ = await onRefreshAuth()
            loadCatalogDataAfterProviderConfiguration()
        }
    }

    func refresh() {
        loadCatalogDataAfterProviderConfiguration(forceCatalogRefresh: true)
    }

    private func loadCatalogDataAfterProviderConfiguration(forceCatalogRefresh: Bool = false) {
        configureCatalogService()
        Task { await configureCatalogProviderEndpoint() }
        loadPanels()
        loadLibrary()
        loadFavorites()
        loadAccountAndStores()
        loadSettingsPreferences()
        if forceCatalogRefresh { browseCatalog(forceRefresh: true) }
    }

    private func configureCatalogProviderEndpoint() async {
        let providerIdpId = session.idpId.isEmpty ? account.providerIdpId : session.idpId
        guard !providerIdpId.isEmpty else { return }
        await withCheckedContinuation { continuation in
            OPNGameServiceSwiftAdapter.fetchGameProviderInfo(idpId: providerIdpId) { success, _, endpoint, error in
                let message = success
                    ? "Configured provider endpoint provider=\(endpoint.loginProvider) idpId=\(providerIdpId)"
                    : "Provider endpoint lookup failed idpId=\(providerIdpId) error=\(error)"
                Task { @MainActor in
                    if success {
                        MacForceNowLog.info(.auth, message)
                    } else {
                        MacForceNowLog.warning(.auth, message)
                    }
                    continuation.resume()
                }
            }
        }
    }

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
        MacForceNowLog.info(.catalog, "Show All opened section=\(section.id) title=\(section.title) games=\(section.games.count) canLoadFullList=\(section.canLoadFullList) seeMoreFilterIds=\(section.seeMoreFilterIds) seeMoreSortId=\(section.seeMoreSortId)")
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

    private func browseCatalog(forceRefresh: Bool) {
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
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.browseCatalogObject(
            searchQuery: query,
            sortId: selectedSortId.isEmpty ? "a_to_z" : selectedSortId,
            filterIds: selectedFilterIds,
            fetchCount: 200,
            forceRefresh: forceRefresh
        ) { success, result, error in
            let resultBox = CatalogSendableValue(result)
            Task { @MainActor in
                guard let self = selfBox.value, generation == self.browseGeneration else { return }
                self.isLoading = false
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - browseStartTime) * 1000)
                guard success else {
                    MacForceNowLog.warning(.catalog, "Show All browse failed elapsed=\(elapsedMs)ms error=\(error)")
                    self.isLoadingMoreCatalog = false
                    if self.refreshAuthIfNeeded(error: error) { return }
                    self.errorMessage = error.isEmpty ? "Unable to browse the GeForce NOW catalog." : error
                    return
                }
                let browseResult = resultBox.value
                let newCount = browseResult.games.count
                let isPartialDelivery = newCount < browseResult.totalCount && browseResult.hasNextPage
                if isPartialDelivery {
                    MacForceNowLog.info(.catalog, "Show All first page delivered elapsed=\(elapsedMs)ms games=\(newCount) total=\(browseResult.totalCount) hasNext=\(browseResult.hasNextPage)")
                } else {
                    MacForceNowLog.info(.catalog, "Show All browse completed elapsed=\(elapsedMs)ms games=\(newCount) prevGames=\(resultCount) total=\(browseResult.totalCount)")
                }
                self.catalogGames = browseResult.games
                self.totalCatalogCount = browseResult.totalCount
                self.supportedCatalogCount = browseResult.numberSupported
                self.hasMoreCatalogResults = browseResult.hasNextPage
                self.catalogEndCursor = browseResult.endCursor
                self.isLoadingMoreCatalog = false
                self.filterGroups = browseResult.filterGroups
                self.sortOptions = browseResult.sortOptions
                MacForceNowLog.info(.catalog, "Show All result applied games=\(newCount) filterGroups=\(browseResult.filterGroups.count) sortOptions=\(browseResult.sortOptions.count) isPartial=\(isPartialDelivery)")
                if !browseResult.selectedSortId.isEmpty { self.selectedSortId = browseResult.selectedSortId }
                self.selectedFilterIds = browseResult.selectedFilterIds
                self.schedulePatchingPollIfNeeded()
            }
        }
    }

    func loadNextCatalogPage() {
        guard hasMoreCatalogResults, !catalogEndCursor.isEmpty, !isLoading, !isLoadingMoreCatalog else { return }
        let generation = browseGeneration
        isLoadingMoreCatalog = true
        let selfBox = CatalogWeakObject(self)
        MacForceNowLog.info(.catalog, "Show All loading next page cursor=\(catalogEndCursor)")
        OPNGameServiceSwiftAdapter.browseCatalogObject(
            searchQuery: searchQuery.trimmed,
            sortId: selectedSortId.isEmpty ? "a_to_z" : selectedSortId,
            filterIds: selectedFilterIds,
            fetchCount: 200,
            forceRefresh: false,
            cursor: catalogEndCursor
        ) { success, result, error in
            let resultBox = CatalogSendableValue(result)
            Task { @MainActor in
                guard let self = selfBox.value, generation == self.browseGeneration else { return }
                self.isLoadingMoreCatalog = false
                guard success else {
                    MacForceNowLog.warning(.catalog, "Show All next page failed error=\(error)")
                    return
                }
                let browseResult = resultBox.value
                let existingIdentities = Set(self.catalogGames.map(\.catalogIdentity))
                let newGames = browseResult.games.filter { !existingIdentities.contains($0.catalogIdentity) }
                self.catalogGames.append(contentsOf: newGames)
                self.totalCatalogCount = max(self.totalCatalogCount, browseResult.totalCount)
                self.supportedCatalogCount = max(self.supportedCatalogCount, browseResult.numberSupported)
                self.hasMoreCatalogResults = browseResult.hasNextPage
                self.catalogEndCursor = browseResult.endCursor
                MacForceNowLog.info(.catalog, "Show All next page applied added=\(newGames.count) total=\(self.catalogGames.count) hasNext=\(browseResult.hasNextPage)")
                self.schedulePatchingPollIfNeeded()
            }
        }
    }

    private func games(for section: OPNCatalogPanelSectionObject, title: String, sectionId: String) -> [OPNCatalogGameObject] {
        guard isAllGamesPanelSection(section, title: title), !catalogGames.isEmpty else { return section.games }
        return catalogGames
    }

    private func isAllGamesPanelSection(_ section: OPNCatalogPanelSectionObject, title: String) -> Bool {
        let normalizedTitle = Self.normalizedCatalogSectionIdentifier(title)
        let normalizedId = Self.normalizedCatalogSectionIdentifier(section.id)
        return normalizedTitle == "allgames" || normalizedId == "allgames" || normalizedId == "catalog" || normalizedId == "catalogresults"
    }

    private static func normalizedCatalogSectionIdentifier(_ value: String) -> String {
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
            NSWorkspace.shared.open(url)
        }
    }

    func toggleSectionExpansion(_ sectionId: String) {
        if expandedSectionIds.contains(sectionId) {
            expandedSectionIds.remove(sectionId)
        } else {
            expandedSectionIds.insert(sectionId)
        }
    }

    func selectGame(_ game: OPNCatalogGameObject?) {
        let resolvedGame = game.flatMap(resolveGameForDetails) ?? game
        selectedGame = resolvedGame
        selectedSectionId = ""
        selectedVariantIndex = resolvedGame.map { Self.preferredVariantIndex(for: $0) } ?? -1
        launchMessage = ""
        actionMessage = ""
    }

    func selectGame(_ game: OPNCatalogGameObject, inSection sectionId: String) {
        let resolvedGame = resolveGameForDetails(game, preferredSectionId: sectionId)
        selectedGame = resolvedGame
        selectedSectionId = sectionId
        selectedVariantIndex = Self.preferredVariantIndex(for: resolvedGame)
        launchMessage = ""
        actionMessage = ""
    }

    func toggleGameSelection(_ game: OPNCatalogGameObject, inSection sectionId: String) {
        if let selectedGame, selectedSectionId == sectionId, Self.looseIdentityMatches(selectedGame, game) {
            selectGame(nil)
            return
        }
        selectGame(game, inSection: sectionId)
    }

    func selectGameFromHero(_ game: OPNCatalogGameObject) {
        selectGame(game)
        requestSelectedGameReveal(for: game, sectionId: "")
    }

    func closeGameDetailsFromBackground() {
        guard selectedGame != nil else { return }
        selectGame(nil)
    }

    func launchSelectedGame() {
        guard let selectedGame else { return }
        launch(game: selectedGame, variantIndex: selectedVariantIndex)
    }

    func launch(game: OPNCatalogGameObject, variantIndex: Int? = nil) {
        beginVendorLaunch(game: game, variantIndex: variantIndex)
    }

    func queuePatchingLaunch(game: OPNCatalogGameObject, variantIndex: Int? = nil) {
        guard Self.isPatching(game) else { return }
        queuedPatchingLaunchIdentity = Self.identity(for: game)
        queuedPatchingLaunchVariantIndex = variantIndex ?? selectedVariantIndexIfMatching(game) ?? Self.preferredVariantIndex(for: game)
        queuedPatchingLaunchGameTitle = game.title.isEmpty ? "GeForce NOW" : game.title
        actionMessage = "Queued \(queuedPatchingLaunchGameTitle) to launch when patching finishes."
        errorMessage = ""
        schedulePatchingPollIfNeeded(immediate: true)
    }

    func isQueuedForPatching(_ game: OPNCatalogGameObject) -> Bool {
        !queuedPatchingLaunchIdentity.isEmpty && Self.identity(for: game) == queuedPatchingLaunchIdentity
    }

    func openGameShortcut(_ shortcut: GFNGameShortcut) {
        configureCatalogService()
        let title = shortcut.lookupTitle.isEmpty ? shortcut.displayName : shortcut.lookupTitle
        MacForceNowLog.info(.shortcut, "CatalogViewModel resolving shortcut cmsId=\(shortcut.cmsId) shortName=\(shortcut.shortName) parentGameId=\(shortcut.parentGameId) title=\(title)")
        setActionMessage("Opening \(title.isEmpty ? "GeForce NOW shortcut" : title)...")
        if let game = matchingGame(for: shortcut, in: allKnownGames) {
            MacForceNowLog.info(.shortcut, "Resolved shortcut from loaded catalog: gameId=\(game.id) uuid=\(game.uuid) launchAppId=\(game.launchAppId) title=\(game.title)")
            selectGame(game)
            launch(game: game, variantIndex: variantIndex(for: shortcut, in: game))
            return
        }
        if Int(shortcut.cmsId) != nil {
            MacForceNowLog.info(.shortcut, "Shortcut not found in loaded catalog; fetching CMS metadata cmsId=\(shortcut.cmsId)")
            let selfBox = CatalogWeakObject(self)
            OPNGameServiceSwiftAdapter.fetchGameObjectByCMSId(shortcut.cmsId) { success, game, error in
                let gameBox = CatalogSendableValue(game)
                Task { @MainActor in
                    guard let self = selfBox.value else { return }
                    let game = gameBox.value
                    if success, let game {
                        MacForceNowLog.info(.shortcut, "Resolved shortcut from CMS metadata: gameId=\(game.id) uuid=\(game.uuid) title=\(game.title)")
                        self.selectGame(game)
                        self.launch(game: game, variantIndex: self.variantIndex(for: shortcut, in: game))
                        return
                    }
                    MacForceNowLog.warning(.shortcut, "Shortcut CMS metadata lookup failed: \(error)")
                    if let game = Self.launchGame(from: shortcut, title: title) {
                        MacForceNowLog.info(.shortcut, "Launching shortcut directly from cmsId=\(shortcut.cmsId) title=\(game.title)")
                        self.selectGame(game)
                        self.launch(game: game, variantIndex: 0)
                    } else {
                        self.resolveShortcutByBrowsing(shortcut, title: title)
                    }
                }
            }
            return
        }
        if let game = Self.launchGame(from: shortcut, title: title) {
            MacForceNowLog.info(.shortcut, "Launching shortcut directly from cmsId=\(shortcut.cmsId) title=\(game.title)")
            selectGame(game)
            launch(game: game, variantIndex: 0)
            return
        }
        resolveShortcutByBrowsing(shortcut, title: title)
    }

    private func resolveShortcutByBrowsing(_ shortcut: GFNGameShortcut, title: String) {
        MacForceNowLog.info(.shortcut, "Shortcut not found in loaded catalog; browsing with query=\(title)")
        let selfBox = CatalogWeakObject(self)
        let handledBox = CatalogSendableValue(CatalogDeliveryGate())
        OPNGameServiceSwiftAdapter.browseCatalogObject(searchQuery: title, sortId: "relevance", filterIds: [], fetchCount: 24) { success, result, error in
            let resultBox = CatalogSendableValue(result)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                guard handledBox.value.claimFirstDelivery() else { return }
                guard success else {
                    MacForceNowLog.error(.shortcut, "Shortcut catalog browse failed: \(error)")
                    self.errorMessage = error.isEmpty ? "Unable to resolve this GeForce NOW shortcut." : error
                    return
                }
                let games = resultBox.value.games
                MacForceNowLog.info(.shortcut, "Shortcut catalog browse returned \(games.count) game(s)")
                guard let game = self.matchingGame(for: shortcut, in: games) ?? games.first else {
                    MacForceNowLog.error(.shortcut, "Shortcut catalog browse returned no matching games")
                    self.errorMessage = "No matching GeForce NOW catalog game was found for this shortcut."
                    return
                }
                MacForceNowLog.info(.shortcut, "Resolved shortcut from browse: gameId=\(game.id) uuid=\(game.uuid) launchAppId=\(game.launchAppId) title=\(game.title)")
                self.catalogGames = games
                self.selectGame(game)
                self.launch(game: game, variantIndex: self.variantIndex(for: shortcut, in: game))
            }
        }
    }

    var isLaunchFlowVisible: Bool {
        launchFlowState != .idle
    }

    var isStreamLaunchLoadingVisible: Bool {
        guard activeStreamConfiguration != nil else { return false }
        return isActiveStreamLaunchOverlayVisible
    }

    var canResumeActiveLaunchSession: Bool {
        activeSessionResumeConfiguration?.resumesExistingSession == true
    }

    func beginVendorLaunch(game: OPNCatalogGameObject, variantIndex: Int? = nil) {
        MacForceNowLog.info(.launch, "Beginning launch for gameId=\(game.id) uuid=\(game.uuid) launchAppId=\(game.launchAppId) title=\(game.title) requestedVariantIndex=\(variantIndex ?? -1)")
        pendingLaunchGame = game
        pendingLaunchVariantIndex = variantIndex ?? Self.preferredVariantIndex(for: game)
        activeLaunchSession = nil
        activeSessionResumeConfiguration = nil
        activeSessionReplacementConfiguration = nil
        launchFlowTitle = game.title.isEmpty ? "GeForce NOW" : game.title
        launchFlowMessage = "Checking for active GeForce NOW sessions..."
        launchFlowError = ""
        launchMessage = "Preparing \(game.title.isEmpty ? "game" : game.title)..."
        errorMessage = ""
        launchFlowState = .checkingSession
        let presence = discordPresence(for: game)
        activeDiscordPresence = presence
        DiscordRichPresence.shared.update(.launching(presence))
        continueVendorLaunch()
    }

    func selectSettingsRegion(_ regionUrl: String) {
        selectedSettingsRegionUrl = regionUrl
        unavailableSettingsRegionUrl = ""
        OPNStreamPreferences.saveSelectedRegionUrl(regionUrl)
        loadSettingsPreferences()
    }

    func keepUnavailableSettingsRegion() {
        unavailableSettingsRegionUrl = ""
    }

    func switchUnavailableSettingsRegionToAutomatic() {
        selectSettingsRegion("")
    }

    func refreshSettingsRegions() {
        guard !isRefreshingSettingsRegions else { return }
        isRefreshingSettingsRegions = true
        let token = launchToken
        let selfBox = CatalogWeakObject(self)
        OPNStreamPreferences.fetchRegions(token: token, providerStreamingBaseUrl: OPNGameServiceSwiftAdapter.providerStreamingBaseURL()) { regions in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                self.isRefreshingSettingsRegions = false
                self.settingsRegionOptions = Self.launchRegionOptions(from: regions)
                if !self.selectedSettingsRegionUrl.isEmpty, !regions.contains(where: { $0.url == self.selectedSettingsRegionUrl }) {
                    self.unavailableSettingsRegionUrl = self.selectedSettingsRegionUrl
                } else {
                    self.unavailableSettingsRegionUrl = ""
                }
            }
        }
    }

    func continueVendorLaunch() {
        guard let game = pendingLaunchGame else { return }
        launchFlowState = .checkingSession
        launchFlowMessage = "Checking for active GeForce NOW sessions..."
        launchFlowError = ""
        let userId = session.userId.isEmpty ? account.userId : session.userId
        OPNGameLaunchBridge.shared.prepareLaunchPlan(
            game: game,
            accessToken: session.accessToken,
            idToken: session.idToken,
            userId: userId,
            idpId: session.idpId.isEmpty ? account.providerIdpId : session.idpId,
            variantIndex: pendingLaunchVariantIndex
        ) { [weak self] success, message, plan in
            guard let self else { return }
            self.launchMessage = ""
            guard success, let plan else {
                MacForceNowLog.error(.launch, "Launch plan failed: \(message)")
                self.clearLaunchFlow()
                self.errorMessage = message.isEmpty ? "Unable to prepare GeForce NOW launch." : message
                return
            }
            switch plan {
            case .ready(let configuration):
                MacForceNowLog.info(.launch, "Launch plan ready appId=\(configuration.appId) title=\(configuration.title)")
                self.startPreparedStream(Self.mediaConfiguration(from: configuration, membershipTier: self.account.membershipTier), message: message)
            case .activeSession(let active, let resume, let replacement):
                MacForceNowLog.info(.launch, "Launch plan found active session activeAppId=\(active.appId) replacementAppId=\(replacement.appId) resumeAppId=\(resume.appId)")
                let activeTitle = self.title(forActiveSession: active)
                self.activeLaunchSession = OPNActiveStreamSessionDescriptor(sessionId: active.id, appId: active.appId, serverIp: active.serverIp, streamingBaseUrl: active.streamingBaseUrl, title: activeTitle)
                self.activeSessionResumeConfiguration = Self.mediaConfiguration(from: resume, titleOverride: activeTitle, membershipTier: self.account.membershipTier)
                self.activeSessionReplacementConfiguration = Self.mediaConfiguration(from: replacement, membershipTier: self.account.membershipTier)
                self.launchFlowState = .activeSessionPrompt
                self.launchFlowMessage = !resume.resumeSessionId.isEmpty && !resume.resumeServer.isEmpty
                    ? "A GeForce NOW session is already running. Resume it or end it before launching \(self.launchFlowTitle)."
                    : "GeForce NOW reports a stale active session that cannot be resumed. End it before launching \(self.launchFlowTitle)."
            }
        }
    }

    func resumeActiveLaunchSession() {
        guard canResumeActiveLaunchSession else {
            launchFlowError = "This GeForce NOW session is no longer resumable. End it and launch again."
            return
        }
        guard let configuration = activeSessionResumeConfiguration else { return }
        startPreparedStream(configuration, message: "Resuming \(configuration.title)...")
    }

    func endActiveSessionAndLaunchSelectedGame() {
        guard let activeLaunchSession, let replacement = activeSessionReplacementConfiguration else { return }
        launchFlowState = .stoppingSession
        launchFlowMessage = "Ending the current GeForce NOW session..."
        launchFlowError = ""
        OPNGameLaunchBridge.shared.stopActiveSession(activeLaunchSession, accessToken: launchToken) { [weak self] success, message in
            guard let self else { return }
            guard success else {
                self.launchFlowState = .activeSessionPrompt
                self.launchFlowError = message
                return
            }
            self.startPreparedStream(replacement, message: "Launching \(replacement.title)...")
        }
    }

    func cancelVendorLaunch() {
        clearLaunchFlow()
        launchMessage = ""
    }

    func cancelActiveStreamLaunch() {
        guard activeStreamConfiguration != nil else { return }
        streamProgressGeneration += 1
        cancelActiveStreamAdPlayback()
        activeStreamConfiguration = nil
        activeStreamProgress = nil
        isActiveStreamLaunchOverlayVisible = false
        clearLaunchFlow()
        launchMessage = ""
        actionMessage = "Stream launch cancelled."
    }

    func showRecordings() {
        selectedMainPage = .recordings
        actionMessage = ""
        errorMessage = ""
    }

    func finishActiveStream(success: Bool, message: String, report: StreamReport?) {
        let finishedConfiguration = activeStreamConfiguration
        cancelActiveStreamAdPlayback()
        activeStreamConfiguration = nil
        activeStreamProgress = nil
        activeDiscordPresence = nil
        DiscordRichPresence.shared.update(.idle)
        isActiveStreamLaunchOverlayVisible = false
        streamProgressGeneration += 1
        clearLaunchFlow()
        launchMessage = ""
        if let finishedConfiguration {
            let session = CatalogPreviousGameSession(configuration: finishedConfiguration, success: success, message: message, report: report)
            previousGameSession = session
            session.save()
            if let report, report.durationSeconds > 0 {
                var statistics = playtimeStatistics
                statistics.record(title: session.title, durationSeconds: report.durationSeconds, endedAt: session.endedAt)
                playtimeStatistics = statistics
                statistics.save(accountIdentifier: Self.playtimeAccountIdentifier(account: account, session: self.session))
            }
        }
        if !success, !message.isEmpty {
            errorMessage = message
            return
        }
        if let report, !report.message.isEmpty {
            actionMessage = report.message
        }
    }

    func updateActiveStreamProgress(_ progress: StreamProgress) {
        activeStreamProgress = progress
        isActiveStreamLaunchOverlayVisible = true
        guard progress.isReady else { return }
        if let presence = activeDiscordPresence {
            DiscordRichPresence.shared.update(.streaming(presence))
        }
        let generation = streamProgressGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard generation == self.streamProgressGeneration else { return }
            self.isActiveStreamLaunchOverlayVisible = false
        }
    }

    func presentRequiredStreamAd(_ ad: StreamSessionAdPresentation) async throws -> Int {
        guard URL(string: ad.mediaUrl) != nil else {
            throw MacForceNowStreamSessionError.sessionAllocationFailed("Required ad media URL is invalid.")
        }
        activeStreamAdContinuation?.resume(throwing: CancellationError())
        activeStreamAdContinuation = nil
        activeStreamAdPlayback = CatalogStreamAdPlayback(
            id: ad.adId,
            title: ad.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Sponsored Message" : ad.title,
            mediaUrl: ad.mediaUrl,
            durationMs: ad.durationMs
        )
        isActiveStreamLaunchOverlayVisible = true
        let title = activeStreamConfiguration?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        activeStreamProgress = StreamProgress(
            title: title?.isEmpty == false ? title ?? "GeForce NOW" : "GeForce NOW",
            message: "Playing sponsored message before your free-tier session continues...",
            steps: StreamLaunchStep.allCases.map(\.title),
            currentStepIndex: StreamLaunchStep.allocateCloudSession.rawValue,
            isReady: false,
            queuePosition: activeStreamProgress?.queuePosition
        )
        return try await withCheckedThrowingContinuation { continuation in
            activeStreamAdContinuation = continuation
        }
    }

    func finishRequiredStreamAdPlayback(watchedTimeInMs: Int) {
        guard let continuation = activeStreamAdContinuation else { return }
        activeStreamAdContinuation = nil
        activeStreamAdPlayback = nil
        continuation.resume(returning: max(0, watchedTimeInMs))
    }

    func failRequiredStreamAdPlayback(_ message: String) {
        guard let continuation = activeStreamAdContinuation else { return }
        activeStreamAdContinuation = nil
        activeStreamAdPlayback = nil
        continuation.resume(throwing: MacForceNowStreamSessionError.sessionAllocationFailed(message.isEmpty ? "Required ad playback failed." : message))
    }

    private func cancelActiveStreamAdPlayback() {
        activeStreamAdPlayback = nil
        guard let continuation = activeStreamAdContinuation else { return }
        activeStreamAdContinuation = nil
        continuation.resume(throwing: CancellationError())
    }

    private var launchToken: String {
        session.idToken.isEmpty ? session.accessToken : session.idToken
    }

    private func startPreparedStream(_ configuration: StreamLaunchConfiguration, message: String) {
        if activeDiscordPresence == nil {
            activeDiscordPresence = discordPresence(for: configuration)
        }
        launchFlowState = .startingStream
        launchFlowMessage = message.isEmpty ? "Starting GeForce NOW stream..." : message
        launchFlowError = ""
        streamProgressGeneration += 1
        isActiveStreamLaunchOverlayVisible = true
        activeStreamProgress = StreamProgress(title: configuration.title.isEmpty ? "GeForce NOW" : configuration.title, message: launchFlowMessage, steps: [], currentStepIndex: -1, isReady: false)
        activeStreamConfiguration = configuration
        clearLaunchFlow()
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription
    }

    private static func mediaConfiguration(from configuration: OPNStreamLaunchConfiguration, titleOverride: String = "", membershipTier: String = "") -> StreamLaunchConfiguration {
        let overrideTitle = titleOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        var metadata = configuration.metadata
        metadata.merge(OPNRemoteCoOpPreferencesStore.load().launchMetadata) { _, launchValue in launchValue }
        let tier = membershipTier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tier.isEmpty { metadata["membershipTier"] = tier }
        return StreamLaunchConfiguration(
            title: overrideTitle.isEmpty ? configuration.title : overrideTitle,
            applicationID: configuration.appId,
            accessToken: configuration.apiToken,
            accountLinked: configuration.accountLinked,
            selectedStore: configuration.selectedStore,
            resumeSessionID: configuration.resumeSessionId,
            resumeServer: configuration.resumeServer,
            metadata: metadata
        )
    }

    private func title(forActiveSession session: OPNActiveStreamSessionDescriptor) -> String {
        let fallback = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.appId > 0 else { return fallback.isEmpty ? "Current Stream" : fallback }
        let applicationID = String(session.appId)
        if let game = allKnownGames.first(where: { Self.game($0, matchesApplicationID: applicationID) }) {
            let title = game.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return fallback.isEmpty ? "Current Stream" : fallback
    }

    private func discordPresence(for game: OPNCatalogGameObject) -> DiscordGamePresence {
        DiscordGamePresence(title: game.title, artworkURL: DiscordArtwork.imageURL(for: game))
    }

    private func discordPresence(for configuration: StreamLaunchConfiguration) -> DiscordGamePresence {
        if let game = allKnownGames.first(where: { Self.game($0, matchesApplicationID: configuration.applicationID) }) {
            return discordPresence(for: game)
        }
        return DiscordGamePresence(title: configuration.title, artworkURL: nil)
    }

    private func presentSessionConflict(_ conflict: StreamSessionConflict, replacementConfiguration: StreamLaunchConfiguration) {
        let applicationID = conflict.applicationID.isEmpty ? replacementConfiguration.applicationID : conflict.applicationID
        let appID = Int(applicationID) ?? 0
        let unresolvedSession = OPNActiveStreamSessionDescriptor(
            sessionId: conflict.sessionID,
            appId: appID,
            serverIp: conflict.serverAddress,
            streamingBaseUrl: OPNStreamPreferences.loadSelectedStreamingBaseUrl(forGame: applicationID),
            title: "Current Stream"
        )
        let activeTitle = title(forActiveSession: unresolvedSession)
        activeLaunchSession = OPNActiveStreamSessionDescriptor(
            sessionId: conflict.sessionID,
            appId: appID,
            serverIp: conflict.serverAddress,
            streamingBaseUrl: unresolvedSession.streamingBaseUrl,
            title: activeTitle
        )
        activeSessionResumeConfiguration = conflict.isResumable
            ? StreamLaunchConfiguration(
                title: activeTitle,
                applicationID: applicationID,
                accessToken: replacementConfiguration.accessToken,
                accountLinked: true,
                selectedStore: "",
                resumeSessionID: conflict.sessionID,
                resumeServer: conflict.serverAddress,
                metadata: replacementConfiguration.metadata
            )
            : nil
        activeSessionReplacementConfiguration = replacementConfiguration
        launchFlowTitle = replacementConfiguration.title.isEmpty ? "GeForce NOW" : replacementConfiguration.title
        launchFlowMessage = conflict.isResumable
            ? "GeForce NOW reports an active session. Resume it or end it before launching \(launchFlowTitle)."
            : "GeForce NOW reports an active session that cannot be resumed. End it before launching \(launchFlowTitle)."
        launchFlowError = ""
        errorMessage = ""
        launchFlowState = .activeSessionPrompt
    }

    private func clearLaunchFlow() {
        launchFlowState = .idle
        launchFlowTitle = ""
        launchFlowMessage = ""
        launchFlowError = ""
        activeLaunchSession = nil
        activeSessionResumeConfiguration = nil
        activeSessionReplacementConfiguration = nil
        pendingLaunchGame = nil
        pendingLaunchVariantIndex = -1
    }

    nonisolated private static func launchRegionOptions(from regions: [OPNStreamRegionOption]) -> [OPNStreamRegionOption] {
        let measured = regions.filter { !$0.url.isEmpty }
        let bestLatency = measured.first?.latencyMs ?? -1
        return [OPNStreamRegionOption(name: "Automatic", url: "", latencyMs: bestLatency, automatic: true)] + measured
    }

    func openStoreForSelectedVariant() {
        guard let selectedGame else { return }
        let variantIndex = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: selectedGame)
        guard variantIndex >= 0, variantIndex < selectedGame.variants.count else { return }
        let variant = selectedGame.variants[variantIndex]
        if let url = URL(string: variant.storeUrl), !variant.storeUrl.isEmpty {
            NSWorkspace.shared.open(url)
            return
        }
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.resolveStoreURL(game: selectedGame, variantIndex: variantIndex) { success, storeURL, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                guard success, let url = URL(string: storeURL), !storeURL.isEmpty else {
                    self.errorMessage = error.isEmpty ? "No store URL is available for this game." : error
                    return
                }
                NSWorkspace.shared.open(url)
            }
        }
    }

    func shareSelectedGame() {
        guard let selectedGame else { return }
        let title = selectedGame.title.isEmpty ? "GeForce NOW game" : selectedGame.title
        let url = selectedGame.primaryStoreURL ?? URL(string: "https://play.geforcenow.com/")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString([title, url?.absoluteString].compactMap { $0 }.joined(separator: "\n"), forType: .string)
        actionMessage = "Copied share details."
    }

    func isFavorite(_ game: OPNCatalogGameObject) -> Bool {
        game.isFavorited || favoriteGameIdentities.contains(Self.identity(for: game))
    }

    func toggleFavoriteSelectedGame() {
        guard let selectedGame else { return }
        let appId = Self.favoriteAppId(for: selectedGame)
        let identity = Self.identity(for: selectedGame)
        guard !appId.isEmpty, !identity.isEmpty else { return }
        let previousGames = CatalogSendableValue(favoriteGames)
        let previousIdentities = favoriteGameIdentities
        let selfBox = CatalogWeakObject(self)
        if isFavorite(selectedGame) {
            favoriteGameIdentities.remove(identity)
            favoriteGames.removeAll { Self.identity(for: $0) == identity }
            updateGameFavoriteState(identity: identity, isFavorited: false)
            actionMessage = "Removing from favorites..."
            OPNGameServiceSwiftAdapter.removeFavoriteApp(appId) { success, error in
                Task { @MainActor in
                    guard let self = selfBox.value else { return }
                    if success {
                        self.actionMessage = "Removed from favorites."
                        self.loadFavorites()
                        self.refreshShowAllIfFavoritesFiltered()
                    } else {
                        self.favoriteGames = previousGames.value
                        self.favoriteGameIdentities = previousIdentities
                        self.updateGameFavoriteState(identity: identity, isFavorited: true)
                        if self.refreshAuthIfNeeded(error: error) { return }
                        self.errorMessage = error.isEmpty ? "Unable to remove this game from favorites." : error
                    }
                }
            }
        } else {
            favoriteGameIdentities.insert(identity)
            updateGameFavoriteState(identity: identity, isFavorited: true)
            let favoriteSnapshot = Self.snapshotObject(for: selectedGame)
            favoriteSnapshot.isFavorited = true
            favoriteGames.insert(favoriteSnapshot, at: 0)
            actionMessage = "Adding to favorites..."
            OPNGameServiceSwiftAdapter.addFavoriteApp(appId) { success, error in
                Task { @MainActor in
                    guard let self = selfBox.value else { return }
                    if success {
                        self.actionMessage = "Added to favorites."
                        self.loadFavorites()
                        self.refreshShowAllIfFavoritesFiltered()
                    } else {
                        self.favoriteGames = previousGames.value
                        self.favoriteGameIdentities = previousIdentities
                        self.updateGameFavoriteState(identity: identity, isFavorited: false)
                        if self.refreshAuthIfNeeded(error: error) { return }
                        self.errorMessage = error.isEmpty ? "Unable to add this game to favorites." : error
                    }
                }
            }
        }
    }

    /// The Show All grid is a server browse, so a favorite that was just added/removed only leaves
    /// the grid after a fresh browse. Cached pages would otherwise keep showing the stale set.
    private func refreshShowAllIfFavoritesFiltered() {
        guard selectedShowAllSection != nil,
              selectedFilterIds.contains(OPNGameService.favoritesCatalogFilterId) else { return }
        browseCatalog(forceRefresh: true)
    }

    func changeSelectedGameStore() {
        guard let selectedGame, selectedGame.variants.count > 1 else {
            actionMessage = "No alternate store is available."
            return
        }
        ownershipFlowStage = .storeSelection
        ownershipFlowMessage = ""
        isStorePickerVisible = true
    }

    func closeStorePicker() {
        isStorePickerVisible = false
        ownershipFlowStage = .hidden
        ownershipFlowMessage = ""
    }

    func selectGameStoreVariant(at index: Int) {
        guard let selectedGame, index >= 0, index < selectedGame.variants.count else { return }
        focusGameStoreVariant(at: index)
        guard let option = platformOptions(for: selectedGame).first(where: { $0.variantIndex == index }) else { return }
        if option.isOwned {
            let variant = selectedGame.variants[index]
            selectOwnedVariant(variant)
            if ownershipFlowStage != .hidden { ownershipFlowStage = .success }
            ownershipFlowMessage = ""
        } else if option.hasAccess {
            if ownershipFlowStage != .hidden { ownershipFlowStage = .success }
            ownershipFlowMessage = ""
        } else if ownershipFlowStage != .hidden {
            ownershipFlowStage = .manualMark
            ownershipFlowMessage = ""
        }
        actionMessage = "Changed store to \(option.title)."
    }

    func focusGameStoreVariant(at index: Int) {
        guard let selectedGame, index >= 0, index < selectedGame.variants.count else { return }
        selectedVariantIndex = index
    }

    func cycleSelectedGameStore() {
        guard let selectedGame, selectedGame.variants.count > 1 else {
            actionMessage = "No alternate store is available."
            return
        }
        let currentIndex = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: selectedGame)
        let nextIndex = (max(currentIndex, 0) + 1) % selectedGame.variants.count
        selectGameStoreVariant(at: nextIndex)
    }

    func addShortcutForSelectedGame() {
        guard let selectedGame else { return }
        let title = selectedGame.title.isEmpty ? "GeForce NOW Game" : selectedGame.title
        do {
            let desktopURL = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let shortcutURL = desktopURL.appendingPathComponent(Self.safeShortcutFilename(title))
            let variantIndex = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: selectedGame)
            let variant = variantIndex >= 0 && variantIndex < selectedGame.variants.count ? selectedGame.variants[variantIndex] : nil
            let cmsId = Self.shortcutCMSId(for: selectedGame, variant: variant)
            let shortName = !selectedGame.shortName.isEmpty ? selectedGame.shortName : (!selectedGame.uuid.isEmpty ? selectedGame.uuid : selectedGame.id)
            guard !cmsId.isEmpty || !shortName.isEmpty else {
                errorMessage = "No GeForce NOW identifier is available for this game."
                return
            }
            let shortcut = GFNGameShortcut(sourceURL: nil, displayName: title, cmsId: cmsId, shortName: shortName, parentGameId: shortName)
            try shortcut.write(to: shortcutURL)
            Self.applyShortcutIcon(to: shortcutURL)
            actionMessage = "Added GeForce NOW shortcut to Desktop."
        } catch {
            errorMessage = "Unable to add shortcut: \(error.localizedDescription)"
        }
    }

    func markSelectedVariantOwned() {
        beginMarkSelectedVariantOwnedFlow()
    }

    func handleUnownedSelectedVariantPrimaryAction() {
        guard let selectedGame else { return }
        if selectedGame.isFreeToPlay {
            autoMarkFreeToPlaySelectedVariantThenLaunch()
        } else {
            markSelectedVariantOwned()
        }
    }

    private func autoMarkFreeToPlaySelectedVariantThenLaunch() {
        guard let selectedGame, let variant = selectedVariant(in: selectedGame), !variant.id.isEmpty else { return }
        let gameIdentity = Self.identity(for: selectedGame)
        let variantId = variant.id
        let variantIndex = selectedVariantIndex
        let title = selectedGame.title.isEmpty ? "game" : selectedGame.title
        let selfBox = CatalogWeakObject(self)
        setActionMessage("Adding free-to-play \(title) to library...")
        OPNGameServiceSwiftAdapter.addOwnedVariant(variantId) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.updateSelectedGameOwnership(gameIdentity: gameIdentity, variantId: variantId, inLibrary: true)
                    self.actionMessage = "Added to library. Launching \(title)..."
                    self.refreshCatalogAfterOwnershipChange()
                    if let game = self.selectedGame {
                        self.launch(game: game, variantIndex: variantIndex)
                    }
                } else {
                    if self.refreshAuthIfNeeded(error: error) { return }
                    self.errorMessage = error.isEmpty ? "Unable to add this free-to-play game to your library." : error
                    self.markSelectedVariantOwned()
                }
            }
        }
    }

    func beginMarkSelectedVariantOwnedFlow() {
        guard let selectedGame, selectedVariant(in: selectedGame) != nil else { return }
        ownershipFlowStage = .resyncing
        isStorePickerVisible = true
        ownershipFlowMessage = syncingOwnershipMessage(for: selectedGame)
        let stores = Self.uniqueNonEmpty(selectedGame.variants.map(\.appStore))
        let syncableStores = stores.filter { accountStatus(forStore: $0)?.hasAccountSyncingData == true }
        guard let store = syncableStores.first else {
            ownershipFlowStage = .storeSelection
            ownershipFlowMessage = ""
            return
        }
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.syncAccountProvider(store: store) { _, _ in
            Task { @MainActor in
                guard let self = selfBox.value, self.ownershipFlowStage == .resyncing else { return }
                self.loadAccountAndStores()
                self.loadLibrary()
                self.browseCatalog()
                self.ownershipFlowStage = .storeSelection
                self.ownershipFlowMessage = ""
            }
        }
    }

    func stopOwnershipResync() {
        ownershipFlowStage = .storeSelection
        ownershipFlowMessage = ""
    }

    func confirmSelectedVariantOwned() {
        guard let selectedGame, let variant = selectedVariant(in: selectedGame), !variant.id.isEmpty else { return }
        let gameIdentity = Self.identity(for: selectedGame)
        let variantId = variant.id
        let title = selectedGame.title.isEmpty ? "game" : selectedGame.title
        let selfBox = CatalogWeakObject(self)
        setActionMessage("Adding \(title) to library...")
        OPNGameServiceSwiftAdapter.addOwnedVariant(variantId) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.updateSelectedGameOwnership(gameIdentity: gameIdentity, variantId: variantId, inLibrary: true)
                    self.ownershipFlowStage = .success
                    self.ownershipFlowMessage = ""
                    self.actionMessage = "Added to library."
                    self.refreshCatalogAfterOwnershipChange()
                } else {
                    self.errorMessage = error.isEmpty ? "Unable to add this game to your library." : error
                }
            }
        }
    }

    func finishOwnershipFlow() {
        closeStorePicker()
    }

    func removeSelectedVariantOwned() {
        guard let selectedGame, let variant = selectedVariant(in: selectedGame), !variant.id.isEmpty else { return }
        let gameIdentity = Self.identity(for: selectedGame)
        let variantId = variant.id
        let title = selectedGame.title.isEmpty ? "game" : selectedGame.title
        let selfBox = CatalogWeakObject(self)
        setActionMessage("Removing \(title) from library...")
        OPNGameServiceSwiftAdapter.removeOwnedVariant(variantId) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.updateSelectedGameOwnership(gameIdentity: gameIdentity, variantId: variantId, inLibrary: false)
                    self.actionMessage = "Removed from library."
                    self.refreshCatalogAfterOwnershipChange()
                } else {
                    self.errorMessage = error.isEmpty ? "Unable to remove this game from your library." : error
                }
            }
        }
    }

    func selectOwnedVariant(_ variant: OPNCatalogGameVariantObject) {
        guard !variant.id.isEmpty else { return }
        let variantId = variant.id
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.selectOwnedVariant(variantId) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.selectedGame?.variants.forEach { $0.librarySelected = $0.id == variantId }
                    self.actionMessage = "Store selection updated."
                    self.refreshCatalogAfterOwnershipChange()
                } else {
                    self.errorMessage = error.isEmpty ? "Unable to update store selection." : error
                }
            }
        }
    }

    func syncSelectedStoreAccount() {
        guard let store = selectedPlatformOption(in: selectedGame)?.accountStore, !store.isEmpty else { return }
        syncStoreAccount(store)
    }

    func syncStoreAccount(_ store: String) {
        guard !store.isEmpty else { return }
        let selfBox = CatalogWeakObject(self)
        setActionMessage("Syncing \(displayName(forStore: store)) account...")
        OPNGameServiceSwiftAdapter.syncAccountProvider(store: store) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.actionMessage = "Store sync started."
                    self.loadAccountAndStores()
                    self.loadLibrary()
                    self.browseCatalog()
                } else {
                    self.errorMessage = error.isEmpty ? "Unable to sync this store account." : error
                }
            }
        }
    }

    func linkSelectedStoreAccount() {
        guard let store = selectedPlatformOption(in: selectedGame)?.accountStore, !store.isEmpty else { return }
        linkStoreAccount(store)
    }

    func linkStoreAccount(_ store: String) {
        guard !store.isEmpty else { return }
        let selfBox = CatalogWeakObject(self)
        setActionMessage("Opening \(displayName(forStore: store)) account linking...")
        OPNGameServiceSwiftAdapter.startAccountLinking(store: store) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.actionMessage = "Account linked."
                    self.loadAccountAndStores()
                    self.loadLibrary()
                    self.browseCatalog()
                } else {
                    self.errorMessage = error.isEmpty ? "Unable to link this store account." : error
                }
            }
        }
    }

    func selectedVariant(in game: OPNCatalogGameObject?) -> OPNCatalogGameVariantObject? {
        guard let game else { return nil }
        let index = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: game)
        guard index >= 0, index < game.variants.count else { return nil }
        return game.variants[index]
    }

    func selectedPlatformOption(in game: OPNCatalogGameObject?) -> CatalogPlatformOption? {
        let options = platformOptions(for: game)
        return options.first(where: { $0.isSelected }) ?? options.first
    }

    func selectedPlatformHasAccess(in game: OPNCatalogGameObject?) -> Bool {
        selectedPlatformOption(in: game)?.hasAccess == true
    }

    func platformOptions(for game: OPNCatalogGameObject?) -> [CatalogPlatformOption] {
        guard let game else { return [] }
        let selectedIndex = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: game)
        return game.variants.enumerated().map { index, variant in
            let subscriptionIds = Self.visibleSubscriptionIds(for: variant)
            let subscriptionDefinition = subscriptionDefinition(for: subscriptionIds)
            let accountStore = subscriptionDefinition?.primaryStore.isEmpty == false ? subscriptionDefinition?.primaryStore ?? "" : variant.appStore
            let account = accountStatus(forStore: accountStore)
            let storeDefinition = storeDefinition(forStore: accountStore)
            let isOwned = Self.variantIsOwned(variant, in: game)
            let hasSubscriptionEntitlement = subscriptionIds.contains { accountHasSubscription($0) }
            let isUnavailable = Self.variantIsUnavailable(variant)
            let isSubscription = !subscriptionIds.isEmpty
            let title = displayName(forVariant: variant)
            let iconURL = iconURL(forVariant: variant)
            let canLink = account == nil && storeDefinition?.isAccountLinkingSupported == true
            let canSync = account?.hasAccountSyncingData == true
            return CatalogPlatformOption(
                id: variant.id.isEmpty ? "\(index)-\(variant.appStore)-\(title)" : variant.id,
                variantIndex: index,
                variant: variant,
                title: title,
                iconURL: iconURL,
                store: variant.appStore,
                subscriptionIds: subscriptionIds,
                primaryStore: accountStore,
                isSubscription: isSubscription,
                isOwned: isOwned,
                hasSubscriptionEntitlement: hasSubscriptionEntitlement,
                hasAccess: isOwned || hasSubscriptionEntitlement,
                isSelected: selectedIndex == index,
                isUnavailable: isUnavailable,
                canLink: canLink,
                canSync: canSync,
                accountDisplayName: account?.userDisplayName ?? "",
                status: platformStatusLabel(isOwned: isOwned, hasSubscriptionEntitlement: hasSubscriptionEntitlement, isUnavailable: isUnavailable, isSubscription: isSubscription, account: account, canLink: canLink, canSync: canSync)
            )
        }
    }

    func displayName(forStore store: String) -> String {
        if let definition = storeDefinitions.first(where: { $0.store.caseInsensitiveCompare(store) == .orderedSame }), !definition.label.isEmpty {
            return definition.label
        }
        return store.isEmpty ? "Store" : store.uppercased()
    }

    func displayName(forSubscription subscription: String) -> String {
        if let definition = subscriptionDefinitions.first(where: { $0.subscription.caseInsensitiveCompare(subscription) == .orderedSame }), !definition.label.isEmpty {
            return definition.label
        }
        return subscription.isEmpty ? "Subscription" : subscription.replacingOccurrences(of: "_", with: " ").capitalized
    }

    func iconURL(forSubscription subscription: String) -> String {
        subscriptionDefinitions.first { $0.subscription.caseInsensitiveCompare(subscription) == .orderedSame }?.logoURL ?? ""
    }

    func displayName(forVariant variant: OPNCatalogGameVariantObject) -> String {
        let subscriptionNames = Self.visibleSubscriptionIds(for: variant).map { displayName(forSubscription: $0) }
        if !subscriptionNames.isEmpty { return subscriptionNames.joined(separator: " / ") }
        if !variant.appStoreLabel.isEmpty { return variant.appStoreLabel }
        return variant.appStore.isEmpty ? "GeForce NOW" : displayName(forStore: variant.appStore)
    }

    func iconURL(forVariant variant: OPNCatalogGameVariantObject) -> String {
        let subscription = Self.visibleSubscriptionIds(for: variant).first ?? ""
        let subscriptionIconURL = iconURL(forSubscription: subscription)
        if !subscriptionIconURL.isEmpty { return subscriptionIconURL }
        return variant.appStoreSmallImageUrl
    }

    func accountStatus(forStore store: String) -> CatalogStoreAccount? {
        accountStores.first { $0.store.caseInsensitiveCompare(store) == .orderedSame }
    }

    private func accountHasSubscription(_ subscription: String) -> Bool {
        accountSubscriptions.contains { $0.caseInsensitiveCompare(subscription) == .orderedSame }
    }

    private func storeDefinition(forStore store: String) -> CatalogStoreDefinition? {
        storeDefinitions.first { $0.store.caseInsensitiveCompare(store) == .orderedSame }
    }

    private func subscriptionDefinition(for subscriptionIds: [String]) -> CatalogSubscriptionDefinition? {
        for subscription in subscriptionIds {
            if let definition = subscriptionDefinitions.first(where: { $0.subscription.caseInsensitiveCompare(subscription) == .orderedSame }) {
                return definition
            }
        }
        return nil
    }

    private func platformStatusLabel(isOwned: Bool, hasSubscriptionEntitlement: Bool, isUnavailable: Bool, isSubscription: Bool, account: CatalogStoreAccount?, canLink: Bool, canSync: Bool) -> String {
        if isOwned { return "Owned" }
        if hasSubscriptionEntitlement { return "Subscribed" }
        if isUnavailable { return "Game not found" }
        if canSync { return "Sync available" }
        if account?.hasAccountLinkingData == true { return "Connected" }
        if canLink { return "Connect" }
        if isSubscription { return "Subscription required" }
        return ""
    }

    var streamingQualityProfileAllowsCustomization: Bool {
        streamProfile.allowsStreamingCustomization
    }

    private func canEditStreamingQualitySettings() -> Bool {
        streamingQualityProfileAllowsCustomization
    }

    func setAspectIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveAspectIndex(index)
        loadSettingsPreferences()
    }

    func setResolutionIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveResolutionIndex(index)
        loadSettingsPreferences()
    }

    func setFpsIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveFpsIndex(index)
        loadSettingsPreferences()
    }

    func setCodecIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveCodecIndex(index)
        loadSettingsPreferences()
    }

    func setBitrateIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveBitrateIndex(index)
        loadSettingsPreferences()
    }

    func setColorQualityIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveColorQualityIndex(index)
        loadSettingsPreferences()
    }

    func setNVSTTransportEnabled(_ enabled: Bool) {
        OPNStreamPreferences.saveNVSTTransportEnabled(enabled)
        actionMessage = enabled ? "Native/NVST stream transport selected." : "WebRTC stream transport selected."
        loadSettingsPreferences()
    }

    func setStreamingQualityProfileIndex(_ index: Int) {
        OPNStreamPreferences.saveStreamingQualityProfileIndex(index)
        loadSettingsPreferences()
    }

    func setCloudGsyncEnabled(_ enabled: Bool) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveCloudGsyncEnabled(enabled)
        loadSettingsPreferences()
    }

    func setFallbackToLogicalResolution(_ enabled: Bool) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveFallbackToLogicalResolution(enabled)
        loadSettingsPreferences()
    }

    func setHudStreamingModeIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveHudStreamingModeIndex(index)
        loadSettingsPreferences()
    }

    func setSDRColorSpaceIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveSDRColorSpaceIndex(index)
        loadSettingsPreferences()
    }

    func setHDRColorSpaceIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveHDRColorSpaceIndex(index)
        loadSettingsPreferences()
    }

    func setPrefilterModeIndex(_ index: Int) {
        OPNStreamPreferences.savePrefilterModeIndex(index)
        loadSettingsPreferences()
    }

    func setPrefilterSharpness(_ value: Double) {
        OPNStreamPreferences.savePrefilterSharpness(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setPrefilterDenoise(_ value: Double) {
        OPNStreamPreferences.savePrefilterDenoise(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setUpscalingModeIndex(_ index: Int) {
        OPNStreamPreferences.saveUpscalingModeIndex(index)
        loadSettingsPreferences()
    }

    func setUpscalingSharpness(_ value: Double) {
        OPNStreamPreferences.saveUpscalingSharpness(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setUpscalingDenoise(_ value: Double) {
        OPNStreamPreferences.saveUpscalingDenoise(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setPillarboxFillModeIndex(_ index: Int) {
        OPNStreamPreferences.savePillarboxFillModeIndex(index)
        loadSettingsPreferences()
    }

    func setPillarboxFillColor(_ hex: String) {
        OPNStreamPreferences.savePillarboxFillColor(hex)
        loadSettingsPreferences()
    }

    func setPillarboxFillDim(_ value: Double) {
        OPNStreamPreferences.savePillarboxFillDim(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setL4SEnabled(_ enabled: Bool) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveL4SEnabled(enabled)
        loadSettingsPreferences()
    }

    func setHDREnabled(_ enabled: Bool) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveHDREnabled(enabled)
        loadSettingsPreferences()
    }

    func setPowerSaverEnabled(_ enabled: Bool) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.savePowerSaverEnabled(enabled)
        loadSettingsPreferences()
    }

    func setSuppressInputWhenInactive(_ enabled: Bool) {
        OPNStreamPreferences.saveSuppressInputWhenInactive(enabled)
        loadSettingsPreferences()
    }

    func setDirectMouseInputEnabled(_ enabled: Bool) {
        OPNStreamPreferences.saveDirectMouseInputEnabled(enabled)
        loadSettingsPreferences()
    }

    func setAntiAFKMouseMovementEnabled(_ enabled: Bool) {
        OPNStreamPreferences.saveAntiAFKMouseMovementEnabled(enabled)
        actionMessage = enabled ? "Anti-AFK mouse movement enabled." : "Anti-AFK mouse movement disabled."
        loadSettingsPreferences()
    }

    func setRemoteCoOpEnabled(_ enabled: Bool) {
        OPNRemoteCoOpPreferencesStore.setEnabled(enabled)
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        actionMessage = enabled ? "Remote Co-Op enabled. Reserved guest slots apply to newly launched streams." : "Remote Co-Op disabled."
        loadSettingsPreferences()
    }

    func setRemoteCoOpAlphaOptedIn(_ optedIn: Bool) {
        OPNRemoteCoOpPreferencesStore.setAlphaOptedIn(optedIn)
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        actionMessage = optedIn ? "Remote Co-Op alpha access enabled. Configure Remote Co-Op from Gameplay settings." : "Remote Co-Op alpha access disabled. Remote Co-Op settings are hidden."
        loadSettingsPreferences()
    }

    func setRemoteCoOpReservedGuestSlots(_ index: Int) {
        OPNRemoteCoOpPreferencesStore.setReservedGuestSlots(index)
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        actionMessage = index > 0 ? "Remote Co-Op will reserve \(index) guest controller slot(s) on newly launched streams." : "Remote Co-Op guest controller slots disabled."
        loadSettingsPreferences()
    }

    func setRemoteCoOpTransportModeIndex(_ index: Int) {
        let modes = OPNRemoteCoOpTransportMode.allCases
        guard modes.indices.contains(index) else { return }
        OPNRemoteCoOpPreferencesStore.setTransportMode(modes[index])
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        loadSettingsPreferences()
    }

    func setRemoteCoOpQualityPresetIndex(_ index: Int) {
        let presets = OPNRemoteCoOpQualityPreset.allCases
        guard presets.indices.contains(index) else { return }
        OPNRemoteCoOpPreferencesStore.setQualityPreset(presets[index])
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        loadSettingsPreferences()
    }

    func setRemoteCoOpLatencyModeIndex(_ index: Int) {
        let modes = OPNRemoteCoOpLatencyMode.allCases
        guard modes.indices.contains(index) else { return }
        OPNRemoteCoOpPreferencesStore.setLatencyMode(modes[index])
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        loadSettingsPreferences()
    }

    func setRemoteCoOpRequireHostApproval(_ required: Bool) {
        OPNRemoteCoOpPreferencesStore.setRequireHostApproval(required)
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        loadSettingsPreferences()
    }

    func setRemoteCoOpSignalingServerURL(_ url: String) {
        OPNRemoteCoOpPreferencesStore.setSignalingServerURL(url)
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        loadSettingsPreferences()
    }

    func setRemoteCoOpGuestJoinBaseURL(_ url: String) {
        OPNRemoteCoOpPreferencesStore.setGuestJoinBaseURL(url)
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        loadSettingsPreferences()
    }

    func setRemoteCoOpHideGuestInviteDetails(_ hidden: Bool) {
        OPNRemoteCoOpPreferencesStore.setHideGuestInviteDetails(hidden)
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        actionMessage = hidden ? "Remote Co-Op guest invites will hide game details." : "Remote Co-Op guest invites will show game details."
        loadSettingsPreferences()
    }

    func setPreventDisplaySleepWhileStreaming(_ enabled: Bool) {
        OPNStreamPreferences.savePreventDisplaySleepWhileStreaming(enabled)
        actionMessage = enabled ? "Display sleep prevention enabled for active streams." : "Display sleep prevention disabled for active streams."
        loadSettingsPreferences()
    }

    func setRecordingVideoBitrateMbps(_ value: Double) {
        OPNStreamPreferences.saveRecordingVideoBitrateMbps(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setRecordingAudioBitrateKbps(_ value: Double) {
        OPNStreamPreferences.saveRecordingAudioBitrateKbps(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setRecordingEnhancedVideoEnabled(_ enabled: Bool) {
        OPNStreamPreferences.saveRecordingEnhancedVideoEnabled(enabled)
        loadSettingsPreferences()
    }

    func setGameVolume(_ value: Double) {
        OPNStreamPreferences.saveGameVolume(value)
        loadSettingsPreferences()
    }

    func setMicrophoneVolume(_ value: Double) {
        OPNStreamPreferences.saveMicrophoneVolume(value)
        loadSettingsPreferences()
    }

    func setMicrophoneMode(_ mode: String) {
        OPNStreamPreferences.saveMicrophoneMode(mode)
        loadSettingsPreferences()
    }

    func setMicrophoneDeviceId(_ deviceId: String) {
        OPNStreamPreferences.saveMicrophoneDeviceId(deviceId)
        loadSettingsPreferences()
    }

    func restoreStreamingProfileDefaults() {
        OPNStreamPreferences.restoreStreamingProfileDefaults()
        actionMessage = "Streaming profile defaults restored."
        loadSettingsPreferences()
    }

    func refreshCatalogImageCacheSummary() {
        Task { @MainActor in
            let statistics = await CatalogImageCache.shared.statistics()
            catalogImageCacheSummary = Self.formattedCacheSummary(statistics)
        }
    }

    func clearCatalogImageCache() {
        Task { @MainActor in
            let cleared = await CatalogImageCache.shared.clear()
            actionMessage = cleared ? "Catalog image cache cleared." : "Unable to clear catalog image cache."
            refreshCatalogImageCacheSummary()
        }
    }

    func optimizedImageURL(_ rawValue: String, width: Int) -> URL? {
        guard !rawValue.isEmpty else { return nil }
        let optimized = OPNGameServiceSwiftAdapter.optimizeImageURL(rawValue, width: width)
        return URL(string: optimized.isEmpty ? rawValue : optimized)
    }

    private static func formattedCacheSummary(_ statistics: CatalogImageCacheStatistics) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        let bytes = formatter.string(fromByteCount: Int64(statistics.totalBytes))
        let entryLabel = statistics.entryCount == 1 ? "entry" : "entries"
        return "\(bytes) / \(statistics.entryCount) \(entryLabel)"
    }

    private func loadPanels() {
        isLoadingPanels = true
        errorMessage = ""
        configureCatalogService()
        let panelStartTime = CFAbsoluteTimeGetCurrent()
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.fetchMarqueePanelObjects { success, panels, error in
            let panelBox = CatalogSendableValue(panels)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - panelStartTime) * 1000)
                    MacForceNowLog.info(.catalog, "Marquee panels loaded elapsed=\(elapsedMs)ms sections=\(panelBox.value.flatMap(\.sections).count)")
                    self.marqueePanels = panelBox.value
                    self.schedulePatchingPollIfNeeded()
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.isLoadingPanels = false
                } else if self.errorMessage.isEmpty {
                    self.errorMessage = error
                }
            }
        }
        OPNGameServiceSwiftAdapter.fetchMainPanelObjects { success, panels, error in
            let panelBox = CatalogSendableValue(panels)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                self.isLoadingPanels = false
                if success {
                    let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - panelStartTime) * 1000)
                    let gameCount = panelBox.value.flatMap(\.sections).flatMap(\.games).count
                    MacForceNowLog.info(.catalog, "Main panels loaded elapsed=\(elapsedMs)ms games=\(gameCount)")
                    self.mainPanels = panelBox.value
                    self.schedulePatchingPollIfNeeded()
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.isLoadingPanels = false
                } else if self.errorMessage.isEmpty {
                    self.errorMessage = error.isEmpty ? "Unable to load GeForce NOW home panels." : error
                }
            }
        }
    }

    private func loadLibrary() {
        configureCatalogService()
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.fetchLibraryGameObjects { success, games, error in
            let gamesBox = CatalogSendableValue(games)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.libraryGames = gamesBox.value
                    self.schedulePatchingPollIfNeeded()
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.libraryGames = []
                }
            }
        }
    }

    private func loadFavorites() {
        configureCatalogService()
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.fetchFavoriteGameObjects { success, games, error in
            let gamesBox = CatalogSendableValue(games)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.updateFavoriteGames(gamesBox.value)
                    self.schedulePatchingPollIfNeeded()
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.updateFavoriteGames([])
                }
            }
        }
    }

    private func updateFavoriteGames(_ games: [OPNCatalogGameObject]) {
        var uniqueGames: [OPNCatalogGameObject] = []
        var identities = Set<String>()
        for game in games {
            let identity = Self.identity(for: game)
            guard !identity.isEmpty, identities.insert(identity).inserted else { continue }
            game.isFavorited = true
            uniqueGames.append(game)
        }
        favoriteGames = uniqueGames
        favoriteGameIdentities = identities
    }

    private func loadAccountAndStores() {
        configureCatalogService()
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.fetchUserAccountDictionary { success, account, error in
            let accountBox = CatalogSendableValue(account)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.accountStores = Self.parseStoreAccounts(accountBox.value)
                    self.accountSubscriptions = Self.parseAccountSubscriptions(accountBox.value)
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.accountStores = []
                    self.accountSubscriptions = []
                }
            }
        }
        OPNGameServiceSwiftAdapter.fetchStoreDefinitionDictionaries { success, definitions, _ in
            let definitionsBox = CatalogSendableValue(definitions)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success { self.storeDefinitions = definitionsBox.value.map(Self.parseStoreDefinition) }
            }
        }
        OPNGameServiceSwiftAdapter.fetchSubscriptionDefinitionDictionaries { success, definitions, _ in
            let definitionsBox = CatalogSendableValue(definitions)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success { self.subscriptionDefinitions = definitionsBox.value.map(Self.parseSubscriptionDefinition) }
            }
        }
        let userId = session.userId.isEmpty ? account.userId : session.userId
        guard !userId.isEmpty else {
            subscriptionStatus = .unavailable
            return
        }
        OPNGameServiceSwiftAdapter.fetchSubscriptionInfo(userId: userId) { success, subscription, error in
            let subscriptionBox = CatalogSendableValue(subscription)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    let subscription = subscriptionBox.value
                    self.subscriptionStatus = CatalogSubscriptionStatus(subscription: subscription)
                    let membershipTier = subscription.membershipTier.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !membershipTier.isEmpty {
                        self.account.membershipTier = membershipTier
                    }
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.subscriptionStatus = .unavailable
                }
            }
        }
    }

    private func loadSettingsPreferences() {
        settingsPreferencesGeneration += 1
        let generation = settingsPreferencesGeneration
        settingsPreferencesTask?.cancel()
        settingsPreferencesTask = Task.detached(priority: .userInitiated) {
            let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
            let profile = OPNStreamPreferences.effectiveProfile(OPNStreamPreferences.loadProfile(), capabilities: capabilities)
            let snapshot = CatalogSettingsPreferencesSnapshot(
                capabilities: capabilities,
                profile: profile,
                remoteCoOpPreferences: OPNRemoteCoOpPreferencesStore.load(),
                selectedRegionUrl: OPNStreamPreferences.loadSelectedRegionUrl(),
                regionOptions: Self.launchRegionOptions(from: OPNStreamPreferences.loadCachedRegions()),
                microphoneDeviceOptions: OPNStreamPreferences.loadMicrophoneDeviceOptions()
            )
            await MainActor.run { [weak self] in
                guard let self, generation == self.settingsPreferencesGeneration, !Task.isCancelled else { return }
                self.streamCapabilities = snapshot.capabilities
                self.streamProfile = snapshot.profile
                self.remoteCoOpPreferences = snapshot.remoteCoOpPreferences
                self.selectedSettingsRegionUrl = snapshot.selectedRegionUrl
                self.settingsRegionOptions = snapshot.regionOptions
                self.unavailableSettingsRegionUrl = snapshot.selectedRegionUrl.isEmpty || snapshot.regionOptions.contains(where: { $0.url == snapshot.selectedRegionUrl }) ? "" : snapshot.selectedRegionUrl
                self.microphoneDeviceOptions = snapshot.microphoneDeviceOptions
                self.settingsPreferencesTask = nil
            }
        }
    }

    private func refreshCatalogAfterOwnershipChange() {
        loadLibrary()
        browseCatalog()
        if let selectedGame {
            let selectedIdentity = Self.identity(for: selectedGame)
            let refreshedGame = (libraryGames + catalogGames).first { Self.identity(for: $0) == selectedIdentity }
            if let refreshedGame { selectGame(refreshedGame) }
        }
    }

    private func schedulePatchingPollIfNeeded(immediate: Bool = true) {
        let patchingAppIds = patchingPollAppIds()
        guard !patchingAppIds.isEmpty else {
            deinitHandle.patchingPollTask?.cancel()
            deinitHandle.patchingPollTask = nil
            return
        }
        guard deinitHandle.patchingPollTask == nil else {
            if immediate {
                Task { @MainActor [weak self] in await self?.refreshPatchingStatuses() }
            }
            return
        }
        deinitHandle.patchingPollTask = Task { @MainActor [weak self] in
            if immediate { await self?.refreshPatchingStatuses() }
            while let self, !Task.isCancelled {
                let delaySeconds = UInt64(Int.random(in: 30...60))
                try? await Task.sleep(for: .seconds(delaySeconds))
                guard !Task.isCancelled else { return }
                await self.refreshPatchingStatuses()
                if self.patchingPollAppIds().isEmpty {
                    self.deinitHandle.patchingPollTask = nil
                    return
                }
            }
        }
    }

    private func refreshPatchingStatuses() async {
        guard !patchingPollInFlight else { return }
        let appIds = patchingPollAppIds()
        guard !appIds.isEmpty else { return }
        patchingPollInFlight = true
        defer { patchingPollInFlight = false }
        let libraryResult = await fetchLibraryPatchStatuses()
        let targetedResult = await fetchAppPatchStatuses(appIds: appIds)
        var mergedStatuses = libraryResult.statuses
        Self.mergePatchStatuses(targetedResult.statuses, into: &mergedStatuses)
        if !mergedStatuses.isEmpty {
            applyPatchingStatuses(mergedStatuses)
        }
        for error in [libraryResult.error, targetedResult.error] where !error.isEmpty {
            if refreshAuthIfNeeded(error: error) { return }
            MacForceNowLog.warning(.catalog, "App patch status poll failed: \(error)")
        }
    }

    private func fetchLibraryPatchStatuses() async -> (statuses: [String: OPNAppPatchStatus], error: String) {
        await withCheckedContinuation { continuation in
            OPNGameServiceSwiftAdapter.fetchLibraryPatchStatuses { success, statuses, error in
                continuation.resume(returning: (success ? statuses : [:], success ? "" : error))
            }
        }
    }

    private func fetchAppPatchStatuses(appIds: [String]) async -> (statuses: [String: OPNAppPatchStatus], error: String) {
        await withCheckedContinuation { continuation in
            OPNGameServiceSwiftAdapter.fetchAppPatchStatuses(appIds: appIds) { success, statuses, error in
                continuation.resume(returning: (success ? statuses : [:], success ? "" : error))
            }
        }
    }

    private func patchingPollAppIds() -> [String] {
        let ids = allKnownGames.filter(Self.isPatching).compactMap(Self.patchStatusAppId)
        return Array(Set(ids)).sorted()
    }

    private func applyPatchingStatuses(_ statuses: [String: OPNAppPatchStatus]) {
        guard !statuses.isEmpty else { return }
        updatePatchingStatuses(in: &catalogGames, statuses: statuses)
        updatePatchingStatuses(in: &libraryGames, statuses: statuses)
        updatePatchingStatuses(in: &favoriteGames, statuses: statuses)
        updatePatchingStatuses(in: &marqueePanels, statuses: statuses)
        updatePatchingStatuses(in: &mainPanels, statuses: statuses)
        if let selectedGame, let status = Self.patchStatus(for: selectedGame, statuses: statuses) {
            applyPatchingStatus(status, to: selectedGame)
        }
        launchQueuedPatchingGameIfReady()
    }

    private func updatePatchingStatuses(in games: inout [OPNCatalogGameObject], statuses: [String: OPNAppPatchStatus]) {
        for game in games {
            guard let status = Self.patchStatus(for: game, statuses: statuses) else { continue }
            applyPatchingStatus(status, to: game)
        }
    }

    private func updatePatchingStatuses(in panels: inout [OPNCatalogPanelObject], statuses: [String: OPNAppPatchStatus]) {
        for panel in panels {
            for section in panel.sections {
                for game in section.games {
                    guard let status = Self.patchStatus(for: game, statuses: statuses) else { continue }
                    applyPatchingStatus(status, to: game)
                }
            }
        }
    }

    private func applyPatchingStatus(_ status: OPNAppPatchStatus, to game: OPNCatalogGameObject) {
        for variant in game.variants {
            if let isPatching = status.variantPatchingById[variant.id] {
                variant.isPatching = isPatching
                variant.patchStatusPrimaryText = isPatching ? status.primaryTextByVariantId[variant.id] ?? variant.patchStatusPrimaryText : ""
                variant.patchStatusSecondaryText = isPatching ? status.secondaryTextByVariantId[variant.id] ?? variant.patchStatusSecondaryText : ""
            }
        }
        game.isPatching = status.isPatching || game.variants.contains { $0.isPatching }
        game.patchStatusPrimaryText = game.isPatching ? game.variants.first { !$0.patchStatusPrimaryText.isEmpty }?.patchStatusPrimaryText ?? status.primaryTextByVariantId.values.first ?? "Patching" : ""
        game.patchStatusSecondaryText = game.isPatching ? game.variants.first { !$0.patchStatusSecondaryText.isEmpty }?.patchStatusSecondaryText ?? status.secondaryTextByVariantId.values.first ?? "" : ""
    }

    private static func mergePatchStatuses(_ source: [String: OPNAppPatchStatus], into target: inout [String: OPNAppPatchStatus]) {
        for (appId, status) in source {
            guard var existing = target[appId] else {
                target[appId] = status
                continue
            }
            existing.isPatching = existing.isPatching || status.isPatching
            existing.variantPatchingById.merge(status.variantPatchingById) { _, new in new }
            existing.primaryTextByVariantId.merge(status.primaryTextByVariantId) { _, new in new }
            existing.secondaryTextByVariantId.merge(status.secondaryTextByVariantId) { _, new in new }
            target[appId] = existing
        }
    }

    private func launchQueuedPatchingGameIfReady() {
        guard !queuedPatchingLaunchIdentity.isEmpty else { return }
        guard let game = allKnownGames.first(where: { Self.identity(for: $0) == queuedPatchingLaunchIdentity }) else { return }
        guard !Self.isPatching(game) else { return }
        let variantIndex = queuedPatchingLaunchVariantIndex
        let title = queuedPatchingLaunchGameTitle.isEmpty ? (game.title.isEmpty ? "GeForce NOW" : game.title) : queuedPatchingLaunchGameTitle
        queuedPatchingLaunchIdentity = ""
        queuedPatchingLaunchVariantIndex = -1
        queuedPatchingLaunchGameTitle = ""
        actionMessage = "Patching finished. Launching \(title)..."
        selectGame(game)
        launch(game: game, variantIndex: variantIndex)
    }

    private func selectedVariantIndexIfMatching(_ game: OPNCatalogGameObject) -> Int? {
        guard let selectedGame, Self.identity(for: selectedGame) == Self.identity(for: game) else { return nil }
        return selectedVariantIndex
    }

    private func updateSelectedGameOwnership(gameIdentity: String, variantId: String, inLibrary: Bool) {
        guard let selectedGame, Self.identity(for: selectedGame) == gameIdentity else { return }
        for variant in selectedGame.variants where variant.id == variantId {
            variant.inLibrary = inLibrary
            variant.librarySelected = inLibrary
        }
        selectedGame.isInLibrary = Self.gameHasOwnedVariant(selectedGame)
    }

    private func updateGameFavoriteState(identity: String, isFavorited: Bool) {
        guard !identity.isEmpty else { return }
        func update(_ games: [OPNCatalogGameObject]) {
            for game in games where Self.identity(for: game) == identity {
                game.isFavorited = isFavorited
            }
        }
        if selectedGame.map(Self.identity(for:)) == identity { selectedGame?.isFavorited = isFavorited }
        update(catalogGames)
        update(libraryGames)
        update(favoriteGames)
        update(marqueeGames)
        update(mainPanelGames)
        for games in fullSectionGames.values { update(games) }
    }

    private func setActionMessage(_ message: String) {
        actionMessage = message
        errorMessage = ""
    }

    nonisolated static func titleGroupingKey(for game: OPNCatalogGameObject) -> String {
        let normalized = game.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? identity(for: game) : normalized
    }

    nonisolated static func dedupedByTitleGrouping(_ games: [OPNCatalogGameObject]) -> [OPNCatalogGameObject] {
        var indexByKey: [String: Int] = [:]
        var result: [OPNCatalogGameObject] = []
        result.reserveCapacity(games.count)
        for game in games {
            let key = titleGroupingKey(for: game)
            if let existingIndex = indexByKey[key] {
                if preferredSKU(game, over: result[existingIndex]) {
                    result[existingIndex] = game
                }
            } else {
                indexByKey[key] = result.count
                result.append(game)
            }
        }
        return result
    }

    nonisolated private static func preferredSKU(_ candidate: OPNCatalogGameObject, over current: OPNCatalogGameObject) -> Bool {
        if candidate.isInLibrary != current.isInLibrary { return candidate.isInLibrary }
        return candidate.variants.count > current.variants.count
    }

    private static func isPatching(_ game: OPNCatalogGameObject) -> Bool {
        game.isPatching || game.variants.contains { $0.isPatching }
    }

    private static func patchStatusAppId(_ game: OPNCatalogGameObject) -> String? {
        for value in [game.uuid, game.id, game.launchAppId] where !value.isEmpty { return value }
        return nil
    }

    private static func patchStatus(for game: OPNCatalogGameObject, statuses: [String: OPNAppPatchStatus]) -> OPNAppPatchStatus? {
        for key in [game.uuid, game.id, game.launchAppId] where !key.isEmpty {
            if let status = statuses[key] { return status }
        }
        return nil
    }

    private static func hasMarqueeHeroArtwork(_ game: OPNCatalogGameObject) -> Bool {
        for key in ["MARQUEE_HERO_IMAGE", "marquee_hero_image"] {
            if game.imageUrlsByType[key]?.contains(where: { !$0.isEmpty }) == true { return true }
        }
        return false
    }

    private func syncingOwnershipMessage(for game: OPNCatalogGameObject) -> String {
        let stores = Self.uniqueNonEmpty(game.variants.map { displayName(forStore: $0.appStore) })
        if stores.isEmpty { return "Syncing connected game libraries..." }
        if stores.count == 1 { return "Syncing \(stores[0]) game library..." }
        return "Syncing \(stores.dropLast().joined(separator: ", ")) and \(stores.last ?? "") game libraries..."
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { continue }
            result.append(trimmed)
        }
        return result
    }

    private func matchingGame(for shortcut: GFNGameShortcut, in games: [OPNCatalogGameObject]) -> OPNCatalogGameObject? {
        let identifiers = Set([shortcut.cmsId, shortcut.shortName, shortcut.parentGameId].map { $0.lowercased() }.filter { !$0.isEmpty })
        if !identifiers.isEmpty {
            for game in games where game.matchesGFNShortcutIdentifiers(identifiers) { return game }
        }
        let title = shortcut.lookupTitle
        guard !title.isEmpty else { return nil }
        return games.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    private func variantIndex(for shortcut: GFNGameShortcut, in game: OPNCatalogGameObject) -> Int {
        if !shortcut.cmsId.isEmpty, let index = game.variants.firstIndex(where: { $0.id.caseInsensitiveCompare(shortcut.cmsId) == .orderedSame }) {
            return index
        }
        return Self.preferredVariantIndex(for: game)
    }

    private func resolveSelectedStoreURL(completion: @escaping @Sendable (URL?) -> Void) {
        guard let selectedGame else {
            completion(nil)
            return
        }
        let variantIndex = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: selectedGame)
        if variantIndex >= 0, variantIndex < selectedGame.variants.count {
            let variant = selectedGame.variants[variantIndex]
            if let url = URL(string: variant.storeUrl), !variant.storeUrl.isEmpty {
                completion(url)
                return
            }
        }
        if let url = selectedGame.primaryStoreURL {
            completion(url)
            return
        }
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.resolveStoreURL(game: selectedGame, variantIndex: max(variantIndex, 0)) { success, storeURL, _ in
            Task { @MainActor in
                guard selfBox.value != nil else { return }
                completion(success ? URL(string: storeURL) : nil)
            }
        }
    }

    private func configureCatalogService() {
        let userId = session.userId.isEmpty ? account.userId : session.userId
        OPNGameServiceSwiftAdapter.configureCatalogSession(accessToken: session.accessToken, idToken: session.idToken, userId: userId)
    }

    private func refreshAuthIfNeeded(error: String) -> Bool {
        guard error.contains("401"), !authRefreshInFlight else { return false }
        authRefreshInFlight = true
        isLoading = false
        isLoadingPanels = false
        errorMessage = "Refreshing NVIDIA session..."
        Task { [weak self] in
            guard let self else { return }
            let refreshed = await onRefreshAuth()
            authRefreshInFlight = false
            guard refreshed else {
                errorMessage = "Unable to refresh your NVIDIA session. Sign out and sign in again."
                return
            }
            errorMessage = ""
            loadCatalogDataAfterProviderConfiguration(forceCatalogRefresh: true)
        }
        return true
    }

    nonisolated static func identity(for game: OPNCatalogGameObject) -> String {
        if !game.id.isEmpty { return game.id }
        if !game.uuid.isEmpty { return game.uuid }
        if !game.launchAppId.isEmpty { return game.launchAppId }
        return game.title
    }

    private static func favoriteAppId(for game: OPNCatalogGameObject) -> String {
        if !game.id.isEmpty { return game.id }
        return game.uuid
    }

    private static func game(_ game: OPNCatalogGameObject, matchesApplicationID applicationID: String) -> Bool {
        guard !applicationID.isEmpty else { return false }
        for value in [game.id, game.uuid, game.launchAppId, game.shortName] where value == applicationID {
            return true
        }
        return game.variants.contains { $0.id == applicationID }
    }

    static func looseIdentityMatches(_ lhs: OPNCatalogGameObject, _ rhs: OPNCatalogGameObject) -> Bool {
        let lhsIdentity = identity(for: lhs)
        let rhsIdentity = identity(for: rhs)
        if !lhsIdentity.isEmpty, !rhsIdentity.isEmpty, lhsIdentity == rhsIdentity { return true }
        return !lhs.title.isEmpty && lhs.title.caseInsensitiveCompare(rhs.title) == .orderedSame
    }

    private static func playtimeAccountIdentifier(account: LoginAccount, session: LoginSession) -> String {
        for value in [session.userId, account.userId, account.externalUserId, account.email] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed.lowercased() }
        }
        return "default"
    }

    private static func snapshotObject(for game: OPNCatalogGameObject) -> OPNCatalogGameObject {
        OPNCatalogGameObject(game: game.swiftValue)
    }

    private static func safeShortcutFilename(_ title: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/").union(.newlines).union(.controlCharacters)
        let sanitized = title.components(separatedBy: invalidCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = sanitized.isEmpty ? "GeForce NOW Game" : sanitized
        return "\(baseName) on GeForce NOW.gfnpc"
    }

    private static func applyShortcutIcon(to url: URL) {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSWorkspace.shared.setIcon(icon, forFile: url.path)
    }

    private func requestSelectedGameReveal(for game: OPNCatalogGameObject, sectionId: String) {
        selectedGameRevealSequence += 1
        selectedGameRevealRequest = CatalogGameRevealRequest(sectionId: sectionId, gameIdentity: Self.identity(for: game), sequence: selectedGameRevealSequence)
    }

    private static func shortcutCMSId(for game: OPNCatalogGameObject, variant: OPNCatalogGameVariantObject?) -> String {
        for value in [variant?.id ?? "", game.launchAppId, game.id] where isPositiveInteger(value) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let variantId = game.variants.map(\.id).first(where: isPositiveInteger) {
            return variantId.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let variantId = variant?.id, !variantId.isEmpty { return variantId }
        return identity(for: game)
    }

    private static func launchGame(from shortcut: GFNGameShortcut, title: String) -> OPNCatalogGameObject? {
        let cmsId = shortcut.cmsId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPositiveInteger(cmsId) else { return nil }
        let game = OPNCatalogGameObject()
        game.id = shortcut.parentGameId.isEmpty ? cmsId : shortcut.parentGameId
        game.uuid = game.id
        game.launchAppId = cmsId
        game.title = title.isEmpty ? "GeForce NOW" : title
        game.shortName = shortcut.shortName
        game.isInLibrary = true
        let variant = OPNCatalogGameVariantObject()
        variant.id = cmsId
        variant.inLibrary = true
        variant.librarySelected = true
        game.variants = [variant]
        return game
    }

    private static func isPositiveInteger(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let intValue = Int(trimmed) else { return false }
        return intValue > 0
    }

    private func resolveGameForDetails(_ game: OPNCatalogGameObject) -> OPNCatalogGameObject {
        resolveGameForDetails(game, preferredSectionId: "")
    }

    private func resolveGameForDetails(_ game: OPNCatalogGameObject, preferredSectionId: String) -> OPNCatalogGameObject {
        if !preferredSectionId.isEmpty,
           let section = catalogSections.first(where: { $0.id == preferredSectionId }),
           let sectionGame = section.games.first(where: { Self.looseIdentityMatches($0, game) }) {
            return sectionGame
        }
        for section in catalogSections {
            if let sectionGame = section.games.first(where: { Self.looseIdentityMatches($0, game) }) {
                return sectionGame
            }
        }
        return game
    }

    static func preferredVariantIndex(for game: OPNCatalogGameObject) -> Int {
        if let index = game.variants.firstIndex(where: { $0.librarySelected }) { return index }
        if let index = game.variants.firstIndex(where: { $0.inLibrary }) { return index }
        return game.variants.isEmpty ? -1 : 0
    }

    static func variantIsOwned(_ variant: OPNCatalogGameVariantObject, in game: OPNCatalogGameObject) -> Bool {
        variant.inLibrary || variant.librarySelected || OPNGameRemediation.gameServiceStatusOwnedForLaunch(variant.serviceStatus) || (game.variants.count == 1 && game.isInLibrary)
    }

    static func gameHasOwnedVariant(_ game: OPNCatalogGameObject) -> Bool {
        game.variants.contains { $0.inLibrary || $0.librarySelected || OPNGameRemediation.gameServiceStatusOwnedForLaunch($0.serviceStatus) }
    }

    static func visibleSubscriptionIds(for variant: OPNCatalogGameVariantObject) -> [String] {
        uniqueNonEmpty([variant.librarySubscription] + variant.subscriptionIds).filter { $0.caseInsensitiveCompare("NONE") != .orderedSame }
    }

    static func variantIsUnavailable(_ variant: OPNCatalogGameVariantObject) -> Bool {
        let status = variant.serviceStatus.lowercased()
        return status.contains("not") || status.contains("unavailable") || status.contains("unsupported")
    }

    private static func parseAccountSubscriptions(_ account: NSDictionary) -> [String] {
        uniqueNonEmpty(account["subscriptions"] as? [String] ?? [])
    }

    private static func parseStoreAccounts(_ account: NSDictionary) -> [CatalogStoreAccount] {
        guard let stores = account["stores"] as? [NSDictionary] else { return [] }
        return stores.map { store in
            let syncing = store["syncing"] as? NSDictionary
            return CatalogStoreAccount(
                store: store["store"] as? String ?? "",
                userDisplayName: store["userDisplayName"] as? String ?? "",
                expiresIn: store["expiresIn"] as? String ?? "",
                userIdentifier: store["userIdentifier"] as? String ?? "",
                hasAccountLinkingData: store["hasAccountLinkingData"] as? Bool ?? false,
                hasAccountSyncingData: store["hasAccountSyncingData"] as? Bool ?? false,
                totalSyncedGames: syncing?["totalNumberOfSyncedGfnGames"] as? Int ?? 0,
                syncState: syncing?["syncState"] as? String ?? "",
                syncDate: syncing?["syncDate"] as? String ?? ""
            )
        }
    }

    private static func parseStoreDefinition(_ definition: NSDictionary) -> CatalogStoreDefinition {
        let metadata = definition["accountLinkingMetadata"] as? NSDictionary
        return CatalogStoreDefinition(
            store: definition["store"] as? String ?? "",
            label: definition["label"] as? String ?? "",
            smallImageUrl: definition["smallImageUrl"] as? String ?? "",
            isAccountLinkingSupported: metadata?["isSupported"] as? Bool ?? false,
            isAccountLinkingRequired: metadata?["isRequired"] as? Bool ?? false,
            accountLinkingLabel: metadata?["label"] as? String ?? ""
        )
    }

    private static func parseSubscriptionDefinition(_ definition: NSDictionary) -> CatalogSubscriptionDefinition {
        CatalogSubscriptionDefinition(
            subscription: definition["subscription"] as? String ?? "",
            label: definition["label"] as? String ?? "",
            logoURL: definition["logoURL"] as? String ?? "",
            primaryStore: definition["primaryStore"] as? String ?? ""
        )
    }
}

struct CatalogSectionModel: Identifiable, Equatable {
    enum Kind: Equatable {
        case catalog
        case library
        case favorites
        case panel
    }

    let id: String
    let title: String
    let games: [OPNCatalogGameObject]
    let kind: Kind
    var tiles: [OPNCatalogPanelTileObject] = []
    var seeMoreFilterIds: [String] = []
    var seeMoreSortId = ""
    var seeMoreTitle = ""

    init(
        id: String,
        title: String,
        games: [OPNCatalogGameObject],
        kind: Kind,
        tiles: [OPNCatalogPanelTileObject] = [],
        seeMoreFilterIds: [String] = [],
        seeMoreSortId: String = "",
        seeMoreTitle: String = ""
    ) {
        self.id = id
        self.title = title
        self.games = CatalogViewModel.dedupedByTitleGrouping(games)
        self.kind = kind
        self.tiles = tiles
        self.seeMoreFilterIds = seeMoreFilterIds
        self.seeMoreSortId = seeMoreSortId
        self.seeMoreTitle = seeMoreTitle
    }

    var canLoadFullList: Bool {
        if kind == .library || kind == .favorites { return true }
        return !seeMoreFilterIds.isEmpty || !seeMoreSortId.isEmpty
    }

    func visibleGames(expanded: Bool) -> [OPNCatalogGameObject] {
        expanded ? games : Array(games.prefix(18))
    }
}

struct CatalogGameRevealRequest: Equatable {
    let sectionId: String
    let gameIdentity: String
    let sequence: Int
}

struct CatalogStoreAccount: Identifiable, Equatable {
    var id: String { store }
    let store: String
    let userDisplayName: String
    let expiresIn: String
    let userIdentifier: String
    let hasAccountLinkingData: Bool
    let hasAccountSyncingData: Bool
    let totalSyncedGames: Int
    let syncState: String
    let syncDate: String
}

struct CatalogStoreDefinition: Identifiable, Equatable {
    var id: String { store }
    let store: String
    let label: String
    let smallImageUrl: String
    let isAccountLinkingSupported: Bool
    let isAccountLinkingRequired: Bool
    let accountLinkingLabel: String
}

struct CatalogSubscriptionDefinition: Identifiable, Equatable {
    var id: String { subscription }
    let subscription: String
    let label: String
    let logoURL: String
    let primaryStore: String
}

struct CatalogPlatformOption: Identifiable {
    let id: String
    let variantIndex: Int
    let variant: OPNCatalogGameVariantObject
    let title: String
    let iconURL: String
    let store: String
    let subscriptionIds: [String]
    let primaryStore: String
    let isSubscription: Bool
    let isOwned: Bool
    let hasSubscriptionEntitlement: Bool
    let hasAccess: Bool
    let isSelected: Bool
    let isUnavailable: Bool
    let canLink: Bool
    let canSync: Bool
    let accountDisplayName: String
    let status: String

    var accountStore: String { primaryStore.isEmpty ? store : primaryStore }
}

struct CatalogPlaytimeStatistics: Codable, Equatable {
    private static let storagePrefix = "MacForceNow.Catalog.PlaytimeStatistics"

    static let empty = CatalogPlaytimeStatistics(totalSeconds: 0, sessionCount: 0, lastSessionSeconds: 0, longestSessionSeconds: 0, lastPlayedTitle: "", lastPlayedAt: nil)

    private(set) var totalSeconds: Double
    private(set) var sessionCount: Int
    private(set) var lastSessionSeconds: Double
    private(set) var longestSessionSeconds: Double
    private(set) var lastPlayedTitle: String
    private(set) var lastPlayedAt: Date?

    var averageSessionSeconds: Double {
        sessionCount > 0 ? totalSeconds / Double(sessionCount) : 0
    }

    mutating func record(title: String, durationSeconds: Double, endedAt: Date) {
        let duration = max(0, durationSeconds.isFinite ? durationSeconds : 0)
        guard duration > 0 else { return }
        totalSeconds += duration
        sessionCount += 1
        lastSessionSeconds = duration
        longestSessionSeconds = max(longestSessionSeconds, duration)
        lastPlayedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        lastPlayedAt = endedAt
    }

    static func load(accountIdentifier: String) -> CatalogPlaytimeStatistics {
        guard let data = UserDefaults.standard.data(forKey: storageKey(accountIdentifier: accountIdentifier)),
              let statistics = try? JSONDecoder().decode(CatalogPlaytimeStatistics.self, from: data) else {
            return .empty
        }
        return statistics
    }

    func save(accountIdentifier: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey(accountIdentifier: accountIdentifier))
    }

    private static func storageKey(accountIdentifier: String) -> String {
        "\(storagePrefix).\(accountIdentifier)"
    }
}

struct CatalogSubscriptionStatus: Equatable {
    static let unavailable = CatalogSubscriptionStatus(membershipTier: "Performance", remainingPlaytimeText: "Unavailable", usageText: "Playtime refresh pending", isAvailable: false)

    let membershipTier: String
    let remainingPlaytimeText: String
    let usageText: String
    let isAvailable: Bool

    var isFreeTierAccount: Bool {
        OPNCatalogGameObject.isFreeMembershipTier(membershipTier)
    }

    init(membershipTier: String, remainingPlaytimeText: String, usageText: String, isAvailable: Bool) {
        self.membershipTier = membershipTier.isEmpty ? "Performance" : membershipTier
        self.remainingPlaytimeText = remainingPlaytimeText
        self.usageText = usageText
        self.isAvailable = isAvailable
    }

    init(subscription: OPNParsedSubscriptionInfo) {
        let tier = subscription.membershipTier.isEmpty ? "Performance" : subscription.membershipTier.capitalized
        if subscription.isUnlimited {
            self.init(membershipTier: tier, remainingPlaytimeText: "Unlimited", usageText: "No monthly playtime cap", isAvailable: true)
            return
        }
        let remaining = Self.hoursText(subscription.remainingHours)
        let used = Self.hoursText(subscription.usedHours)
        let total = Self.hoursText(subscription.totalHours)
        let usage = subscription.totalHours > 0 ? "\(used) used of \(total)" : "\(used) used"
        self.init(membershipTier: tier, remainingPlaytimeText: "\(remaining) left", usageText: usage, isAvailable: true)
    }

    private static func hoursText(_ hours: Double) -> String {
        let totalMinutes = max(0, Int((hours * 60).rounded()))
        let wholeHours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if wholeHours > 0, minutes > 0 { return "\(wholeHours)h \(minutes)m" }
        if wholeHours > 0 { return "\(wholeHours)h" }
        return "\(minutes)m"
    }
}

struct CatalogPreviousGameSession: Codable, Equatable {
    private static let storageKey = "MacForceNow.Catalog.PreviousGameSession"

    let title: String
    let appId: String
    let store: String
    let result: String
    let endedAt: Date
    let launchTime: String
    let averageLatency: String
    let averageBitrate: String
    let droppedFrames: String

    init(configuration: StreamLaunchConfiguration, success: Bool, message: String, report: StreamReport?) {
        let reportTitle = report?.title ?? ""
        title = reportTitle.isEmpty ? (configuration.title.isEmpty ? "GeForce NOW" : configuration.title) : reportTitle
        appId = configuration.applicationID
        store = configuration.selectedStore
        if success {
            result = report?.success == false ? "Ended with warnings" : "Ended normally"
        } else {
            result = message.isEmpty ? "Ended with error" : message
        }
        endedAt = Date()
        launchTime = report.map { Self.durationText(seconds: $0.durationSeconds) } ?? "Unknown"
        averageLatency = report?.metadata["averageLatency"] ?? "Unknown"
        averageBitrate = report?.metadata["averageBitrate"] ?? "Unknown"
        droppedFrames = report?.metadata["droppedFrames"] ?? "Unknown"
    }

    private static func durationText(seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    static func load() -> CatalogPreviousGameSession? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(CatalogPreviousGameSession.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

private extension OPNCatalogPanelSectionObject {
    func sectionIdentity(fallbackPanelId: String) -> String {
        if !id.isEmpty { return id }
        let titlePart = title.isEmpty ? "section" : title
        return [fallbackPanelId, titlePart].filter { !$0.isEmpty }.joined(separator: ":")
    }
}

private extension OPNCatalogGameObject {
    var primaryStoreURL: URL? {
        variants.compactMap { URL(string: $0.storeUrl) }.first
    }
}

private final class CatalogViewModelDeinitHandle: @unchecked Sendable {
    var patchingPollTask: Task<Void, Never>?
}
