import AppKit
import Foundation

typealias OPNPanelCallback = @Sendable (_ success: Bool, _ panels: [OPNPanelResult], _ error: String) -> Void
typealias OPNCatalogCallback = @Sendable (_ success: Bool, _ games: [OPNGameInfo], _ error: String) -> Void
typealias OPNCatalogBrowseCallback = @Sendable (_ success: Bool, _ result: OPNCatalogBrowseResult, _ error: String) -> Void
typealias OPNSubscriptionCallback = @Sendable (_ success: Bool, _ subscription: OPNSubscriptionInfo, _ error: String) -> Void
typealias OPNStoreURLCallback = @Sendable (_ success: Bool, _ storeURL: String, _ error: String) -> Void
typealias OPNProviderInfoCallback = @Sendable (_ success: Bool, _ providerInfo: OPNGameProviderInfo, _ selectedEndpoint: OPNGameProviderEndpoint, _ error: String) -> Void
typealias OPNOwnershipActionCallback = @Sendable (_ success: Bool, _ error: String) -> Void
typealias OPNUserAccountCallback = @Sendable (_ success: Bool, _ accountInfo: OPNUserAccountInfo, _ error: String) -> Void
typealias OPNStoreDefinitionsCallback = @Sendable (_ success: Bool, _ definitions: [OPNStoreDefinition], _ error: String) -> Void
typealias OPNGameLaunchProgressCallback = @Sendable (_ message: String, _ session: [String: Any]) -> Void
typealias OPNGameLaunchCallback = @Sendable (_ success: Bool, _ session: [String: Any], _ offerSdp: String, _ error: String) -> Void

private final class OPNLaunchPollState: @unchecked Sendable {
    var retries = 0
    var lastPollWasPendingProgress = false
}

private final class OPNLaunchPollBox: @unchecked Sendable {
    var poll: (@Sendable () -> Void)?

    func call() { poll?() }

    func schedule(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in call() }
    }
}

final class OPNGameService: @unchecked Sendable {
    static let shared = OPNGameService()

    private static let panelsHash = "f8e26265a5db5c20e1334a6872cf04b6e3970507697f6ae55a6ddefa5420daf0"
    private static let marqueeHash = "dd4bddfdef4707dfe340cc2040d6bb9c4c45f706976fca15b2ef33221c385d7f"
    private static let libraryWithTimeHash = "039e8c0d553972975485fee56e59f2549d2fdb518e247a42ab5022056a74406f"
    private static let appMetaDataHash = "cf8b620dfd03617017ba7c858cee65197e1ace5180e41be194b39227227ced63"
    private static let nvClientId = "ec7e38d4-03af-4b58-b131-cfb0495903ab"
    private static let nvClientVersion = "2.0.80.173"
    private static let defaultStreamingBaseUrl = "https://prod.cloudmatchbeta.nvidiagrid.net/"
    private static let providerServiceUrlsEndpoint = "https://pcs.geforcenow.com/v1/serviceUrls"
    private static let accountLinkingServer = "https://als.geforcenow.com"
    private static let accountLinkingClientId = "gfn-pc"
    private static let defaultSubscriptionVpcId = "NP-AMS-08"
    private static let defaultCatalogFetchCount = 96
    private static let maxCatalogPages = 3
    private static let catalogCacheFreshSeconds: TimeInterval = 15 * 60
    private static let catalogDefinitionsFreshSeconds: TimeInterval = 24 * 60 * 60
    private static let accountLinkingRequestTimeoutSeconds: TimeInterval = 15
    private static let accountLinkingCallbackTimeoutSeconds: TimeInterval = 5 * 60
    private static let serverVpcCacheFreshSeconds: TimeInterval = 5 * 60
    private static let workQueue = DispatchQueue(label: "com.opennow.game-service.swift.work")

    private struct VpcCacheEntry {
        let vpcId: String
        let timestamp: Date
    }

    private static let vpcLock = NSLock()
    nonisolated(unsafe) private static var vpcCache: [String: VpcCacheEntry] = [:]
    nonisolated(unsafe) private static var pendingVpcCallbacks: [String: [(String) -> Void]] = [:]

    private var accessToken = ""
    private var accountLinkingToken = ""
    private var vpcId = ""
    private var userId = ""
    private var graphqlURL = "https://games.geforce.com/graphql"
    private var streamingBaseUrl = ""
    private var providerStreamingBaseUrl = OPNGameService.defaultStreamingBaseUrl

    private init() {}

    func setAccessToken(_ token: String) { accessToken = token }
    func setAccountLinkingToken(_ token: String) { accountLinkingToken = token }
    func setVpcId(_ id: String) { vpcId = id }
    func setUserId(_ id: String) { userId = id }
    func setStreamingBaseUrl(_ url: String) {
        streamingBaseUrl = url
        OPNSessionManager.shared.setStreamingBaseUrl(url)
    }
    func providerStreamingBaseURL() -> String { providerStreamingBaseUrl.isEmpty ? Self.defaultStreamingBaseUrl : providerStreamingBaseUrl }

    func launchGame(appId: String, internalTitle: String, settings: [String: Any], recoveryMode: Bool, progress: @escaping OPNGameLaunchProgressCallback, completion: @escaping OPNGameLaunchCallback) {
        OPNSentry.logInfoMessage("[GameService] LaunchGame called with appId=\(appId) recovery=\(recoveryMode)")
        OPNSessionManager.shared.setAccessToken(accessToken)
        OPNSessionManager.shared.getActiveSessions { [weak self] ok, sessions, error in
            guard let self else { return }
            if !ok {
                if self.isSessionAuthenticationError(error) {
                    self.dispatchLaunch(completion, false, [:], "", error)
                    return
                }
                OPNSentry.logErrorMessage("[GameService] GetActiveSessions failed, falling through to CreateSession: \(error)")
                self.createLaunchSession(appId: appId, internalTitle: internalTitle, settings: settings, recoveryMode: recoveryMode, progress: progress, completion: completion)
                return
            }
            if self.tryUseExistingSession(sessions, appId: appId, internalTitle: internalTitle, settings: settings, recoveryMode: recoveryMode, progress: progress, completion: completion) {
                return
            }
            OPNSentry.logInfoMessage("[GameService] Creating new session")
            self.createLaunchSession(appId: appId, internalTitle: internalTitle, settings: settings, recoveryMode: recoveryMode, progress: progress, completion: completion)
        }
    }

    private func createLaunchSession(appId: String, internalTitle: String, settings: [String: Any], recoveryMode: Bool, progress: @escaping OPNGameLaunchProgressCallback, completion: @escaping OPNGameLaunchCallback) {
        OPNSessionManager.shared.createSession(appId: appId, internalTitle: internalTitle, settings: settings) { [weak self] success, info, error in
            guard let self else { return }
            if !success {
                if self.retryExistingSessionAfterLimitError(error, appId: appId, internalTitle: internalTitle, settings: settings, recoveryMode: recoveryMode, progress: progress, completion: completion) {
                    return
                }
                self.dispatchLaunch(completion, false, [:], "", error)
                return
            }
            if self.isSessionReady(info), !self.launchString(info["serverIp"]).isEmpty {
                self.reportLaunchProgress(progress, session: info)
                self.dispatchLaunch(completion, true, info, "", "")
                return
            }
            self.reportLaunchProgress(progress, session: info)
            self.pollSessionReady(sessionId: self.launchString(info["sessionId"]), serverIp: self.launchString(info["serverIp"]), progress: progress, completion: completion)
        }
    }

    private func tryUseExistingSession(_ sessions: [[String: Any]], appId: String, internalTitle: String, settings: [String: Any], recoveryMode: Bool, progress: @escaping OPNGameLaunchProgressCallback, completion: @escaping OPNGameLaunchCallback) -> Bool {
        let appIdNumber = Int(appId) ?? 0
        if let session = sessions.first(where: { launchInt($0["appId"]) == appIdNumber && isSessionReady($0) && !launchString($0["serverIp"]).isEmpty }) {
            OPNSentry.logInfoMessage("[GameService] Polling ready session \(launchString(session["sessionId"])) status=\(launchInt(session["status"]))")
            pollSessionReady(sessionId: launchString(session["sessionId"]), serverIp: launchString(session["serverIp"]), progress: progress, completion: completion)
            return true
        }
        if let session = sessions.first(where: { isSessionReady($0) && !launchString($0["sessionId"]).isEmpty && !launchString($0["serverIp"]).isEmpty }) {
            OPNSentry.logInfoMessage("[GameService] Polling existing ready session \(launchString(session["sessionId"])) for appId=\(launchInt(session["appId"])) instead of creating a second session")
            pollSessionReady(sessionId: launchString(session["sessionId"]), serverIp: launchString(session["serverIp"]), progress: progress, completion: completion)
            return true
        }
        if let session = sessions.first(where: { launchInt($0["appId"]) == appIdNumber && launchInt($0["status"]) == 6 }) {
            nonisolated(unsafe) let launchSettings = settings
            waitForSessionTeardown(sessionId: launchString(session["sessionId"]), appId: appIdNumber, progress: progress) { [weak self] complete, error in
                guard let self else { return }
                if complete { self.launchGame(appId: appId, internalTitle: internalTitle, settings: launchSettings, recoveryMode: recoveryMode, progress: progress, completion: completion) }
                else { self.dispatchLaunch(completion, false, [:], "", error) }
            }
            return true
        }
        if let session = sessions.first(where: { launchInt($0["appId"]) == appIdNumber && launchInt($0["status"]) == 1 && !launchString($0["serverIp"]).isEmpty }) {
            OPNSentry.logInfoMessage("[GameService] Polling existing session \(launchString(session["sessionId"]))")
            pollSessionReady(sessionId: launchString(session["sessionId"]), serverIp: launchString(session["serverIp"]), progress: progress, completion: completion)
            return true
        }
        if let session = sessions.first(where: { launchInt($0["status"]) == 1 && !launchString($0["sessionId"]).isEmpty && !launchString($0["serverIp"]).isEmpty }) {
            OPNSentry.logInfoMessage("[GameService] Polling existing queued session \(launchString(session["sessionId"])) for appId=\(launchInt(session["appId"])) instead of creating a second session")
            pollSessionReady(sessionId: launchString(session["sessionId"]), serverIp: launchString(session["serverIp"]), progress: progress, completion: completion)
            return true
        }
        return false
    }

    private func retryExistingSessionAfterLimitError(_ error: String, appId: String, internalTitle: String, settings: [String: Any], recoveryMode: Bool, progress: @escaping OPNGameLaunchProgressCallback, completion: @escaping OPNGameLaunchCallback) -> Bool {
        guard isSessionLimitExceededError(error) else { return false }
        OPNSentry.logInfoMessage("[GameService] SESSION_LIMIT_EXCEEDED; retrying existing session lookup")
        if tryUseExistingSession(activeSessionsFromSessionLimitError(error), appId: appId, internalTitle: internalTitle, settings: settings, recoveryMode: recoveryMode, progress: progress, completion: completion) {
            return true
        }
        nonisolated(unsafe) let launchSettings = settings
        OPNSessionManager.shared.getActiveSessions { [weak self] ok, sessions, _ in
            guard let self else { return }
            if ok, self.tryUseExistingSession(sessions, appId: appId, internalTitle: internalTitle, settings: launchSettings, recoveryMode: recoveryMode, progress: progress, completion: completion) {
                return
            }
            self.dispatchLaunch(completion, false, [:], "", error)
        }
        return true
    }

    private func pollSessionReady(sessionId: String, serverIp: String, progress: @escaping OPNGameLaunchProgressCallback, completion: @escaping OPNGameLaunchCallback) {
        let state = OPNLaunchPollState()
        let pollBox = OPNLaunchPollBox()
        pollBox.poll = { [weak self, state, pollBox] in
            guard let self else { return }
            if state.retries >= 60, !state.lastPollWasPendingProgress {
                self.dispatchLaunch(completion, false, [:], "", "Session poll timeout")
                return
            }
            if state.retries >= 60, state.lastPollWasPendingProgress { state.retries = 0 }
            state.retries += 1
            OPNSessionManager.shared.pollSession(sessionId: sessionId, serverIp: serverIp) { [weak self, state] ok, info, _ in
                guard let self else { return }
                if ok, self.isSessionReady(info), !self.launchString(info["serverIp"]).isEmpty {
                    self.reportLaunchProgress(progress, session: info)
                    self.dispatchLaunch(completion, true, info, "", "")
                    return
                }
                if ok, self.launchInt(info["status"]) == 6 {
                    self.reportTeardownProgress(progress, session: info)
                    state.lastPollWasPendingProgress = true
                } else if ok {
                    self.reportLaunchProgress(progress, session: info)
                    state.lastPollWasPendingProgress = self.isSessionLaunchProgressPending(info)
                } else {
                    state.lastPollWasPendingProgress = false
                }
                if ok, self.launchInt(info["status"]) > 3, self.launchInt(info["status"]) != 6 {
                    self.dispatchLaunch(completion, false, [:], "", "Session in terminal error state")
                    return
                }
                let delay = state.retries <= 12 ? 0.3 : (state.retries <= 20 ? 0.5 : 1.0)
                pollBox.schedule(after: delay)
            }
        }
        pollBox.call()
    }

