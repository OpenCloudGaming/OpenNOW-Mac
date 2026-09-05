//  Claiming an already-running seat session: validating it, resuming it where the state allows, and
//  otherwise asking the seat to hand it over.
//

@preconcurrency import Foundation

extension OPNSessionManager {
    func claimSession(sessionId: String, serverIp: String, appId: String, settings: [String: Any], recoveryMode: Bool, completion: @escaping (Bool, [String: Any], String) -> Void) {
        guard let launchAppId = OPNLaunchAppId.resolve(appId) else {
            OPNSentry.logWarningMessage(OPNSentry.formattedLogMessage(level: "warning", area: "ClaimSession", message: "Refusing claim with invalid appId=\(escapedLogString(appId.trimmingCharacters(in: .whitespacesAndNewlines))) sessionId=\(escapedLogString(sessionId))"))
            completion(false, [:], "This game does not include a launchable GeForce NOW app id.")
            return
        }
        let token = currentAccessToken()
        guard !token.isEmpty else {
            completion(false, [:], "No access token")
            return
        }
        guard !serverIp.isEmpty else {
            completion(false, [:], "No server IP for claim")
            return
        }
        let deviceId = OPNDeviceIdentity.stableCloudmatchDeviceId()
        let clientId = UUID().uuidString.lowercased()
        let base = CloudMatchRequestFactory.resolvedSessionBaseURL(streamingBaseURL: currentStreamingBaseUrl(), serverIP: serverIp)
        let headers = CloudMatchClientHeaders.streamSession(transportMode: streamTransportMode(settings))
        guard var validationRequest = CloudMatchRequestFactory.pollSessionRequest(baseURLString: base, sessionId: sessionId, accessToken: token, deviceId: deviceId, timeoutInterval: 30, headers: headers) else {
            completion(false, [:], "Invalid validation URL")
            return
        }
        OPNSentry.logInfoMessage(OPNSentry.formattedLogMessage(level: "info", area: "ClaimSession", message: "Starting claim sessionId=\(sessionId) serverIp=\(serverIp) appId=\(launchAppId.stringValue) transport=\(streamTransportMode(settings)) resolution=\(string(settings["resolution"])) fps=\(int(settings["fps"], fallback: 60)) codec=\(string(settings["codec"])) color=\(string(settings["colorQuality"])) bitrate=\(int(settings["maxBitrateMbps"], fallback: 50))Mbps l4s=\(bool(settings["enableL4S"]) ? "on" : "off") recovery=\(recoveryMode)"))
        nonisolated(unsafe) let completion = completion
        nonisolated(unsafe) let context = ClaimContext(sessionId: sessionId,
                                                       serverIp: serverIp,
                                                       base: base,
                                                       headers: headers,
                                                       clientId: clientId,
                                                       deviceId: deviceId,
                                                       token: token,
                                                       appId: launchAppId,
                                                       settings: settings)
        let validationNetworkStart = OPNNetworkLog.start(&validationRequest, operation: "cloudmatch.validateSessionClaim")
        let tracedValidationRequest = validationRequest
        OPNSessionProxySessionProvider.shared.controlPlaneURLSession(for: .session).dataTask(with: tracedValidationRequest) { [weak self] data, response, error in
            OPNNetworkLog.finish(tracedValidationRequest, operation: "cloudmatch.validateSessionClaim", startedAt: validationNetworkStart, data: data, response: response, error: error)
            guard let self else { return }
            self.handleClaimValidation(data: data, response: response, error: error, context: context, completion: completion)
        }.resume()
    }

    /// Everything the claim flow threads through its stages.
    struct ClaimContext {
        let sessionId: String
        let serverIp: String
        let base: String
        let headers: CloudMatchClientHeaders
        let clientId: String
        let deviceId: String
        let token: String
        let appId: OPNResolvedLaunchAppId
        let settings: [String: Any]
    }

