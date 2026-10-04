//  Launching a game: the catalog's side of a launch the application owns. The session itself lives in
//  `OPNGameSession`, at application scope, because a catalog is remounted on a browsing switch.

import Foundation
import Observation

extension CatalogViewModel {
    /// The session this catalog's account owns, if any. Nil when the running game belongs to another
    /// account, which is what keeps one account's game off another account's page.
    var gameSession: OPNGameSession? {
        guard let accountID = account.storedAccountID else { return nil }
        return sessionRegistry.session(ownedBy: accountID)
    }

    // MARK: - What the page reads

    var isLaunchFlowVisible: Bool { launchFlowState != .idle }

    /// A stream is live in its own window right now, which is what drives the page's running-session
    /// banner. Distinct from `isActiveHomeSessionVisible`, a suspended seat with no stream.
    var isStreamRunning: Bool { activeStreamConfiguration != nil }

    var activeStreamConfiguration: StreamLaunchConfiguration? { gameSession?.configuration }

    var activeStreamProgress: StreamProgress? { gameSession?.progress }

    var isActiveStreamLaunchOverlayVisible: Bool { gameSession?.isLaunchOverlayVisible ?? false }

    var canResumeActiveLaunchSession: Bool { gameSession?.canResumeActiveSession ?? false }

    /// The launch flow's phase, reduced to the states the page draws. `streaming` reads as idle here
    /// because the stream window owns that state, not the catalog's launch overlay.
    var launchFlowState: CatalogLaunchFlowState {
        switch gameSession?.phase {
        case .checkingSession: return .checkingSession
        case .activeSessionPrompt: return .activeSessionPrompt
        case .stoppingSession: return .stoppingSession
        // From here the stream window owns the screen, so the catalog's launch overlay is done.
        case .startingStream, .streaming, nil: return .idle
        }
    }

    var launchFlowTitle: String { gameSession?.launchFlowTitle ?? "" }

    /// The running stream's title, as the banner shows it. Falls back the same way the stream
    /// window's own title does, so the two never disagree.
    var runningStreamTitle: String { gameSession?.title ?? "" }

    /// The running stream's artwork, for the page backdrop.
    var runningStreamArtworkURL: URL? { gameSession?.artworkURL }

    /// This account's own device id, so the seat answers about this account rather than about the
    /// machine: two accounts can stream at once, and each has to look like its own device.
    var cloudmatchDeviceId: String {
        account.storedAccountID.map { OPNDeviceIdentity.cloudmatchDeviceId(accountID: $0) }
            ?? OPNDeviceIdentity.stableCloudmatchDeviceId()
    }

    /// Brings this account's own stream window forward. Another account's window is not what the
    /// reader asked for when they click this page's banner.
    func focusOwnedStreamWindow() {
        guard let gameSession else { return }
        OPNStreamWindowPresenter.shared.focus(gameSession.id)
    }

    /// Ends this account's own stream. Two accounts can stream at once, so the banner cannot mean
    /// "the last one started".
    func endOwnedStream() {
        guard let gameSession else { return }
        _ = StreamSessionLifecycle.sendCommand(.endSession, to: gameSession.id)
    }

    // MARK: - Launch entry points

    func launchSelectedGame() {
        guard let selectedGame else { return }
        launch(game: selectedGame, variantIndex: selectedVariantIndex)
    }

    func launch(game: OPNCatalogGameObject, variantIndex: Int? = nil) {
        beginVendorLaunch(game: game, variantIndex: variantIndex)
    }

    func queuePatchingLaunch(game: OPNCatalogGameObject, variantIndex: Int? = nil) {
        guard CatalogPatchStatusLogic.isPatching(game) else { return }
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
        OPNLog.info(.shortcut, "CatalogViewModel resolving shortcut cmsId=\(shortcut.cmsId) shortName=\(shortcut.shortName) parentGameId=\(shortcut.parentGameId) title=\(title)")
        setActionMessage("Opening \(title.isEmpty ? "GeForce NOW shortcut" : title)...")
        if let game = matchingGame(for: shortcut, in: allKnownGames) {
            OPNLog.info(.shortcut, "Resolved shortcut from loaded catalog: gameId=\(game.id) uuid=\(game.uuid) launchAppId=\(game.launchAppId) title=\(game.title)")
            selectGame(game)
            launch(game: game, variantIndex: variantIndex(for: shortcut, in: game))
            return
        }
        if Int(shortcut.cmsId) != nil {
            OPNLog.info(.shortcut, "Shortcut not found in loaded catalog; fetching CMS metadata cmsId=\(shortcut.cmsId)")
            gameService.fetchGameObjectByCMSId(shortcut.cmsId) { [weak self] success, game, error in
                guard let self else { return }
                if success, let game {
                    OPNLog.info(.shortcut, "Resolved shortcut from CMS metadata: gameId=\(game.id) uuid=\(game.uuid) title=\(game.title)")
                    self.selectGame(game)
                    self.launch(game: game, variantIndex: self.variantIndex(for: shortcut, in: game))
                    return
                }
                OPNLog.warning(.shortcut, "Shortcut CMS metadata lookup failed: \(error)")
                if let game = Self.launchGame(from: shortcut, title: title) {
                    OPNLog.info(.shortcut, "Launching shortcut directly from cmsId=\(shortcut.cmsId) title=\(game.title)")
                    self.selectGame(game)
                    self.launch(game: game, variantIndex: 0)
                } else {
                    self.resolveShortcutByBrowsing(shortcut, title: title)
                }
            }
            return
        }
        if let game = Self.launchGame(from: shortcut, title: title) {
            OPNLog.info(.shortcut, "Launching shortcut directly from cmsId=\(shortcut.cmsId) title=\(game.title)")
            selectGame(game)
            launch(game: game, variantIndex: 0)
            return
        }
        resolveShortcutByBrowsing(shortcut, title: title)
    }