    private func waitForSessionTeardown(sessionId: String, appId: Int, progress: @escaping OPNGameLaunchProgressCallback, completion: @escaping @Sendable (Bool, String) -> Void) {
        let state = OPNLaunchPollState()
        let pollBox = OPNLaunchPollBox()
        pollBox.poll = { [weak self, state, pollBox] in
            guard let self else { return }
            if state.retries >= 90 {
                completion(false, "Timed out waiting for previous session cleanup")
                return
            }
            state.retries += 1
            self.reportTeardownProgress(progress, session: [:])
            OPNSessionManager.shared.getActiveSessions { [weak self] ok, sessions, error in
                guard let self else { return }
                if !ok {
                    OPNSentry.logErrorMessage("[GameService] Teardown wait active-session poll failed: \(error)")
                    pollBox.schedule(after: 1)
                    return
                }
                if sessions.contains(where: { self.launchString($0["sessionId"]) == sessionId && self.launchInt($0["status"]) == 6 }) || sessions.contains(where: { self.launchInt($0["appId"]) == appId && self.launchInt($0["status"]) == 6 }) {
                    pollBox.schedule(after: 1)
                    return
                }
                completion(true, "")
            }
        }
        pollBox.call()
    }

    private func isSessionReady(_ session: [String: Any]) -> Bool {
        let status = launchInt(session["status"])
        return status == 2 || status == 3
    }

    private func isSessionLaunchProgressPending(_ session: [String: Any]) -> Bool {
        if launchInt(session["status"]) != 1 { return false }
        if let adState = session["adState"] as? [String: Any], launchBool(adState["isAdsRequired"]) { return true }
        if launchInt(session["queuePosition"]) > 0 || launchInt(session["seatSetupStep"]) > 0 { return true }
        return [1, 2, 3, 4].contains(launchInt(session["progressState"]))
    }

    private func progressMessage(for session: [String: Any]) -> String {
        if let adState = session["adState"] as? [String: Any], launchBool(adState["isAdsRequired"]) {
            let message = launchString(adState["message"])
            if !message.isEmpty { return message }
            return launchBool(adState["isQueuePaused"]) ? "Launch paused for ads." : "Watch the ad to continue."
        }
        if launchInt(session["status"]) == 6 { return "Previous session is ending. Waiting for GeForce NOW to finish cleanup..." }
        switch launchInt(session["progressState"]) {
        case 3: return "Previous session is ending. Waiting for GeForce NOW to finish cleanup..."
        case 4: return "Waiting for cloud storage to be ready..."
        case 2: return queueProgressMessage(launchInt(session["queuePosition"]))
        case 1: return "Connecting to GeForce NOW..."
        case 5: return "Setting up cloud rig..."
        default: break
        }
        if launchInt(session["queuePosition"]) > 0 { return queueProgressMessage(launchInt(session["queuePosition"])) }
        return "Waiting for cloud session..."
    }

    private func queueProgressMessage(_ position: Int) -> String {
        if position > 2 { return "\(position - 1) gamers ahead of you." }
        if position == 2 { return "1 gamer ahead of you." }
        if position == 1 { return "You're next in queue." }
        return "Waiting in queue..."
    }

    private func reportLaunchProgress(_ progress: @escaping OPNGameLaunchProgressCallback, session: [String: Any]) {
        let message = progressMessage(for: session)
        nonisolated(unsafe) let launchSession = session
        DispatchQueue.main.async { progress(message, launchSession) }
    }

    private func reportTeardownProgress(_ progress: @escaping OPNGameLaunchProgressCallback, session: [String: Any]) {
        var cleanupInfo = session
        cleanupInfo["queuePosition"] = 0
        nonisolated(unsafe) let launchCleanupInfo = cleanupInfo
        DispatchQueue.main.async { progress("Previous session is ending. Waiting for GeForce NOW to finish cleanup...", launchCleanupInfo) }
    }

    private func dispatchLaunch(_ completion: @escaping OPNGameLaunchCallback, _ success: Bool, _ session: [String: Any], _ offerSdp: String, _ error: String) {
        nonisolated(unsafe) let launchSession = session
        DispatchQueue.main.async { completion(success, launchSession, offerSdp, error) }
    }

    private func isSessionAuthenticationError(_ error: String) -> Bool {
        error.contains("HTTP 401") || error.contains("HTTP 403") || error.contains("AUTH_FAILURE") || error.contains("auth_failure") || error.contains("No access token")
    }

    private func isSessionLimitExceededError(_ error: String) -> Bool {
        error.contains("SESSION_LIMIT") || error.contains("\"statusCode\":11")
    }

    private func activeSessionsFromSessionLimitError(_ error: String) -> [[String: Any]] {
        guard let jsonStart = error.firstIndex(of: "{") else { return [] }
        let jsonText = String(error[jsonStart...])
        guard let data = jsonText.data(using: .utf8), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return activeSessionEntries(from: launchArray(json["otherUserSessions"]))
    }

    private func activeSessionEntries(from sessions: [Any]) -> [[String: Any]] {
        sessions.compactMap { item -> [String: Any]? in
            guard let session = item as? [String: Any] else { return nil }
            let sessionId = launchString(session["sessionId"])
            let status = launchInt(session["status"])
            guard !sessionId.isEmpty, [1, 2, 3, 6].contains(status) else { return nil }
            var connectionHost = ""
            for connection in launchArray(session["connectionInfo"]).compactMap({ $0 as? [String: Any] }) where launchInt(connection["usage"]) == 14 {
                let ip = usableSessionHost(launchString(connection["ip"]))
                if !ip.isEmpty {
                    connectionHost = ip
                    break
                }
                let resourceHost = hostFromStreamingResourcePath(launchString(connection["resourcePath"]))
                if !resourceHost.isEmpty {
                    connectionHost = resourceHost
                    break
                }
            }
            let controlInfo = session["sessionControlInfo"] as? [String: Any]
            let controlHost = launchString(controlInfo?["ip"])
            let serverIp = controlHost.isEmpty ? connectionHost : controlHost
            guard !serverIp.isEmpty else { return nil }
            let requestData = session["sessionRequestData"] as? [String: Any]
            return [
                "sessionId": sessionId,
                "appId": launchInt(requestData?["appId"]),
                "status": status,
                "serverIp": serverIp,
                "gpuType": launchString(session["gpuType"]),
                "signalingUrl": connectionHost.isEmpty ? (controlHost.isEmpty ? "" : "wss://\(controlHost):443/nvst/") : "wss://\(connectionHost):443/nvst/",
            ]
        }
    }

    private func hostFromStreamingResourcePath(_ resourcePath: String) -> String {
        for prefix in ["rtsps://", "rtsp://", "wss://", "https://"] where resourcePath.hasPrefix(prefix) {
            let remainder = String(resourcePath.dropFirst(prefix.count))
            let end = remainder.firstIndex(where: { $0 == ":" || $0 == "/" }) ?? remainder.endIndex
            let host = String(remainder[..<end])
            return host.first == "." ? "" : host
        }
        return ""
    }

    private func usableSessionHost(_ value: String) -> String {
        value.isEmpty || value.first == "." ? "" : value
    }

    private func launchString(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private func launchInt(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private func launchBool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return ["true", "1", "yes"].contains(value.lowercased()) }
        return false
    }

    private func launchArray(_ value: Any?) -> [Any] {
        if let value = value as? [Any] { return value }
        if let value = value as? NSArray { return value as? [Any] ?? [] }
        return []
    }

    func fetchProviderInfo(idpId: String, completion: @escaping OPNProviderInfoCallback) {
        guard let url = URL(string: Self.providerServiceUrlsEndpoint) else {
            dispatchProviderInfo(completion, false, OPNGameProviderInfo(), OPNGameProviderEndpoint(), "Invalid provider info URL")
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.gfnUserAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, let data, statusCode == 200 else {
                var endpoint = OPNGameProviderEndpoint()
                endpoint.streamingServiceUrl = Self.defaultStreamingBaseUrl
                self.providerStreamingBaseUrl = endpoint.streamingServiceUrl
                self.dispatchProviderInfo(completion, false, OPNGameProviderInfo(), endpoint, error?.localizedDescription ?? "Provider info request failed")
                return
            }

            let json = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
            let info = self.parseGameProviderInfo(json)
            var endpoint = self.selectGameProviderEndpoint(info, idpId: idpId)
            if endpoint.streamingServiceUrl.isEmpty { endpoint.streamingServiceUrl = Self.defaultStreamingBaseUrl }
            self.providerStreamingBaseUrl = self.normalizeStreamingBaseUrl(endpoint.streamingServiceUrl)
            if self.providerStreamingBaseUrl.isEmpty { self.providerStreamingBaseUrl = Self.defaultStreamingBaseUrl }
            endpoint.streamingServiceUrl = self.providerStreamingBaseUrl
            self.dispatchProviderInfo(completion, true, info, endpoint, "")
        }.resume()
    }

    func fetchMarqueePanels(completion: @escaping OPNPanelCallback) {
        fetchPanels(operationName: "panels/Marquee", hash: Self.marqueeHash, panelNames: ["MARQUEE"], missingMessage: "No panels in marquee response", completion: completion)
    }

    func fetchMainPanels(completion: @escaping OPNPanelCallback) {
        fetchPanels(operationName: "panels/MainV2", hash: Self.panelsHash, panelNames: ["MAIN"], missingMessage: "No panels in response", completion: completion)
    }

    func fetchCatalogGames(completion: @escaping OPNCatalogCallback) {
        browseCatalogGames(searchQuery: "", sortId: "relevance", filterIds: [], fetchCount: 200) { success, result, error in
            completion(success, result.games, error)
        }
    }

    func browseCatalogGames(searchQuery: String, sortId: String, filterIds: [String], fetchCount: Int, completion: @escaping OPNCatalogBrowseCallback) {
        let token = accessToken
        let accountIdentifier = userId
        let providerBaseUrl = providerStreamingBaseURL()
        let locale = Self.currentGFNLocale()
        getServerVpcId(token: token, providerStreamingBaseUrl: providerBaseUrl) { [weak self] resolvedVpcId in
            guard let self else { return }
            self.continueBrowseCatalogGames(
                accountIdentifier: accountIdentifier,
                providerBaseUrl: providerBaseUrl,
                locale: locale,
                resolvedVpcId: resolvedVpcId,
                searchQuery: searchQuery,
                sortId: sortId,
                filterIds: filterIds,
                fetchCount: fetchCount,
                completion: completion
            )
        }
    }