    /// The validation poll's answer: reject the claim, resume the live session, or fall through to
    /// claiming from scratch.
    func handleClaimValidation(data: Data?,
                                       response: URLResponse?,
                                       error: Error?,
                                       context: ClaimContext,
                                       completion: @escaping (Bool, [String: Any], String) -> Void) {
        var preClaimStatus = 0
        var validatedSession: [String: Any]?
        if let error {
            OPNSentry.logWarningMessage(OPNSentry.formattedLogMessage(level: "warning", area: "ClaimSession", message: "Validation request failed error=\(error.localizedDescription)"))
        } else if let data {
            validatedSession = CloudMatchResponseParser.jsonDictionary(data)?["session"] as? [String: Any]
            preClaimStatus = int(validatedSession?["status"])
            if let rejection = claimValidationRejection(data: data, response: response, preClaimStatus: preClaimStatus, sessionId: context.sessionId) {
                completion(false, [:], rejection)
                return
            }
        }
        if let validatedSession, let state = CloudMatchSessionState(rawValue: preClaimStatus),
           resumeValidatedClaim(state: state, session: validatedSession, context: context, completion: completion) {
            return
        }
        sendClaimSession(sessionId: context.sessionId,
                         serverIp: context.serverIp,
                         appId: context.appId,
                         settings: context.settings,
                         token: context.token,
                         deviceId: context.deviceId,
                         clientId: context.clientId,
                         initialProfile: validatedSession.map { negotiatedStreamProfile(from: $0) } ?? [:],
                         completion: completion)
    }

    /// Why the seat refused the validation poll, or nil when it answered normally.
    func claimValidationRejection(data: Data, response: URLResponse?, preClaimStatus: Int, sessionId: String) -> String? {
        let json = CloudMatchResponseParser.jsonDictionary(data)
        let statusCode = int((json?["requestStatus"] as? [String: Any])?["statusCode"])
        let http = response as? HTTPURLResponse
        guard (http?.statusCode ?? 0) >= 400 || (statusCode != 0 && statusCode != 1 && preClaimStatus == 0) else { return nil }
        if let staleMessage = CloudMatchResponseParser.staleActiveSessionClaimMessage(data) {
            clearPersistedActiveSessionId(sessionId)
            return staleMessage
        }
        if let limitedModeMessage = CloudMatchResponseParser.limitedModeStreamingMessage(data) {
            return limitedModeMessage
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        return "STALE_ACTIVE_SESSION: validation HTTP \(http?.statusCode ?? 0): \(body)"
    }

    /// Handles a session that is already alive. False means the state does not resume and the
    /// caller should claim from scratch.
    func resumeValidatedClaim(state: CloudMatchSessionState,
                                      session: [String: Any],
                                      context: ClaimContext,
                                      completion: @escaping (Bool, [String: Any], String) -> Void) -> Bool {
        let initialProfile = negotiatedStreamProfile(from: session)
        switch state {
        case .readyForConnection, .streaming:
            // A live session still needs the RESUME hand-over. Taking its endpoints straight from
            // the validation poll skips telling the seat who is connecting now, and its RTSPS
            // control channel then answers the WebSocket upgrade with HTTP 501 — measured against
            // a session started on another device, where a freshly created session on the same
            // build upgrades normally. The seat answers the hand-over for an unpaused session with
            // SESSION_NOT_PAUSED, which `finishClaimRejection` already polls through.
            return false
        case .initializing, .resuming:
            pollClaimSession(sessionId: context.sessionId, serverIp: context.serverIp, deviceId: context.deviceId, clientId: context.clientId, headers: context.headers, initialProfile: initialProfile, requiresNvstControlEndpoint: streamTransportMode(context.settings) == "nvst", completion: completion)
        case .pausedUnintentional, .pausedIntentional:
            return false
        case .finished:
            clearPersistedActiveSessionId(context.sessionId)
            completion(false, [:], "This GeForce NOW session is no longer resumable. End it and launch again.")
        }
        return true
    }

    func sendClaimSession(sessionId: String, serverIp: String, appId: OPNResolvedLaunchAppId, settings: [String: Any], token: String, deviceId: String, clientId: String, initialProfile: [String: Any] = [:], completion: @escaping (Bool, [String: Any], String) -> Void) {
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        let hdrEnabled = bool(settings["enableHdr"]) && capabilities.hdrDisplaySupported
        let transportMode = streamTransportMode(settings)
        let selectedStore = string(settings["selectedStore"]).isEmpty ? "unknown" : string(settings["selectedStore"])
        // A claim sends the same session request the create path does — the seat resumes against
        // it — with the title left out, since the session it belongs to already named one.
        let payload: [String: Any] = [
            "action": 2,
            "data": "RESUME",
            "sessionRequestData": sessionRequestData(launchAppId: appId,
                                                     internalTitle: NSNull(),
                                                     settings: settings,
                                                     capabilities: capabilities,
                                                     transportMode: transportMode,
                                                     hdrEnabled: hdrEnabled,
                                                     deviceId: deviceId,
                                                     selectedStore: selectedStore),
            "metaData": [],
        ]
        let layout = string(settings["keyboardLayout"]).isEmpty ? "us" : string(settings["keyboardLayout"])
        let language = string(settings["gameLanguage"]).isEmpty ? OPNLocale.currentGFNLocale() : string(settings["gameLanguage"])
        OPNProtocolDebug.logJSONObject(label: "session claim request", object: payload)
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(false, [:], "Failed to encode claim request")
            return
        }
        let base = CloudMatchRequestFactory.resolvedSessionBaseURL(streamingBaseURL: currentStreamingBaseUrl(), serverIP: serverIp)
        let headers = CloudMatchClientHeaders.streamSession(transportMode: transportMode)
        guard var request = CloudMatchRequestFactory.claimSessionRequest(baseURLString: base, sessionId: sessionId, accessToken: token, deviceId: deviceId, keyboardLayout: layout, languageCode: language, body: bodyData, headers: headers) else {
            completion(false, [:], "Invalid claim URL")
            return
        }
        nonisolated(unsafe) let completion = completion
        let target = ClaimPollTarget(sessionId: sessionId, serverIp: serverIp, deviceId: deviceId, clientId: clientId, headers: headers, initialProfile: initialProfile, requiresNvstControlEndpoint: transportMode == "nvst")
        let networkStart = OPNNetworkLog.start(&request, operation: "cloudmatch.claimSession")
        let tracedRequest = request
        OPNSessionProxySessionProvider.shared.controlPlaneURLSession(for: .session).dataTask(with: tracedRequest) { [weak self] data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.claimSession", startedAt: networkStart, data: data, response: response, error: error)
            guard let self else { return }
            self.handleClaimResponse(data: data, response: response, error: error, target: target, completion: completion)
        }.resume()
    }

