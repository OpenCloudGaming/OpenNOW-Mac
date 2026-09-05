@preconcurrency import Foundation


final class OPNSessionManager: NSObject, @unchecked Sendable {
    static let shared = OPNSessionManager()

    // Reachable from the manager's extensions in the neighbouring files; nothing outside the
    // manager touches them.
    let lock = NSLock()
    var accessToken = ""
    var streamingBaseUrl = defaultBaseUrl
    var adStatesBySessionId: [String: [String: Any]] = [:]

    static let defaultBaseUrl = CloudMatch.productionBaseURLString
    static let persistedActiveSessionIdKey = "OpenNOW.Stream.ActiveSessionId"

    func setAccessToken(_ token: String) {
        lock.withLock { accessToken = token }
    }

    func setStreamingBaseUrl(_ url: String) {
        lock.withLock { streamingBaseUrl = CloudMatchRequestFactory.resolvedSessionBaseURL(streamingBaseURL: url, serverIP: "") }
    }

    func createSession(appId: String, internalTitle: String, settings: [String: Any]) async -> (Bool, [String: Any], String) {
        guard let launchAppId = OPNLaunchAppId.resolve(appId) else {
            OPNSentry.logWarningMessage(OPNSentry.formattedLogMessage(level: "warning", area: "SessionManager", message: "Refusing session creation with invalid appId=\(escapedLogString(appId.trimmingCharacters(in: .whitespacesAndNewlines)))"))
            return (false, [:], "This game does not include a launchable GeForce NOW app id.")
        }
        let token = currentAccessToken()
        guard !token.isEmpty else {
            return (false, [:], "No access token")
        }

        clearPersistedActiveSessionId("")
        let baseUrl = currentStreamingBaseUrl()
        let clientId = UUID().uuidString.lowercased()
        let deviceId = OPNDeviceIdentity.stableCloudmatchDeviceId()
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        let effectiveSettings = settingsByApplyingCloudVariables(settings, capabilities: capabilities)
        let hdrEnabled = bool(effectiveSettings["enableHdr"]) && capabilities.hdrDisplaySupported
        let transportMode = streamTransportMode(effectiveSettings)
        let selectedStore = string(effectiveSettings["selectedStore"]).isEmpty ? "unknown" : string(effectiveSettings["selectedStore"])

        OPNSentry.logInfoMessage(OPNSentry.formattedLogMessage(level: "info", area: "SessionManager", message: "Creating cloud session appId=\(launchAppId.stringValue) base=\(baseUrl) transport=\(transportMode) resolution=\(string(effectiveSettings["resolution"])) fps=\(int(effectiveSettings["fps"], fallback: 60)) codec=\(string(effectiveSettings["codec"])) color=\(string(effectiveSettings["colorQuality"])) bitrate=\(int(effectiveSettings["maxBitrateMbps"], fallback: 50))Mbps l4s=\(bool(effectiveSettings["enableL4S"]) ? "on" : "off") profile=\(int(effectiveSettings["streamingQualityProfile"])) networkTestSessionId=\(escapedLogString(string(effectiveSettings["networkTestSessionId"])))"))

        let body: [String: Any] = [
            "sessionRequestData": sessionRequestData(launchAppId: launchAppId,
                                                     internalTitle: internalTitle,
                                                     settings: effectiveSettings,
                                                     capabilities: capabilities,
                                                     transportMode: transportMode,
                                                     hdrEnabled: hdrEnabled,
                                                     deviceId: deviceId,
                                                     selectedStore: selectedStore)
        ]
        let layout = string(effectiveSettings["keyboardLayout"]).isEmpty ? "us" : string(effectiveSettings["keyboardLayout"])
        let language = string(effectiveSettings["gameLanguage"]).isEmpty ? OPNLocale.currentGFNLocale() : string(effectiveSettings["gameLanguage"])
        OPNProtocolDebug.logJSONObject(label: "session create request", object: body)
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return (false, [:], "Failed to encode session create request")
        }
        let headers = CloudMatchClientHeaders.streamSession(transportMode: transportMode)
        guard var request = CloudMatchRequestFactory.createSessionRequest(baseURLString: baseUrl, accessToken: token, deviceId: deviceId, keyboardLayout: layout, languageCode: language, body: bodyData, headers: headers) else {
            return (false, [:], "Invalid session create URL")
        }
        request.setValue("https://play.geforcenow.com", forHTTPHeaderField: "Origin")