    private func continueBrowseCatalogGames(
        accountIdentifier: String,
        providerBaseUrl: String,
        locale: String,
        resolvedVpcId: String,
        searchQuery: String,
        sortId: String,
        filterIds: [String],
        fetchCount: Int,
        completion: @escaping OPNCatalogBrowseCallback
    ) {
        let requestedSortId = sortId.isEmpty ? "last_played" : sortId
        let requestedFetchCount = max(24, min(fetchCount > 0 ? fetchCount : Self.defaultCatalogFetchCount, 200))
        let catalogCacheKey = OPNGameDataCache.shared.catalogKey(
            accountIdentifier: accountIdentifier,
            searchQuery: searchQuery,
            sortId: requestedSortId,
            filterIds: filterIds,
            fetchCount: requestedFetchCount,
            locale: locale,
            providerStreamingBaseUrl: providerBaseUrl,
            vpcId: resolvedVpcId
        )

        if var fresh = OPNGameDataCache.shared.loadFreshCatalog(key: catalogCacheKey, maxAgeSeconds: Self.catalogCacheFreshSeconds),
           let definitions = OPNGameDataCache.shared.loadCatalogDefinitions(locale: locale, maxAgeSeconds: Self.catalogDefinitionsFreshSeconds) {
            _ = parseCatalogDefinitions(definitions, result: &fresh)
            dispatchCatalogBrowse(completion, true, fresh, "")
            return
        }

        let deliveredCachedResult = AtomicFlag()
        if let cached = OPNGameDataCache.shared.loadCatalog(key: catalogCacheKey) {
            deliveredCachedResult.setTrue()
            dispatchCatalogBrowse(completion, true, cached, "")
        }

        let definitionsQuery = """
        query GetFilterGroupAndSortOrderDefinitions($locale: String!) {
            filterGroupDefinitions(language: $locale) { id label filters { id label filters } }
            sortOrderDefinitions(language: $locale) { id label orderBy }
        }
        """

        let parameters = CatalogDefinitionParameters(
            requestedSortId: requestedSortId,
            filterIds: filterIds,
            requestedFetchCount: requestedFetchCount,
            searchQuery: searchQuery,
            resolvedVpcId: resolvedVpcId,
            locale: locale,
            catalogCacheKey: catalogCacheKey
        )

        if let cachedDefinitions = OPNGameDataCache.shared.loadCatalogDefinitions(locale: locale, maxAgeSeconds: Self.catalogDefinitionsFreshSeconds) {
            handleCatalogDefinitions(cachedDefinitions, "", parameters: parameters, deliveredCachedResult: deliveredCachedResult, completion: completion)
        } else {
            postGraphQlJson(query: definitionsQuery, variables: ["locale": locale] as NSDictionary) { [weak self] data, error in
                guard let self else { return }
                if error.isEmpty, let data { OPNGameDataCache.shared.saveCatalogDefinitions(locale: locale, definitions: data) }
                self.handleCatalogDefinitions(data, error, parameters: parameters, deliveredCachedResult: deliveredCachedResult, completion: completion)
            }
        }
    }

    private func handleCatalogDefinitions(
        _ definitionsData: NSDictionary?,
        _ definitionsError: String,
        parameters: CatalogDefinitionParameters,
        deliveredCachedResult: AtomicFlag,
        completion: @escaping OPNCatalogBrowseCallback
    ) {
        if !definitionsError.isEmpty {
            if !deliveredCachedResult.value { dispatchCatalogBrowse(completion, false, OPNCatalogBrowseResult(), definitionsError) }
            return
        }
        let definitionsBox = definitionsData.map(NSDictionaryBox.init)
        Self.workQueue.async { [weak self, definitionsBox] in
            guard let self else { return }
            var result = OPNCatalogBrowseResult()
            let filterPayloadById = self.parseCatalogDefinitions(definitionsBox?.value, result: &result)
            var selectedSort = OPNCatalogSortOption(id: "relevance", label: "Relevance", orderBy: "itemMetadata.relevance:DESC,sortName:ASC")
            for option in result.sortOptions where option.id == parameters.requestedSortId {
                selectedSort = option
                break
            }

            var filters: [String: Any] = [:]
            for filterId in parameters.filterIds {
                guard let payload = filterPayloadById[filterId] else { continue }
                self.deepMergeDictionary(into: &filters, source: payload)
                result.selectedFilterIds.append(filterId)
            }
            let trimmedSearch = parameters.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            result.searchQuery = trimmedSearch
            result.selectedSortId = selectedSort.id
            self.fetchCatalogPages(
                baseResult: result,
                query: trimmedSearch.isEmpty ? Self.catalogQuery : Self.catalogSearchQuery,
                vpcId: parameters.resolvedVpcId,
                locale: parameters.locale,
                sortString: selectedSort.orderBy,
                fetchCount: parameters.requestedFetchCount,
                searchString: trimmedSearch,
                filters: filters as NSDictionary,
                catalogCacheKey: parameters.catalogCacheKey,
                deliveredCachedResult: deliveredCachedResult,
                completion: completion
            )
        }
    }

    func fetchLibraryGames(completion: @escaping OPNCatalogCallback) {
        getServerVpcId(token: accessToken, providerStreamingBaseUrl: providerStreamingBaseURL()) { [weak self] resolvedVpcId in
            guard let self else { return }
            let variables: NSDictionary = ["vpcId": resolvedVpcId, "locale": Self.currentGFNLocale(), "panelNames": ["LIBRARY"]]
            let flatten: @Sendable (NSDictionary?, String) -> Void = { [weak self] data, error in
                guard let self else { return }
                if !error.isEmpty {
                    self.dispatchCatalog(completion, false, [], error)
                    return
                }
                guard let panels = data?["panels"] as? [NSDictionary] else {
                    self.dispatchCatalog(completion, false, [], "No panels in library response")
                    return
                }
                let games = self.parsePanelResults(panels).flatMap { $0.sections }.flatMap { $0.games }
                self.enrichGames(games, vpcId: resolvedVpcId) { enriched in
                    self.dispatchCatalog(completion, true, self.deduplicateGames(enriched), "")
                }
            }
            self.postGraphQL(operationName: "panels/Library", queryHash: Self.libraryWithTimeHash, variables: variables) { data, error in
                if error.isEmpty {
                    flatten(data, error)
                } else {
                    let retryVariables: NSDictionary = ["vpcId": resolvedVpcId, "locale": Self.currentGFNLocale(), "panelNames": ["LIBRARY"]]
                    self.postGraphQL(operationName: "panels/Library", queryHash: Self.panelsHash, variables: retryVariables, completion: flatten)
                }
            }
        }
    }

    func fetchPublicGames(completion: @escaping OPNCatalogCallback) {
        let locales = Self.currentGFNLocaleURLPathComponentFallbacks()
        fetchPublicGamesLocale(locales: locales.isEmpty ? ["en-US"] : locales, index: 0, completion: completion)
    }

    func fetchSubscriptionInfo(userId: String, completion: @escaping OPNSubscriptionCallback) {
        let token = accessToken
        guard !token.isEmpty else {
            dispatchSubscription(completion, false, OPNSubscriptionInfo(), "No access token")
            return
        }
        guard !userId.isEmpty else {
            dispatchSubscription(completion, false, OPNSubscriptionInfo(), "No user ID")
            return
        }

        getServerVpcId(token: token, providerStreamingBaseUrl: providerStreamingBaseURL()) { [weak self] resolvedVpcId in
            guard let self else { return }
            var components = URLComponents(string: "https://mes.geforcenow.com/v4/subscriptions")
            components?.queryItems = [
                URLQueryItem(name: "serviceName", value: "gfn_pc"),
                URLQueryItem(name: "languageCode", value: Self.currentGFNLocale()),
                URLQueryItem(name: "vpcId", value: resolvedVpcId == "GFN-PC" ? Self.defaultSubscriptionVpcId : resolvedVpcId),
                URLQueryItem(name: "userId", value: userId),
            ]
            guard let url = components?.url else {
                self.dispatchSubscription(completion, false, OPNSubscriptionInfo(), "Invalid subscription URL")
                return
            }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "GET"
            request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            Self.applyClientHeaders(to: &request, includeBrowserHeaders: false)
            URLSession.shared.dataTask(with: request) { data, response, error in
                Self.workQueue.async {
                    if let error {
                        self.dispatchSubscription(completion, false, OPNSubscriptionInfo(), error.localizedDescription)
                        return
                    }
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? NSDictionary
                    guard statusCode == 200, let json else {
                        self.dispatchSubscription(completion, false, OPNSubscriptionInfo(), "Subscription API failed (\(statusCode))")
                        return
                    }
                    self.dispatchSubscription(completion, true, self.parseSubscriptionInfo(json), "")
                }
            }.resume()
        }
    }

    func resolveStoreURL(game: OPNGameInfo, variantIndex: Int, completion: @escaping OPNStoreURLCallback) {
        if let localStoreURL = storeURLForKnownGame(game, variantIndex: variantIndex), !localStoreURL.isEmpty {
            dispatchStoreURL(completion, true, localStoreURL, "")
            return
        }
        let appId = game.uuid.isEmpty ? game.id : game.uuid
        guard !appId.isEmpty else {
            dispatchStoreURL(completion, false, "", "No app ID available for store URL lookup")
            return
        }
        guard !accessToken.isEmpty else {
            dispatchStoreURL(completion, false, "", "No access token")
            return
        }
        let selectedVariant = game.variants.indices.contains(variantIndex) ? game.variants[variantIndex] : nil
        getServerVpcId(token: accessToken, providerStreamingBaseUrl: providerStreamingBaseURL()) { [weak self] resolvedVpcId in
            guard let self else { return }
            self.fetchAppMetadata(appIds: [appId], vpcId: resolvedVpcId.isEmpty ? "GFN-PC" : resolvedVpcId) { data, error in
                if !error.isEmpty {
                    self.dispatchStoreURL(completion, false, "", error)
                    return
                }
                guard let items = (data?["apps"] as? NSDictionary)?["items"] as? [NSDictionary] else {
                    self.dispatchStoreURL(completion, false, "", "No app metadata in store URL response")
                    return
                }
                let metadataApp = items.first { self.safeString($0["id"]) == appId } ?? items.first
                guard let metadataApp else {
                    self.dispatchStoreURL(completion, false, "", "No matching app metadata for store URL lookup")
                    return
                }
                let metadataGame = self.parseGameItem(metadataApp)
                let storeURL = self.storeURLForMetadataGame(metadataGame, variantId: selectedVariant?.id ?? "", store: selectedVariant?.appStore ?? "")
                if storeURL.isEmpty {
                    self.dispatchStoreURL(completion, false, "", "No store URL found for selected variant")
                    return
                }
                self.dispatchStoreURL(completion, true, storeURL, "")
            }
        }
    }

    func fetchUserAccount(completion: @escaping OPNUserAccountCallback) {
        let query = """
        query GetUserAccount {
          userAccount {
            subscriptions { id }
            storesData { store accountLinkingData { userDisplayName expiresIn userIdentifier accountSyncingData { totalNumberOfSyncedGfnGames syncState syncDate } } }
          }
        }
        """
        postGraphQlJson(query: query, variables: [:] as NSDictionary) { [weak self] data, error in
            guard let self else { return }
            if !error.isEmpty {
                self.dispatchUserAccount(completion, false, OPNUserAccountInfo(), error)
                return
            }
            self.dispatchUserAccount(completion, true, self.parseUserAccountInfo(data), "")
        }
    }

    func fetchStoreDefinitions(completion: @escaping OPNStoreDefinitionsCallback) {
        let query = """
        query GetStoreDefinitions($locale: String!) {
          appStoreDefinitions(language: $locale) {
            store label sortOrder smallImageUrl
            features {
              __typename
              ... on AccountLinkingSso { displayProposition supported }
              ... on AccountGamesSyncing { displayProposition supported }
              ... on AccountSubscriptions { displayProposition }
            }
            accountLinkingMetadata { supportedVariantIds isSupported isRequired label }
          }
        }
        """
        postGraphQlJson(query: query, variables: ["locale": Self.currentGFNLocale()] as NSDictionary) { [weak self] data, error in
            guard let self else { return }
            if !error.isEmpty {
                self.dispatchStoreDefinitions(completion, false, [], error)
                return
            }
            self.dispatchStoreDefinitions(completion, true, self.parseStoreDefinitions(data), "")
        }
    }

    func addOwnedVariant(_ variantId: String, completion: @escaping OPNOwnershipActionCallback) {
        ownedVariantMutation(mutationName: "AddOwnedVariant", fieldName: "addOwnedVariant", variantId: variantId, completion: completion)
    }

    func removeOwnedVariant(_ variantId: String, completion: @escaping OPNOwnershipActionCallback) {
        ownedVariantMutation(mutationName: "RemoveOwnedVariant", fieldName: "removeOwnedVariant", variantId: variantId, completion: completion)
    }

    func selectOwnedVariant(_ variantId: String, completion: @escaping OPNOwnershipActionCallback) {
        ownedVariantMutation(mutationName: "SelectOwnedVariant", fieldName: "selectOwnedVariant", variantId: variantId, completion: completion)
    }