    /// What a claim needs to keep polling the seat after the claim request itself returns.
    struct ClaimPollTarget: @unchecked Sendable {
        let sessionId: String
        let serverIp: String
        let deviceId: String
        let clientId: String
        let headers: CloudMatchClientHeaders
        /// The profile the validation poll already reported, kept as the base for whatever the
        /// claim response and the poll that follows do not restate.
        let initialProfile: [String: Any]
        let requiresNvstControlEndpoint: Bool
    }

    func handleClaimResponse(data: Data?,
                                     response: URLResponse?,
                                     error: Error?,
                                     target: ClaimPollTarget,
                                     completion: @escaping (Bool, [String: Any], String) -> Void) {
        if let error {
            completion(false, [:], error.localizedDescription)
            return
        }
        guard let data else {
            completion(false, [:], "No claim response")
            return
        }
        OPNProtocolDebug.logJSONData(label: "session claim response", data: data)
        let body = String(data: data, encoding: .utf8) ?? ""
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            let notPaused = CloudMatchResponseParser.isSessionNotPausedResponse(data)
                || body.contains("SESSION_NOT_PAUSED")
                || body.contains("\"statusCode\":34")
            finishClaimRejection(data: data, notPaused: notPaused, fallback: "Claim HTTP \(http?.statusCode ?? 0): \(body)", target: target, completion: completion)
            return
        }
        guard let json = CloudMatchResponseParser.jsonDictionary(data), CloudMatchResponseParser.requestSucceeded(json) else {
            let requestStatus = CloudMatchResponseParser.jsonDictionary(data)?["requestStatus"] as? [String: Any]
            let statusCode = int(requestStatus?["statusCode"])
            let description = string(requestStatus?["statusDescription"])
            let notPaused = description.contains("SESSION_NOT_PAUSED") || statusCode == 34
            finishClaimRejection(data: data,
                                 notPaused: notPaused,
                                 fallback: "Claim API error \(statusCode): \(description.isEmpty ? "unknown" : description)",
                                 target: target,
                                 completion: completion)
            return
        }
        let claimProfile = (json["session"] as? [String: Any]).map { self.negotiatedStreamProfile(from: $0) } ?? target.initialProfile
        pollClaimSession(sessionId: target.sessionId, serverIp: target.serverIp, deviceId: target.deviceId, clientId: target.clientId, headers: target.headers, initialProfile: claimProfile, requiresNvstControlEndpoint: target.requiresNvstControlEndpoint, completion: completion)
    }

    /// A claim the seat refused. "Not paused" means the session is already coming up, so polling
    /// takes over; otherwise the most specific reason the seat gave is reported.
    func finishClaimRejection(data: Data,
                                      notPaused: Bool,
                                      fallback: String,
                                      target: ClaimPollTarget,
                                      completion: @escaping (Bool, [String: Any], String) -> Void) {
        if notPaused {
            pollClaimSession(sessionId: target.sessionId, serverIp: target.serverIp, deviceId: target.deviceId, clientId: target.clientId, headers: target.headers, initialProfile: target.initialProfile, requiresNvstControlEndpoint: target.requiresNvstControlEndpoint, completion: completion)
            return
        }
        if let staleMessage = CloudMatchResponseParser.staleActiveSessionClaimMessage(data) {
            clearPersistedActiveSessionId(target.sessionId)
            completion(false, [:], staleMessage)
            return
        }
        if let limitedModeMessage = CloudMatchResponseParser.limitedModeStreamingMessage(data) {
            completion(false, [:], limitedModeMessage)
            return
        }
        completion(false, [:], fallback)
    }

    func pollClaimSession(sessionId: String, serverIp: String, deviceId: String, clientId: String, headers: CloudMatchClientHeaders, initialProfile: [String: Any], requiresNvstControlEndpoint: Bool, completion: @escaping (Bool, [String: Any], String) -> Void) {
        OPNPollClaimSessionContext(manager: self,
                                   sessionId: sessionId,
                                   base: CloudMatchRequestFactory.resolvedSessionBaseURL(streamingBaseURL: currentStreamingBaseUrl(), serverIP: serverIp),
                                   token: currentAccessToken(),
                                   deviceId: deviceId,
                                   clientId: clientId,
                                   headers: headers,
                                   initialProfile: initialProfile,
                                   requiresNvstControlEndpoint: requiresNvstControlEndpoint,
                                   completion: completion).poll(attempt: 0)
    }

    func pollClaimSessionRequestFinished(context: OPNPollClaimSessionContext, attempt: Int, data: Data?, error: Error?) {
        guard error == nil, let data, let json = CloudMatchResponseParser.jsonDictionary(data), let session = json["session"] as? [String: Any] else {
            context.retry(after: pollDelay(attempt), attempt: attempt + 1)
            return
        }
        let status = int(session["status"])
        if isReadyActiveSessionStatus(status) {
            let responseSessionId = string(session["sessionId"])
            if !responseSessionId.isEmpty, responseSessionId != context.sessionId {
                context.complete(false, [:], "Resume returned a different session id")
                return
            }
            if context.requiresNvstControlEndpoint, attempt < Self.nvstControlEndpointGraceAttempts,
               !hasAdvertisedNvstControlEndpoint(session) {
                // The seat reports the session ready while still provisioned for the client that
                // created it. Connecting now reaches a host with no RTSP service (HTTP 501), so
                // keep polling until the hand-over publishes the control endpoint. Bounded: past
                // the grace window, hand back what the seat gave us and let the transport report
                // the real failure rather than timing out the whole poll budget.
                context.retry(after: pollDelay(attempt), attempt: attempt + 1)
                return
            }
            var info = sessionInfo(from: session, requestedSessionId: context.sessionId, baseUrl: context.base, clientId: context.clientId, deviceId: context.deviceId, initialProfile: context.initialProfile)
            info["isResume"] = true
            mergeAndStoreAdState(&info)
            context.complete(true, info, "")
        } else if canContinuePollingActiveSessionStatus(status) {
            context.retry(after: pollDelay(attempt), attempt: attempt + 1)
        } else {
            context.complete(false, [:], "Session in terminal error state")
        }
    }
}
