//  CatalogViewModel.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import Foundation
import Observation

extension OPNCatalogGameObject {
    func matchesGFNShortcutIdentifiers(_ identifiers: Set<String>) -> Bool {
        for value in [id, uuid, launchAppId, shortName] where identifiers.contains(value.lowercased()) {
            return true
        }
        return variants.contains { identifiers.contains($0.id.lowercased()) }
    }
}

@MainActor
final class CatalogDeliveryGate {
    private var delivered = false

    func claimFirstDelivery() -> Bool {
        if delivered { return false }
        delivered = true
        return true
    }
}

struct CatalogSettingsPreferencesSnapshot: Sendable {
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
    case network
    case connections
    case controller
    case remoteCoOp
    case general
    case experimental
    case about

    var id: String { rawValue }

    /// Remote Co-Op is alpha-gated, so its tab only exists once the alpha has been opted into in
    /// Experimental. This mirrors how its settings card used to be hidden inside Gameplay - the
    /// feature became a tab, not more discoverable.
    /// Every tab. Remote Co-Op used to be filtered out until its alpha was opted into; it ships to
    /// everyone now, so nothing is conditional. Kept as a function so the tab bar and pad navigation
    /// still read the same list - iterating `allCases` in one place and a filtered list in the other
    /// is what let the pad land on a tab that was not drawn.
    static func visibleCases() -> [CatalogSettingsGroup] {
        allCases
    }

    var title: String {
        switch self {
        case .account: return "Account"
        case .streaming: return "Streaming"
        case .network: return "Network"
        case .connections: return "Connections"
        case .controller: return "Controller"
        case .remoteCoOp: return "Remote Co-Op"
        case .general: return "General"
        case .experimental: return "Experimental"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .account: return "Membership, profile, and current NVIDIA session details."
        case .streaming: return "Tune streaming quality, server location, and MetalFX upscaling."
        case .network: return "Route GeForce NOW requests through a proxy. Stream traffic always connects directly."
        case .connections: return "Manage store accounts and Twitch broadcast settings."
        case .controller: return "Steam Controller support, permissions, input testing, and mapping."
        case .remoteCoOp: return "Invite a friend into your session from a browser. Alpha."
        case .general: return "Interface mode and display scale."
        case .experimental: return "Unfinished and in-development features. Expect rough edges."
        case .about: return "OpenNOW Mac runtime, system capability, and service identifiers."
        }
    }