    func syncAccountProvider(store: String, completion: @escaping OPNOwnershipActionCallback) {
        let token = accountLinkingToken.isEmpty ? accessToken : accountLinkingToken
        guard !token.isEmpty else {
            dispatchOwnership(completion, false, "Missing account-linking token")
            return
        }
        guard !store.isEmpty else {
            dispatchOwnership(completion, false, "Missing store for sync")
            return
        }
        let encodedStore = percentEncodeQueryValue(store)
        guard let url = URL(string: "\(Self.accountLinkingServer)/v1/sync/\(encodedStore)") else {
            dispatchOwnership(completion, false, "Invalid ALS sync URL")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: Self.accountLinkingRequestTimeoutSeconds)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.dispatchOwnership(completion, false, error.localizedDescription)
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode != 202 {
                let message = statusCode > 0 ? "ALS sync returned HTTP \(statusCode)" : "Missing ALS sync response"
                _ = self.accountLinkingResponseSnippet(data)
                self.dispatchOwnership(completion, false, message)
                return
            }
            self.dispatchOwnership(completion, true, "")
        }.resume()
    }

    func startAccountLinking(store: String, completion: @escaping OPNOwnershipActionCallback) {
        let token = accountLinkingToken.isEmpty ? accessToken : accountLinkingToken
        guard !token.isEmpty else {
            dispatchOwnership(completion, false, "Missing account-linking token")
            return
        }
        guard !store.isEmpty else {
            dispatchOwnership(completion, false, "Missing store for account linking")
            return
        }
        guard let listener = AccountLinkingCallbackListener() else {
            dispatchOwnership(completion, false, "No available port for account linking callback")
            return
        }

        let redirectURI = "http://localhost:\(listener.port)/"
        var components = URLComponents(string: "\(Self.accountLinkingServer)/v1/login_url")
        components?.queryItems = [
            URLQueryItem(name: "platform", value: store),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "client_id", value: Self.accountLinkingClientId),
        ]
        guard let url = components?.url else {
            listener.close()
            dispatchOwnership(completion, false, "Invalid ALS login URL request")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: Self.accountLinkingRequestTimeoutSeconds)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, statusCode == 200, let data else {
                listener.close()
                self.dispatchOwnership(completion, false, error?.localizedDescription ?? "ALS login URL request failed")
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
            guard let loginURLText = self.safeString(json?["login_url"]), let loginURL = URL(string: loginURLText) else {
                listener.close()
                self.dispatchOwnership(completion, false, "ALS login URL response did not include login_url")
                return
            }
            listener.wait(timeout: Self.accountLinkingCallbackTimeoutSeconds, completion: completion)
            DispatchQueue.main.async { NSWorkspace.shared.open(loginURL) }
        }.resume()
    }

    func prewarmLaunchData() {
        let token = accessToken
        if !token.isEmpty { getServerVpcId(token: token, providerStreamingBaseUrl: providerStreamingBaseURL()) { _ in } }
    }

    static func optimizeImageURL(_ url: String, width: Int = 272) -> String {
        if url.isEmpty { return url }
        if url.contains("img.nvidiagrid.net") { return "\(url);f=webp;w=\(width)" }
        return url
    }

    private func fetchPanels(operationName: String, hash: String, panelNames: [String], missingMessage: String, completion: @escaping OPNPanelCallback) {
        getServerVpcId(token: accessToken, providerStreamingBaseUrl: providerStreamingBaseURL()) { [weak self] resolvedVpcId in
            guard let self else { return }
            let variables: NSDictionary = ["vpcId": resolvedVpcId, "locale": Self.currentGFNLocale(), "panelNames": panelNames]
            self.postGraphQL(operationName: operationName, queryHash: hash, variables: variables) { data, error in
                if !error.isEmpty {
                    self.dispatchPanel(completion, false, [], error)
                    return
                }
                guard let rawPanels = data?["panels"] as? [NSDictionary] else {
                    self.dispatchPanel(completion, false, [], missingMessage)
                    return
                }
                self.dispatchPanel(completion, true, self.parsePanelResults(rawPanels), "")
            }
        }
    }

    private func postGraphQL(operationName: String, queryHash: String, variables: NSDictionary?, completion: @escaping @Sendable (NSDictionary?, String) -> Void) {
        let variableData = variables.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data("{}".utf8)
        let variableText = String(data: variableData, encoding: .utf8) ?? "{}"
        let extensions: NSDictionary = ["persistedQuery": ["sha256Hash": queryHash]]
        let extensionData = (try? JSONSerialization.data(withJSONObject: extensions)) ?? Data("{}".utf8)
        let extensionText = String(data: extensionData, encoding: .utf8) ?? "{}"
        let huId = "\(Int(Date().timeIntervalSince1970 * 1000))\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"
        let urlText = "https://games.geforce.com/graphql?requestType=\(percentEncodeQueryValue(operationName))&extensions=\(percentEncodeQueryValue(extensionText))&huId=\(huId)&variables=\(percentEncodeQueryValue(variableText))"
        guard let url = URL(string: urlText) else {
            dispatchGraphQL(completion, nil, "Invalid URL")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        applyBaseHeaders(to: &request)
        request.setValue("application/graphql", forHTTPHeaderField: "Content-Type")
        runGraphQLRequest(request, completion: completion)
    }

    private func postGraphQlJson(query: String, variables: NSDictionary?, completion: @escaping @Sendable (NSDictionary?, String) -> Void) {
        guard let url = URL(string: graphqlURL) else {
            dispatchGraphQL(completion, nil, "Invalid URL")
            return
        }
        var body: [String: Any] = ["query": query]
        if let variables { body["variables"] = variables }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        applyBaseHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        runGraphQLRequest(request, completion: completion)
    }

    private func runGraphQLRequest(_ request: URLRequest, completion: @escaping @Sendable (NSDictionary?, String) -> Void) {
        URLSession.shared.dataTask(with: request) { data, response, error in
            var payload: NSDictionary?
            var message = ""
            if let error {
                message = error.localizedDescription
            } else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? NSDictionary
                if statusCode != 200 || json == nil {
                    message = "GraphQL error (\(statusCode))"
                } else if let errors = json?["errors"] as? [NSDictionary], !errors.isEmpty {
                    message = errors.first?["message"] as? String ?? "GraphQL error"
                } else if let dataPayload = json?["data"] as? NSDictionary {
                    payload = dataPayload
                } else {
                    message = "No data in GraphQL response"
                }
            }
            self.dispatchGraphQL(completion, payload, message)
        }.resume()
    }

    private func fetchAppMetadata(appIds: [String], vpcId: String, completion: @escaping @Sendable (NSDictionary?, String) -> Void) {
        let variables: NSDictionary = ["vpcId": vpcId.isEmpty ? "GFN-PC" : vpcId, "locale": Self.currentGFNLocale(), "appIds": appIds]
        postGraphQL(operationName: "appMetaData", queryHash: Self.appMetaDataHash, variables: variables, completion: completion)
    }

    private func fetchCatalogPages(baseResult: OPNCatalogBrowseResult, query: String, vpcId: String, locale: String, sortString: String, fetchCount: Int, searchString: String, filters: NSDictionary, catalogCacheKey: String, deliveredCachedResult: AtomicFlag, completion: @escaping OPNCatalogBrowseCallback) {
        let state = CatalogPageState(result: baseResult)
        let filterBox = NSDictionaryBox(filters)
        let fetchPage = RecursiveCatalogPageFetcher()
        fetchPage.action = { [weak self, state, fetchPage] page, cursor in
            guard let self else { return }
            var variables: [String: Any] = ["vpcId": vpcId, "locale": locale, "sortString": sortString, "fetchCount": fetchCount, "cursor": cursor, "filters": filterBox.value]
            if !searchString.isEmpty { variables["searchString"] = searchString }
            postGraphQlJson(query: query, variables: variables as NSDictionary) { [weak self] data, error in
                guard let self else { return }
                let dataBox = data.map(NSDictionaryBox.init)
                Self.workQueue.async { [dataBox] in
                    if !error.isEmpty {
                        if !deliveredCachedResult.value { self.dispatchCatalogBrowse(completion, false, OPNCatalogBrowseResult(), error) }
                        return
                    }
                    guard let apps = dataBox?.value["apps"] as? NSDictionary else {
                        if !deliveredCachedResult.value { self.dispatchCatalogBrowse(completion, false, OPNCatalogBrowseResult(), "No apps data") }
                        return
                    }
                    if let items = apps["items"] as? [NSDictionary] { state.collectedApps.append(contentsOf: items) }
                    state.result.numberReturned += self.safeInt(apps["numberReturned"])
                    state.result.numberSupported = self.safeInt(apps["numberSupported"])
                    let pageInfo = apps["pageInfo"] as? NSDictionary
                    let hasNextPage = self.safeBool(pageInfo?["hasNextPage"])
                    let endCursor = self.safeString(pageInfo?["endCursor"]) ?? ""
                    state.result.totalCount = self.safeInt(pageInfo?["totalCount"])
                    state.result.hasNextPage = hasNextPage
                    if !endCursor.isEmpty { state.result.endCursor = endCursor }
                    if hasNextPage, !endCursor.isEmpty, page + 1 < Self.maxCatalogPages {
                        fetchPage.action?(page + 1, endCursor)
                        return
                    }
                    let games = state.collectedApps.map { self.parseGameItem($0) }.filter { !$0.id.isEmpty && !$0.title.isEmpty && !$0.variants.isEmpty }
                    state.result.numberSupported = max(state.result.numberSupported, games.count)
                    state.result.totalCount = max(state.result.totalCount, games.count)
                    self.enrichGames(games, vpcId: vpcId) { enriched in
                        var finalResult = state.result
                        finalResult.games = enriched
                        OPNGameDataCache.shared.saveCatalog(key: catalogCacheKey, result: finalResult)
                        self.dispatchCatalogBrowse(completion, true, finalResult, "")
                    }
                }
            }
        }
        fetchPage.action?(0, "")
    }

    private func enrichGames(_ games: [OPNGameInfo], vpcId: String, completion: @escaping @Sendable ([OPNGameInfo]) -> Void) {
        let appIds = Array(Set(games.map(\.uuid).filter { !$0.isEmpty }))
        if appIds.isEmpty {
            completion(games)
            return
        }
        let metadataState = MetadataState()
        let chunks = stride(from: 0, to: appIds.count, by: 40).map { Array(appIds[$0..<min($0 + 40, appIds.count)]) }
        let group = DispatchGroup()
        for chunk in chunks {
            group.enter()
            fetchAppMetadata(appIds: chunk, vpcId: vpcId) { [weak self] data, _ in
                if let self, let items = (data?["apps"] as? NSDictionary)?["items"] as? [NSDictionary] {
                    let itemsBox = NSDictionaryArrayBox(items)
                    Self.workQueue.async { [itemsBox] in
                        for item in itemsBox.values {
                            if let appId = self.safeString(item["id"]) { metadataState.metadataById[appId] = item }
                        }
                        group.leave()
                    }
                } else {
                    group.leave()
                }
            }
        }
        group.notify(queue: Self.workQueue) {
            let enriched = games.map { game in
                guard let metadata = metadataState.metadataById[game.uuid] else { return game }
                var merged = game
                let metadataGame = self.parseGameItem(metadata)
                self.mergeMissingStoreMetadata(target: &merged, metadata: metadataGame)
                if !metadataGame.description.isEmpty { merged.description = metadataGame.description }
                if merged.genres.isEmpty { merged.genres = metadataGame.genres }
                if merged.featureLabels.isEmpty { merged.featureLabels = metadataGame.featureLabels }
                if merged.developerName.isEmpty { merged.developerName = metadataGame.developerName }
                if merged.publisherName.isEmpty { merged.publisherName = metadataGame.publisherName }
                if merged.imageUrl.isEmpty { merged.imageUrl = metadataGame.imageUrl }
                if merged.heroImageUrl.isEmpty { merged.heroImageUrl = metadataGame.heroImageUrl }
                if !metadataGame.screenshotUrls.isEmpty { merged.screenshotUrls = metadataGame.screenshotUrls }
                if !metadataGame.imageUrlsByType.isEmpty { merged.imageUrlsByType = metadataGame.imageUrlsByType }
                if merged.maxLocalPlayers <= 0 { merged.maxLocalPlayers = metadataGame.maxLocalPlayers }
                if merged.maxOnlinePlayers <= 0 { merged.maxOnlinePlayers = metadataGame.maxOnlinePlayers }
                if merged.supportedControls.isEmpty { merged.supportedControls = metadataGame.supportedControls }
                if merged.contentRatings.isEmpty { merged.contentRatings = metadataGame.contentRatings }
                if merged.nvidiaTech.isEmpty { merged.nvidiaTech = metadataGame.nvidiaTech }
                return merged
            }
            completion(enriched)
        }
    }

    private func parseGameItem(_ app: NSDictionary?) -> OPNGameInfo {
        guard let app else { return OPNGameInfo() }
        var game = OPNGameInfo()
        game.id = safeString(app["id"]) ?? ""
        game.uuid = game.id
        game.title = safeString(app["title"]) ?? ""
        game.shortName = safeString(app["shortName"]) ?? ""
        game.description = firstSafeString(app, keys: ["description", "longDescription", "shortDescription", "summary"]) ?? ""
        game.developerName = safeString(app["developerName"]) ?? ""
        game.publisherName = safeString(app["publisherName"]) ?? ""
        game.maxLocalPlayers = safeInt(app["maxLocalPlayers"])
        game.maxOnlinePlayers = safeInt(app["maxOnlinePlayers"])
        appendStringValues(&game.supportedControls, app["supportedControls"])
        appendStringValues(&game.contentRatings, app["contentRatings"])
        appendStringValues(&game.nvidiaTech, app["nvidiaTech"])
        if game.description.isEmpty, let itemMetadata = app["itemMetadata"] as? NSDictionary {
            game.description = firstSafeString(itemMetadata, keys: ["description", "longDescription", "shortDescription", "summary"]) ?? ""
        }
        if let gfn = app["gfn"] as? NSDictionary {
            game.playabilityState = safeString(gfn["playabilityState"]) ?? ""
            game.membershipTierLabel = safeString(gfn["minimumMembershipTierLabel"]) ?? ""
            game.playType = safeString(gfn["playType"]) ?? ""
        }
        if let images = app["images"] as? NSDictionary {
            for case let key as String in images.allKeys {
                let urls = imageStrings(from: images[key]).map { Self.optimizeImageURL($0, width: 1200) }.uniqueValues()
                if !urls.isEmpty { game.imageUrlsByType[key] = urls }
            }
            let landscape = firstLandscapeImageString(images)
            let poster = firstPosterImageString(images)
            let primary = landscape ?? poster
            if let landscape { game.heroImageUrl = Self.optimizeImageURL(landscape, width: 1200) }
            if let primary { game.imageUrl = Self.optimizeImageURL(primary, width: 900) }
            game.screenshotUrls = imageStrings(from: images["SCREENSHOTS"]).map { Self.optimizeImageURL($0, width: 720) }.uniqueValues()
        }
        if let variants = app["variants"] as? [NSDictionary] {
            for item in variants {
                var variant = OPNGameVariant()
                variant.id = safeString(item["id"]) ?? ""
                variant.appStore = safeString(item["appStore"]) ?? ""
                variant.storeUrl = safeString(item["storeUrl"]) ?? ""
                if let gfn = item["gfn"] as? NSDictionary, let library = gfn["library"] as? NSDictionary {
                    variant.serviceStatus = safeString(library["status"]) ?? ""
                    variant.librarySelected = safeBool(library["selected"])
                    if variant.librarySelected { variant.inLibrary = true }
                }
                if !variant.appStore.isEmpty, variant.appStore != "UNKNOWN", variant.appStore != "NONE" {
                    if let index = game.variants.firstIndex(where: { $0.appStore.caseInsensitiveCompare(variant.appStore) == .orderedSame }) {
                        _ = mergeVariantFromSameStore(target: &game.variants[index], source: variant)
                    } else {
                        game.availableStores.append(variant.appStore)
                        game.variants.append(variant)
                    }
                }
            }
        }
        var firstNumericVariant = ""
        for variant in game.variants {
            if variant.inLibrary, !variant.serviceStatus.isEmpty { game.isInLibrary = true }
            let numeric = !variant.id.isEmpty && variant.id.allSatisfy(\.isNumber)
            if numeric, variant.librarySelected { game.launchAppId = variant.id }
            if numeric, firstNumericVariant.isEmpty { firstNumericVariant = variant.id }
        }
        if game.launchAppId.isEmpty { game.launchAppId = firstNumericVariant }
        if let genres = app["genres"] as? [Any] {
            for item in genres {
                if let text = item as? String { appendUnique(&game.genres, text) }
                if let dictionary = item as? NSDictionary { appendUnique(&game.genres, safeString(dictionary["name"]) ?? "") }
            }
        }
        if let features = (app["featureLabels"] ?? app["features"]) as? [String] {
            for feature in features { appendUnique(&game.featureLabels, feature) }
        }
        return game
    }

    private func parsePanelResults(_ rawPanels: [NSDictionary]) -> [OPNPanelResult] {
        rawPanels.compactMap { panel in
            var result = OPNPanelResult()
            result.id = safeString(panel["id"]) ?? ""
            result.title = safeString(panel["name"]) ?? ""
            if result.id.isEmpty { result.id = result.title }
            result.typename = safeString(panel["__typename"]) ?? ""
            let sections = panel["sections"] as? [NSDictionary] ?? []
            result.sections = sections.compactMap { section in
                var panelSection = OPNPanelSection()
                panelSection.id = safeString(section["id"]) ?? ""
                panelSection.title = safeString(section["title"]) ?? ""
                panelSection.typename = safeString(section["__typename"]) ?? ""
                let items = section["items"] as? [NSDictionary] ?? []
                panelSection.games = items.compactMap { item in
                    guard safeString(item["__typename"]) == "GameItem", let app = item["app"] as? NSDictionary else { return nil }
                    let game = parseGameItem(app)
                    return !game.id.isEmpty && !game.title.isEmpty && !game.variants.isEmpty ? game : nil
                }
                return panelSection.games.isEmpty ? nil : panelSection
            }
            return result.sections.isEmpty ? nil : result
        }
    }

    private func parseCatalogDefinitions(_ definitionsData: NSDictionary?, result: inout OPNCatalogBrowseResult) -> [String: [String: Any]] {
        var filterPayloadById: [String: [String: Any]] = [:]
        let groups = definitionsData?["filterGroupDefinitions"] as? [NSDictionary] ?? []
        for groupRaw in groups {
            var group = OPNCatalogFilterGroup()
            group.id = safeString(groupRaw["id"]) ?? ""
            group.label = safeString(groupRaw["label"]) ?? ""
            let filters = groupRaw["filters"] as? [NSDictionary] ?? []
            for entry in filters {
                let filterId = safeString(entry["id"]) ?? ""
                if filterId.isEmpty { continue }
                var mergedPayload: [String: Any] = [:]
                for payloadString in entry["filters"] as? [String] ?? [] {
                    guard let data = payloadString.data(using: .utf8), let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                    deepMergeDictionary(into: &mergedPayload, source: payload)
                }
                if mergedPayload.isEmpty { continue }
                filterPayloadById[filterId] = mergedPayload
                group.options.append(OPNCatalogFilterOption(id: filterId, rawId: filterId, label: safeString(entry["label"]) ?? filterId, groupId: group.id, groupLabel: group.label))
            }
            if !group.options.isEmpty { result.filterGroups.append(group) }
        }
        let sorts = definitionsData?["sortOrderDefinitions"] as? [NSDictionary] ?? []
        for sort in sorts {
            let id = safeString(sort["id"]) ?? ""
            let orderBy = safeString(sort["orderBy"]) ?? ""
            if !id.isEmpty, !orderBy.isEmpty {
                result.sortOptions.append(OPNCatalogSortOption(id: id, label: safeString(sort["label"]) ?? id, orderBy: orderBy))
            }
        }
        return filterPayloadById
    }

    private func parseUserAccountInfo(_ data: NSDictionary?) -> OPNUserAccountInfo {
        var info = OPNUserAccountInfo()
        guard let userAccount = data?["userAccount"] as? NSDictionary else { return info }
        info.subscriptions = (userAccount["subscriptions"] as? [NSDictionary] ?? []).compactMap { safeString($0["id"]) }.filter { !$0.isEmpty }
        for storeData in userAccount["storesData"] as? [NSDictionary] ?? [] {
            var storeInfo = OPNStoreAccountInfo()
            storeInfo.store = safeString(storeData["store"]) ?? ""
            if let linkingData = storeData["accountLinkingData"] as? NSDictionary {
                storeInfo.hasAccountLinkingData = true
                storeInfo.userDisplayName = safeString(linkingData["userDisplayName"]) ?? ""
                storeInfo.expiresIn = safeString(linkingData["expiresIn"]) ?? ""
                storeInfo.userIdentifier = safeString(linkingData["userIdentifier"]) ?? ""
                if let syncingData = linkingData["accountSyncingData"] as? NSDictionary {
                    storeInfo.hasAccountSyncingData = true
                    storeInfo.syncing.totalNumberOfSyncedGfnGames = safeInt(syncingData["totalNumberOfSyncedGfnGames"])
                    storeInfo.syncing.syncState = safeString(syncingData["syncState"]) ?? ""
                    storeInfo.syncing.syncDate = safeString(syncingData["syncDate"]) ?? ""
                }
            }
            if !storeInfo.store.isEmpty { info.stores.append(storeInfo) }
        }
        return info
    }

    private func parseStoreDefinitions(_ data: NSDictionary?) -> [OPNStoreDefinition] {
        var definitions: [OPNStoreDefinition] = []
        for storeData in data?["appStoreDefinitions"] as? [NSDictionary] ?? [] {
            var definition = OPNStoreDefinition()
            definition.store = safeString(storeData["store"]) ?? ""
            definition.label = safeString(storeData["label"]) ?? ""
            definition.smallImageUrl = safeString(storeData["smallImageUrl"]) ?? ""
            definition.sortOrder = safeInt(storeData["sortOrder"])
            for featureData in storeData["features"] as? [NSDictionary] ?? [] {
                let feature = OPNStoreFeatureInfo(type: safeString(featureData["__typename"]) ?? "", displayProposition: safeString(featureData["displayProposition"]) ?? "", supported: safeBool(featureData["supported"]))
                if !feature.type.isEmpty { definition.features.append(feature) }
            }
            if let metadata = storeData["accountLinkingMetadata"] as? NSDictionary {
                definition.accountLinkingMetadata.supportedVariantIds = safeStringArray(metadata["supportedVariantIds"])
                definition.accountLinkingMetadata.isSupported = safeBool(metadata["isSupported"])
                definition.accountLinkingMetadata.isRequired = safeBool(metadata["isRequired"])
                definition.accountLinkingMetadata.label = safeString(metadata["label"]) ?? ""
            }
            if !definition.store.isEmpty { definitions.append(definition) }
        }
        return definitions.sorted { $0.sortOrder == $1.sortOrder ? $0.store < $1.store : $0.sortOrder < $1.sortOrder }
    }

    private func parseSubscriptionInfo(_ json: NSDictionary) -> OPNSubscriptionInfo {
        var info = OPNSubscriptionInfo()
        info.membershipTier = safeString(json["membershipTier"]).flatMap { $0.isEmpty ? nil : $0 } ?? "Free"
        info.subscriptionType = safeString(json["type"]) ?? ""
        info.subscriptionSubType = safeString(json["subType"]) ?? ""
        info.allottedHours = safeMinutesAsHours(json["allottedTimeInMinutes"])
        info.purchasedHours = safeMinutesAsHours(json["purchasedTimeInMinutes"])
        info.rolledOverHours = safeMinutesAsHours(json["rolledOverTimeInMinutes"])
        let fallbackTotal = info.allottedHours + info.purchasedHours + info.rolledOverHours
        info.totalHours = safeMinutesAsHours(json["totalTimeInMinutes"])
        if info.totalHours <= 0 { info.totalHours = fallbackTotal }
        info.remainingHours = safeMinutesAsHours(json["remainingTimeInMinutes"])
        info.usedHours = max(0, info.totalHours - info.remainingHours)
        info.isUnlimited = info.subscriptionSubType == "UNLIMITED"
        if let state = json["currentSubscriptionState"] as? NSDictionary {
            info.isGamePlayAllowed = state["isGamePlayAllowed"] as? Bool ?? true
        }
        return info
    }

    fileprivate func parseGameProviderInfo(_ json: NSDictionary?) -> OPNGameProviderInfo {
        let raw = providerInfoDictionary(json)
        var info = OPNGameProviderInfo()
        guard let raw else { return info }
        info.defaultProvider = safeString(raw["defaultProvider"]) ?? ""
        info.loggedInProvider = safeString(raw["loggedInProvider"]) ?? ""
        info.loginRequired = safeBool(raw["loginRequired"])
        info.loginPreferredProviders = safeStringArray(raw["loginPreferredProviders"])
        let endpoints = raw["gfnServiceEndpoints"] as? [NSDictionary] ?? []
        for entry in endpoints {
            var endpoint = OPNGameProviderEndpoint()
            endpoint.loginProvider = safeString(entry["loginProvider"]) ?? ""
            endpoint.loginProviderCode = safeString(entry["loginProviderCode"]) ?? ""
            endpoint.loginProviderDisplayName = safeString(entry["loginProviderDisplayName"]) ?? ""
            endpoint.streamingServiceUrl = normalizeStreamingBaseUrl(safeString(entry["streamingServiceUrl"]) ?? "")
            endpoint.idpId = safeString(entry["idpId"]) ?? ""
            endpoint.redeemRedirectUrl = safeString(entry["redeemRedirectUrl"]) ?? ""
            endpoint.priority = safeInt(entry["loginProviderPriority"])
            if !endpoint.streamingServiceUrl.isEmpty { info.endpoints.append(endpoint) }
        }
        info.endpoints.sort { $0.priority < $1.priority }
        return info
    }

    private func providerInfoDictionary(_ json: NSDictionary?) -> NSDictionary? {
        guard let json else { return nil }
        if let info = json["gfnServiceInfo"] as? NSDictionary { return info }
        if let data = json["data"] as? NSDictionary {
            if let info = data["gfnServiceInfo"] as? NSDictionary { return info }
            if let serviceUrls = data["serviceUrls"] as? NSDictionary, let info = serviceUrls["gfnServiceInfo"] as? NSDictionary { return info }
        }
        return json
    }

    fileprivate func selectGameProviderEndpoint(_ info: OPNGameProviderInfo, idpId: String) -> OPNGameProviderEndpoint {
        if !idpId.isEmpty, let endpoint = info.endpoints.first(where: { $0.idpId == idpId }) { return endpoint }
        if !info.loggedInProvider.isEmpty, let endpoint = info.endpoints.first(where: { $0.loginProvider == info.loggedInProvider || $0.loginProviderCode == info.loggedInProvider }) { return endpoint }
        if !info.defaultProvider.isEmpty, let endpoint = info.endpoints.first(where: { $0.loginProvider == info.defaultProvider || $0.loginProviderCode == info.defaultProvider }) { return endpoint }
        if let endpoint = info.endpoints.first(where: { !$0.streamingServiceUrl.isEmpty }) { return endpoint }
        var fallback = OPNGameProviderEndpoint()
        fallback.loginProvider = info.defaultProvider
        fallback.streamingServiceUrl = Self.defaultStreamingBaseUrl
        return fallback
    }

    private func ownedVariantMutation(mutationName: String, fieldName: String, variantId: String, completion: @escaping OPNOwnershipActionCallback) {
        guard !variantId.isEmpty else {
            dispatchOwnership(completion, false, "Missing variant ID")
            return
        }
        let mutation = "mutation \(mutationName)($cmsId: String!, $locale: String!) { \(fieldName) (language: $locale, variantId: $cmsId) { app { id } } }"
        let variables: NSDictionary = ["cmsId": variantId, "locale": Self.currentGFNLocale()]
        postGraphQlJson(query: mutation, variables: variables) { [weak self] data, error in
            guard let self else { return }
            if !error.isEmpty {
                self.dispatchOwnership(completion, false, error)
                return
            }
            let app = (data?[fieldName] as? NSDictionary)?["app"] as? NSDictionary
            guard let appId = self.safeString(app?["id"]), !appId.isEmpty else {
                self.dispatchOwnership(completion, false, "Ownership mutation response did not include an app ID")
                return
            }
            self.dispatchOwnership(completion, true, "")
        }
    }

    private func getServerVpcId(token: String, providerStreamingBaseUrl: String, completion: @escaping @Sendable (String) -> Void) {
        let normalized = normalizeStreamingBaseUrl(providerStreamingBaseUrl)
        let cacheKey = "\(normalized)|\(token.hashValue)"
        Self.vpcLock.lock()
        if let entry = Self.vpcCache[cacheKey], Date().timeIntervalSince(entry.timestamp) <= Self.serverVpcCacheFreshSeconds {
            Self.vpcLock.unlock()
            completion(entry.vpcId)
            return
        }
        if Self.pendingVpcCallbacks[cacheKey] != nil {
            Self.pendingVpcCallbacks[cacheKey]?.append(completion)
            Self.vpcLock.unlock()
            return
        }
        Self.pendingVpcCallbacks[cacheKey] = [completion]
        Self.vpcLock.unlock()

        let finish: @Sendable (String) -> Void = { vpcId in
            let resolved = vpcId.isEmpty ? "GFN-PC" : vpcId
            Self.vpcLock.lock()
            Self.vpcCache[cacheKey] = VpcCacheEntry(vpcId: resolved, timestamp: Date())
            let callbacks = Self.pendingVpcCallbacks.removeValue(forKey: cacheKey) ?? []
            Self.vpcLock.unlock()
            for callback in callbacks { callback(resolved) }
        }

        guard let url = URL(string: "\(normalized)v2/serverInfo") else {
            finish("GFN-PC")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization")
        Self.applyClientHeaders(to: &request, includeBrowserHeaders: false)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil, let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
                finish("GFN-PC")
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
            let serverId = (json?["requestStatus"] as? NSDictionary)?["serverId"] as? String
            finish(serverId ?? "GFN-PC")
        }.resume()
    }

    private func applyBaseHeaders(to request: inout URLRequest) {
        request.setValue("https://play.geforcenow.com", forHTTPHeaderField: "Origin")
        request.setValue("https://play.geforcenow.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        Self.applyClientHeaders(to: &request, includeBrowserHeaders: true)
        if !accessToken.isEmpty { request.setValue("GFNJWT \(accessToken)", forHTTPHeaderField: "Authorization") }
    }

    private static func applyClientHeaders(to request: inout URLRequest, includeBrowserHeaders: Bool) {
        request.setValue(nvClientId, forHTTPHeaderField: "nv-client-id")
        request.setValue("NATIVE", forHTTPHeaderField: "nv-client-type")
        request.setValue(nvClientVersion, forHTTPHeaderField: "nv-client-version")
        request.setValue("NVIDIA-CLASSIC", forHTTPHeaderField: "nv-client-streamer")
        request.setValue("MACOS", forHTTPHeaderField: "nv-device-os")
        request.setValue("DESKTOP", forHTTPHeaderField: "nv-device-type")
        if includeBrowserHeaders {
            request.setValue("UNKNOWN", forHTTPHeaderField: "nv-device-make")
            request.setValue("UNKNOWN", forHTTPHeaderField: "nv-device-model")
            request.setValue("CHROME", forHTTPHeaderField: "nv-browser-type")
            request.setValue(gfnUserAgent, forHTTPHeaderField: "User-Agent")
        }
    }

    private static var gfnUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 GFN-PC/2.0.80.173"
    }

    private func normalizeStreamingBaseUrl(_ url: String) -> String {
        if url.isEmpty { return Self.defaultStreamingBaseUrl }
        guard let components = URLComponents(string: url), components.scheme?.lowercased() == "https", components.host?.isEmpty == false else { return "" }
        return url.hasSuffix("/") ? url : "\(url)/"
    }

    private func safeString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return value as? String
    }

    private func safeStringArray(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { safeString($0) }.filter { !$0.isEmpty }
    }

    private func safeInt(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private func safeBool(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["true", "1", "yes"].contains(string.lowercased()) }
        return false
    }

    private func safeMinutesAsHours(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue / 60 }
        if let string = value as? String { return (Double(string) ?? 0) / 60 }
        return 0
    }

    private func firstSafeString(_ dictionary: NSDictionary, keys: [String]) -> String? {
        for key in keys {
            if let value = safeString(dictionary[key]), !value.isEmpty { return value }
        }
        return nil
    }

    private func imageStrings(from rawValue: Any?) -> [String] {
        guard let rawValue, !(rawValue is NSNull) else { return [] }
        if let text = rawValue as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let array = rawValue as? [Any] { return array.flatMap { imageStrings(from: $0) }.uniqueValues() }
        guard let dictionary = rawValue as? NSDictionary else { return [] }
        if let directURL = firstSafeString(dictionary, keys: ["url", "URL", "src", "href", "imageUrl", "imageURL", "thumbnailUrl", "thumbnailURL", "contentUrl", "contentURL"]) {
            return imageStrings(from: directURL)
        }
        return dictionary.allValues.flatMap { imageStrings(from: $0) }.uniqueValues()
    }

    private func firstImageString(_ images: NSDictionary, keys: [String]) -> String? {
        for key in keys {
            if let url = imageStrings(from: images[key]).first, !url.isEmpty { return url }
        }
        return nil
    }

    private func firstLandscapeImageString(_ images: NSDictionary) -> String? {
        firstImageString(images, keys: ["MARQUEE_HERO_IMAGE", "HERO_IMAGE", "TV_BANNER", "FEATURE_IMAGE", "KEY_IMAGE", "KEY_ART"])
    }

    private func firstPosterImageString(_ images: NSDictionary) -> String? {
        firstImageString(images, keys: ["GAME_BOX_ART", "KEY_IMAGE", "KEY_ART"])
    }

    private func appendStringValues(_ values: inout [String], _ rawValue: Any?) {
        if let text = rawValue as? String {
            appendUnique(&values, text)
            return
        }
        for item in rawValue as? [Any] ?? [] {
            if let text = item as? String { appendUnique(&values, text) }
            if let dictionary = item as? NSDictionary { appendUnique(&values, firstSafeString(dictionary, keys: ["name", "label", "value", "rating", "control", "type"]) ?? "") }
        }
    }

    private func appendUnique(_ values: inout [String], _ value: String) {
        if !value.isEmpty, !values.contains(value) { values.append(value) }
    }

    private func deepMergeDictionary(into target: inout [String: Any], source: [String: Any]) {
        for (key, value) in source {
            if var targetDictionary = target[key] as? [String: Any], let sourceDictionary = value as? [String: Any] {
                deepMergeDictionary(into: &targetDictionary, source: sourceDictionary)
                target[key] = targetDictionary
            } else {
                target[key] = value
            }
        }
    }

    private func mergeVariantFromSameStore(target: inout OPNGameVariant, source: OPNGameVariant) -> Bool {
        var changed = false
        if !source.id.isEmpty, target.id.isEmpty || (!target.librarySelected && source.librarySelected) { target.id = source.id; changed = true }
        if target.storeUrl.isEmpty, !source.storeUrl.isEmpty { target.storeUrl = source.storeUrl; changed = true }
        if !source.serviceStatus.isEmpty, target.serviceStatus.isEmpty || (!target.librarySelected && source.librarySelected) { target.serviceStatus = source.serviceStatus; changed = true }
        if !target.librarySelected, source.librarySelected { target.librarySelected = true; changed = true }
        if !target.inLibrary, source.inLibrary { target.inLibrary = true; changed = true }
        return changed
    }

    private func mergeMissingStoreMetadata(target: inout OPNGameInfo, metadata: OPNGameInfo) {
        if target.launchAppId.isEmpty { target.launchAppId = metadata.launchAppId }
        for store in metadata.availableStores where !target.availableStores.contains(where: { $0.caseInsensitiveCompare(store) == .orderedSame }) { target.availableStores.append(store) }
        for metadataVariant in metadata.variants {
            if let index = target.variants.firstIndex(where: { variantMatchesStoreMetadata(target: $0, metadata: metadataVariant) }) {
                if target.variants[index].id.isEmpty { target.variants[index].id = metadataVariant.id }
                if target.variants[index].appStore.isEmpty { target.variants[index].appStore = metadataVariant.appStore }
                if target.variants[index].storeUrl.isEmpty { target.variants[index].storeUrl = metadataVariant.storeUrl }
                if target.variants[index].serviceStatus.isEmpty { target.variants[index].serviceStatus = metadataVariant.serviceStatus }
                if !target.variants[index].librarySelected { target.variants[index].librarySelected = metadataVariant.librarySelected }
                if !target.variants[index].inLibrary { target.variants[index].inLibrary = metadataVariant.inLibrary }
            } else if !metadataVariant.appStore.isEmpty {
                target.variants.append(metadataVariant)
                if !target.availableStores.contains(where: { $0.caseInsensitiveCompare(metadataVariant.appStore) == .orderedSame }) { target.availableStores.append(metadataVariant.appStore) }
            }
        }
    }

    private func variantMatchesStoreMetadata(target: OPNGameVariant, metadata: OPNGameVariant) -> Bool {
        if !target.id.isEmpty, !metadata.id.isEmpty, target.id == metadata.id { return true }
        if !target.appStore.isEmpty, !metadata.appStore.isEmpty, target.appStore.caseInsensitiveCompare(metadata.appStore) == .orderedSame { return true }
        return false
    }

    private func storeURLForKnownGame(_ game: OPNGameInfo, variantIndex: Int) -> String? {
        if game.variants.indices.contains(variantIndex), !game.variants[variantIndex].storeUrl.isEmpty { return game.variants[variantIndex].storeUrl }
        return game.variants.first { !$0.storeUrl.isEmpty }?.storeUrl
    }

    private func storeURLForMetadataGame(_ metadataGame: OPNGameInfo, variantId: String, store: String) -> String {
        if !variantId.isEmpty, let url = metadataGame.variants.first(where: { $0.id == variantId && !$0.storeUrl.isEmpty })?.storeUrl { return url }
        if !store.isEmpty, let url = metadataGame.variants.first(where: { $0.appStore.caseInsensitiveCompare(store) == .orderedSame && !$0.storeUrl.isEmpty })?.storeUrl { return url }
        return metadataGame.variants.first { !$0.storeUrl.isEmpty }?.storeUrl ?? ""
    }

    private func deduplicateGames(_ games: [OPNGameInfo]) -> [OPNGameInfo] {
        var byId: [String: OPNGameInfo] = [:]
        for game in games {
            guard !game.id.isEmpty else { continue }
            if var existing = byId[game.id] {
                let existingVariantIds = Set(existing.variants.map(\.id))
                existing.variants.append(contentsOf: game.variants.filter { !existingVariantIds.contains($0.id) })
                if existing.title.isEmpty { existing.title = game.title }
                if existing.imageUrl.isEmpty { existing.imageUrl = game.imageUrl }
                if existing.heroImageUrl.isEmpty { existing.heroImageUrl = game.heroImageUrl }
                if !game.screenshotUrls.isEmpty { existing.screenshotUrls = game.screenshotUrls }
                for (key, value) in game.imageUrlsByType where existing.imageUrlsByType[key] == nil { existing.imageUrlsByType[key] = value }
                if existing.description.isEmpty { existing.description = game.description }
                byId[game.id] = existing
            } else {
                byId[game.id] = game
            }
        }
        return Array(byId.values).filter { !$0.variants.isEmpty }
    }

    private func fetchPublicGamesLocale(locales: [String], index: Int, completion: @escaping OPNCatalogCallback) {
        if index >= locales.count {
            dispatchCatalog(completion, false, [], "No public game locale fallback succeeded")
            return
        }
        guard let url = URL(string: "https://static.nvidiagrid.net/supported-public-game-list/locales/gfnpc-\(locales[index]).json") else {
            fetchPublicGamesLocale(locales: locales, index: index + 1, completion: completion)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            Self.workQueue.async {
                let json = error == nil ? data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [NSDictionary] : nil
                guard let json else {
                    self.fetchPublicGamesLocale(locales: locales, index: index + 1, completion: completion)
                    return
                }
                let games = json.compactMap { item -> OPNGameInfo? in
                    guard self.safeString(item["status"]) == "AVAILABLE", let title = self.safeString(item["title"]), !title.isEmpty else { return nil }
                    var game = OPNGameInfo()
                    game.title = title
                    game.description = self.firstSafeString(item, keys: ["description", "longDescription", "shortDescription", "summary"]) ?? ""
                    let rawId = item["id"]
                    let sid = (rawId as? NSNumber)?.stringValue ?? (rawId as? String) ?? title
                    let steamURL = self.safeString(item["steamUrl"])
                    let steamAppId = steamURL?.components(separatedBy: "/app/").dropFirst().first?.components(separatedBy: "/").first
                    let finalAppId = steamAppId?.isEmpty == false ? steamAppId ?? sid : sid
                    game.id = finalAppId
                    game.uuid = sid
                    if let steamAppId, !steamAppId.isEmpty {
                        game.heroImageUrl = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(steamAppId)/library_hero.jpg"
                        game.imageUrl = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(steamAppId)/header.jpg"
                    }
                    return game
                }
                self.dispatchCatalog(completion, true, games, "")
            }
        }.resume()
    }

    private func percentEncodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?#%+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func accountLinkingResponseSnippet(_ data: Data?) -> String {
        guard let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return "" }
        let normalized = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return normalized.count > 512 ? String(normalized.prefix(512)) : normalized
    }

    private static func currentGFNLocale() -> String {
        OPNLocale.currentGFNLocale()
    }

    private static func currentGFNLocaleURLPathComponentFallbacks() -> [String] {
        OPNLocale.currentGFNLocaleURLPathComponentFallbacks()
    }

    private func dispatchGraphQL(_ completion: @escaping @Sendable (NSDictionary?, String) -> Void, _ payload: NSDictionary?, _ message: String) {
        let payloadBox = payload.map(NSDictionaryBox.init)
        Self.workQueue.async { [payloadBox] in completion(payloadBox?.value, message) }
    }

    private func dispatchPanel(_ completion: @escaping OPNPanelCallback, _ success: Bool, _ panels: [OPNPanelResult], _ error: String) {
        DispatchQueue.main.async { completion(success, panels, error) }
    }

    private func dispatchCatalog(_ completion: @escaping OPNCatalogCallback, _ success: Bool, _ games: [OPNGameInfo], _ error: String) {
        DispatchQueue.main.async { completion(success, games, error) }
    }

    private func dispatchCatalogBrowse(_ completion: @escaping OPNCatalogBrowseCallback, _ success: Bool, _ result: OPNCatalogBrowseResult, _ error: String) {
        DispatchQueue.main.async { completion(success, result, error) }
    }

    private func dispatchSubscription(_ completion: @escaping OPNSubscriptionCallback, _ success: Bool, _ subscription: OPNSubscriptionInfo, _ error: String) {
        DispatchQueue.main.async { completion(success, subscription, error) }
    }

    private func dispatchStoreURL(_ completion: @escaping OPNStoreURLCallback, _ success: Bool, _ storeURL: String, _ error: String) {
        DispatchQueue.main.async { completion(success, storeURL, error) }
    }

    private func dispatchProviderInfo(_ completion: @escaping OPNProviderInfoCallback, _ success: Bool, _ providerInfo: OPNGameProviderInfo, _ selectedEndpoint: OPNGameProviderEndpoint, _ error: String) {
        DispatchQueue.main.async { completion(success, providerInfo, selectedEndpoint, error) }
    }

    fileprivate func dispatchOwnership(_ completion: @escaping OPNOwnershipActionCallback, _ success: Bool, _ error: String) {
        DispatchQueue.main.async { completion(success, error) }
    }

    private func dispatchUserAccount(_ completion: @escaping OPNUserAccountCallback, _ success: Bool, _ accountInfo: OPNUserAccountInfo, _ error: String) {
        DispatchQueue.main.async { completion(success, accountInfo, error) }
    }

    private func dispatchStoreDefinitions(_ completion: @escaping OPNStoreDefinitionsCallback, _ success: Bool, _ definitions: [OPNStoreDefinition], _ error: String) {
        DispatchQueue.main.async { completion(success, definitions, error) }
    }
}

