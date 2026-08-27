//
//  CatalogLaunchPrefetch.swift
//  OpenNOW
//

import Foundation

/// Fetches the home panels at process launch, before the catalog view exists.
///
/// Without this the first panel request cannot start until SwiftUI has built the
/// scene, resolved the active session and mounted `CatalogView`, so the whole
/// round trip happens after the splash screen instead of underneath it. The
/// catalog view model adopts whatever this has (or has in flight) through
/// `attach(accountIdentifier:onEvent:)` rather than issuing the same query again.
@MainActor
final class CatalogLaunchPrefetch {
    static let shared = CatalogLaunchPrefetch()

    enum PanelKind: String {
        case marquee
        case main
    }

    enum Event {
        case panels(PanelKind, [OPNCatalogPanelObject])
        case failed(PanelKind, String)
    }

    struct Attachment {
        var marquee = false
        var main = false

        var isEmpty: Bool { !marquee && !main }
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
    private var marqueePanels: [OPNCatalogPanelObject] = []
    private var mainPanels: [OPNCatalogPanelObject] = []
    private var marqueeState = FetchState.idle
    private var mainState = FetchState.idle
    private var observer: ((Event) -> Void)?
    private var startedAt: ContinuousClock.Instant?
    private var didPrefetchHeroImages = false
    private var didPrefetchRailImages = false

    private init() {}

    var hasHomePanels: Bool { !mainPanels.isEmpty }

    var isFetching: Bool { marqueeState == .inFlight || mainState == .inFlight }

    func start(accountIdentifier: String, accessToken: String, idToken: String) {
        guard marqueeState == .idle, mainState == .idle else { return }
        guard !accountIdentifier.isEmpty, !accessToken.isEmpty || !idToken.isEmpty else { return }
        self.accountIdentifier = accountIdentifier
        marqueeState = .inFlight
        mainState = .inFlight
        startedAt = ContinuousClock.now
        // Also prewarms the vpcId lookup, which every catalog query waits on.
        gameService.configureCatalogSession(accessToken: accessToken, idToken: idToken, userId: accountIdentifier)
        OpenNOWLog.info(.catalog, "Launch panel prefetch started")
        gameService.fetchMarqueePanelObjects { [weak self] success, panels, error in
            self?.handle(kind: .marquee, success: success, panels: panels, error: error)
        }
        gameService.fetchMainPanelObjects { [weak self] success, panels, error in
            self?.handle(kind: .main, success: success, panels: panels, error: error)
        }
    }

    /// Reports which panel kinds the caller can leave to this prefetch. A kind
    /// that already failed (or was never started) is not adopted, so the caller
    /// still fetches it itself.
    func attach(accountIdentifier: String, onEvent: @escaping (Event) -> Void) -> Attachment {
        guard !accountIdentifier.isEmpty, accountIdentifier == self.accountIdentifier else { return Attachment() }
        var attachment = Attachment()
        attachment.marquee = marqueeState == .inFlight || marqueeState == .delivered
        attachment.main = mainState == .inFlight || mainState == .delivered
        // Panels primed from the disk cache are still worth handing over even when
        // the caller keeps ownership of the network fetch: they paint now.
        let hasStoredPanels = !marqueePanels.isEmpty || !mainPanels.isEmpty
        guard !attachment.isEmpty || hasStoredPanels else { return Attachment() }
        observer = onEvent
        if !marqueePanels.isEmpty { onEvent(.panels(.marquee, marqueePanels)) }
        if !mainPanels.isEmpty { onEvent(.panels(.main, mainPanels)) }
        return attachment
    }

