//  CatalogViewModel.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import Combine
import Common
import Foundation
import OpenNOWGameServices
import WebRTCMedia

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

private struct CatalogSettingsPreferencesSnapshot: Sendable {
    let capabilities: OPNStreamDeviceCapabilities
    let profile: OPNStreamPreferenceProfile
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

@MainActor
enum CatalogMainPage: String, CaseIterable, Identifiable {
    case games
    case recordings
    case settings

    var id: String { rawValue }
}

@MainActor
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

@MainActor
enum CatalogSettingsPage: String, CaseIterable, Identifiable {
    case account
    case connections
    case gameplay
    case serverLocation
    case resolutionUpscaling
    case system
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "Account"
        case .connections: return "Connections"
        case .gameplay: return "Gameplay"
        case .serverLocation: return "Server Location"
        case .resolutionUpscaling: return "Resolution Upscaling"
        case .system: return "System"
        case .about: return "About"
        }
    }
}

@MainActor
final class CatalogViewModel: ObservableObject {
    @Published var selectedMainPage = CatalogMainPage.games
    @Published var selectedCatalogDestination = CatalogDestination.home
    @Published var selectedSettingsPage = CatalogSettingsPage.account
    @Published var searchQuery = ""
    @Published var selectedSortId = "last_played"
    @Published var selectedFilterIds: [String] = []
    @Published var isLoading = false
    @Published var isLoadingPanels = false
    @Published var errorMessage = ""
    @Published var launchMessage = ""
    @Published var actionMessage = ""
    @Published var marqueePanels: [OPNCatalogPanelObject] = []
    @Published var mainPanels: [OPNCatalogPanelObject] = []
    @Published var catalogGames: [OPNCatalogGameObject] = []
    @Published var libraryGames: [OPNCatalogGameObject] = []
    @Published var filterGroups: [OPNCatalogFilterGroupObject] = []
    @Published var sortOptions: [OPNCatalogSortOptionObject] = []
    @Published var totalCatalogCount = 0
    @Published var supportedCatalogCount = 0
    @Published var hasMoreCatalogResults = false
    @Published var expandedSectionIds: Set<String> = []
    @Published var accountStores: [CatalogStoreAccount] = []
    @Published var storeDefinitions: [CatalogStoreDefinition] = []
    @Published var selectedGame: OPNCatalogGameObject?
    @Published var selectedSectionId = ""
    @Published var selectedVariantIndex = -1
    @Published var activeStreamConfiguration: StreamLaunchConfiguration?
    @Published var activeStreamProgress: StreamProgress?
    @Published var isActiveStreamLaunchOverlayVisible = false
    @Published var launchFlowState = CatalogLaunchFlowState.idle
    @Published var launchFlowTitle = ""
    @Published var launchFlowMessage = ""
    @Published var launchFlowError = ""
    @Published var activeLaunchSession: OPNActiveStreamSessionDescriptor?
    @Published var streamProfile = OPNStreamPreferenceProfile()
    @Published var streamCapabilities = OPNStreamDeviceCapabilities()
    @Published var settingsRegionOptions: [OPNStreamRegionOption] = []
    @Published var selectedSettingsRegionUrl = ""
    @Published var isRefreshingSettingsRegions = false
    @Published var microphoneDeviceOptions: [OPNStreamMicrophoneDeviceOption] = []
    @Published var previousGameSession = CatalogPreviousGameSession.load()
    @Published var playtimeStatistics = CatalogPlaytimeStatistics.empty
    @Published var subscriptionStatus = CatalogSubscriptionStatus.unavailable
    @Published var favoriteGameIdentities: Set<String> = []
    @Published var favoriteGameSnapshots: [String: OPNCatalogGameObject] = [:]
    @Published var selectedGameRevealRequest: CatalogGameRevealRequest?
    @Published var catalogImageCacheSummary = "Calculating"
    @Published var isStorePickerVisible = false
    @Published var ownershipFlowStage = CatalogOwnershipFlowStage.hidden
    @Published var ownershipFlowMessage = ""

