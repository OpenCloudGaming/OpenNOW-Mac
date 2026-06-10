import Foundation

private final class OPNCatalogWeakObject<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}

private final class OPNCatalogSendableValue<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

private func opnCatalogAppendFingerprintField(_ fingerprint: inout String, _ value: String) {
    fingerprint += "\(value.count):\(value)|"
}

private func opnCatalogFingerprintList(_ values: [String]) -> String {
    var fingerprint = "["
    for value in values.sorted() { opnCatalogAppendFingerprintField(&fingerprint, value) }
    fingerprint += "]"
    return fingerprint
}

private func opnCatalogGameLibraryFingerprint(_ games: [OPNCatalogGameObject]) -> String {
    var entries: [String] = []
    entries.reserveCapacity(games.count)
    for game in games {
        var entry = ""
        opnCatalogAppendFingerprintField(&entry, game.id)
        opnCatalogAppendFingerprintField(&entry, game.uuid)
        opnCatalogAppendFingerprintField(&entry, game.launchAppId)
        opnCatalogAppendFingerprintField(&entry, game.title)
        opnCatalogAppendFingerprintField(&entry, game.shortName)
        opnCatalogAppendFingerprintField(&entry, game.playabilityState)
        opnCatalogAppendFingerprintField(&entry, game.imageUrl)
        opnCatalogAppendFingerprintField(&entry, opnCatalogFingerprintList(game.availableStores))
        opnCatalogAppendFingerprintField(&entry, opnCatalogFingerprintList(game.genres))
        let variantEntries = game.variants.map { variant in
            var variantEntry = ""
            opnCatalogAppendFingerprintField(&variantEntry, variant.id)
            opnCatalogAppendFingerprintField(&variantEntry, variant.appStore)
            opnCatalogAppendFingerprintField(&variantEntry, variant.storeUrl)
            opnCatalogAppendFingerprintField(&variantEntry, variant.serviceStatus)
            opnCatalogAppendFingerprintField(&variantEntry, variant.librarySelected ? "1" : "0")
            opnCatalogAppendFingerprintField(&variantEntry, variant.inLibrary ? "1" : "0")
            return variantEntry
        }
        opnCatalogAppendFingerprintField(&entry, opnCatalogFingerprintList(variantEntries))
        entries.append(entry)
    }
    var fingerprint = ""
    for entry in entries.sorted() { opnCatalogAppendFingerprintField(&fingerprint, entry) }
    return fingerprint
}

private func opnCatalogFeaturedGames(from panels: [OPNCatalogPanelObject]) -> ([OPNCatalogGameObject], Bool) {
    let limit = 6
    func textMatches(_ value: String) -> Bool { value.lowercased().contains("featured") }
    func identity(_ game: OPNCatalogGameObject) -> String {
        if !game.id.isEmpty { return game.id }
        if !game.uuid.isEmpty { return game.uuid }
        if !game.launchAppId.isEmpty { return game.launchAppId }
        return game.title
    }
    func appendUnique(_ game: OPNCatalogGameObject, to games: inout [OPNCatalogGameObject], seen: inout Set<String>) {
        let id = identity(game)
        guard !id.isEmpty, !seen.contains(id) else { return }
        seen.insert(id)
        games.append(game)
    }

    var explicit: [OPNCatalogGameObject] = []
    var explicitSeen = Set<String>()
    for panel in panels {
        let panelFeatured = textMatches(panel.title) || textMatches(panel.id)
        for section in panel.sections where panelFeatured || textMatches(section.title) || textMatches(section.id) {
            for game in section.games { appendUnique(game, to: &explicit, seen: &explicitSeen) }
        }
    }
    if !explicit.isEmpty { return (Array(explicit.prefix(limit)), true) }

    var curated: [OPNCatalogGameObject] = []
    var curatedSeen = Set<String>()
    for panel in panels {
        for section in panel.sections {
            for game in section.games { appendUnique(game, to: &curated, seen: &curatedSeen) }
        }
    }
    return (Array(curated.prefix(limit)), false)
}

private func opnCatalogPerformInt(_ object: NSObject, _ selectorName: String, _ value: Int32) {
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector) else { return }
    typealias Message = @convention(c) (AnyObject, Selector, Int32) -> Void
    unsafeBitCast(object.method(for: selector), to: Message.self)(object, selector, value)
}

