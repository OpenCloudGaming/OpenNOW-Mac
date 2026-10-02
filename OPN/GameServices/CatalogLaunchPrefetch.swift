import Foundation

/// Decides when the launch prefetch may drop the catalog graphs it retains for the home page.
/// They duplicate the view model's own copy, so they go once it has adopted every delivery.
struct CatalogLaunchPrefetchRetention {
    private(set) var isLaunchResultsAdopted = false
    private(set) var isHandoverFinished = false
    private var pendingDeliveryCount = 0

    /// False before adoption and while a delivery is outstanding: either would strand a rail.
    var isReadyToReleaseRetainedGraphs: Bool {
        isLaunchResultsAdopted && pendingDeliveryCount == 0 && !isHandoverFinished
    }

    mutating func recordDeliveriesStarted(_ count: Int) {
        guard !isHandoverFinished, count > 0 else { return }
        pendingDeliveryCount += count
    }

    mutating func recordDeliveryFinished() {
        pendingDeliveryCount = max(0, pendingDeliveryCount - 1)
    }

    mutating func recordLaunchResultsAdopted() {
        guard !isHandoverFinished else { return }
        isLaunchResultsAdopted = true
    }

    mutating func recordHandoverFinished() {
        isHandoverFinished = true
        pendingDeliveryCount = 0
    }
}

/// Fetches everything the home screen needs at process launch, before the catalog view exists.
///
/// Without this the first request cannot start until SwiftUI has built the scene, resolved the
/// active session and mounted `CatalogView`, so the whole round trip happens after the splash
/// screen instead of underneath it. The catalog view model adopts whatever this has (or has in
/// flight) through `attach(accountIdentifier:onEvent:)` rather than issuing the same query again.
///
/// Two data shapes ride along here: panels (marquee hero, main rails) and flat game lists
/// (favorites, library). Each shape has one generic fetch/attach/deliver path so adding a third
/// home game list later - a "recently played" rail, say - is a new `GameListKind` case and one
/// `gameService.fetch...` call in `start()`, not a new parallel set of state/handler plumbing.
@MainActor
final class CatalogLaunchPrefetch {
    static let shared = CatalogLaunchPrefetch()

    enum PanelKind: String, CaseIterable {
        case marquee
        case main
    }

    enum GameListKind: String, CaseIterable {
        case favorites
        case library
    }

    enum Event {
        case panels(PanelKind, [OPNCatalogPanelObject])
        case panelsFailed(PanelKind, String)
        case games(GameListKind, [OPNCatalogGameObject])
        case gamesFailed(GameListKind, String)
    }

    struct Attachment {
        var marquee = false
        var main = false
        var favorites = false
        var library = false

        var isEmpty: Bool { !marquee && !main && !favorites && !library }
    }

    private enum FetchState {
        case idle
        case inFlight
        case delivered
        case failed
    }

    let gameService = OPNGameService.shared
    let imageCache = CatalogImageCache.shared

    private(set) var accountIdentifier = ""
    private var panels: [PanelKind: [OPNCatalogPanelObject]] = [:]
    private var panelStates: [PanelKind: FetchState] = [:]
    private var gameLists: [GameListKind: [OPNCatalogGameObject]] = [:]
    private var gameListStates: [GameListKind: FetchState] = [:]
    private var observer: ((Event) -> Void)?
    private var retention = CatalogLaunchPrefetchRetention()
    var startedAt: ContinuousClock.Instant?
    private var didPrefetchHeroImages = false
    private var didPrefetchRailImages = false

    private init() {}

    var hasHomePanels: Bool { !(panels[.main] ?? []).isEmpty }

    var isFetching: Bool { isActiveState(panelStates[.marquee]) || isActiveState(panelStates[.main]) }

    func start(accountIdentifier: String, accessToken: String, idToken: String) {
        guard !retention.isHandoverFinished else { return }
        guard (panelStates[.marquee] ?? .idle) == .idle, (panelStates[.main] ?? .idle) == .idle else { return }
        guard !accountIdentifier.isEmpty, !accessToken.isEmpty || !idToken.isEmpty else { return }
        self.accountIdentifier = accountIdentifier
        for kind in PanelKind.allCases { panelStates[kind] = .inFlight }
        for kind in GameListKind.allCases { gameListStates[kind] = .inFlight }
        retention.recordDeliveriesStarted(PanelKind.allCases.count + GameListKind.allCases.count)
        startedAt = ContinuousClock.now
        StartupReadiness.shared.noteProgress()
        // Also prewarms the vpcId lookup, which every catalog query waits on.
        gameService.configureCatalogSession(accessToken: accessToken, idToken: idToken, userId: accountIdentifier)
        OPNLog.info(.catalog, "Launch panel prefetch started")
        gameService.fetchMarqueePanelObjects { [weak self] success, panels, error in
            self?.handlePanels(kind: .marquee, success: success, panels: panels, error: error)
        }
        gameService.fetchMainPanelObjects { [weak self] success, panels, error in
            self?.handlePanels(kind: .main, success: success, panels: panels, error: error)
        }
        // Favorites and library render nothing on the first frame, but they share the same
        // control-plane session as the panels above, so they ride along under the splash screen
        // the same way - instead of, previously, only starting once `CatalogViewModel` itself was
        // built and its own gate (`scheduleSecondaryCatalogLoads`) let them through.
        gameService.fetchFavoriteGameObjects { [weak self] success, games, error in
            self?.handleGameList(kind: .favorites, success: success, games: games, error: error)
        }
        gameService.fetchLibraryGameObjects { [weak self] success, games, error in
            self?.handleGameList(kind: .library, success: success, games: games, error: error)
        }
    }