    /// Paints from the panel disk cache without a usable token. A launch whose
    /// stored session has expired has to refresh auth before it can fetch anything,
    /// which is seconds of skeleton for data that is already on disk. States stay
    /// idle so the catalog view model still runs its own fetch once auth is ready.
    func primeFromCache(accountIdentifier: String) {
        guard self.accountIdentifier.isEmpty || self.accountIdentifier == accountIdentifier else { return }
        guard !accountIdentifier.isEmpty else { return }
        self.accountIdentifier = accountIdentifier
        for kind in [PanelKind.marquee, PanelKind.main] {
            gameService.loadCachedPanels(cacheKind: kind.rawValue, accountIdentifier: accountIdentifier) { [weak self] cachedPanels in
                guard let cachedPanels, !cachedPanels.isEmpty else { return }
                let panels = cachedPanels.map(OPNCatalogPanelObject.init)
                Task { @MainActor in
                    self?.applyCachedPanels(panels, for: kind)
                }
            }
        }
    }

    private func applyCachedPanels(_ panels: [OPNCatalogPanelObject], for kind: PanelKind) {
        guard storedPanels(for: kind).isEmpty else { return }
        switch kind {
        case .marquee:
            marqueePanels = panels
        case .main:
            mainPanels = panels
        }
        OpenNOWLog.info(.catalog, "Launch panel prime from cache kind=\(kind.rawValue) sections=\(panels.flatMap(\.sections).count)")
        observer?(.panels(kind, panels))
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
        marqueePanels = []
        mainPanels = []
        marqueeState = .idle
        mainState = .idle
        startedAt = nil
        didPrefetchHeroImages = false
        didPrefetchRailImages = false
    }

    private func handle(kind: PanelKind, success: Bool, panels: [OPNCatalogPanelObject], error: String) {
        guard success, !panels.isEmpty else {
            let message = error.isEmpty ? "No \(kind.rawValue) panels returned." : error
            setState(.failed, for: kind)
            guard storedPanels(for: kind).isEmpty else { return }
            OpenNOWLog.warning(.catalog, "Launch panel prefetch failed kind=\(kind.rawValue) error=\(message)")
            observer?(.failed(kind, message))
            return
        }

        setState(.delivered, for: kind)
        switch kind {
        case .marquee:
            marqueePanels = panels
        case .main:
            mainPanels = panels
        }
        if let startedAt {
            let elapsed = startedAt.duration(to: .now).components
            let elapsedMs = Int(elapsed.seconds * 1000) + Int(elapsed.attoseconds / 1_000_000_000_000_000)
            OpenNOWLog.info(.catalog, "Launch panel prefetch delivered kind=\(kind.rawValue) elapsed=\(elapsedMs)ms sections=\(panels.flatMap(\.sections).count)")
        }
        observer?(.panels(kind, panels))
        prefetchFirstFrameImages(for: kind)
    }

    private func setState(_ state: FetchState, for kind: PanelKind) {
        switch kind {
        case .marquee:
            marqueeState = state
        case .main:
            mainState = state
        }
    }

    private func storedPanels(for kind: PanelKind) -> [OPNCatalogPanelObject] {
        switch kind {
        case .marquee:
            return marqueePanels
        case .main:
            return mainPanels
        }
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
            let games = marqueePanels.flatMap { $0.sections.flatMap(\.games) }
            for game in games.prefix(3) {
                append(game.bestMarqueeHeroImageURL, width: 1920, into: &urls, seen: &seen)
                append(game.bestLogoImageURL, width: 620, into: &urls, seen: &seen)
            }
            imageCache.prefetchPriority(urls, maxPixelSize: 1920)
        case .main:
            guard !didPrefetchRailImages else { return }
            didPrefetchRailImages = true
            let sections = mainPanels.flatMap(\.sections).filter { !$0.games.isEmpty }
            for section in sections.prefix(2) {
                for game in section.games.prefix(8) {
                    append(game.bestWideImageURL, width: 768, into: &urls, seen: &seen)
                }
                for tile in section.tiles.prefix(2) {
                    append(tile.imageUrl, width: 768, into: &urls, seen: &seen)
                }
            }
            imageCache.prefetchPriority(urls, maxPixelSize: 768)
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