@objc(OPNGameServiceSwiftAdapter)
final class OPNGameServiceSwiftAdapter: NSObject {
    @objc(setAccessToken:)
    static func setAccessToken(_ token: String) {
        OPNGameService.shared.setAccessToken(token)
    }

    @objc(setAccountLinkingToken:)
    static func setAccountLinkingToken(_ token: String) {
        OPNGameService.shared.setAccountLinkingToken(token)
    }

    @objc(setVpcId:)
    static func setVpcId(_ id: String) {
        OPNGameService.shared.setVpcId(id)
    }

    @objc(setUserId:)
    static func setUserId(_ id: String) {
        OPNGameService.shared.setUserId(id)
    }

    @objc(setStreamingBaseUrl:)
    static func setStreamingBaseUrl(_ url: String) {
        OPNGameService.shared.setStreamingBaseUrl(url)
    }

    @objc(providerStreamingBaseURL)
    static func providerStreamingBaseURL() -> String {
        OPNGameService.shared.providerStreamingBaseURL()
    }

    @objc(prewarmLaunchData)
    static func prewarmLaunchData() {
        OPNGameService.shared.prewarmLaunchData()
    }

    @objc(fetchProviderInfoWithIdpId:completion:)
    static func fetchProviderInfo(idpId: String, completion: @escaping @Sendable (Bool, OPNParsedGameProviderInfo, OPNParsedGameProviderEndpoint, String) -> Void) {
        OPNGameService.shared.fetchProviderInfo(idpId: idpId) { success, info, endpoint, error in
            completion(success, OPNParsedGameProviderInfo(info: info), OPNParsedGameProviderEndpoint(endpoint: endpoint), error)
        }
    }