        let (data, http, transportError) = await exchange(&request, operation: "cloudmatch.createSession")
        if let transportError { return (false, [:], transportError) }
        OPNProtocolDebug.logJSONData(label: "session create response", data: data)
        guard http?.statusCode == 200 else {
            return createSessionFailure(data: data, statusCode: http?.statusCode ?? 0, baseUrl: baseUrl, requestedAppId: launchAppId.intValue)
        }
        guard let json = CloudMatchResponseParser.jsonDictionary(data), CloudMatchResponseParser.requestSucceeded(json) else {
            return (false, [:], CloudMatchResponseParser.requestStatusError(data: data, fallback: "Failed to parse session response"))
        }
        guard let session = json["session"] as? [String: Any] else {
            return (false, [:], "No session in response")
        }
        var info = sessionInfo(from: session, requestedSessionId: "", baseUrl: baseUrl, clientId: clientId, deviceId: deviceId, initialProfile: [:])
        mergeAndStoreAdState(&info)
        return (true, info, "")
    }

    /// One logged CloudMatch round trip. `errorMessage` is non-nil only when the transport itself
    /// failed, in which case the body is empty.
    func exchange(_ request: inout URLRequest, operation: String) async -> (data: Data, response: HTTPURLResponse?, errorMessage: String?) {
        let networkStart = OPNNetworkLog.start(&request, operation: operation)
        let traced = request
        do {
            let (data, response) = try await OPNSessionProxySessionProvider.shared.data(for: traced, purpose: .session)
            OPNNetworkLog.finish(traced, operation: operation, startedAt: networkStart, data: data, response: response, error: nil)
            return (data, response as? HTTPURLResponse, nil)
        } catch {
            OPNNetworkLog.finish(traced, operation: operation, startedAt: networkStart, data: nil, response: nil, error: error)
            return (Data(), nil, error.localizedDescription)
        }
    }

    /// The `sessionRequestData` payload CloudMatch expects, including the metadata list the seat
    /// keys its own telemetry off.
    func sessionRequestData(launchAppId: OPNResolvedLaunchAppId,
                                    internalTitle: Any,
                                    settings effectiveSettings: [String: Any],
                                    capabilities: OPNStreamDeviceCapabilities,
                                    transportMode: String,
                                    hdrEnabled: Bool,
                                    deviceId: String,
                                    selectedStore: String) -> [String: Any] {
        let timezoneOffset = -TimeZone.current.secondsFromGMT() * 1000
        var metadata = [
            ["key": "SubSessionId", "value": UUID().uuidString.lowercased()],
            ["key": "wssignaling", "value": "1"],
            ["key": "networkType", "value": networkTypeValue(effectiveSettings)],
            ["key": "networkLatencyMs", "value": networkLatencyValue(effectiveSettings)],
            ["key": "ClientImeSupport", "value": "0"],
            ["key": "clientPhysicalResolution", "value": clientPhysicalResolutionMetadata(settings: effectiveSettings, capabilities: capabilities)],
            ["key": "surroundAudioInfo", "value": String(int(effectiveSettings["surroundAudioMetadata"], fallback: 2))],
            ["key": "store", "value": selectedStore],
        ]
        if transportMode == "webrtc" {
            metadata.append(["key": "GSStreamerType", "value": "WebRTC"])
        }

        var sessionRequestData: [String: Any] = [
            "appId": launchAppId.intValue,
            "internalTitle": internalTitle,
            "availableSupportedControllers": stringArray(effectiveSettings["availableSupportedControllers"]),
            "networkTestSessionId": networkTestSessionIdValue(effectiveSettings),
            "parentSessionId": NSNull(),
            "clientIdentification": "GFN-PC",
            "deviceHashId": deviceId,
            "clientVersion": GFNClientMetadata.webRTCClientVersion,
            "sdkVersion": "1.0",
            "streamerVersion": 1,
            "clientPlatformName": sessionClientPlatformName(transportMode),
            "clientRequestMonitorSettings": [monitorSettings(effectiveSettings, capabilities: capabilities, hdrEnabled: hdrEnabled)],
            "useOps": bool(effectiveSettings["useOps"], fallback: true),
            "audioMode": int(effectiveSettings["audioMode"], fallback: 2),
            "metaData": metadata,
            "sdrHdrMode": hdrEnabled ? 1 : 0,
            "clientDisplayHdrCapabilities": NSNull(),
            "surroundAudioInfo": int(effectiveSettings["surroundAudioInfo"], fallback: 0),
            "remoteControllersBitmap": int(effectiveSettings["remoteControllersBitmap"]),
            "clientTimezoneOffset": timezoneOffset,
            "enhancedStreamMode": int(effectiveSettings["enhancedStreamMode"], fallback: 1),
            "appLaunchMode": int(effectiveSettings["appLaunchMode"], fallback: 1),
            "secureRTSPSupported": transportMode == "nvst",
            "partnerCustomData": string(effectiveSettings["partnerCustomData"]),
            "accountLinked": bool(effectiveSettings["accountLinked"], fallback: true),
            "enablePersistingInGameSettings": bool(effectiveSettings["enablePersistingInGameSettings"]),
            "userAge": int(effectiveSettings["userAge"]),
            "requestedStreamingFeatures": requestedStreamingFeatures(effectiveSettings, hdrEnabled: hdrEnabled),
        ]
        if let transport = sessionTransportPolicy(effectiveSettings) {
            sessionRequestData["transport"] = transport
        }
        return sessionRequestData
    }

    /// Classifies a non-200 create response. A stale claim, a limited-mode account and a session
    /// limit each carry their own recovery, and only the last one hands back a conflict payload.
    func createSessionFailure(data: Data, statusCode: Int, baseUrl: String, requestedAppId: Int) -> (Bool, [String: Any], String) {
        let body = String(data: data, encoding: .utf8) ?? ""
        let errorMessage = "HTTP \(statusCode): \(body)"
        if let staleMessage = CloudMatchResponseParser.staleActiveSessionClaimMessage(data) {
            clearPersistedActiveSessionId("")
            return (false, [:], staleMessage)
        }
        if let limitedModeMessage = CloudMatchResponseParser.limitedModeStreamingMessage(data) {
            return (false, [:], limitedModeMessage)
        }
        guard let json = CloudMatchResponseParser.jsonDictionary(data),
              CloudMatchResponseParser.isSessionLimitExceededResponse(json),
              let selected = selectSessionLimitReuseEntry(activeSessionEntries(from: array(json["otherUserSessions"]), streamingBaseUrl: baseUrl), requestedAppId: requestedAppId) else {
            return (false, [:], errorMessage)
        }
        var conflict = selected
        let isResumable = isResumableActiveSessionStatus(int(selected["status"]))
        conflict["isSessionLimitConflict"] = true
        conflict["isResumable"] = isResumable
        let message = isResumable
            ? "A GeForce NOW session is already active. Resume it or end it before launching another game."
            : "A GeForce NOW session is already active. End it before launching another game."
        return (false, conflict, message)
    }

    func pollSession(sessionId: String, serverIp: String) async -> (Bool, [String: Any], String) {
        let token = currentAccessToken()
        guard !token.isEmpty else {
            return (false, [:], "No access token")
        }
        guard isValidSessionId(sessionId) else {
            return (false, [:], "Invalid session id for poll: \(escapedLogString(sessionId))")
        }
        let base = CloudMatchRequestFactory.resolvedSessionBaseURL(streamingBaseURL: currentStreamingBaseUrl(), serverIP: serverIp)
        guard var request = CloudMatchRequestFactory.pollSessionRequest(baseURLString: base, sessionId: sessionId, accessToken: token, deviceId: OPNDeviceIdentity.stableCloudmatchDeviceId()) else {
            return (false, [:], "Invalid poll URL")
        }
        let networkStart = OPNNetworkLog.start(&request, operation: "cloudmatch.pollSession")
        let tracedRequest = request
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await OPNSessionProxySessionProvider.shared.data(for: tracedRequest, purpose: .session)
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.pollSession", startedAt: networkStart, data: data, response: response, error: nil)
        } catch {
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.pollSession", startedAt: networkStart, data: nil, response: nil, error: error)
            return (false, [:], error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            return (false, [:], "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
        }
        guard let json = CloudMatchResponseParser.jsonDictionary(data), let session = json["session"] as? [String: Any] else {
            return (false, [:], "No session in poll response")
        }
        var info = sessionInfo(from: session, requestedSessionId: sessionId, baseUrl: base, clientId: "", deviceId: "", initialProfile: [:])
        guard string(info["sessionId"]) == sessionId else {
            return (false, [:], "SESSION_ID_MISMATCH: requested \(escapedLogString(sessionId)) but response contained \(escapedLogString(string(info["sessionId"])))")
        }
        mergeAndStoreAdState(&info)
        logPollSessionSummary(httpStatus: http.statusCode, info: info)
        return (true, info, "")
    }

    func stopSession(sessionId: String, serverIp: String) async -> (Bool, String) {
        let token = currentAccessToken()
        guard !token.isEmpty else {
            return (false, "No access token")
        }
        clearPersistedActiveSessionId(sessionId)
        let base = CloudMatchRequestFactory.resolvedSessionBaseURL(streamingBaseURL: currentStreamingBaseUrl(), serverIP: serverIp)
        guard var request = CloudMatchRequestFactory.stopSessionRequest(baseURLString: base, sessionId: sessionId, accessToken: token, deviceId: OPNDeviceIdentity.stableCloudmatchDeviceId()) else {
            return (false, "Invalid stop session URL")
        }
        let networkStart = OPNNetworkLog.start(&request, operation: "cloudmatch.stopSession")
        let tracedRequest = request
        let data: Data?
        let response: URLResponse
        do {
            (data, response) = try await OPNSessionProxySessionProvider.shared.data(for: tracedRequest, purpose: .session)
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.stopSession", startedAt: networkStart, data: data, response: response, error: nil)
        } catch {
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.stopSession", startedAt: networkStart, data: nil, response: nil, error: error)
            return (false, error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return (false, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
        }
        return (true, "")
    }

    func getActiveSessions() async -> (Bool, [[String: Any]], String) {
        let token = currentAccessToken()
        guard !token.isEmpty else {
            return (false, [], "No access token")
        }
        let base = currentStreamingBaseUrl()
        guard var request = CloudMatchRequestFactory.activeSessionsRequest(baseURLString: base, accessToken: token, deviceId: OPNDeviceIdentity.stableCloudmatchDeviceId()) else {
            return (false, [], "Invalid sessions URL")
        }
        let networkStart = OPNNetworkLog.start(&request, operation: "cloudmatch.activeSessions")
        let tracedRequest = request
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await OPNSessionProxySessionProvider.shared.data(for: tracedRequest, purpose: .session)
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.activeSessions", startedAt: networkStart, data: data, response: response, error: nil)
        } catch {
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.activeSessions", startedAt: networkStart, data: nil, response: nil, error: error)
            return (false, [], error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return (false, [], "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let json = CloudMatchResponseParser.jsonDictionary(data), CloudMatchResponseParser.requestSucceeded(json) else {
            return (false, [], "API error from sessions endpoint")
        }
        return (true, activeSessionEntries(from: array(json["sessions"]), streamingBaseUrl: base), "")
    }

    func reportSessionAd(session: [String: Any], adId: String, action: String, watchedTimeInMs: Int, pausedTimeInMs: Int, cancelReason: String) async -> (Bool, [String: Any], String) {
        let token = currentAccessToken()
        let sessionId = string(session["sessionId"])
        let actionCode = adActionCode(action)
        guard !token.isEmpty else {
            return (false, [:], "No access token")
        }
        guard !sessionId.isEmpty, !adId.isEmpty, actionCode != 0 else {
            return (false, [:], "Invalid ad update request")
        }
        let base = CloudMatchRequestFactory.resolvedSessionBaseURL(streamingBaseURL: string(session["streamingBaseUrl"]).isEmpty ? currentStreamingBaseUrl() : string(session["streamingBaseUrl"]), serverIP: string(session["serverIp"]))
        var adUpdate: [String: Any] = ["adId": adId, "adAction": actionCode, "clientTimestamp": Int(Date().timeIntervalSince1970)]
        if watchedTimeInMs >= 0 { adUpdate["watchedTimeInMs"] = watchedTimeInMs }
        if pausedTimeInMs >= 0 { adUpdate["pausedTimeInMs"] = pausedTimeInMs }
        if !cancelReason.isEmpty { adUpdate["cancelReason"] = cancelReason }
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: ["action": 6, "adUpdates": [adUpdate]])
        } catch {
            return (false, [:], "Failed to encode ad update request")
        }
        guard var request = CloudMatchRequestFactory.adUpdateRequest(baseURLString: base, sessionId: sessionId, accessToken: token, deviceId: string(session["deviceId"]).isEmpty ? OPNDeviceIdentity.stableCloudmatchDeviceId() : string(session["deviceId"]), body: bodyData) else {
            return (false, [:], "Invalid ad update URL")
        }
        let networkStart = OPNNetworkLog.start(&request, operation: "cloudmatch.reportSessionAd")
        let tracedRequest = request
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await OPNSessionProxySessionProvider.shared.data(for: tracedRequest, purpose: .session)
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.reportSessionAd", startedAt: networkStart, data: data, response: response, error: nil)
        } catch {
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.reportSessionAd", startedAt: networkStart, data: nil, response: nil, error: error)
            return (false, [:], error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            return (false, [:], "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
        }
        guard let json = CloudMatchResponseParser.jsonDictionary(data), CloudMatchResponseParser.requestSucceeded(json) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            return (false, [:], "Ad update API error: \(body)")
        }
        var updated = session
        if let sessionJson = json["session"] as? [String: Any] {
            let progress = OPNSessionJSONParser.parseSessionProgress(from: sessionJson as NSDictionary)
            updated["status"] = int(sessionJson["status"])
            updated["queuePosition"] = progress.queuePosition
            updated["seatSetupStep"] = progress.seatSetupStep
            updated["progressState"] = progress.progressState
            updated["remainingSessionLimitSeconds"] = progress.remainingSessionLimitSeconds
            updated["negotiatedStreamProfile"] = negotiatedStreamProfile(from: sessionJson)
            updated["adState"] = sessionAdState(from: sessionJson)
            mergeAndStoreAdState(&updated)
        }
        return (true, updated, "")
    }

}
