//  One local game session, owned by the application rather than by the catalog that started it, so a
//  browsing switch cannot replace the window, the credentials or the provider route it runs on.

import Foundation
import Observation

/// Where a launch has got to. `streaming` is the only phase with a transport.
enum OPNGameSessionPhase: Equatable, Sendable {
    case checkingSession
    case activeSessionPrompt
    case stoppingSession
    case startingStream
    case streaming
}

@MainActor
@Observable
final class OPNGameSession {
    let id: UUID
    /// When the intent was accepted, so a refusal can say how long the slot has been held.
    let startedAt = Date()
    /// Held as the live models rather than as copies of their tokens, so a refresh the account
    /// performs mid-session is what the next request uses.
    let account: LoginAccount
    let session: LoginSession
    let streamProfile: OPNStreamPreferenceProfile

    private(set) var accountID: OPNAccountID
    var phase: OPNGameSessionPhase = .checkingSession
    var configuration: StreamLaunchConfiguration?
    var launchFlowTitle = ""
    var launchFlowMessage = ""
    var launchFlowError = ""
    var activeLaunchSession: OPNActiveStreamSessionDescriptor?
    var progress: StreamProgress?
    var isLaunchOverlayVisible = false
    var adPlayback: CatalogStreamAdPlayback?
    /// One ready alert per launch: allocation and the transport each publish a ready progress.
    var didNotifySessionReady = false

    private let gameService: any CatalogGameServing
    private let launchBridge: any GameLaunchBridging
    private let discordPresence: any DiscordPresenceServing
    private let registry: OPNGameSessionRegistry
    private let results: OPNGameSessionResultStore

    private var resumeConfiguration: StreamLaunchConfiguration?
    private var replacementConfiguration: StreamLaunchConfiguration?
    private var pendingGame: OPNCatalogGameObject?
    private var pendingVariantIndex = -1
    /// The catalog game the intent was accepted for, kept for the whole session: it is what the
    /// result is tagged with and what vendor-side titles resolve against.
    private var launchedGame: OPNCatalogGameObject?
    private var adContinuation: CheckedContinuation<Int, Error>?
    private var progressGeneration = 0
    private var activeDiscordPresence: DiscordGamePresence?
    /// One terminal outcome per session, whichever path reaches it first, so a late transport report
    /// cannot publish a second result or reopen the admission slot.
    private var isFinished = false

    init(
        id: UUID = UUID(),
        account: LoginAccount,
        session: LoginSession,
        accountID: OPNAccountID,
        gameService: any CatalogGameServing,
        launchBridge: any GameLaunchBridging,
        discordPresence: any DiscordPresenceServing,
        streamProfile: OPNStreamPreferenceProfile,
        registry: OPNGameSessionRegistry,
        results: OPNGameSessionResultStore
    ) {
        self.id = id
        self.account = account
        self.session = session
        self.accountID = accountID
        self.gameService = gameService
        self.launchBridge = launchBridge
        self.discordPresence = discordPresence
        self.streamProfile = streamProfile
        self.registry = registry
        self.results = results
    }

    // MARK: - Identity

    /// The account whose history, playtime and summary this session's results belong to.
    var playtimeAccountIdentifier: String {
        Self.playtimeAccountIdentifier(account: account, session: session)
    }

    /// The device id this session streams under. The seat allows one live session per device, so it
    /// is the owner's rather than the machine's - otherwise a second account is refused as the same
    /// device as the first.
    var cloudmatchDeviceId: String {
        OPNDeviceIdentity.cloudmatchDeviceId(accountID: accountID)
    }

