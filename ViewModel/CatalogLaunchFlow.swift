//
//  CatalogLaunchFlow.swift
//  OpenNOW
//
//  Launching a game: the vendor launch flow, an active session that has to be resumed or
//  ended first, the required ad, and reporting how the stream finished.
//  Split out of CatalogViewModel.swift.
//

import Foundation
import Observation

extension CatalogViewModel {
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
        OpenNOWLog.info(.shortcut, "CatalogViewModel resolving shortcut cmsId=\(shortcut.cmsId) shortName=\(shortcut.shortName) parentGameId=\(shortcut.parentGameId) title=\(title)")
        setActionMessage("Opening \(title.isEmpty ? "GeForce NOW shortcut" : title)...")
        if let game = matchingGame(for: shortcut, in: allKnownGames) {
            OpenNOWLog.info(.shortcut, "Resolved shortcut from loaded catalog: gameId=\(game.id) uuid=\(game.uuid) launchAppId=\(game.launchAppId) title=\(game.title)")
            selectGame(game)
            launch(game: game, variantIndex: variantIndex(for: shortcut, in: game))
            return
        }
        if Int(shortcut.cmsId) != nil {
            OpenNOWLog.info(.shortcut, "Shortcut not found in loaded catalog; fetching CMS metadata cmsId=\(shortcut.cmsId)")
            gameService.fetchGameObjectByCMSId(shortcut.cmsId) { [weak self] success, game, error in
                guard let self else { return }
                if success, let game {
                    OpenNOWLog.info(.shortcut, "Resolved shortcut from CMS metadata: gameId=\(game.id) uuid=\(game.uuid) title=\(game.title)")
                    self.selectGame(game)
                    self.launch(game: game, variantIndex: self.variantIndex(for: shortcut, in: game))
                    return
                }
                OpenNOWLog.warning(.shortcut, "Shortcut CMS metadata lookup failed: \(error)")
                if let game = Self.launchGame(from: shortcut, title: title) {
                    OpenNOWLog.info(.shortcut, "Launching shortcut directly from cmsId=\(shortcut.cmsId) title=\(game.title)")
                    self.selectGame(game)
                    self.launch(game: game, variantIndex: 0)
                } else {
                    self.resolveShortcutByBrowsing(shortcut, title: title)
                }
            }
            return
        }
        if let game = Self.launchGame(from: shortcut, title: title) {
            OpenNOWLog.info(.shortcut, "Launching shortcut directly from cmsId=\(shortcut.cmsId) title=\(game.title)")
            selectGame(game)
            launch(game: game, variantIndex: 0)
            return
        }
        resolveShortcutByBrowsing(shortcut, title: title)
    }

    func resolveShortcutByBrowsing(_ shortcut: GFNGameShortcut, title: String) {
        OpenNOWLog.info(.shortcut, "Shortcut not found in loaded catalog; browsing with query=\(title)")
        let deliveryGate = CatalogDeliveryGate()
        gameService.browseCatalogObject(searchQuery: title, sortId: "relevance", filterIds: [], fetchCount: 24) { [weak self] success, result, error in
            guard let self else { return }
            guard deliveryGate.claimFirstDelivery() else { return }
            guard success else {
                OpenNOWLog.error(.shortcut, "Shortcut catalog browse failed: \(error)")
                self.errorMessage = error.isEmpty ? "Unable to resolve this GeForce NOW shortcut." : error
                return
            }
            let games = result.games
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

    var isActiveHomeSessionVisible: Bool {
        activeHomeSession != nil && launchFlowState == .idle && activeStreamConfiguration == nil
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
        let presence = discordPresence(for: game)
        activeDiscordPresence = presence
        discordPresence.update(.launching(presence))
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

    func continueVendorLaunch() {
        guard let game = pendingLaunchGame else { return }
        launchFlowState = .checkingSession
        launchFlowMessage = "Checking for active GeForce NOW sessions..."
        launchFlowError = ""
        let userId = session.userId.isEmpty ? account.userId : session.userId
        launchBridge.prepareLaunchPlan(
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
                OpenNOWLog.error(.launch, "Launch plan failed: \(message)")
                self.clearLaunchFlow()
                self.errorMessage = message.isEmpty ? "Unable to prepare GeForce NOW launch." : message
                return
            }
            switch plan {
            case .ready(let configuration):
                OpenNOWLog.info(.launch, "Launch plan ready appId=\(configuration.appId) title=\(configuration.title)")
                self.startPreparedStream(Self.mediaConfiguration(from: configuration, membershipTier: self.account.membershipTier), message: message)
            case .activeSession(let active, let resume, let replacement):
                OpenNOWLog.info(.launch, "Launch plan found active session activeAppId=\(active.appId) replacementAppId=\(replacement.appId) resumeAppId=\(resume.appId)")
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
        launchBridge.stopActiveSession(activeLaunchSession, accessToken: launchToken) { [weak self] success, message in
            guard let self else { return }
            guard success else {
                self.launchFlowState = .activeSessionPrompt
                self.launchFlowError = message
                return
            }
            self.startPreparedStream(replacement, message: "Launching \(replacement.title)...")
        }
    }

    func checkActiveHomeSession() {
        guard launchFlowState == .idle, activeStreamConfiguration == nil, !isCheckingHomeSession else { return }
        isCheckingHomeSession = true
        let token = launchToken
        let streamingBaseUrl = OPNStreamPreferences.loadSelectedStreamingBaseUrl()
        OPNActiveSessionService.fetchActiveSessions(accessToken: token, streamingBaseUrl: streamingBaseUrl) { [weak self] ok, sessions, _ in
            guard let self else { return }
            self.isCheckingHomeSession = false
            guard ok, let session = sessions.first(where: \.isResumable) ?? sessions.first else {
                self.activeHomeSession = nil
                return
            }
            self.activeHomeSession = session
        }
    }

    func resumeActiveHomeSession() {
        guard let session = activeHomeSession, session.isResumable else { return }
        let applicationID = session.appId > 0 ? String(session.appId) : ""
        let title = activeHomeSessionTitle.isEmpty ? "Current Stream" : activeHomeSessionTitle
        let configuration = StreamLaunchConfiguration(
            title: title,
            applicationID: applicationID,
            accessToken: launchToken,
            accountLinked: true,
            selectedStore: "",
            resumeSessionID: session.sessionId,
            resumeServer: session.serverIp,
            metadata: [:]
        )
        activeHomeSession = nil
        startPreparedStream(configuration, message: "Resuming \(title)...")
    }

    func endActiveHomeSession() {
        guard let session = activeHomeSession else { return }
        let token = launchToken
        activeHomeSession = nil
        OPNActiveSessionService.stopSession(
            accessToken: token,
            sessionId: session.sessionId,
            serverIp: session.serverIp,
            streamingBaseUrl: session.streamingBaseUrl
        ) { [weak self] success, message in
            guard let self else { return }
            if !success {
                self.errorMessage = message.isEmpty ? "Unable to end the active session." : message
            }
            self.checkActiveHomeSession()
        }
    }

    func resolveActiveHomeSessionTitle(for session: OPNActiveSessionObject) -> String {
        guard session.appId > 0 else { return "Current Stream" }
        let applicationID = String(session.appId)
        if let game = allKnownGames.first(where: { Self.game($0, matchesApplicationID: applicationID) }) {
            let title = game.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return "Current Stream"
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
        discordPresence.update(.idle)
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
        checkActiveHomeSession()
    }

    func updateActiveStreamProgress(_ progress: StreamProgress) {
        activeStreamProgress = progress
        isActiveStreamLaunchOverlayVisible = true
        guard progress.isReady else { return }
        if let presence = activeDiscordPresence {
            discordPresence.update(.streaming(presence))
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
            throw OpenNOWStreamSessionError.sessionAllocationFailed("Required ad media URL is invalid.")
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
        continuation.resume(throwing: OpenNOWStreamSessionError.sessionAllocationFailed(message.isEmpty ? "Required ad playback failed." : message))
    }

    func cancelActiveStreamAdPlayback() {
        activeStreamAdPlayback = nil
        guard let continuation = activeStreamAdContinuation else { return }
        activeStreamAdContinuation = nil
        continuation.resume(throwing: CancellationError())
    }

    var launchToken: String {
        session.idToken.isEmpty ? session.accessToken : session.idToken
    }

    func startPreparedStream(_ configuration: StreamLaunchConfiguration, message: String) {
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

    static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription
    }

    static func mediaConfiguration(from configuration: OPNStreamLaunchConfiguration, titleOverride: String = "", membershipTier: String = "") -> StreamLaunchConfiguration {
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

    func title(forActiveSession session: OPNActiveStreamSessionDescriptor) -> String {
        let fallback = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.appId > 0 else { return fallback.isEmpty ? "Current Stream" : fallback }
        let applicationID = String(session.appId)
        if let game = allKnownGames.first(where: { Self.game($0, matchesApplicationID: applicationID) }) {
            let title = game.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return fallback.isEmpty ? "Current Stream" : fallback
    }

    func discordPresence(for game: OPNCatalogGameObject) -> DiscordGamePresence {
        DiscordGamePresence(title: game.title, artworkURL: DiscordArtwork.imageURL(for: game))
    }

    func discordPresence(for configuration: StreamLaunchConfiguration) -> DiscordGamePresence {
        if let game = allKnownGames.first(where: { Self.game($0, matchesApplicationID: configuration.applicationID) }) {
            return discordPresence(for: game)
        }
        return DiscordGamePresence(title: configuration.title, artworkURL: nil)
    }

    func presentSessionConflict(_ conflict: StreamSessionConflict, replacementConfiguration: StreamLaunchConfiguration) {
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

    func clearLaunchFlow() {
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

    nonisolated static func launchRegionOptions(from regions: [OPNStreamRegionOption]) -> [OPNStreamRegionOption] {
        let measured = regions.filter { !$0.url.isEmpty }
        let bestLatency = measured.first?.latencyMs ?? -1
        return [OPNStreamRegionOption(name: "Automatic", url: "", latencyMs: bestLatency, automatic: true)] + measured
    }
}
