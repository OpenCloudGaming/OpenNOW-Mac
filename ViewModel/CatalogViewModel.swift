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
    case resyncing
    case storeSelection
    case manualMark
    case success
}

/// Every modal that covers the whole catalog. One value rather than a boolean each: two of these
/// on screen at once used to be expressible, and a store-picker stage used to survive the picker
/// being dismissed. The surfaces the catalog does not own - the launch flow and the stream launch
/// loading screen - stay on their own state machines.
@MainActor
enum CatalogModalOverlay: Equatable {
    case storePicker(stage: CatalogOwnershipFlowStage)
    case gameInfo
    case diagnosticsUploadConfirmation

    var storePickerStage: CatalogOwnershipFlowStage? {
        guard case let .storePicker(stage) = self else { return nil }
        return stage
    }
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
    case video
    case audio
    case input
    case keybindings
    case recording
    case network
    case remoteCoOp
    case theme
    case general
    case system
    case labs

    var id: String { rawValue }

    /// Every destination, always. Labs is drawn even with nothing on trial, so it is somewhere people
    /// can learn to look rather than a tab that comes and goes; its page says so itself. Kept as a
    /// function so the sidebar and pad navigation read the same list - iterating `allCases` in one
    /// place and a filtered list in the other is what let the pad land on a tab that was not drawn.
    static func visibleCases() -> [CatalogSettingsGroup] {
        allCases
    }

    /// True for a page that is nothing but an empty state. It names itself, so the standard page
    /// header above it would be a second, competing title, and there is nothing to scroll.
    @MainActor var isEmptyStatePage: Bool {
        self == .labs && !OPNLabs.hasFlags
    }

    var title: String {
        switch self {
        case .account: return "Account"
        case .video: return "Video"
        case .audio: return "Audio"
        case .input: return "Input"
        case .keybindings: return "Keybindings"
        case .recording: return "Recording"
        case .network: return "Network"
        case .remoteCoOp: return "Remote Co-Op"
        case .theme: return "Look"
        case .general: return "General"
        case .system: return "System"
        case .labs: return "Labs"
        }
    }

    var subtitle: String {
        switch self {
        case .account: return "Membership, playtime, connected stores, and the current NVIDIA session."
        case .video: return "Resolution, frame rate, codec, colour, and the picture the stream arrives with."
        case .audio: return "Game output, surround, and the microphone the stream sends."
        case .input: return "Mouse, keyboard, and every controller OpenNOW speaks to."
        case .keybindings: return "Every shortcut OpenNOW owns, for controlling a stream or browsing the catalog."
        case .recording: return "What \(OPNKeybindings.standard.combo(for: .toggleRecording).spokenLabel) writes to disk, and where to find it afterwards."
        case .network: return "Server location, stream transport, and proxy routing."
        case .remoteCoOp: return "Invite a friend into your session from a browser."
        case .theme: return "How OpenNOW looks: interface scale, accent, and the rails the home page draws its games in."
        case .general: return "Alerts, game launch, Discord, privacy, and maintenance."
        case .system: return "Product identity, updates, release notes, and what this Mac can do."
        case .labs: return "Features on trial. Off by default, and liable to change or vanish."
        }
    }