    func resolveShortcutByBrowsing(_ shortcut: GFNGameShortcut, title: String) {
        OPNLog.info(.shortcut, "Shortcut not found in loaded catalog; browsing with query=\(title)")
        let deliveryGate = CatalogDeliveryGate()
        gameService.browseCatalogObject(searchQuery: title, sortId: "relevance", filterIds: [], fetchCount: 24) { [weak self] success, result, error in
            guard let self else { return }
            guard deliveryGate.claimFirstDelivery() else { return }
            guard success else {
                OPNLog.error(.shortcut, "Shortcut catalog browse failed: \(error)")
                self.reportLaunchFailure(error.isEmpty ? "Unable to resolve this GeForce NOW shortcut." : error)
                return
            }
            let games = result.games
            OPNLog.info(.shortcut, "Shortcut catalog browse returned \(games.count) game(s)")
            guard let game = self.matchingGame(for: shortcut, in: games) ?? games.first else {
                OPNLog.error(.shortcut, "Shortcut catalog browse returned no matching games")
                self.reportLaunchFailure("No matching GeForce NOW catalog game was found for this shortcut.")
                return
            }
            OPNLog.info(.shortcut, "Resolved shortcut from browse: gameId=\(game.id) uuid=\(game.uuid) launchAppId=\(game.launchAppId) title=\(game.title)")
            self.catalogGames = games
            self.selectGame(game)
            self.launch(game: game, variantIndex: self.variantIndex(for: shortcut, in: game))
        }
    }

    /// Accepts the intent, then hands it to an application-owned session. The session, not this
    /// catalog, owns the launch from here, so a browsing switch no longer abandons it.
    func beginVendorLaunch(game: OPNCatalogGameObject, variantIndex: Int? = nil) {
        OPNLog.info(.launch, "Beginning launch for gameId=\(game.id) uuid=\(game.uuid) launchAppId=\(game.launchAppId) title=\(game.title) requestedVariantIndex=\(variantIndex ?? -1)")
        errorMessage = ""
        launchErrorMessage = ""
        guard let gameSession = beginOwnedSession() else { return }
        gameSession.begin(game: game, variantIndex: variantIndex)
    }

    /// Admits an application-owned session for this account, before the vendor is asked for anything
    /// and before any window is replaced, or reports why it could not. Another account's game is not
    /// in the way: the limit is one game per account.
    private func beginOwnedSession() -> OPNGameSession? {
        guard let accountID = account.resolveStableAccountID() else {
            reportLaunchFailure("This account has no saved identity to start a game with. Sign in again.")
            return nil
        }
        guard let gameSession = sessionRegistry.begin(
            account: account,
            session: session,
            gameService: gameService,
            launchBridge: launchBridge,
            discordPresence: discordPresence,
            streamProfile: streamProfile
        ) else {
            reportLaunchFailure(refusalMessage(for: accountID))
            return nil
        }
        return gameSession
    }

    /// A second game for one account is refused outright rather than ending the one already running.
    /// The message says whether it is running or still starting, and where the control that frees it
    /// is: only a running game has an END, and it is on this account's own page.
    private func refusalMessage(for accountID: OPNAccountID) -> String {
        guard let owned = sessionRegistry.session(ownedBy: accountID) else { return "" }
        OPNLog.warning(.launch, "Launch refused: session=\(owned.id) owner=\(accountID) phase=\(owned.phase) running=\(owned.isRunning) heldFor=\(Int(Date().timeIntervalSince(owned.startedAt)))s")
        guard owned.isRunning else {
            return "This account is already starting a game. Cancel that launch before starting another."
        }
        return "This account is already running a game. End it from the banner at the top of the page before starting another."
    }

