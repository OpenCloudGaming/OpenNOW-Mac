//
//  CatalogLaunchPrefetch.swift
//  OpenNOW
//

import Foundation

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

    private let gameService = OPNGameService.shared
    private let imageCache = CatalogImageCache.shared

    private(set) var accountIdentifier = ""
    private var panels: [PanelKind: [OPNCatalogPanelObject]] = [:]
    private var panelStates: [PanelKind: FetchState] = [:]
    private var gameLists: [GameListKind: [OPNCatalogGameObject]] = [:]
    private var gameListStates: [GameListKind: FetchState] = [:]
    private var observer: ((Event) -> Void)?
    private var startedAt: ContinuousClock.Instant?
    private var didPrefetchHeroImages = false
    private var didPrefetchRailImages = false

    private init() {}

    var hasHomePanels: Bool { !(panels[.main] ?? []).isEmpty }

    var isFetching: Bool { isActiveState(panelStates[.marquee]) || isActiveState(panelStates[.main]) }

    func start(accountIdentifier: String, accessToken: String, idToken: String) {
        guard (panelStates[.marquee] ?? .idle) == .idle, (panelStates[.main] ?? .idle) == .idle else { return }
        guard !accountIdentifier.isEmpty, !accessToken.isEmpty || !idToken.isEmpty else { return }
        self.accountIdentifier = accountIdentifier
        for kind in PanelKind.allCases { panelStates[kind] = .inFlight }
        for kind in GameListKind.allCases { gameListStates[kind] = .inFlight }
        startedAt = ContinuousClock.now
        // Also prewarms the vpcId lookup, which every catalog query waits on.
        gameService.configureCatalogSession(accessToken: accessToken, idToken: idToken, userId: accountIdentifier)
        OpenNOWLog.info(.catalog, "Launch panel prefetch started")
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
            if let stored = gameLists[kind], !stored.isEmpty { onEvent(.games(kind, stored)) }
        }
        return attachment
    }

    /// Paints from the panel disk cache without a usable token. A launch whose stored session has
    /// expired has to refresh auth before it can fetch anything, which is seconds of skeleton for
    /// data that is already on disk. States stay idle so the catalog view model still runs its own
    /// fetch once auth is ready. Favorites/library have no disk cache of their own to prime from.
    func primeFromCache(accountIdentifier: String) {
        guard self.accountIdentifier.isEmpty || self.accountIdentifier == accountIdentifier else { return }
        guard !accountIdentifier.isEmpty else { return }
        self.accountIdentifier = accountIdentifier
        for kind in PanelKind.allCases {
            gameService.loadCachedPanels(cacheKind: kind.rawValue, accountIdentifier: accountIdentifier) { [weak self] cachedPanels in
                guard let cachedPanels, !cachedPanels.isEmpty else { return }
                let panels = cachedPanels.map(OPNCatalogPanelObject.init)
                Task { @MainActor in
                    self?.applyCachedPanels(panels, for: kind)
                }
            }
        }
    }

    private func applyCachedPanels(_ cached: [OPNCatalogPanelObject], for kind: PanelKind) {
        guard (panels[kind] ?? []).isEmpty else { return }
        panels[kind] = cached
        OpenNOWLog.info(.catalog, "Launch panel prime from cache kind=\(kind.rawValue) sections=\(cached.flatMap(\.sections).count)")
        observer?(.panels(kind, cached))
        prefetchFirstFrameImages(for: kind)
    }

    func detach() {
        observer = nil
    }

    /// Drops everything so a later explicit refresh goes to the network instead
    /// of adopting launch-time results.
    func invalidate() {
        observer = nil
        accountIdentifier = ""
        panels = [:]
        panelStates = [:]
        gameLists = [:]
        gameListStates = [:]
        startedAt = nil
        didPrefetchHeroImages = false
        didPrefetchRailImages = false
    }

    private func handlePanels(kind: PanelKind, success: Bool, panels newPanels: [OPNCatalogPanelObject], error: String) {
        guard success, !newPanels.isEmpty else {
            let message = error.isEmpty ? "No \(kind.rawValue) panels returned." : error
            panelStates[kind] = .failed
            guard (panels[kind] ?? []).isEmpty else { return }
            OpenNOWLog.warning(.catalog, "Launch panel prefetch failed kind=\(kind.rawValue) error=\(message)")
            observer?(.panelsFailed(kind, message))
            return
        }

        panelStates[kind] = .delivered
        panels[kind] = newPanels
        logDelivered(label: "panel", kind: kind.rawValue, count: newPanels.flatMap(\.sections).count, unit: "sections")
        observer?(.panels(kind, newPanels))
        prefetchFirstFrameImages(for: kind)
    }

    // Unlike panels, an empty result is a legitimate outcome here (the account just has no
    // favorites, or owns nothing yet) rather than something to retry as a failure.
    private func handleGameList(kind: GameListKind, success: Bool, games: [OPNCatalogGameObject], error: String) {
        guard success else {
            gameListStates[kind] = .failed
            guard (gameLists[kind] ?? []).isEmpty else { return }
            OpenNOWLog.warning(.catalog, "Launch \(kind.rawValue) prefetch failed error=\(error)")
            observer?(.gamesFailed(kind, error))
            return
        }
        gameListStates[kind] = .delivered
        gameLists[kind] = games
        logDelivered(label: kind.rawValue, kind: nil, count: games.count, unit: "games")
        observer?(.games(kind, games))
    }

    private func logDelivered(label: String, kind: String?, count: Int, unit: String) {
        guard let startedAt else { return }
        let elapsed = startedAt.duration(to: .now).components
        let elapsedMs = Int(elapsed.seconds * 1000) + Int(elapsed.attoseconds / 1_000_000_000_000_000)
        let kindSuffix = kind.map { " kind=\($0)" } ?? ""
        OpenNOWLog.info(.catalog, "Launch \(label) prefetch delivered\(kindSuffix) elapsed=\(elapsedMs)ms \(unit)=\(count)")
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
            for game in games.prefix(3) {
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
                for game in section.games.prefix(8) {
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