    @objc(fetchSubscriptionInfoWithUserId:completion:)
    static func fetchSubscriptionInfo(userId: String, completion: @escaping @Sendable (Bool, OPNParsedSubscriptionInfo, String) -> Void) {
        OPNGameService.shared.fetchSubscriptionInfo(userId: userId) { success, subscription, error in
            completion(success, OPNParsedSubscriptionInfo(subscription: subscription), error)
        }
    }

    @objc(fetchMainPanelObjectsWithCompletion:)
    static func fetchMainPanelObjects(completion: @escaping @Sendable (Bool, [OPNCatalogPanelObject], String) -> Void) {
        OPNGameService.shared.fetchMainPanels { success, panels, error in
            completion(success, panels.map(OPNCatalogPanelObject.init), error)
        }
    }

    @objc(fetchMarqueePanelObjectsWithCompletion:)
    static func fetchMarqueePanelObjects(completion: @escaping @Sendable (Bool, [OPNCatalogPanelObject], String) -> Void) {
        OPNGameService.shared.fetchMarqueePanels { success, panels, error in
            completion(success, panels.map(OPNCatalogPanelObject.init), error)
        }
    }

    @objc(browseCatalogObjectWithSearchQuery:sortId:filterIds:fetchCount:completion:)
    static func browseCatalogObject(searchQuery: String, sortId: String, filterIds: [String], fetchCount: Int, completion: @escaping @Sendable (Bool, OPNCatalogBrowseResultObject, String) -> Void) {
        OPNGameService.shared.browseCatalogGames(searchQuery: searchQuery, sortId: sortId, filterIds: filterIds, fetchCount: fetchCount) { success, result, error in
            completion(success, OPNCatalogBrowseResultObject(result: result), error)
        }
    }