    /// Reports which kinds the caller can leave to this prefetch. A kind that already failed (or
    /// was never started) is not adopted, so the caller still fetches it itself.
    func attach(accountIdentifier: String, onEvent: @escaping (Event) -> Void) -> Attachment {
        // Nothing retained and nothing in flight, so the caller fetches both shapes itself.
        guard !retention.isHandoverFinished else { return Attachment() }
        guard !accountIdentifier.isEmpty, accountIdentifier == self.accountIdentifier else { return Attachment() }
        var attachment = Attachment()
        attachment.marquee = isActiveState(panelStates[.marquee])
        attachment.main = isActiveState(panelStates[.main])
        attachment.favorites = isActiveState(gameListStates[.favorites])
        attachment.library = isActiveState(gameListStates[.library])
        // Data primed from disk cache is still worth handing over even when the caller keeps
        // ownership of the network fetch: it paints now.
        let hasStoredData = panels.values.contains { !$0.isEmpty } || gameLists.values.contains { !$0.isEmpty }
        guard !attachment.isEmpty || hasStoredData else { return Attachment() }
        observer = onEvent
        for kind in PanelKind.allCases {
            if let stored = panels[kind], !stored.isEmpty { onEvent(.panels(kind, stored)) }
        }
        for kind in GameListKind.allCases {
            if let stored = gameLists[kind] { onEvent(.games(kind, stored)) }
        }
        return attachment
    }

    /// Drops one prefetched list once the user has changed the data behind it. `attach` hands a
    /// delivered snapshot to every later caller, so without this a launch-time favorites list was
    /// re-adopted by every reload for the rest of the session: a favorite removed in this session
    /// came straight back on the next refresh, which made the control look dead.
    func invalidate(_ kind: GameListKind) {
        gameLists[kind] = nil
        gameListStates[kind] = .idle
    }

    /// Paints from the panel disk cache without a usable token. A launch whose stored session has
    /// expired has to refresh auth before it can fetch anything, which is seconds of skeleton for
    /// data that is already on disk. States stay idle so the catalog view model still runs its own
    /// fetch once auth is ready. Favorites/library have no disk cache of their own to prime from.
    func primeFromCache(accountIdentifier: String) {
        guard self.accountIdentifier.isEmpty || self.accountIdentifier == accountIdentifier else { return }
        guard !accountIdentifier.isEmpty else { return }
        guard !retention.isHandoverFinished else { return }
        self.accountIdentifier = accountIdentifier
        retention.recordDeliveriesStarted(PanelKind.allCases.count)
        for kind in PanelKind.allCases {
            gameService.loadCachedPanels(cacheKind: kind.rawValue, accountIdentifier: accountIdentifier) { [weak self] cachedPanels in
                let panels = cachedPanels.map { $0.map(OPNCatalogPanelObject.init) } ?? []
                Task { @MainActor in
                    self?.applyCachedPanels(panels, for: kind)
                }
            }
        }
    }

    private func applyCachedPanels(_ cached: [OPNCatalogPanelObject], for kind: PanelKind) {
        defer { finishDelivery() }
        guard !retention.isHandoverFinished, !cached.isEmpty, (panels[kind] ?? []).isEmpty else { return }
        panels[kind] = cached
        StartupReadiness.shared.noteProgress()
        OPNLog.info(.catalog, "Launch panel prime from cache kind=\(kind.rawValue) sections=\(cached.flatMap(\.sections).count)")
        observer?(.panels(kind, cached))
        prefetchFirstFrameImages(for: kind)
    }

    func detach() {
        observer = nil
    }

    /// Tells this prefetch the home catalog has run every launch attach point, so the graphs may go
    /// as soon as the last delivery lands.
    func recordLaunchResultsAdopted() {
        retention.recordLaunchResultsAdopted()
        releaseRetainedGraphsWhenReady()
    }

    /// Drops everything so a later explicit refresh goes to the network instead
    /// of adopting launch-time results.
    func invalidate() {
        dropRetainedGraphs()
        accountIdentifier = ""
        panelStates = [:]
        gameListStates = [:]
        startedAt = nil
        didPrefetchHeroImages = false
        didPrefetchRailImages = false
    }

    /// Drops the graphs, the observer and the handover: nothing retained may be handed over again.
    private func dropRetainedGraphs() {
        retention.recordHandoverFinished()
        panels = [:]
        gameLists = [:]
        observer = nil
        OPNLog.info(.catalog, "Launch prefetch released the retained catalog graphs")
    }

