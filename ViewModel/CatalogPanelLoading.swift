//  Loading what the catalog shows: home panels, library and favourites, the account's stores,
//  and the image cache behind the artwork. Split out of CatalogViewModel.swift.
//

import Foundation
import Observation

extension CatalogViewModel {
    func refreshCatalogImageCacheSummary() {
        Task { @MainActor in
            let statistics = await imageCache.statistics()
            catalogImageCacheSummary = Self.formattedCacheSummary(statistics)
        }
    }

    func clearCatalogImageCache() {
        Task { @MainActor in
            let cleared = await imageCache.clear()
            actionMessage = cleared ? "Catalog image cache cleared." : "Unable to clear catalog image cache."
            refreshCatalogImageCacheSummary()
        }
    }

    func optimizedImageURL(_ rawValue: String, width: Int) -> URL? {
        guard !rawValue.isEmpty else { return nil }
        let optimized = OPNGameService.optimizeImageURL(rawValue, width: width)
        return URL(string: optimized.isEmpty ? rawValue : optimized)
    }

    static func formattedCacheSummary(_ statistics: CatalogImageCacheStatistics) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        let bytes = formatter.string(fromByteCount: Int64(statistics.totalBytes))
        let entryLabel = statistics.entryCount == 1 ? "entry" : "entries"
        return "\(bytes) / \(statistics.entryCount) \(entryLabel)"
    }

    func loadPanels() {
        isLoadingPanels = true
        isLoadingMarquee = true
        errorMessage = ""
        configureCatalogService()

        // The launch prefetch may already own (or have finished) these queries;
        // adopt whatever it has instead of asking for the same panels twice.
        let attachment = CatalogLaunchPrefetch.shared.attach(accountIdentifier: catalogAccountIdentifier) { [weak self] event in
            self?.handleLaunchPrefetchEvent(event)
        }
        if !attachment.marquee { loadMarqueePanels() }
        if !attachment.main { loadMainPanels() }
        if !attachment.isEmpty {
            OpenNOWLog.info(.catalog, "Adopted launch panel prefetch marquee=\(attachment.marquee) main=\(attachment.main)")
        }
    }

    func handleLaunchPrefetchEvent(_ event: CatalogLaunchPrefetch.Event) {
        switch event {
        case .panels(.marquee, let panels):
            isLoadingMarquee = false
            applyMarqueePanels(panels)
        case .panels(.main, let panels):
            isLoadingPanels = false
            applyMainPanels(panels)
        case .panelsFailed(.marquee, _):
            loadMarqueePanels()
        case .panelsFailed(.main, let message):
            if errorMessage.isEmpty { errorMessage = message }
            loadMainPanels()
        case .games(.favorites, let games):
            isLoadingFavorites = false
            updateFavoriteGames(games)
            schedulePatchingPollIfNeeded()
        case .gamesFailed(.favorites, _):
            fetchFavoritesFromNetwork()
        case .games(.library, let games):
            isLoadingLibrary = false
            libraryGames = games
            schedulePatchingPollIfNeeded()
        case .gamesFailed(.library, _):
            fetchLibraryFromNetwork()
        }
    }

    var catalogAccountIdentifier: String {
        session.userId.isEmpty ? account.userId : session.userId
    }

    func loadMarqueePanels() {
        let panelStartTime = CFAbsoluteTimeGetCurrent()
        gameService.fetchMarqueePanelObjects { [weak self] success, panels, error in
            guard let self else { return }
            self.isLoadingMarquee = false
            if success {
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - panelStartTime) * 1000)
                OpenNOWLog.info(.catalog, "Marquee panels loaded elapsed=\(elapsedMs)ms sections=\(panels.flatMap(\.sections).count)")
                self.applyMarqueePanels(panels)
            } else if self.refreshAuthIfNeeded(error: error) {
                self.isLoadingPanels = false
            } else if self.errorMessage.isEmpty {
                self.errorMessage = error
            }
        }
    }

    func loadMainPanels() {
        let panelStartTime = CFAbsoluteTimeGetCurrent()
        gameService.fetchMainPanelObjects { [weak self] success, panels, error in
            guard let self else { return }
            self.isLoadingPanels = false
            if success {
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - panelStartTime) * 1000)
                let gameCount = panels.flatMap(\.sections).flatMap(\.games).count
                OpenNOWLog.info(.catalog, "Main panels loaded elapsed=\(elapsedMs)ms games=\(gameCount)")
                self.applyMainPanels(panels)
            } else if self.refreshAuthIfNeeded(error: error) {
                self.isLoadingPanels = false
            } else if self.errorMessage.isEmpty {
                self.errorMessage = error.isEmpty ? "Unable to load GeForce NOW home panels." : error
            }
        }
    }

    // Panels are delivered more than once per fetch (disk cache, parsed response,
    // then metadata-enriched response). Assigning an identical set again rebuilds
    // every rail for nothing, so identical redeliveries are dropped.
    func applyMarqueePanels(_ panels: [OPNCatalogPanelObject]) {
        let fingerprint = Self.panelsFingerprint(panels)
        guard fingerprint != appliedMarqueePanelsFingerprint else { return }
        appliedMarqueePanelsFingerprint = fingerprint
        marqueePanels = panels
        schedulePatchingPollIfNeeded()
    }

    func applyMainPanels(_ panels: [OPNCatalogPanelObject]) {
        let fingerprint = Self.panelsFingerprint(panels)
        guard fingerprint != appliedMainPanelsFingerprint else { return }
        appliedMainPanelsFingerprint = fingerprint
        mainPanels = panels
        schedulePatchingPollIfNeeded()
    }

    static func panelsFingerprint(_ panels: [OPNCatalogPanelObject]) -> Int {
        var hasher = Hasher()
        for panel in panels {
            hasher.combine(panel.id)
            hasher.combine(panel.sections.count)
            for section in panel.sections {
                hasher.combine(section.id)
                hasher.combine(section.games.count)
                hasher.combine(section.tiles.count)
                for game in section.games {
                    hasher.combine(game.id)
                    hasher.combine(game.promoTag)
                    hasher.combine(game.skuTags)
                    hasher.combine(game.isFreeToPlay)
                    hasher.combine(game.isInLibrary)
                    hasher.combine(game.isFavorited)
                    hasher.combine(game.isPatching)
                }
            }
        }
        return hasher.finalize()
    }

    func loadLibrary() {
        configureCatalogService()
        isLoadingLibrary = true
        // See `loadFavorites()`: the launch prefetch fires this alongside the home panels, under
        // the splash screen, so it has often already arrived by the time this gate lets it through.
        let attachment = CatalogLaunchPrefetch.shared.attach(accountIdentifier: catalogAccountIdentifier) { [weak self] event in
            self?.handleLaunchPrefetchEvent(event)
        }
        guard !attachment.library else {
            OpenNOWLog.info(.catalog, "Adopted launch library prefetch")
            return
        }
        fetchLibraryFromNetwork()
    }

    func fetchLibraryFromNetwork() {
        gameService.fetchLibraryGameObjects { [weak self] success, games, error in
            guard let self else { return }
            self.isLoadingLibrary = false
            if success {
                self.libraryGames = games
                self.schedulePatchingPollIfNeeded()
            } else if self.refreshAuthIfNeeded(error: error) {
                self.libraryGames = []
            }
        }
    }

    func loadFavorites() {
        configureCatalogService()
        isLoadingFavorites = true
        // The launch prefetch fires this alongside the home panels, under the splash screen, so
        // by the time the panels rail unblocks this call it has often already arrived (or arrives
        // moments later through the same observer `loadPanels()` already registered). Adopt it
        // instead of paying for a second, later round trip.
        let attachment = CatalogLaunchPrefetch.shared.attach(accountIdentifier: catalogAccountIdentifier) { [weak self] event in
            self?.handleLaunchPrefetchEvent(event)
        }
        guard !attachment.favorites else {
            OpenNOWLog.info(.catalog, "Adopted launch favorites prefetch")
            return
        }
        fetchFavoritesFromNetwork()
    }

    func fetchFavoritesFromNetwork() {
        gameService.fetchFavoriteGameObjects { [weak self] success, games, error in
            guard let self else { return }
            self.isLoadingFavorites = false
            if success {
                self.updateFavoriteGames(games)
                self.schedulePatchingPollIfNeeded()
            } else if self.refreshAuthIfNeeded(error: error) {
                self.updateFavoriteGames([])
            }
        }
    }

    func updateFavoriteGames(_ games: [OPNCatalogGameObject]) {
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

    func loadAccountAndStores() {
        configureCatalogService()
        gameService.fetchUserAccount { [weak self] success, account, error in
            guard let self else { return }
            if success {
                self.accountStores = CatalogAccountParsing.parseStoreAccounts(account)
                self.accountSubscriptions = CatalogAccountParsing.parseAccountSubscriptions(account)
            } else if self.refreshAuthIfNeeded(error: error) {
                self.accountStores = []
                self.accountSubscriptions = []
            }
        }
        gameService.fetchStoreDefinitions { [weak self] success, definitions, _ in
            guard let self else { return }
            if success { self.storeDefinitions = definitions.map(CatalogAccountParsing.parseStoreDefinition) }
        }
        gameService.fetchSubscriptionDefinitions { [weak self] success, definitions, _ in
            guard let self else { return }
            if success { self.subscriptionDefinitions = definitions.map(CatalogAccountParsing.parseSubscriptionDefinition) }
        }
        let userId = session.userId.isEmpty ? account.userId : session.userId
        guard !userId.isEmpty else {
            subscriptionStatus = .unavailable
            return
        }
        gameService.fetchSubscriptionInfo(userId: userId) { [weak self] success, subscription, error in
            guard let self else { return }
            if success {
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