    @objc(fetchLibraryGameObjectsWithCompletion:)
    static func fetchLibraryGameObjects(completion: @escaping @Sendable (Bool, [OPNCatalogGameObject], String) -> Void) {
        OPNGameService.shared.fetchLibraryGames { success, games, error in
            completion(success, games.map(OPNCatalogGameObject.init), error)
        }
    }

    @objc(fetchUserAccountDictionaryWithCompletion:)
    static func fetchUserAccountDictionary(completion: @escaping @Sendable (Bool, NSDictionary, String) -> Void) {
        OPNGameService.shared.fetchUserAccount { success, account, error in
            completion(success, userAccountDictionary(account), error)
        }
    }

    @objc(fetchStoreDefinitionDictionariesWithCompletion:)
    static func fetchStoreDefinitionDictionaries(completion: @escaping @Sendable (Bool, [NSDictionary], String) -> Void) {
        OPNGameService.shared.fetchStoreDefinitions { success, definitions, error in
            completion(success, definitions.map(storeDefinitionDictionary), error)
        }
    }

    @objc(addOwnedVariant:completion:)
    static func addOwnedVariant(_ variantId: String, completion: @escaping @Sendable (Bool, String) -> Void) {
        OPNGameService.shared.addOwnedVariant(variantId, completion: completion)
    }

    @objc(removeOwnedVariant:completion:)
    static func removeOwnedVariant(_ variantId: String, completion: @escaping @Sendable (Bool, String) -> Void) {
        OPNGameService.shared.removeOwnedVariant(variantId, completion: completion)
    }

    @objc(selectOwnedVariant:completion:)
    static func selectOwnedVariant(_ variantId: String, completion: @escaping @Sendable (Bool, String) -> Void) {
        OPNGameService.shared.selectOwnedVariant(variantId, completion: completion)
    }

    @objc(syncAccountProviderWithStore:completion:)
    static func syncAccountProvider(store: String, completion: @escaping @Sendable (Bool, String) -> Void) {
        OPNGameService.shared.syncAccountProvider(store: store, completion: completion)
    }

    @objc(startAccountLinkingWithStore:completion:)
    static func startAccountLinking(store: String, completion: @escaping @Sendable (Bool, String) -> Void) {
        OPNGameService.shared.startAccountLinking(store: store, completion: completion)
    }