@MainActor
extension OPNAppDelegateLegacy {
    @objc(loadStorePanelsWithRetry:)
    func loadStorePanels(canRetry: Bool) {
        guard let storeView else { return }
        storeView.setLoading(true)
        let accountIdentifier = OPNAppDelegateSupport.authSessionIdentifier(currentSession)
        OPNGameServiceSwiftAdapter.setAccessToken(OPNAppDelegateSupport.authSessionToken(currentSession))
        OPNGameServiceSwiftAdapter.setVpcId("GFN-PC")
        let selfBox = OPNCatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.fetchMainPanelObjects { success, panelObjects, error in
            let panelBox = OPNCatalogSendableValue(panelObjects)
            Task { @MainActor in
                guard let self = selfBox.value, accountIdentifier == OPNAppDelegateSupport.authSessionIdentifier(self.currentSession) else { return }
                if !success && canRetry && error.contains("401") {
                    self.refreshCatalogAuth { refreshed in
                        if refreshed { self.loadStorePanels(canRetry: false) }
                    }
                    return
                }
                guard let storeView = self.storeView, self.currentScreen == 2 else { return }
                guard success else {
                    storeView.setError(error.isEmpty ? "Unable to load Store collections." : error)
                    return
                }
                self.cachedStorePanelObjects = panelBox.value
                self.cachedStorePanelsAccountIdentifier = accountIdentifier
                self.hasCachedStorePanels = true
                storeView.setPanelObjects(panelBox.value)
                storeView.setLoading(false)
            }
        }
    }

    @objc func startGameLibraryRefreshTimer() {
        guard gameLibraryRefreshTimer == nil else { return }
        gameLibraryRefreshTimer = Timer.scheduledTimer(timeInterval: 30.0 * 60.0, target: self, selector: #selector(gameLibraryRefreshTimerFired(_:)), userInfo: nil, repeats: true)
    }

    @objc func stopGameLibraryRefreshTimer() {
        gameLibraryRefreshTimer?.invalidate()
        gameLibraryRefreshTimer = nil
    }

    @objc func gameLibraryRefreshTimerFired(_ timer: Timer) {
        _ = timer
        refreshGameLibraryInBackground()
    }

    @objc func refreshGameLibraryInBackground() {
        guard currentSession.isAuthenticated, !currentSession.accessToken.isEmpty, !gameLibraryRefreshInFlight else { return }
        gameLibraryRefreshInFlight = true
        let accountIdentifier = OPNAppDelegateSupport.authSessionIdentifier(currentSession)
        fetchGameLibrary(canRetry: true) { success, games in
            guard accountIdentifier == OPNAppDelegateSupport.authSessionIdentifier(self.currentSession) else { self.gameLibraryRefreshInFlight = false; return }
            self.gameLibraryRefreshInFlight = false
            guard success else { return }
            let fingerprint = opnCatalogGameLibraryFingerprint(games)
            let changed = !self.hasCachedGameLibrary || self.cachedGameLibraryAccountIdentifier != accountIdentifier || self.cachedGameLibraryFingerprint != fingerprint
            guard changed else { return }
            self.cachedGameLibraryObjects = games
            self.cachedGameLibraryFingerprint = fingerprint
            self.cachedGameLibraryAccountIdentifier = accountIdentifier
            self.hasCachedGameLibrary = true
            if self.currentScreen == 3, let catalogView = self.catalogView { catalogView.setGameObjects(games) }
            else if self.currentScreen == 2, let storeView = self.storeView { storeView.setLibraryGameObjects(games) }
        }
    }

    @objc func loadGamesIntoCatalog() {
        loadGamesIntoCatalog(canRetry: true)
    }

    @objc(loadGamesIntoCatalogWithRetry:)
    func loadGamesIntoCatalog(canRetry: Bool) {
        guard catalogView != nil else { return }
        refreshFeaturedGamesForCatalog(canRetry: canRetry)
        refreshActiveSessionsForCatalog()
        browseCatalog(searchQuery: "", sortId: "last_played", filterIds: [], canRetry: canRetry, retryAttempt: 0)
    }

    @objc func refreshActiveSessionsForCatalog() {
        guard catalogView != nil, !activeSessionsRefreshInFlight else { return }
        activeSessionsRefreshInFlight = true
        let accountIdentifier = OPNAppDelegateSupport.authSessionIdentifier(currentSession)
        let apiToken = OPNAppDelegateSupport.authSessionToken(currentSession)
        let selfBox = OPNCatalogWeakObject(self)
        OPNActiveSessionService.fetchActiveSessions(accessToken: apiToken) { ok, sessions, error in
            let sessionsBox = OPNCatalogSendableValue(sessions)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                self.activeSessionsRefreshInFlight = false
                guard accountIdentifier == OPNAppDelegateSupport.authSessionIdentifier(self.currentSession), let catalogView = self.catalogView, self.currentScreen == 3 else { return }
                guard ok else {
                    OPNSentry.logErrorMessage("[AppDelegate] Active session hero-state fetch failed: \(error)")
                    catalogView.setActiveSessionAppIds([])
                    return
                }
                let appIds = sessionsBox.value.filter { [1, 2, 3, 6].contains($0.status) && $0.appId > 0 }.map { NSNumber(value: $0.appId) }
                catalogView.setActiveSessionAppIds(appIds)
            }
        }
    }