    func cancelVendorLaunch() {
        gameSession?.cancelLaunch()
        launchMessage = ""
    }

    func resumeActiveLaunchSession() {
        gameSession?.resumeActiveSession()
    }

    func switchToSelectedGame() {
        gameSession?.switchToSelectedGame()
    }

    // MARK: - The vendor's already-running session

    /// A seat the vendor still holds for this account: not a local stream, so it is the browsing
    /// account's own question and lives on the catalog.
    var isActiveHomeSessionVisible: Bool {
        activeHomeSession != nil && launchFlowState == .idle && activeStreamConfiguration == nil
    }

    var activeHomeSessionTitle: String {
        guard let session = activeHomeSession else { return "" }
        return resolveActiveHomeSessionTitle(for: session)
    }

    func resolveActiveHomeSessionTitle(for session: OPNActiveSessionObject) -> String {
        guard session.appId > 0 else { return "Current Stream" }
        if let game = catalogGame(forApplicationID: String(session.appId)) {
            let title = game.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return "Current Stream"
    }

    /// The catalog game behind a vendor app id, when the loaded catalog knows it.
    func catalogGame(forApplicationID applicationID: String) -> OPNCatalogGameObject? {
        guard !applicationID.isEmpty else { return nil }
        return allKnownGames.first { Self.game($0, matchesApplicationID: applicationID) }
    }

    /// Whether this game is the session the seat is currently holding, which is what earns a tile
    /// the resumable treatment.
    func isResumableSessionGame(_ game: OPNCatalogGameObject) -> Bool {
        guard let session = activeHomeSession, session.isResumable, session.appId > 0 else { return false }
        return Self.game(game, matchesApplicationID: String(session.appId))
    }

    func checkActiveHomeSession() {
        guard launchFlowState == .idle, activeStreamConfiguration == nil, !isCheckingHomeSession else { return }
        isCheckingHomeSession = true
        let token = launchToken
        let streamingBaseUrl = OPNStreamPreferences.loadSelectedStreamingBaseUrl()
        OPNActiveSessionService.fetchActiveSessions(accessToken: token, streamingBaseUrl: streamingBaseUrl, deviceId: cloudmatchDeviceId) { [weak self] ok, sessions, _ in
            guard let self else { return }
            self.isCheckingHomeSession = false
            guard ok, let session = sessions.first(where: \.isResumable) ?? sessions.first else {
                self.activeHomeSession = nil
                return
            }
            self.activeHomeSession = session
        }
    }

    /// Resuming a seat the vendor already allocated. The session is app-owned from here, so the
    /// resume survives a browsing switch like any other accepted intent.
    func resumeActiveHomeSession() {
        guard let session = activeHomeSession, session.isResumable else { return }
        let applicationID = session.appId > 0 ? String(session.appId) : ""
        let title = activeHomeSessionTitle.isEmpty ? "Current Stream" : activeHomeSessionTitle
        // Cleared only once the resume is admitted, so a refusal leaves the card the reader pressed.
        guard let gameSession = beginOwnedSession() else { return }
        activeHomeSession = nil
        gameSession.beginResume(
            title: title,
            applicationID: applicationID,
            sessionID: session.sessionId,
            server: session.serverIp,
            game: catalogGame(forApplicationID: applicationID)
        )
    }

    /// Resumes a session detected outside the catalog - the menu bar's own row.
    func resumeSession() {
        OPNLog.info(.launch, "Menu bar resuming the resumable session")
        resumeActiveHomeSession()
    }

    func endActiveHomeSession() {
        guard let session = activeHomeSession else { return }
        let token = launchToken
        activeHomeSession = nil
        OPNActiveSessionService.stopSession(
            accessToken: token,
            sessionId: session.sessionId,
            serverIp: session.serverIp,
            streamingBaseUrl: session.streamingBaseUrl,
            deviceId: cloudmatchDeviceId
        ) { [weak self] success, message in
            guard let self else { return }
            if !success {
                self.reportLaunchFailure(message.isEmpty ? "Unable to end the active session." : message)
            }
            self.checkActiveHomeSession()
        }
    }

    // MARK: - Results

    /// Applies a result the application-owned session published, when it belongs to this catalog's
    /// account. The only place a finished session writes history, playtime or the summary.
    func applySessionResult(_ result: OPNGameSessionResult) {
        launchMessage = ""
        if !result.wasCancelled, let configuration = result.configuration {
            let previous = CatalogPreviousGameSession(configuration: configuration, success: result.success, message: result.message, report: result.report)
            previousGameSession = previous
            previous.save()
            if result.success {
                recordFinishedSession(previous, configuration: configuration, game: result.launchedGame, report: result.report)
            }
        }
        if result.wasCancelled {
            actionMessage = "Stream launch cancelled."
            return
        }
        presentSessionInsights(report: result.report)
        if !result.success, !result.message.isEmpty {
            reportLaunchFailure(result.message)
        } else if let report = result.report, !report.message.isEmpty {
            actionMessage = report.message
        }
        checkActiveHomeSession()
    }

    /// Writes the finished game into this account's recent games and playtime. Both stores are keyed
    /// by the account the session belonged to, not by whichever account is selected now.
    private func recordFinishedSession(_ previous: CatalogPreviousGameSession, configuration: StreamLaunchConfiguration, game: OPNCatalogGameObject?, report: StreamReport?) {
        let accountIdentifier = Self.playtimeAccountIdentifier(account: account, session: session)
        let recordedIdentity = game.map { Self.identity(for: $0) } ?? ""
        var recentlyPlayed = self.recentlyPlayed
        recentlyPlayed.record(
            title: previous.title,
            appId: recordedIdentity.isEmpty ? configuration.applicationID : recordedIdentity,
            store: configuration.selectedStore,
            playedAt: previous.endedAt,
            artworkURL: game?.imageUrl
        )
        self.recentlyPlayed = recentlyPlayed
        recentlyPlayed.save(accountIdentifier: accountIdentifier)
        guard let report, report.durationSeconds > 0 else { return }
        var statistics = playtimeStatistics
        statistics.record(title: previous.title, durationSeconds: report.durationSeconds, endedAt: previous.endedAt)
        playtimeStatistics = statistics
        statistics.save(accountIdentifier: accountIdentifier)
    }

    /// Builds the summary of a stream that actually ran, when the preference is on.
    private func presentSessionInsights(report: StreamReport?) {
        guard let report, OPNSessionInsightsPreferences.isEnabled,
              let insights = SessionInsights(
                  report: report,
                  fallbackResolution: "\(streamProfile.resolution.width)x\(streamProfile.resolution.height)",
                  fallbackCodec: streamProfile.codec.value,
                  fallbackFrameRate: streamProfile.fps
              )
        else { return }
        sessionInsights = insights
    }

    /// Adopts a result that arrived while this catalog was not mounted, so a game that ended on
    /// another account's page still lands in its owner's history the next time it is opened.
    func adoptPendingSessionResult() {
        guard let accountID = account.storedAccountID,
              let result = sessionResultStore.takeResult(for: accountID) else { return }
        applySessionResult(result)
    }

    func observeSessionResults() {
        guard deinitHandle.sessionResultObserver == nil else { return }
        deinitHandle.sessionResultObserver = NotificationCenter.default.addObserver(
            forName: OPNGameSessionResultStore.didPublishNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.adoptPendingSessionResult() }
        }
    }