    @objc(resolveStoreURLWithGameObject:variantIndex:completion:)
    static func resolveStoreURL(game: OPNCatalogGameObject, variantIndex: Int, completion: @escaping @Sendable (Bool, String, String) -> Void) {
        OPNGameService.shared.resolveStoreURL(game: game.swiftValue, variantIndex: variantIndex, completion: completion)
    }

    @objc(optimizeImageURL:width:)
    static func optimizeImageURL(_ url: String, width: Int) -> String {
        OPNGameService.optimizeImageURL(url, width: width)
    }

    @objc(parseProviderInfoFromJSON:)
    static func parseProviderInfo(from json: NSDictionary?) -> OPNParsedGameProviderInfo {
        OPNParsedGameProviderInfo(info: OPNGameService.shared.parseGameProviderInfo(json))
    }

    @objc(selectProviderEndpointFromInfo:idpId:)
    static func selectProviderEndpoint(from info: OPNParsedGameProviderInfo, idpId: String) -> OPNParsedGameProviderEndpoint {
        let swiftInfo = info.swiftValue
        return OPNParsedGameProviderEndpoint(endpoint: OPNGameService.shared.selectGameProviderEndpoint(swiftInfo, idpId: idpId))
    }

    private static func userAccountDictionary(_ account: OPNUserAccountInfo) -> NSDictionary {
        [
            "subscriptions": account.subscriptions,
            "stores": account.stores.map(storeAccountDictionary),
        ] as NSDictionary
    }

    private static func storeAccountDictionary(_ account: OPNStoreAccountInfo) -> NSDictionary {
        [
            "store": account.store,
            "userDisplayName": account.userDisplayName,
            "expiresIn": account.expiresIn,
            "userIdentifier": account.userIdentifier,
            "hasAccountLinkingData": account.hasAccountLinkingData,
            "hasAccountSyncingData": account.hasAccountSyncingData,
            "syncing": [
                "totalNumberOfSyncedGfnGames": account.syncing.totalNumberOfSyncedGfnGames,
                "syncState": account.syncing.syncState,
                "syncDate": account.syncing.syncDate,
            ],
        ] as NSDictionary
    }

    private static func storeDefinitionDictionary(_ definition: OPNStoreDefinition) -> NSDictionary {
        [
            "store": definition.store,
            "label": definition.label,
            "smallImageUrl": definition.smallImageUrl,
            "sortOrder": definition.sortOrder,
            "features": definition.features.map { ["type": $0.type, "displayProposition": $0.displayProposition, "supported": $0.supported] as NSDictionary },
            "accountLinkingMetadata": [
                "supportedVariantIds": definition.accountLinkingMetadata.supportedVariantIds,
                "isSupported": definition.accountLinkingMetadata.isSupported,
                "isRequired": definition.accountLinkingMetadata.isRequired,
                "label": definition.accountLinkingMetadata.label,
            ] as NSDictionary,
        ] as NSDictionary
    }

}

@objcMembers
final class OPNParsedSubscriptionInfo: NSObject {
    let membershipTier: String
    let subscriptionType: String
    let subscriptionSubType: String
    let isUnlimited: Bool
    let totalHours: Double
    let usedHours: Double
    let remainingHours: Double

    init(subscription: OPNSubscriptionInfo) {
        membershipTier = subscription.membershipTier
        subscriptionType = subscription.subscriptionType
        subscriptionSubType = subscription.subscriptionSubType
        isUnlimited = subscription.isUnlimited
        totalHours = subscription.totalHours
        usedHours = subscription.usedHours
        remainingHours = subscription.remainingHours
    }
}

@objcMembers
final class OPNParsedGameProviderEndpoint: NSObject {
    let loginProvider: String
    let loginProviderCode: String
    let loginProviderDisplayName: String
    let streamingServiceUrl: String
    let idpId: String
    let redeemRedirectUrl: String
    let priority: Int

    init(endpoint: OPNGameProviderEndpoint) {
        loginProvider = endpoint.loginProvider
        loginProviderCode = endpoint.loginProviderCode
        loginProviderDisplayName = endpoint.loginProviderDisplayName
        streamingServiceUrl = endpoint.streamingServiceUrl
        idpId = endpoint.idpId
        redeemRedirectUrl = endpoint.redeemRedirectUrl
        priority = endpoint.priority
    }

    var swiftValue: OPNGameProviderEndpoint {
        var endpoint = OPNGameProviderEndpoint()
        endpoint.loginProvider = loginProvider
        endpoint.loginProviderCode = loginProviderCode
        endpoint.loginProviderDisplayName = loginProviderDisplayName
        endpoint.streamingServiceUrl = streamingServiceUrl
        endpoint.idpId = idpId
        endpoint.redeemRedirectUrl = redeemRedirectUrl
        endpoint.priority = priority
        return endpoint
    }
}

@objcMembers
final class OPNParsedGameProviderInfo: NSObject {
    let defaultProvider: String
    let loggedInProvider: String
    let loginRequired: Bool
    let loginPreferredProviders: [String]
    let endpoints: [OPNParsedGameProviderEndpoint]

    init(info: OPNGameProviderInfo) {
        defaultProvider = info.defaultProvider
        loggedInProvider = info.loggedInProvider
        loginRequired = info.loginRequired
        loginPreferredProviders = info.loginPreferredProviders
        endpoints = info.endpoints.map(OPNParsedGameProviderEndpoint.init(endpoint:))
    }

    var swiftValue: OPNGameProviderInfo {
        var info = OPNGameProviderInfo()
        info.defaultProvider = defaultProvider
        info.loggedInProvider = loggedInProvider
        info.loginRequired = loginRequired
        info.loginPreferredProviders = loginPreferredProviders
        info.endpoints = endpoints.map(\.swiftValue)
        return info
    }
}

private struct CatalogDefinitionParameters: Sendable {
    let requestedSortId: String
    let filterIds: [String]
    let requestedFetchCount: Int
    let searchQuery: String
    let resolvedVpcId: String
    let locale: String
    let catalogCacheKey: String
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func setTrue() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

private final class CatalogPageState: @unchecked Sendable {
    var collectedApps: [NSDictionary] = []
    var result: OPNCatalogBrowseResult

    init(result: OPNCatalogBrowseResult) {
        self.result = result
    }
}

private final class RecursiveCatalogPageFetcher: @unchecked Sendable {
    var action: (@Sendable (_ page: Int, _ cursor: String) -> Void)?
}

private final class MetadataState: @unchecked Sendable {
    var metadataById: [String: NSDictionary] = [:]
}

private final class NSDictionaryBox: @unchecked Sendable {
    let value: NSDictionary

    init(_ value: NSDictionary) {
        self.value = value
    }
}

private final class NSDictionaryArrayBox: @unchecked Sendable {
    let values: [NSDictionary]

    init(_ values: [NSDictionary]) {
        self.values = values
    }
}

private final class AccountLinkingCallbackListener: @unchecked Sendable {
    let port: Int32
    private let socketDescriptor: Int32
    private let service = OPNGameService.shared

    init?() {
        let candidatePorts: [Int32] = [2259, 6460, 7119, 8870, 9096]
        for candidate in candidatePorts {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            if descriptor < 0 { continue }
            var reuse: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
            address.sin_port = in_port_t(candidate).bigEndian
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindResult == 0, listen(descriptor, 1) == 0 {
                socketDescriptor = descriptor
                port = candidate
                return
            }
            Darwin.close(descriptor)
        }
        return nil
    }

    func close() {
        Darwin.close(socketDescriptor)
    }

    func wait(timeout: TimeInterval, completion: @escaping OPNOwnershipActionCallback) {
        let descriptor = socketDescriptor
        DispatchQueue.global(qos: .default).async { [self, service] in
            var readSet = fd_set()
            self.fdZero(&readSet)
            self.fdSet(descriptor, set: &readSet)
            var time = timeval(tv_sec: Int(timeout), tv_usec: 0)
            let ready = select(descriptor + 1, &readSet, nil, nil, &time)
            if ready <= 0 {
                Darwin.close(descriptor)
                service.dispatchOwnership(completion, false, ready == 0 ? "Timed out waiting for account linking callback" : "Account linking callback listener failed")
                return
            }
            let client = accept(descriptor, nil, nil)
            Darwin.close(descriptor)
            if client < 0 {
                service.dispatchOwnership(completion, false, "Failed to accept account linking callback")
                return
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = recv(client, &buffer, buffer.count - 1, 0)
            let request = bytesRead > 0 ? String(bytes: buffer.prefix(bytesRead), encoding: .utf8) ?? "" : ""
            let hasError = request.contains("error=") || request.contains("error_description=")
            self.sendCallbackPage(client: client, success: !hasError)
            Darwin.close(client)
            if bytesRead <= 0 {
                service.dispatchOwnership(completion, false, "Empty account linking callback request")
            } else if hasError {
                service.dispatchOwnership(completion, false, "Account linking was not completed")
            } else {
                service.dispatchOwnership(completion, true, "")
            }
        }
    }

    private func sendCallbackPage(client: Int32, success: Bool) {
        let successBody = "<!doctype html><html><head><meta charset=\"utf-8\"><title>OpenNOW Account Linking</title></head><body style=\"background:#050807;color:#f1fff7;font:16px -apple-system,BlinkMacSystemFont,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0\"><main><h1>Account link complete</h1><p>You can close this window and return to OpenNOW.</p></main><script>setTimeout(function(){window.close()},1200)</script></body></html>"
        let errorBody = "<!doctype html><html><head><meta charset=\"utf-8\"><title>OpenNOW Account Linking</title></head><body style=\"background:#140606;color:#fff0f0;font:16px -apple-system,BlinkMacSystemFont,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0\"><main><h1>Account link failed</h1><p>Return to OpenNOW to try again.</p></main></body></html>"
        let body = success ? successBody : errorBody
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        _ = response.withCString { send(client, $0, strlen($0), 0) }
    }

    private func fdZero(_ set: inout fd_set) {
        memset(&set, 0, MemoryLayout<fd_set>.size)
    }

    private func fdSet(_ descriptor: Int32, set: inout fd_set) {
        let intOffset = Int(descriptor) / 32
        let bitOffset = Int(descriptor) % 32
        withUnsafeMutablePointer(to: &set) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: MemoryLayout<fd_set>.size / MemoryLayout<Int32>.size) { values in
                values[intOffset] |= 1 << Int32(bitOffset)
            }
        }
    }
}

private extension Array where Element: Hashable {
    func uniqueValues() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension OPNGameService {
    static var catalogQuery: String {
        """
        query GetFilterBrowseResults($vpcId: String!, $locale: String!, $sortString: String!, $fetchCount: Int!, $cursor: String!, $filters: AppFilterFields!) {
            apps(vpcId: $vpcId, language: $locale, orderBy: $sortString, first: $fetchCount, after: $cursor, filters: $filters) {
                numberReturned numberSupported pageInfo { hasNextPage endCursor totalCount }
                items { id title images { KEY_ART KEY_IMAGE GAME_BOX_ART TV_BANNER HERO_IMAGE MARQUEE_HERO_IMAGE FEATURE_IMAGE GAME_LOGO SCREENSHOTS } variants { id appStore storeUrl supportedControls gfn { status library { status selected } } } gfn { playabilityState minimumMembershipTierLabel catalogSkuStrings { SKU_BASED_TAG } } itemMetadata { campaignIds } }
            }
        }
        """
    }

    static var catalogSearchQuery: String {
        """
        query GetSearchFilterResults($vpcId: String!, $locale: String!, $sortString: String!, $fetchCount: Int!, $cursor: String!, $searchString: String!, $filters: AppFilterFields!) {
            apps(vpcId: $vpcId, language: $locale, orderBy: $sortString, first: $fetchCount, after: $cursor, searchQuery: $searchString, filters: $filters) {
                numberReturned numberSupported pageInfo { hasNextPage endCursor totalCount }
                items { id title images { KEY_ART KEY_IMAGE GAME_BOX_ART TV_BANNER HERO_IMAGE MARQUEE_HERO_IMAGE FEATURE_IMAGE GAME_LOGO SCREENSHOTS } variants { id appStore storeUrl supportedControls gfn { status library { status selected } } } gfn { playabilityState minimumMembershipTierLabel catalogSkuStrings { SKU_BASED_TAG } } itemMetadata { campaignIds } }
            }
        }
        """
    }
}