    @objc(refreshFeaturedGamesForCatalogWithRetry:)
    func refreshFeaturedGamesForCatalog(canRetry: Bool) {
        guard (catalogView != nil || storeView != nil), !featuredGamesRefreshInFlight else { return }
        let accountIdentifier = OPNAppDelegateSupport.authSessionIdentifier(currentSession)
        if hasCachedFeaturedGames && cachedFeaturedGamesAccountIdentifier == accountIdentifier {
            catalogView?.setFeaturedGameObjects(cachedFeaturedGameObjects)
            storeView?.setFeaturedGameObjects(cachedFeaturedGameObjects)
            return
        }
        featuredGamesRefreshInFlight = true
        OPNGameServiceSwiftAdapter.setAccessToken(OPNAppDelegateSupport.authSessionToken(currentSession))
        OPNGameServiceSwiftAdapter.setVpcId("GFN-PC")
        let selfBox = OPNCatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.fetchMarqueePanelObjects { success, panelObjects, error in
            let panelBox = OPNCatalogSendableValue(panelObjects)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                guard accountIdentifier == OPNAppDelegateSupport.authSessionIdentifier(self.currentSession) else { self.featuredGamesRefreshInFlight = false; return }
                if !success && canRetry && error.contains("401") {
                    self.featuredGamesRefreshInFlight = false
                    self.refreshCatalogAuth { refreshed in
                        if refreshed { self.refreshFeaturedGamesForCatalog(canRetry: false) }
                    }
                    return
                }
                self.featuredGamesRefreshInFlight = false
                guard success else {
                    OPNSentry.logErrorMessage("[AppDelegate] Marquee featured games fetch failed: \(error)")
                    return
                }
                let featured = opnCatalogFeaturedGames(from: panelBox.value)
                OPNSentry.logInfoMessage("[AppDelegate] featured games resolved from marquee count=\(featured.0.count) explicit=\(featured.1)")
                self.cachedFeaturedGameObjects = featured.0
                self.cachedFeaturedGamesAccountIdentifier = accountIdentifier
                self.hasCachedFeaturedGames = true
                if self.currentScreen == 3 { self.catalogView?.setFeaturedGameObjects(featured.0) }
                if self.currentScreen == 2 { self.storeView?.setFeaturedGameObjects(featured.0) }
            }
        }
    }

    func browseCatalog(searchQuery: String, sortId: String, filterIds: [String], canRetry: Bool, retryAttempt: Int) {
        guard let catalogView else { return }
        catalogBrowseGeneration += 1
        let requestGeneration = catalogBrowseGeneration
        OPNSentry.logInfoMessage("[CatalogBrowse] request start generation=\(requestGeneration) search=\(searchQuery) sort=\(sortId) filters=\(filterIds.count) retryAttempt=\(retryAttempt)")
        let accountIdentifier = OPNAppDelegateSupport.authSessionIdentifier(currentSession)
        OPNGameServiceSwiftAdapter.setAccessToken(OPNAppDelegateSupport.authSessionToken(currentSession))
        OPNGameServiceSwiftAdapter.setUserId(accountIdentifier)
        OPNGameServiceSwiftAdapter.setVpcId("GFN-PC")
        catalogView.setLoading(true)
        let selfBox = OPNCatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.browseCatalogObject(searchQuery: searchQuery, sortId: sortId.isEmpty ? "last_played" : sortId, filterIds: filterIds, fetchCount: 96) { success, result, error in
            let resultBox = OPNCatalogSendableValue(result)
            Task { @MainActor in
                guard let self = selfBox.value, requestGeneration == self.catalogBrowseGeneration else { return }
                guard accountIdentifier == OPNAppDelegateSupport.authSessionIdentifier(self.currentSession) else { return }
                if !success && canRetry && error.contains("401") {
                    self.refreshCatalogAuth { refreshed in
                        if refreshed { self.browseCatalog(searchQuery: searchQuery, sortId: sortId, filterIds: filterIds, canRetry: false, retryAttempt: retryAttempt) }
                        else { self.catalogView?.setLoading(false); opnCatalogPerformInt(self, "transitionToScreen:", 0) }
                    }
                    return
                }
                if !success {
                    if canRetry && OPNAppDelegateSupport.transientNetworkLostError(error) && retryAttempt < 10 {
                        let nextAttempt = retryAttempt + 1
                        let delay = pow(2.0, Double(retryAttempt))
                        OPNSentry.logErrorMessage("[AppDelegate] Catalog browse network lost; retry \(nextAttempt)/10 in \(Int(delay))s")
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            guard let self = selfBox.value, requestGeneration == self.catalogBrowseGeneration, accountIdentifier == OPNAppDelegateSupport.authSessionIdentifier(self.currentSession), self.catalogView != nil, self.currentScreen == 3 else { return }
                            self.browseCatalog(searchQuery: searchQuery, sortId: sortId, filterIds: filterIds, canRetry: canRetry, retryAttempt: nextAttempt)
                        }
                        return
                    }
                    self.catalogView?.setLoading(false)
                    self.catalogView?.setError(error.isEmpty ? "Unable to browse catalog." : error)
                    return
                }
                self.catalogView?.setLoading(false)
                self.cachedGameLibraryObjects = resultBox.value.games
                self.cachedGameLibraryFingerprint = opnCatalogGameLibraryFingerprint(resultBox.value.games)
                self.cachedGameLibraryAccountIdentifier = accountIdentifier
                self.hasCachedGameLibrary = true
                self.catalogView?.setCatalogBrowseResultObject(resultBox.value)
                self.startGameLibraryRefreshTimer()
            }
        }
    }

    func fetchGameLibrary(canRetry: Bool, completion: @escaping @MainActor (Bool, [OPNCatalogGameObject]) -> Void) {
        let accountIdentifier = OPNAppDelegateSupport.authSessionIdentifier(currentSession)
        OPNGameServiceSwiftAdapter.setAccessToken(OPNAppDelegateSupport.authSessionToken(currentSession))
        OPNGameServiceSwiftAdapter.setUserId(accountIdentifier)
        OPNGameServiceSwiftAdapter.setVpcId("GFN-PC")
        let selfBox = OPNCatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.browseCatalogObject(searchQuery: "", sortId: "last_played", filterIds: [], fetchCount: 96) { success, result, error in
            let resultBox = OPNCatalogSendableValue(result)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                guard accountIdentifier == OPNAppDelegateSupport.authSessionIdentifier(self.currentSession) else { completion(false, []); return }
                if !success && canRetry && error.contains("401") {
                    self.refreshCatalogAuth { refreshed in
                        if refreshed { self.fetchGameLibrary(canRetry: false, completion: completion) }
                        else { completion(false, []) }
                    }
                    return
                }
                completion(success, success ? resultBox.value.games : [])
            }
        }
    }

    func refreshCatalogAuth(completion: @escaping @MainActor (Bool) -> Void) {
        let selfBox = OPNCatalogWeakObject(self)
        OPNAuthServiceDirect.shared.refreshSession(force: true) { success, freshObject, _ in
            let freshBox = OPNCatalogSendableValue(freshObject)
            Task { @MainActor in
                guard let self = selfBox.value else { completion(false); return }
                if success {
                    self.currentSession = freshBox.value
                    if self.pendingStayLoggedIn { OPNAuthServiceDirect.shared.saveSession(freshBox.value) }
                    self.refreshAccountMenu()
                    completion(true)
                    return
                }
                let fallback = OPNAuthServiceDirect.shared.loadSavedSession()
                if fallback.isAuthenticated && OPNAppDelegateSupport.authSessionAccessTokenValid(fallback) {
                    self.currentSession = fallback
                    opnCatalogPerformInt(self, "transitionToScreen:", 2)
                } else {
                    opnCatalogPerformInt(self, "transitionToScreen:", 0)
                }
                completion(false)
            }
        }
    }
}