    private func releaseRetainedGraphsWhenReady() {
        guard retention.isReadyToReleaseRetainedGraphs else { return }
        dropRetainedGraphs()
    }

    /// One launch delivery - a fetch or a panel cache read - has landed.
    private func finishDelivery() {
        retention.recordDeliveryFinished()
        releaseRetainedGraphsWhenReady()
    }

    private func handlePanels(kind: PanelKind, success: Bool, panels newPanels: [OPNCatalogPanelObject], error: String) {
        defer { finishDelivery() }
        guard !retention.isHandoverFinished else { return }
        guard success, !newPanels.isEmpty else {
            let message = error.isEmpty ? "No \(kind.rawValue) panels returned." : error
            panelStates[kind] = .failed
            guard (panels[kind] ?? []).isEmpty else { return }
            OPNLog.warning(.catalog, "Launch panel prefetch failed kind=\(kind.rawValue) error=\(message)")
            observer?(.panelsFailed(kind, message))
            return
        }

        panelStates[kind] = .delivered
        panels[kind] = newPanels
        StartupReadiness.shared.noteProgress()
        logDelivered(label: "panel", kind: kind.rawValue, count: newPanels.flatMap(\.sections).count, unit: "sections")
        observer?(.panels(kind, newPanels))
        prefetchFirstFrameImages(for: kind)
    }

    // Unlike panels, an empty result is a legitimate outcome here (the account just has no
    // favorites, or owns nothing yet) rather than something to retry as a failure.
    private func handleGameList(kind: GameListKind, success: Bool, games: [OPNCatalogGameObject], error: String) {
        defer { finishDelivery() }
        guard !retention.isHandoverFinished else { return }
        guard success else {
            gameListStates[kind] = .failed
            guard (gameLists[kind] ?? []).isEmpty else { return }
            OPNLog.warning(.catalog, "Launch \(kind.rawValue) prefetch failed error=\(error)")
            observer?(.gamesFailed(kind, error))
            return
        }
        gameListStates[kind] = .delivered
        gameLists[kind] = games
        StartupReadiness.shared.noteProgress()
        logDelivered(label: kind.rawValue, kind: nil, count: games.count, unit: "games")
        observer?(.games(kind, games))
    }

    private func logDelivered(label: String, kind: String?, count: Int, unit: String) {
        guard let startedAt else { return }
        let elapsed = startedAt.duration(to: .now).components
        let elapsedMs = Int(elapsed.seconds * 1000) + Int(elapsed.attoseconds / 1_000_000_000_000_000)
        let kindSuffix = kind.map { " kind=\($0)" } ?? ""
        OPNLog.info(.catalog, "Launch \(label) prefetch delivered\(kindSuffix) elapsed=\(elapsedMs)ms \(unit)=\(count)")
    }

    private func isActiveState(_ state: FetchState?) -> Bool {
        state == .inFlight || state == .delivered
    }

    // Only the artwork the first frame shows is worth priority bandwidth: the
    // hero plus the leading tiles of the first rails. Everything else is left to
    // the normal background prefetch once the rails scroll.
    private func prefetchFirstFrameImages(for kind: PanelKind) {
        var urls: [URL] = []
        var seen = Set<String>()
        switch kind {
        case .marquee:
            guard !didPrefetchHeroImages else { return }
            didPrefetchHeroImages = true
            let games = (panels[.marquee] ?? []).flatMap { $0.sections.flatMap(\.games) }
            // Only the slide on screen is warmed here. The hero view prefetches the next banner
            // during the current slide's five seconds, so decoding the rest now would only move
            // work into the launch spike.
            for game in games.prefix(1) {
                append(game.bestMarqueeHeroImageURL, width: 1920, into: &urls, seen: &seen)
                append(game.bestLogoImageURL, width: 620, into: &urls, seen: &seen)
            }
            // Retains the compressed bytes: the hero reads its scrim colour out of them, so an
            // entry without them is a miss and a second decode of the largest artwork in the app.
            imageCache.prefetchPriority(urls, maxPixelSize: 1920, retainingSourceData: true)
        case .main:
            guard !didPrefetchRailImages else { return }
            didPrefetchRailImages = true
            let sections = (panels[.main] ?? []).flatMap(\.sections).filter { !$0.games.isEmpty }
            for section in sections.prefix(2) {
                for game in section.games.prefix(4) {
                    append(game.bestWideImageURL, width: 768, into: &urls, seen: &seen)
                }
                for tile in section.tiles.prefix(2) {
                    append(tile.imageUrl, width: 768, into: &urls, seen: &seen)
                }
            }
            imageCache.prefetchPriority(urls, maxPixelSize: 768, retainingSourceData: false)
        }
    }

    private func append(_ rawValue: String, width: Int, into urls: inout [URL], seen: inout Set<String>) {
        guard !rawValue.isEmpty else { return }
        let optimized = OPNGameService.optimizeImageURL(rawValue, width: width)
        guard let url = URL(string: optimized.isEmpty ? rawValue : optimized) else { return }
        let key = url.absoluteString
        guard seen.insert(key).inserted else { return }
        urls.append(url)
    }
}