    static func playtimeAccountIdentifier(account: LoginAccount, session: LoginSession) -> String {
        for value in [session.userId, account.userId, account.externalUserId, account.email] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty else { return trimmed.lowercased() }
        }
        return "default"
    }

    func rekey(to identity: OPNAccountID) {
        accountID = identity
    }

    // MARK: - What the owner's catalog and the stream window read

    var title: String {
        let configurationTitle = configuration?.title ?? ""
        guard configurationTitle.isEmpty else { return configurationTitle }
        let flowTitle = launchFlowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return flowTitle.isEmpty ? "GeForce NOW" : flowTitle
    }

    var artworkURL: URL? { configuration?.loadingArtworkURL }

    var isRunning: Bool { configuration != nil }

    var isLaunchLoadingVisible: Bool { configuration != nil && isLaunchOverlayVisible }

    var canResumeActiveSession: Bool { resumeConfiguration != nil }

    /// Read through the owner's stored session, so a refresh that lands mid-launch is picked up.
    private var launchToken: String {
        session.idToken.isEmpty ? session.accessToken : session.idToken
    }

    private var launchUserId: String {
        session.userId.isEmpty ? account.userId : session.userId
    }

    private var launchIdpId: String {
        session.idpId.isEmpty ? account.providerIdpId : session.idpId
    }

    // MARK: - Launch

    /// Freezes the intent on this session's owner and starts the vendor launch flow.
    func begin(game: OPNCatalogGameObject, variantIndex: Int?) {
        pendingGame = game
        launchedGame = game
        pendingVariantIndex = variantIndex ?? Self.preferredVariantIndex(for: game)
        activeLaunchSession = nil
        resumeConfiguration = nil
        replacementConfiguration = nil
        launchFlowTitle = game.title.isEmpty ? "GeForce NOW" : game.title
        launchFlowMessage = "Checking for active GeForce NOW sessions..."
        launchFlowError = ""
        phase = .checkingSession
        let presence = discordPresence(for: game)
        activeDiscordPresence = presence
        discordPresence.update(.launching(presence))
        OPNLog.info(.launch, "Session \(id) launching gameId=\(game.id) appId=\(game.launchAppId) accountID=\(accountID)")
        continueLaunch()
    }

    /// Resumes a session the vendor already allocated: there is no launch plan to resolve.
    func beginResume(title: String, applicationID: String, sessionID: String, server: String, game: OPNCatalogGameObject?) {
        guard !isFinished else { return }
        let resumeTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Current Stream" : title
        OPNLog.info(.launch, "Session \(id) resuming detected session appId=\(applicationID) accountID=\(accountID)")
        pendingGame = game
        launchedGame = game
        launchFlowTitle = resumeTitle
        launchFlowMessage = "Resuming \(resumeTitle)..."
        launchFlowError = ""
        phase = .startingStream
        startPreparedStream(
            StreamLaunchConfiguration(
                title: resumeTitle,
                applicationID: applicationID,
                accessToken: launchToken,
                accountLinked: true,
                selectedStore: "",
                resumeSessionID: sessionID,
                resumeServer: server,
                metadata: [:]
            )
        )
    }

    func continueLaunch() {
        guard let game = pendingGame else { return }
        phase = .checkingSession
        launchFlowMessage = "Checking for active GeForce NOW sessions..."
        launchFlowError = ""
        launchBridge.prepareLaunchPlan(
            game: game,
            accessToken: session.accessToken,
            idToken: session.idToken,
            userId: launchUserId,
            idpId: launchIdpId,
            variantIndex: pendingVariantIndex,
            deviceId: cloudmatchDeviceId
        ) { [weak self] success, message, plan in
            guard let self else { return }
            guard success, let plan else {
                OPNLog.error(.launch, "Launch plan failed: \(message)")
                self.failLaunch(message.isEmpty ? "Unable to prepare GeForce NOW launch." : message)
                return
            }
            self.applyLaunchPlan(plan)
        }
    }

    private func applyLaunchPlan(_ plan: OPNGameLaunchPlan) {
        switch plan {
        case .ready(let configuration):
            OPNLog.info(.launch, "Launch plan ready appId=\(configuration.appId) title=\(configuration.title)")
            startPreparedStream(Self.mediaConfiguration(from: configuration, membershipTier: account.membershipTier))
        case .activeSession(let active, let resume, let replacement):
            presentActiveSessionPrompt(active: active, resume: resume, replacement: replacement)
        }
    }

    /// The vendor is already holding a session for this account, so the reader has to end it or
    /// resume it before the game they asked for can start.
    private func presentActiveSessionPrompt(active: OPNActiveStreamSessionDescriptor, resume: OPNStreamLaunchConfiguration, replacement: OPNStreamLaunchConfiguration) {
        OPNLog.info(.launch, "Launch plan found active session activeAppId=\(active.appId) replacementAppId=\(replacement.appId) resumeAppId=\(resume.appId)")
        let activeTitle = title(forActiveSession: active)
        activeLaunchSession = OPNActiveStreamSessionDescriptor(sessionId: active.id, appId: active.appId, serverIp: active.serverIp, streamingBaseUrl: active.streamingBaseUrl, title: activeTitle)
        resumeConfiguration = Self.mediaConfiguration(from: resume, titleOverride: activeTitle, membershipTier: account.membershipTier)
        replacementConfiguration = Self.mediaConfiguration(from: replacement, membershipTier: account.membershipTier)
        phase = .activeSessionPrompt
        let isResumable = !resume.resumeSessionId.isEmpty && !resume.resumeServer.isEmpty
        launchFlowMessage = isResumable
            ? "A GeForce NOW session is already running. Resume it or end it before launching \(launchFlowTitle)."
            : "GeForce NOW reports a stale active session that cannot be resumed. End it before launching \(launchFlowTitle)."
    }

    func resumeActiveSession() {
        guard canResumeActiveSession, let configuration = resumeConfiguration else {
            launchFlowError = "This GeForce NOW session is no longer resumable. End it and launch again."
            return
        }
        startPreparedStream(configuration)
    }

    /// Ends the session the vendor is already holding, then starts the one the reader asked for.
    func switchToSelectedGame() {
        guard let activeLaunchSession, let replacement = replacementConfiguration else { return }
        phase = .stoppingSession
        launchFlowMessage = "Ending the current GeForce NOW session..."
        launchFlowError = ""
        launchBridge.stopActiveSession(activeLaunchSession, accessToken: launchToken, deviceId: cloudmatchDeviceId) { [weak self] success, message in
            guard let self else { return }
            guard success else {
                self.phase = .activeSessionPrompt
                self.launchFlowError = message
                return
            }
            self.startPreparedStream(replacement)
        }
    }

    /// Abandons an intent that never produced a stream, freeing the slot for the next launch.
    func cancelLaunch() {
        guard !isFinished else { return }
        isFinished = true
        clearFlowState()
        registry.end(self)
    }

    /// Abandons a stream the reader cancelled. Nothing is recorded, but the owner's catalog is told
    /// because it owns the status line.
    func cancelStreamLaunch() {
        guard !isFinished, let finishedConfiguration = configuration else { return }
        isFinished = true
        progressGeneration += 1
        cancelAdPlayback()
        configuration = nil
        ControllerMappingStore.shared.endSession()
        progress = nil
        isLaunchOverlayVisible = false
        clearFlowState()
        registry.notifySessionDidChange()
        publish(configuration: finishedConfiguration, success: false, message: "", report: nil, wasCancelled: true)
        registry.end(self)
    }

    func startPreparedStream(_ configuration: StreamLaunchConfiguration) {
        let mappingGameIdentity = pendingGame?.catalogIdentity ?? ""
        let ownedConfiguration = configuration.snapshottingSession(
            ownerDisplayName: account.displayName,
            mappingGameIdentity: mappingGameIdentity
        )
        if activeDiscordPresence == nil {
            activeDiscordPresence = discordPresence(for: ownedConfiguration)
        }
        phase = .startingStream
        launchFlowMessage = "Starting GeForce NOW stream..."
        launchFlowError = ""
        progressGeneration += 1
        isLaunchOverlayVisible = true
        didNotifySessionReady = false
        progress = StreamProgress(title: ownedConfiguration.title.isEmpty ? "GeForce NOW" : ownedConfiguration.title, message: launchFlowMessage, steps: [], currentStepIndex: -1, isReady: false)
        OPNSessionReadyAction.prepareAuthorizationIfNeeded()
        self.configuration = ownedConfiguration
        ControllerMappingStore.shared.beginSession(
            appId: ownedConfiguration.applicationID,
            catalogIdentity: mappingGameIdentity.isEmpty ? nil : mappingGameIdentity,
            title: pendingGame?.title
        )
        clearFlowState()
        registry.notifySessionDidChange()
    }

    // MARK: - Stream

    func updateProgress(_ progress: StreamProgress) {
        self.progress = progress
        isLaunchOverlayVisible = true
        guard progress.isReady else { return }
        phase = .streaming
        if !didNotifySessionReady {
            didNotifySessionReady = true
            OPNSessionReadyAction.sessionDidBecomeReady(title: progress.title, sessionID: id)
        }
        if let presence = activeDiscordPresence {
            discordPresence.update(.streaming(presence))
        }
        let generation = progressGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard generation == self.progressGeneration else { return }
            self.isLaunchOverlayVisible = false
        }
    }

    func presentRequiredAd(_ ad: StreamSessionAdPresentation) async throws -> Int {
        guard URL(string: ad.mediaUrl) != nil else {
            throw OPNStreamSessionError.sessionAllocationFailed("Required ad media URL is invalid.")
        }
        adContinuation?.resume(throwing: CancellationError())
        adContinuation = nil
        adPlayback = CatalogStreamAdPlayback(
            id: ad.adId,
            title: ad.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Sponsored Message" : ad.title,
            mediaUrl: ad.mediaUrl,
            durationMs: ad.durationMs
        )
        isLaunchOverlayVisible = true
        let title = configuration?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        progress = StreamProgress(
            title: title?.isEmpty == false ? title ?? "GeForce NOW" : "GeForce NOW",
            message: "Playing sponsored message before your free-tier session continues...",
            steps: StreamLaunchStep.allCases.map(\.title),
            currentStepIndex: StreamLaunchStep.allocateCloudSession.rawValue,
            isReady: false,
            queuePosition: progress?.queuePosition
        )
        return try await withCheckedThrowingContinuation { continuation in
            adContinuation = continuation
        }
    }

    func finishRequiredAdPlayback(watchedTimeInMs: Int) {
        guard let continuation = adContinuation else { return }
        adContinuation = nil
        adPlayback = nil
        continuation.resume(returning: max(0, watchedTimeInMs))
    }

    func failRequiredAdPlayback(_ message: String) {
        guard let continuation = adContinuation else { return }
        adContinuation = nil
        adPlayback = nil
        continuation.resume(throwing: OPNStreamSessionError.sessionAllocationFailed(message.isEmpty ? "Required ad playback failed." : message))
    }

    func cancelAdPlayback() {
        adPlayback = nil
        guard let continuation = adContinuation else { return }
        adContinuation = nil
        continuation.resume(throwing: CancellationError())
    }

    /// The stream ended. History, playtime and the summary are published to the owner rather than
    /// written here, because the owner's catalog is what holds them in memory and on disk.
    func endStream(success: Bool, message: String, report: StreamReport?) {
        guard !isFinished else { return }
        isFinished = true
        let finishedConfiguration = configuration
        progressGeneration += 1
        cancelAdPlayback()
        configuration = nil
        ControllerMappingStore.shared.endSession()
        progress = nil
        activeDiscordPresence = nil
        discordPresence.update(.idle)
        isLaunchOverlayVisible = false
        clearFlowState()
        registry.notifySessionDidChange()
        publish(configuration: finishedConfiguration, success: success, message: message, report: report, wasCancelled: false)
        registry.end(self)
    }

    private func failLaunch(_ message: String) {
        guard !isFinished else { return }
        isFinished = true
        clearFlowState()
        publish(configuration: nil, success: false, message: message, report: nil, wasCancelled: false)
        registry.end(self)
    }

    private func publish(configuration: StreamLaunchConfiguration?, success: Bool, message: String, report: StreamReport?, wasCancelled: Bool) {
        results.publish(
            OPNGameSessionResult(
                accountID: accountID,
                configuration: configuration,
                launchedGame: launchedGame,
                success: success,
                message: message,
                report: report,
                wasCancelled: wasCancelled
            )
        )
    }

    private func clearFlowState() {
        launchFlowTitle = ""
        launchFlowMessage = ""
        launchFlowError = ""
        activeLaunchSession = nil
        resumeConfiguration = nil
        replacementConfiguration = nil
        pendingGame = nil
        pendingVariantIndex = -1
    }

    // MARK: - Titles and presence

    private func title(forActiveSession session: OPNActiveStreamSessionDescriptor) -> String {
        let fallback = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFallback = fallback.isEmpty ? "Current Stream" : fallback
        guard session.appId > 0 else { return resolvedFallback }
        let applicationID = String(session.appId)
        guard let game = launchedGame, Self.game(game, matchesApplicationID: applicationID) else { return resolvedFallback }
        let title = game.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? resolvedFallback : title
    }

    private func discordPresence(for game: OPNCatalogGameObject) -> DiscordGamePresence {
        DiscordGamePresence(title: game.title, artworkURL: DiscordArtwork.imageURL(for: game))
    }

    private func discordPresence(for configuration: StreamLaunchConfiguration) -> DiscordGamePresence {
        guard let game = launchedGame, Self.game(game, matchesApplicationID: configuration.applicationID) else {
            return DiscordGamePresence(title: configuration.title, artworkURL: nil)
        }
        return discordPresence(for: game)
    }

    // MARK: - Shared launch helpers

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

    static func preferredVariantIndex(for game: OPNCatalogGameObject) -> Int {
        if let index = game.variants.firstIndex(where: { $0.librarySelected }) { return index }
        if let index = game.variants.firstIndex(where: { $0.inLibrary }) { return index }
        return game.variants.isEmpty ? -1 : 0
    }

    static func game(_ game: OPNCatalogGameObject, matchesApplicationID applicationID: String) -> Bool {
        guard !applicationID.isEmpty else { return false }
        for value in [game.id, game.uuid, game.launchAppId, game.shortName] where value == applicationID {
            return true
        }
        return game.variants.contains { $0.id == applicationID }
    }
}