    let account: LoginAccount
    let session: LoginSession
    let onRefreshAuth: () -> Void

    private var hasLoaded = false
    private var browseGeneration = 0
    private var authRefreshInFlight = false
    private var cancellables = Set<AnyCancellable>()
    private var pendingLaunchGame: OPNCatalogGameObject?
    private var pendingLaunchVariantIndex = -1
    private var activeSessionResumeConfiguration: StreamLaunchConfiguration?
    private var activeSessionReplacementConfiguration: StreamLaunchConfiguration?
    private var streamProgressGeneration = 0
    private var settingsPreferencesGeneration = 0
    private var selectedGameRevealSequence = 0
    private var settingsPreferencesTask: Task<Void, Never>?

    init(account: LoginAccount, session: LoginSession, onRefreshAuth: @escaping () -> Void) {
        self.account = account
        self.session = session
        self.onRefreshAuth = onRefreshAuth
        let playtimeAccountIdentifier = Self.playtimeAccountIdentifier(account: account, session: session)
        let favoriteAccountIdentifiers = Self.favoriteAccountIdentifiers(account: account, session: session)
        playtimeStatistics = CatalogPlaytimeStatistics.load(accountIdentifier: playtimeAccountIdentifier)
        favoriteGameIdentities = Self.loadFavoriteGameIdentities(accountIdentifiers: favoriteAccountIdentifiers)
        favoriteGameSnapshots = Self.loadFavoriteGameSnapshots(accountIdentifiers: favoriteAccountIdentifiers)
        favoriteGameIdentities.formUnion(favoriteGameSnapshots.keys)
        $searchQuery
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.browseCatalog() }
            .store(in: &cancellables)
    }

    var marqueeGames: [OPNCatalogGameObject] {
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
        return games
    }

    var heroRotationGames: [OPNCatalogGameObject] {
        var games: [OPNCatalogGameObject] = []
        var seen = Set<String>()
        Self.appendUniqueHeroGames(from: marqueeGames, into: &games, seen: &seen)
        return games
    }

    var catalogSections: [CatalogSectionModel] {
        if selectedCatalogDestination == .library, !isBrowseMode {
            return libraryGames.isEmpty ? [] : [CatalogSectionModel(id: "my-library", title: "My Library", games: libraryGames, kind: .library)]
        }
        if selectedCatalogDestination == .favorites, !isBrowseMode {
            let games = favoriteGames
            return games.isEmpty ? [] : [CatalogSectionModel(id: "local-favorites", title: "My Favorites", games: games, kind: .panel)]
        }

        var sections: [CatalogSectionModel] = []
        var seenTitles = Set<String>()
        let localFavoriteGames = favoriteGames
        if !isBrowseMode, !localFavoriteGames.isEmpty {
            sections.append(CatalogSectionModel(id: "local-favorites", title: "My Favorites", games: localFavoriteGames, kind: .panel))
            seenTitles.insert("My Favorites")
        }
        for panel in mainPanels {
            for section in panel.sections where !section.games.isEmpty {
                let title = section.title.isEmpty ? panel.title : section.title
                let resolvedTitle = title.isEmpty ? "Featured Games" : title
                guard !seenTitles.contains(resolvedTitle) else { continue }
                seenTitles.insert(resolvedTitle)
                sections.append(CatalogSectionModel(id: section.sectionIdentity(fallbackPanelId: panel.id), title: resolvedTitle, games: section.games, kind: .panel))
            }
        }
        if isBrowseMode, !catalogGames.isEmpty {
            sections.insert(CatalogSectionModel(id: "catalog-results", title: "Search Results", games: catalogGames, kind: .catalog), at: 0)
        }
        if !isBrowseMode, !libraryGames.isEmpty {
            let insertionIndex = sections.isEmpty ? 0 : min(sections.count, 1)
            sections.insert(CatalogSectionModel(id: "my-library", title: "My Library", games: libraryGames, kind: .library), at: insertionIndex)
        }
        return Array(sections.prefix(10))
    }

    var isBrowseMode: Bool {
        !searchQuery.trimmed.isEmpty || !selectedFilterIds.isEmpty
    }

    var selectedSortLabel: String {
        sortOptions.first { $0.id == selectedSortId }?.label ?? "Recently Played"
    }

    var visibleFilterGroups: [OPNCatalogFilterGroupObject] {
        filterGroups.filter { !$0.options.isEmpty }
    }

    var favoriteGames: [OPNCatalogGameObject] {
        guard !favoriteGameIdentities.isEmpty else { return [] }
        var games: [OPNCatalogGameObject] = []
        var seen = Set<String>()
        for game in allKnownGames {
            let identity = Self.identity(for: game)
            guard favoriteGameIdentities.contains(identity), !seen.contains(identity) else { continue }
            seen.insert(identity)
            games.append(game)
        }
        for identity in favoriteGameIdentities.sorted() where !seen.contains(identity) {
            guard let snapshot = favoriteGameSnapshots[identity] else { continue }
            seen.insert(identity)
            games.append(snapshot)
        }
        return games
    }

    private var allKnownGames: [OPNCatalogGameObject] {
        marqueeGames + catalogGames + libraryGames + mainPanelGames
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
        configureCatalogService()
        loadPanels()
        loadLibrary()
        loadAccountAndStores()
        loadSettingsPreferences()
        browseCatalog()
    }

    func refresh() {
        configureCatalogService()
        loadPanels()
        loadLibrary()
        loadAccountAndStores()
        loadSettingsPreferences()
        browseCatalog()
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
    }

    func showSettings(_ page: CatalogSettingsPage = .account) {
        selectedMainPage = .settings
        selectedSettingsPage = page
        loadSettingsPreferences()
    }

    func browseCatalog() {
        browseGeneration += 1
        let generation = browseGeneration
        isLoading = true
        errorMessage = ""
        configureCatalogService()
        let query = searchQuery.trimmed
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.browseCatalogObject(
            searchQuery: query,
            sortId: selectedSortId.isEmpty ? "last_played" : selectedSortId,
            filterIds: selectedFilterIds,
            fetchCount: 96
        ) { success, result, error in
            let resultBox = CatalogSendableValue(result)
            Task { @MainActor in
                guard let self = selfBox.value, generation == self.browseGeneration else { return }
                self.isLoading = false
                guard success else {
                    if self.refreshAuthIfNeeded(error: error) { return }
                    self.errorMessage = error.isEmpty ? "Unable to browse the GeForce NOW catalog." : error
                    return
                }
                let browseResult = resultBox.value
                self.catalogGames = browseResult.games
                self.totalCatalogCount = browseResult.totalCount
                self.supportedCatalogCount = browseResult.numberSupported
                self.hasMoreCatalogResults = browseResult.hasNextPage
                self.filterGroups = browseResult.filterGroups
                self.sortOptions = browseResult.sortOptions
                if !browseResult.selectedSortId.isEmpty { self.selectedSortId = browseResult.selectedSortId }
                self.selectedFilterIds = browseResult.selectedFilterIds
                self.refreshFavoriteSnapshotsFromKnownGames()
            }
        }
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

    func openGameShortcut(_ shortcut: GFNGameShortcut) {
        configureCatalogService()
        let title = shortcut.lookupTitle.isEmpty ? shortcut.displayName : shortcut.lookupTitle
        OpenNOWLog.info(.shortcut, "CatalogViewModel resolving shortcut cmsId=\(shortcut.cmsId) shortName=\(shortcut.shortName) parentGameId=\(shortcut.parentGameId) title=\(title)")
        setActionMessage("Opening \(title.isEmpty ? "GeForce NOW shortcut" : title)...")
        if let game = matchingGame(for: shortcut, in: allKnownGames) {
            OpenNOWLog.info(.shortcut, "Resolved shortcut from loaded catalog: gameId=\(game.id) uuid=\(game.uuid) launchAppId=\(game.launchAppId) title=\(game.title)")
            selectGame(game)
            launch(game: game, variantIndex: variantIndex(for: shortcut, in: game))
            return
        }
        OpenNOWLog.info(.shortcut, "Shortcut not found in loaded catalog; browsing with query=\(title)")
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.browseCatalogObject(searchQuery: title, sortId: "relevance", filterIds: [], fetchCount: 24) { success, result, error in
            let resultBox = CatalogSendableValue(result)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                guard success else {
                    OpenNOWLog.error(.shortcut, "Shortcut catalog browse failed: \(error)")
                    self.errorMessage = error.isEmpty ? "Unable to resolve this GeForce NOW shortcut." : error
                    return
                }
                let games = resultBox.value.games
                OpenNOWLog.info(.shortcut, "Shortcut catalog browse returned \(games.count) game(s)")
                guard let game = self.matchingGame(for: shortcut, in: games) ?? games.first else {
                    OpenNOWLog.error(.shortcut, "Shortcut catalog browse returned no matching games")
                    self.errorMessage = "No matching GeForce NOW catalog game was found for this shortcut."
                    return
                }
                OpenNOWLog.info(.shortcut, "Resolved shortcut from browse: gameId=\(game.id) uuid=\(game.uuid) launchAppId=\(game.launchAppId) title=\(game.title)")
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
        (activeLaunchSession?.appId ?? 0) > 0 && activeSessionResumeConfiguration != nil
    }

    func beginVendorLaunch(game: OPNCatalogGameObject, variantIndex: Int? = nil) {
        OpenNOWLog.info(.launch, "Beginning launch for gameId=\(game.id) uuid=\(game.uuid) launchAppId=\(game.launchAppId) title=\(game.title) requestedVariantIndex=\(variantIndex ?? -1)")
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
        continueVendorLaunch()
    }

    func selectSettingsRegion(_ regionUrl: String) {
        selectedSettingsRegionUrl = regionUrl
        OPNStreamPreferences.saveSelectedRegionUrl(regionUrl)
        loadSettingsPreferences()
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
                    self.selectSettingsRegion("")
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
            variantIndex: pendingLaunchVariantIndex
        ) { [weak self] success, message, plan in
            guard let self else { return }
            self.launchMessage = ""
            guard success, let plan else {
                OpenNOWLog.error(.launch, "Launch plan failed: \(message)")
                self.clearLaunchFlow()
                self.errorMessage = message.isEmpty ? "Unable to prepare GeForce NOW launch." : message
                return
            }
            switch plan {
            case .ready(let configuration):
                OpenNOWLog.info(.launch, "Launch plan ready appId=\(configuration.appId) title=\(configuration.title)")
                self.startPreparedStream(Self.mediaConfiguration(from: configuration), message: message)
            case .activeSession(let active, let resume, let replacement):
                OpenNOWLog.info(.launch, "Launch plan found active session activeAppId=\(active.appId) replacementAppId=\(replacement.appId) resumeAppId=\(resume.appId)")
                self.activeLaunchSession = active
                self.activeSessionResumeConfiguration = Self.mediaConfiguration(from: resume)
                self.activeSessionReplacementConfiguration = Self.mediaConfiguration(from: replacement)
                self.launchFlowState = .activeSessionPrompt
                self.launchFlowMessage = active.appId > 0
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
        activeStreamConfiguration = nil
        activeStreamProgress = nil
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
        let generation = streamProgressGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard generation == self.streamProgressGeneration else { return }
            self.isActiveStreamLaunchOverlayVisible = false
        }
    }

    private var launchToken: String {
        session.idToken.isEmpty ? session.accessToken : session.idToken
    }

    private func startPreparedStream(_ configuration: StreamLaunchConfiguration, message: String) {
        launchFlowState = .startingStream
        launchFlowMessage = message.isEmpty ? "Starting GeForce NOW stream..." : message
        launchFlowError = ""
        streamProgressGeneration += 1
        isActiveStreamLaunchOverlayVisible = true
        activeStreamProgress = StreamProgress(title: configuration.title.isEmpty ? "GeForce NOW" : configuration.title, message: launchFlowMessage, steps: [], currentStepIndex: -1, isReady: false)
        activeStreamConfiguration = configuration
        clearLaunchFlow()
    }

    private static func mediaConfiguration(from configuration: OPNStreamLaunchConfiguration) -> StreamLaunchConfiguration {
        StreamLaunchConfiguration(
            title: configuration.title,
            applicationID: configuration.appId,
            accessToken: configuration.apiToken,
            accountLinked: configuration.accountLinked,
            selectedStore: configuration.selectedStore,
            resumeSessionID: configuration.resumeSessionId,
            resumeServer: configuration.resumeServer,
            metadata: configuration.metadata
        )
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
        favoriteGameIdentities.contains(Self.identity(for: game))
    }

    func toggleFavoriteSelectedGame() {
        guard let selectedGame else { return }
        let identity = Self.identity(for: selectedGame)
        guard !identity.isEmpty else { return }
        if favoriteGameIdentities.contains(identity) {
            favoriteGameIdentities.remove(identity)
            var snapshots = favoriteGameSnapshots
            snapshots.removeValue(forKey: identity)
            favoriteGameSnapshots = snapshots
            actionMessage = "Removed from favorites."
        } else {
            favoriteGameIdentities.insert(identity)
            var snapshots = favoriteGameSnapshots
            snapshots[identity] = Self.snapshotObject(for: selectedGame)
            favoriteGameSnapshots = snapshots
            actionMessage = "Added to favorites."
        }
        saveFavorites()
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
        selectedVariantIndex = index
        let variant = selectedGame.variants[index]
        if variant.inLibrary || variant.librarySelected || selectedGame.isInLibrary {
            selectOwnedVariant(variant)
            ownershipFlowStage = .storeSelection
            ownershipFlowMessage = ""
        } else if ownershipFlowStage != .hidden {
            ownershipFlowStage = .manualMark
            ownershipFlowMessage = ""
        }
        actionMessage = "Changed store to \(displayName(forStore: variant.appStore))."
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
            actionMessage = "Added GeForce NOW shortcut to Desktop."
        } catch {
            errorMessage = "Unable to add shortcut: \(error.localizedDescription)"
        }
    }

    func markSelectedVariantOwned() {
        beginMarkSelectedVariantOwnedFlow()
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
        guard let store = selectedVariant(in: selectedGame)?.appStore, !store.isEmpty else { return }
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
        guard let store = selectedVariant(in: selectedGame)?.appStore, !store.isEmpty else { return }
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

    func displayName(forStore store: String) -> String {
        if let definition = storeDefinitions.first(where: { $0.store.caseInsensitiveCompare(store) == .orderedSame }), !definition.label.isEmpty {
            return definition.label
        }
        return store.isEmpty ? "Store" : store.uppercased()
    }

    func accountStatus(forStore store: String) -> CatalogStoreAccount? {
        accountStores.first { $0.store.caseInsensitiveCompare(store) == .orderedSame }
    }

    func setAspectIndex(_ index: Int) {
        OPNStreamPreferences.saveAspectIndex(index)
        loadSettingsPreferences()
    }

    func setResolutionIndex(_ index: Int) {
        OPNStreamPreferences.saveResolutionIndex(index)
        loadSettingsPreferences()
    }

    func setFpsIndex(_ index: Int) {
        OPNStreamPreferences.saveFpsIndex(index)
        loadSettingsPreferences()
    }

    func setCodecIndex(_ index: Int) {
        OPNStreamPreferences.saveCodecIndex(index)
        loadSettingsPreferences()
    }

    func setBitrateIndex(_ index: Int) {
        OPNStreamPreferences.saveBitrateIndex(index)
        loadSettingsPreferences()
    }

    func setColorQualityIndex(_ index: Int) {
        OPNStreamPreferences.saveColorQualityIndex(index)
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

    func setL4SEnabled(_ enabled: Bool) {
        OPNStreamPreferences.saveL4SEnabled(enabled)
        loadSettingsPreferences()
    }

    func setHDREnabled(_ enabled: Bool) {
        OPNStreamPreferences.saveHDREnabled(enabled)
        loadSettingsPreferences()
    }

    func setLowLatencyModeEnabled(_ enabled: Bool) {
        OPNStreamPreferences.saveLowLatencyModeEnabled(enabled)
        loadSettingsPreferences()
    }

    func setPowerSaverEnabled(_ enabled: Bool) {
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
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.fetchMarqueePanelObjects { success, panels, error in
            let panelBox = CatalogSendableValue(panels)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.marqueePanels = panelBox.value
                    self.refreshFavoriteSnapshotsFromKnownGames()
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
                    self.mainPanels = panelBox.value
                    self.refreshFavoriteSnapshotsFromKnownGames()
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
                    self.refreshFavoriteSnapshotsFromKnownGames()
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.libraryGames = []
                }
            }
        }
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
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.accountStores = []
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
                    self.subscriptionStatus = CatalogSubscriptionStatus(subscription: subscriptionBox.value)
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
                selectedRegionUrl: OPNStreamPreferences.loadSelectedRegionUrl(),
                regionOptions: Self.launchRegionOptions(from: OPNStreamPreferences.loadCachedRegions()),
                microphoneDeviceOptions: OPNStreamPreferences.loadMicrophoneDeviceOptions()
            )
            await MainActor.run { [weak self] in
                guard let self, generation == self.settingsPreferencesGeneration, !Task.isCancelled else { return }
                self.streamCapabilities = snapshot.capabilities
                self.streamProfile = snapshot.profile
                self.selectedSettingsRegionUrl = snapshot.selectedRegionUrl
                self.settingsRegionOptions = snapshot.regionOptions
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

    private func refreshFavoriteSnapshotsFromKnownGames() {
        guard !favoriteGameIdentities.isEmpty else { return }
        var snapshots = favoriteGameSnapshots
        var changed = false
        for game in allKnownGames {
            let identity = Self.identity(for: game)
            guard favoriteGameIdentities.contains(identity), snapshots[identity] == nil else { continue }
            snapshots[identity] = Self.snapshotObject(for: game)
            changed = true
        }
        guard changed else { return }
        favoriteGameSnapshots = snapshots
        saveFavorites()
    }

    private func saveFavorites() {
        let identifiers = Self.favoriteAccountIdentifiers(account: account, session: session)
        Self.saveFavoriteGameIdentities(favoriteGameIdentities, accountIdentifiers: identifiers)
        Self.saveFavoriteGameSnapshots(favoriteGameSnapshots, accountIdentifiers: identifiers)
    }

    private func updateSelectedGameOwnership(gameIdentity: String, variantId: String, inLibrary: Bool) {
        guard let selectedGame, Self.identity(for: selectedGame) == gameIdentity else { return }
        selectedGame.isInLibrary = inLibrary
        for variant in selectedGame.variants where variant.id == variantId {
            variant.inLibrary = inLibrary
            variant.librarySelected = inLibrary
        }
    }

    private func setActionMessage(_ message: String) {
        actionMessage = message
        errorMessage = ""
    }

    private static func appendUniqueHeroGames(from source: [OPNCatalogGameObject], into games: inout [OPNCatalogGameObject], seen: inout Set<String>) {
        for game in source {
            guard hasMarqueeHeroArtwork(game) else { continue }
            let identity = identity(for: game)
            guard !identity.isEmpty, !seen.contains(identity) else { continue }
            seen.insert(identity)
            games.append(game)
        }
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

    private func resolveSelectedStoreURL(completion: @escaping (URL?) -> Void) {
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
        onRefreshAuth()
        return true
    }

    static func identity(for game: OPNCatalogGameObject) -> String {
        if !game.id.isEmpty { return game.id }
        if !game.uuid.isEmpty { return game.uuid }
        if !game.launchAppId.isEmpty { return game.launchAppId }
        return game.title
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

    private static func favoriteAccountIdentifiers(account: LoginAccount, session: LoginSession) -> [String] {
        var identifiers: [String] = []
        for value in [session.userId, account.userId, account.externalUserId, account.email] {
            let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !identifier.isEmpty, !identifiers.contains(identifier) else { continue }
            identifiers.append(identifier)
        }
        return identifiers.isEmpty ? ["default"] : identifiers
    }

    private static func favoritesKey(accountIdentifier: String) -> String {
        "OpenNOW.catalog.favoriteGameIdentities.\(accountIdentifier)"
    }

    private static func favoriteSnapshotsKey(accountIdentifier: String) -> String {
        "OpenNOW.catalog.favoriteGameSnapshots.\(accountIdentifier)"
    }

    private static func loadFavoriteGameIdentities(accountIdentifiers: [String]) -> Set<String> {
        var identities = Set<String>()
        for accountIdentifier in accountIdentifiers {
            identities.formUnion(UserDefaults.standard.stringArray(forKey: favoritesKey(accountIdentifier: accountIdentifier)) ?? [])
        }
        return identities
    }

    private static func saveFavoriteGameIdentities(_ identities: Set<String>, accountIdentifiers: [String]) {
        let values = Array(identities).sorted()
        for accountIdentifier in accountIdentifiers {
            UserDefaults.standard.set(values, forKey: favoritesKey(accountIdentifier: accountIdentifier))
        }
    }

    private static func loadFavoriteGameSnapshots(accountIdentifiers: [String]) -> [String: OPNCatalogGameObject] {
        var snapshots: [String: OPNCatalogGameObject] = [:]
        let decoder = JSONDecoder()
        for accountIdentifier in accountIdentifiers {
            guard let data = UserDefaults.standard.data(forKey: favoriteSnapshotsKey(accountIdentifier: accountIdentifier)),
                  let games = try? decoder.decode([OPNGameInfo].self, from: data) else { continue }
            for game in games {
                let object = OPNCatalogGameObject(game: game)
                let identity = identity(for: object)
                guard !identity.isEmpty, snapshots[identity] == nil else { continue }
                snapshots[identity] = object
            }
        }
        return snapshots
    }

    private static func saveFavoriteGameSnapshots(_ snapshots: [String: OPNCatalogGameObject], accountIdentifiers: [String]) {
        let games = snapshots.keys.sorted().compactMap { snapshots[$0]?.swiftValue }
        guard let data = try? JSONEncoder().encode(games) else { return }
        for accountIdentifier in accountIdentifiers {
            UserDefaults.standard.set(data, forKey: favoriteSnapshotsKey(accountIdentifier: accountIdentifier))
        }
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
}

struct CatalogSectionModel: Identifiable, Equatable {
    enum Kind: Equatable {
        case catalog
        case library
        case panel
    }

    let id: String
    let title: String
    let games: [OPNCatalogGameObject]
    let kind: Kind

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

struct CatalogPlaytimeStatistics: Codable, Equatable {
    private static let storagePrefix = "OpenNOW.Catalog.PlaytimeStatistics"

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
    private static let storageKey = "OpenNOW.Catalog.PreviousGameSession"

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