    /// Clears the post-session summary. `isOptingOut` turns the preference off for the next stream.
    func dismissSessionInsights(isOptingOut: Bool) {
        if isOptingOut {
            OPNSessionInsightsPreferences.isEnabled = false
        }
        sessionInsights = nil
    }

    /// The token every catalog-side vendor request authenticates with. The session keeps its own
    /// copy of this decision so a launch in flight never reads the browsing account's token.
    var launchToken: String {
        session.idToken.isEmpty ? session.accessToken : session.idToken
    }

    // MARK: - Settings

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
        OPNStreamPreferences.fetchRegions(token: token, providerStreamingBaseUrl: gameService.providerStreamingBaseURL()) { [weak self] regions in
            guard let self else { return }
            self.isRefreshingSettingsRegions = false
            self.settingsRegionOptions = Self.launchRegionOptions(from: regions)
            if !self.selectedSettingsRegionUrl.isEmpty, !regions.contains(where: { $0.url == self.selectedSettingsRegionUrl }) {
                self.unavailableSettingsRegionUrl = self.selectedSettingsRegionUrl
            } else {
                self.unavailableSettingsRegionUrl = ""
            }
        }
    }

    nonisolated static func launchRegionOptions(from regions: [OPNStreamRegionOption]) -> [OPNStreamRegionOption] {
        let measured = regions.filter { !$0.url.isEmpty }
        let bestLatency = measured.first?.latencyMs ?? -1
        return [OPNStreamRegionOption(name: "Automatic", url: "", latencyMs: bestLatency, automatic: true)] + measured
    }

    // MARK: - Pages the menu bar opens

    func showRecordings() {
        selectedMainPage = .recordings
        actionMessage = ""
        errorMessage = ""
    }

    func showScreenshots() {
        selectedMainPage = .screenshots
        actionMessage = ""
        errorMessage = ""
    }
}