    var icon: String {
        switch self {
        case .account: return "person.crop.circle.fill"
        case .video: return "play.tv.fill"
        case .audio: return "speaker.wave.2.fill"
        case .input: return "gamecontroller.fill"
        case .keybindings: return "keyboard"
        case .recording: return "record.circle"
        case .network: return "network"
        case .remoteCoOp: return "person.2.fill"
        case .theme: return "paintpalette.fill"
        case .general: return "gearshape.2.fill"
        case .system: return "info.circle.fill"
        case .labs: return "flask.fill"
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
    /// Raised once when an edit under a named quality preset moved the profile to Custom, so the
    /// page can say so rather than leave the preset silently changing under the reader.
    var didSwitchToCustomStreamingProfile = false
    /// The card a search result asked for. Set with the destination, cleared by the page once it has
    /// scrolled there - the page cannot scroll until it exists, and it does not exist until the
    /// destination has changed.
    var pendingSettingsSectionID: String?
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
    var isLoadingLibrary = false { didSet { cachedBaseCatalogSections = nil } }
    var isLoadingFavorites = false { didSet { cachedBaseCatalogSections = nil } }
    var catalogEndCursor = ""
    var errorMessage = ""
    /// A launch that failed, kept until the next launch attempt or an explicit dismissal.
    /// `errorMessage` doubles as the catalog's transient status line and is wiped by any browse,
    /// panel load or action message — so the one message the user most needs (the seat refused the
    /// title) vanished a moment after it appeared. This one only launch failures write.
    var launchErrorMessage = ""
    var launchMessage = ""
    /// Support-diagnostics generation, driven from both the About settings card and the home
    /// error banner. See CatalogDiagnostics.swift.
    var diagnosticsState = AboutDiagnosticsState.ready
    var diagnosticsErrorContext = ""
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
    /// Which entitlement row of the selected variant the user picked: nil falls back to the
    /// variant's default row (store when owned, otherwise subscription).
    var selectedRowIsSubscription: Bool?
    var activeStreamConfiguration: StreamLaunchConfiguration?
    var activeStreamProgress: StreamProgress?
    /// One ready alert per launch: allocation and the transport each publish a ready progress.
    var didNotifySessionReady = false
    var isActiveStreamLaunchOverlayVisible = false
    /// True while the pointer is over a game tile. The page-wide "tap anywhere else to close the
    /// details" gesture runs alongside the tile's own tap, so a click on the open tile closed the
    /// panel and the tile's toggle then reopened it — the details never closed from the tile.
    var isPointerInsideGameTile = false
    var launchFlowState = CatalogLaunchFlowState.idle
    var launchFlowTitle = ""
    var launchFlowMessage = ""
    var launchFlowError = ""
    var activeLaunchSession: OPNActiveStreamSessionDescriptor?
    var activeHomeSession: OPNActiveSessionObject?
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
    /// Live state of the Settings microphone test; the probe itself is the CoreAudio tap.
    var microphoneTestActive = false
    var microphoneTestLevel = 0.0
    var microphoneTestMessage: String?
    var microphoneLevelProbe: OPNMicrophoneLevelProbe?
    var microphoneTestAutoStop: Task<Void, Never>?
    var previousGameSession = CatalogPreviousGameSession.load()
    var playtimeStatistics = CatalogPlaytimeStatistics.empty
    var recentlyPlayed = CatalogRecentlyPlayed.empty {
        didSet { invalidateDerivedCatalogCaches() }
    }
    /// The Jump Back In rail is a Look choice, so it lives with the other interface preferences
    /// and the home page rebuilds its rails when it flips.
    var isJumpBackInEnabled = OPNThemePreferences.isJumpBackInEnabled {
        didSet { invalidateDerivedCatalogCaches() }
    }
    /// The reader's arrangement of the home rails: their order and which are switched off. Stored
    /// separately from the catalog so it survives a reload that returns the rails in another order.
    var homeRailArrangement = OPNHomeCustomization.arrangement {
        didSet { OPNHomeCustomization.arrangement = homeRailArrangement }
    }
    var subscriptionStatus = CatalogSubscriptionStatus.unavailable
    var favoriteGameIdentities: Set<String> = []
    var favoriteGames: [OPNCatalogGameObject] = [] {
        didSet { invalidateDerivedCatalogCaches() }
    }
    /// The reader's locally-owned collections. There is no vendor endpoint for these: they are
    /// written only to this Mac, keyed per account, and the reader backs them up themselves.
    var userCollections: [OPNUserCollection] = [] {
        didSet { invalidateDerivedCatalogCaches() }
    }
    /// Games for a local Show All page, held apart from `catalogGames` so a server browse can never
    /// overwrite them and a local page can never seed a server filter.
    var localShowAllGames: [OPNCatalogGameObject] = []
    /// Members of the open local collection that the loaded catalog does not currently carry, so the
    /// page can say how many are missing instead of dropping them silently.
    var localShowAllUnavailableCount = 0
    /// The collection picker raised from a game's detail panel.
    var isCollectionsPickerPresented = false
    /// The manager raised from the menu's Collections group.
    var isCollectionsManagerPresented = false
    /// The create/rename/delete dialog, one at a time.
    var collectionsDialog: CatalogCollectionsDialog?
    var collectionsDraftName = ""
    var collectionsDialogError = ""
    /// The one-time explainer that collections are local-only.
    var isCollectionsNoticePresented = false
    var selectedGameRevealRequest: CatalogGameRevealRequest?
    var catalogImageCacheSummary = "Calculating"
    var presentedModal: CatalogModalOverlay?
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
    /// The catalog's own account actions, handed in by `CatalogView`, so a switch asked for from the
    /// menu bar runs the identical path the on-screen dropdown does.
    let onSwitchAccount: (LoginAccount) -> Void
    let onAddAccount: () -> Void
    /// The saved accounts and which of them are signed out, fed from the view's SwiftData query. The
    /// menu bar snapshot is derived from these rather than from the live models.
    var menuBarLoginAccounts: [LoginAccount] = []
    var menuBarSignedOutEmails: Set<String> = []
    /// A switch the menu bar asked for before the account list reached this model, held until the
    /// list arrives. Opening the window from the menu bar parks the request, and the list is pushed
    /// by the view a beat after it attaches, so a dropped request would look like a dead button.
    var pendingMenuBarAccountSwitchEmail: String?

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

    init(account: LoginAccount, session: LoginSession, gameService: any CatalogGameServing = OPNGameService.shared, launchBridge: any GameLaunchBridging = OPNGameLaunchBridge.shared, imageCache: any CatalogImageServing = CatalogImageCache.shared, discordPresence: any DiscordPresenceServing = DiscordRichPresence.shared, systemIntegration: any SystemIntegrationServing = AppKitSystemIntegration(), onSwitchAccount: @escaping (LoginAccount) -> Void = { _ in }, onAddAccount: @escaping () -> Void = {}, onRefreshAuth: @escaping () async -> Bool) {
        self.account = account
        self.session = session
        self.gameService = gameService
        self.launchBridge = launchBridge
        self.imageCache = imageCache
        self.discordPresence = discordPresence
        self.systemIntegration = systemIntegration
        self.onSwitchAccount = onSwitchAccount
        self.onAddAccount = onAddAccount
        self.onRefreshAuth = onRefreshAuth
    }

    /// Records the saved accounts the menu bar can show and switch, and settles a switch that was
    /// asked for before this list existed.
    func updateMenuBarAccounts(_ accounts: [LoginAccount], signedOutAccountEmails: Set<String>) {
        menuBarLoginAccounts = accounts
        menuBarSignedOutEmails = signedOutAccountEmails
        guard let email = pendingMenuBarAccountSwitchEmail,
              let match = accounts.first(where: { $0.email == email }) else { return }
        pendingMenuBarAccountSwitchEmail = nil
        onSwitchAccount(match)
    }

    /// The saved accounts as the menu bar snapshot carries them, the active one marked.
    var menuBarAccounts: [OPNMenuBarAccount] {
        menuBarLoginAccounts.map { login in
            OPNMenuBarAccount(
                email: login.email,
                displayName: login.displayName,
                membershipTier: login.membershipTier,
                isSignedOut: menuBarSignedOutEmails.contains(login.email),
                isActive: login.email == account.email
            )
        }
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
        recentlyPlayed = CatalogRecentlyPlayed.load(accountIdentifier: playtimeAccountIdentifier)
        userCollections = CatalogCollectionsStore.load(accountIdentifier: collectionsAccountIdentifier).collections
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
    @ObservationIgnored var cachedBaseCatalogSections: [CatalogSectionModel]?

    private func invalidateDerivedCatalogCaches() {
        cachedMarqueeGames = nil
        cachedHeroRotationGames = nil
        cachedBaseCatalogSections = nil
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
        OPNLog.info(.catalog, "Initial catalog load deferred until expired session refresh completes")
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
            self.loadAccount()
            self.loadStores()
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
                        OPNLog.info(.auth, message)
                    } else {
                        OPNLog.warning(.auth, message)
                    }
                    continuation.resume()
                }
            }
        }
    }

    var isStorePickerVisible: Bool { presentedModal?.storePickerStage != nil }

    var isGameInfoVisible: Bool { presentedModal == .gameInfo }

    var isDiagnosticsUploadConfirmationVisible: Bool { presentedModal == .diagnosticsUploadConfirmation }

    /// Stage of the store picker, or nil when the picker is not the presented modal.
    var ownershipFlowStage: CatalogOwnershipFlowStage? { presentedModal?.storePickerStage }

    func selectGame(_ game: OPNCatalogGameObject?) {
        let resolvedGame = game.flatMap(resolveGameForDetails) ?? game
        selectedGame = resolvedGame
        selectedSectionId = ""
        selectedVariantIndex = resolvedGame.map { Self.preferredVariantIndex(for: $0) } ?? -1
        selectedRowIsSubscription = nil
        launchMessage = ""
        actionMessage = ""
        if isGameInfoVisible { presentedModal = nil }
    }

    func selectGame(_ game: OPNCatalogGameObject, inSection sectionId: String) {
        let resolvedGame = resolveGameForDetails(game, preferredSectionId: sectionId)
        selectedGame = resolvedGame
        selectedSectionId = sectionId
        selectedVariantIndex = Self.preferredVariantIndex(for: resolvedGame)
        selectedRowIsSubscription = nil
        launchMessage = ""
        actionMessage = ""
        if isGameInfoVisible { presentedModal = nil }
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

    /// The full game info page. It reads the current selection, so it is only meaningful while a
    /// game is selected.
    func showGameInfo() {
        guard selectedGame != nil else { return }
        presentedModal = .gameInfo
    }

    func closeGameInfo() {
        guard isGameInfoVisible else { return }
        presentedModal = nil
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