    var icon: String {
        switch self {
        case .account: return "person.crop.circle.fill"
        case .streaming: return "play.tv.fill"
        case .network: return "network"
        case .connections: return "link"
        case .controller: return "gamecontroller.fill"
        case .remoteCoOp: return "person.2.fill"
        case .general: return "gearshape.2.fill"
        case .experimental: return "flask.fill"
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
    /// The hero and the rails come from two different queries. `isLoadingPanels` only follows the
    /// main (rails) one, so the hero needs its own flag - otherwise the rails paint at the top of
    /// the page and the hero shoves them down whenever the marquee query finishes second.
    var isLoadingMarquee = false
    /// The deferred library/favorites fetches run after the main grid. These hold a skeleton rail
    /// in place while they do, so the rails do not silently pop in when they land.
    var isLoadingLibrary = false { didSet { cachedCatalogSections = nil } }
    var isLoadingFavorites = false { didSet { cachedCatalogSections = nil } }
    var catalogEndCursor = ""
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
    var activeHomeSession: OPNActiveSessionObject?
    var activeHomeSessionTitle: String {
        guard let session = activeHomeSession else { return "" }
        return resolveActiveHomeSessionTitle(for: session)
    }
    var streamProfile = OPNStreamPreferenceProfile()
    var remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
    /// Whether a Cloudflare relay key is stored. The token itself is never published - only whether
    /// one exists, so the UI can say so without holding it.
    var remoteCoOpRelayCredentials = OPNRemoteCoOpTURNKeyStore.load()
    var remoteCoOpAblyKey = OPNRemoteCoOpAblyKeyStore.load()
    var remoteCoOpAblyKeyMessage = ""
    var remoteCoOpTURNSetupInFlight = false
    var remoteCoOpRelayTestInFlight = false
    var remoteCoOpRelayTestMessage = ""
    var remoteCoOpRelayTestPassed = false
    var remoteCoOpTURNSetupMessage = ""
    var remoteCoOpTURNUsage: OPNRemoteCoOpTURNUsage?
    var remoteCoOpTURNUsageMessage = ""
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
    var fullSectionGames: [String: [OPNCatalogGameObject]] = [:]
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
    var browseGeneration = 0
    var appliedMarqueePanelsFingerprint = 0
    var appliedMainPanelsFingerprint = 0
    private var secondaryCatalogLoadsTask: Task<Void, Never>?
    var authRefreshInFlight = false
    private var searchDebounceTask: Task<Void, Never>?
    var pendingLaunchGame: OPNCatalogGameObject?
    var pendingLaunchVariantIndex = -1
    var activeDiscordPresence: DiscordGamePresence?
    var activeSessionResumeConfiguration: StreamLaunchConfiguration?
    var activeSessionReplacementConfiguration: StreamLaunchConfiguration?
    var isCheckingHomeSession = false
    var streamProgressGeneration = 0
    var activeStreamAdContinuation: CheckedContinuation<Int, Error>?
    var settingsPreferencesGeneration = 0
    var selectedGameRevealSequence = 0
    var settingsPreferencesTask: Task<Void, Never>?
    var patchingPollInFlight = false
    var queuedPatchingLaunchIdentity = ""
    var queuedPatchingLaunchVariantIndex = -1
    let gameService: any CatalogGameServing
    let launchBridge: any GameLaunchBridging
    let imageCache: any CatalogImageServing
    let discordPresence: any DiscordPresenceServing
    let systemIntegration: any SystemIntegrationServing
    let deinitHandle = CatalogViewModelDeinitHandle()

    private var hasStarted = false

    init(account: LoginAccount, session: LoginSession, gameService: any CatalogGameServing = OPNGameService.shared, launchBridge: any GameLaunchBridging = OPNGameLaunchBridge.shared, imageCache: any CatalogImageServing = CatalogImageCache.shared, discordPresence: any DiscordPresenceServing = DiscordRichPresence.shared, systemIntegration: any SystemIntegrationServing = AppKitSystemIntegration(), onRefreshAuth: @escaping () async -> Bool) {
        self.account = account
        self.session = session
        self.gameService = gameService
        self.launchBridge = launchBridge
        self.imageCache = imageCache
        self.discordPresence = discordPresence
        self.systemIntegration = systemIntegration
        self.onRefreshAuth = onRefreshAuth
    }

    /// Narrow door onto the image cache for `CatalogImagePrefetch`, which lives in its own file and
    /// therefore cannot see the private property.
    func prefetchImages(_ urls: [URL]) {
        imageCache.prefetch(urls)
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
    @ObservationIgnored var cachedMarqueeGames: [OPNCatalogGameObject]?
    @ObservationIgnored var cachedHeroRotationGames: [OPNCatalogGameObject]?
    @ObservationIgnored var cachedCatalogSections: [CatalogSectionModel]?

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

    var allKnownGames: [OPNCatalogGameObject] {
        marqueeGames + catalogGames + libraryGames + favoriteGames + mainPanelGames
    }

    var mainPanelGames: [OPNCatalogGameObject] {
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
        OpenNOWLog.info(.catalog, "Initial catalog load deferred until expired session refresh completes")
        Task { [weak self] in
            guard let self else { return }
            _ = await onRefreshAuth()
            loadCatalogDataAfterProviderConfiguration()
        }
    }

    func refresh() {
        // An explicit refresh must hit the network, not re-adopt the panels the
        // launch prefetch already handed over.
        CatalogLaunchPrefetch.shared.invalidate()
        loadCatalogDataAfterProviderConfiguration(forceCatalogRefresh: true)
    }

    func loadCatalogDataAfterProviderConfiguration(forceCatalogRefresh: Bool = false) {
        configureCatalogService()
        Task { await configureCatalogProviderEndpoint() }
        // Claim the library and favorites rail slots up front rather than when their (deferred)
        // fetches start. Setting them later meant the rails appeared mid-load and pushed
        // everything under them down the page. This has to run before `loadPanels()`, whose
        // prefetch replay can already deliver those lists and clear the flags again.
        if !isBrowseMode {
            if libraryGames.isEmpty { isLoadingLibrary = true }
            if favoriteGames.isEmpty { isLoadingFavorites = true }
        }
        loadPanels()
        loadSettingsPreferences()
        scheduleSecondaryCatalogLoads()
        if forceCatalogRefresh { browseCatalog(forceRefresh: true) }
    }

    // Library, favorites, account and active-session lookups render nothing on the
    // first frame, yet they share the control-plane session with the panel queries
    // and delay them when the whole burst starts at once. They wait for the home
    // rails to have data, or for a short grace period if the rails are slow.
    private func scheduleSecondaryCatalogLoads() {
        // `loadCatalogDataAfterProviderConfiguration` reserves the library and favorites rail slots
        // and this task's `loadLibrary()`/`loadFavorites()` are what release them again, so every
        // path that abandons this task must be one that immediately replaces it - otherwise those
        // rails hold a skeleton forever. The cancel below is the only cancellation site for exactly
        // that reason; a new one has to release the flags itself.
        secondaryCatalogLoadsTask?.cancel()
        secondaryCatalogLoadsTask = Task { [weak self] in
            for _ in 0..<Self.secondaryCatalogLoadPollCount {
                guard let self, !Task.isCancelled else { return }
                if !self.mainPanels.isEmpty { break }
                do {
                    try await Task.sleep(for: .milliseconds(Self.secondaryCatalogLoadPollMilliseconds))
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.loadLibrary()
            self.loadFavorites()
            self.loadAccountAndStores()
        }
        // Unlike the rest of this burst, the active-session lookup goes to the streaming host
        // rather than the catalog control plane, so it contends with nothing here. Waiting for the
        // panels only meant its banner landed after the page had painted and pushed it all down.
        checkActiveHomeSession()
    }

    // Short: a cold panel fetch can take seconds, and holding the library and
    // favorites rails that long is more visible to the user than the connection
    // contention it avoids. Cached panels release it almost immediately.
    private static let secondaryCatalogLoadPollCount = 10
    private static let secondaryCatalogLoadPollMilliseconds = 50

    private func configureCatalogProviderEndpoint() async {
        let providerIdpId = session.idpId.isEmpty ? account.providerIdpId : session.idpId
        guard !providerIdpId.isEmpty else { return }
        await withCheckedContinuation { continuation in
            gameService.fetchProviderInfo(idpId: providerIdpId) { success, _, endpoint, error in
                let message = success
                    ? "Configured provider endpoint provider=\(endpoint.loginProvider) idpId=\(providerIdpId)"
                    : "Provider endpoint lookup failed idpId=\(providerIdpId) error=\(error)"
                Task { @MainActor in
                    if success {
                        OpenNOWLog.info(.auth, message)
                    } else {
                        OpenNOWLog.warning(.auth, message)
                    }
                    continuation.resume()
                }
            }
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

}


extension OPNCatalogPanelSectionObject {
    func sectionIdentity(fallbackPanelId: String) -> String {
        if !id.isEmpty { return id }
        let titlePart = title.isEmpty ? "section" : title
        return [fallbackPanelId, titlePart].filter { !$0.isEmpty }.joined(separator: ":")
    }
}

extension OPNCatalogGameObject {
    var primaryStoreURL: URL? {
        variants.compactMap { URL(string: $0.storeUrl) }.first
    }
}

final class CatalogViewModelDeinitHandle: @unchecked Sendable {
    var patchingPollTask: Task<Void, Never>?
}
