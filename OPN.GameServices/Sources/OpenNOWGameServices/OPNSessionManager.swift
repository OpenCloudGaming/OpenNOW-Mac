@preconcurrency import Foundation

import CloudMatch
import Common
import OpenNOWTelemetry
import WebRTCMedia

final class OPNSessionManager: NSObject, @unchecked Sendable {
    static let shared = OPNSessionManager()

    private let lock = NSLock()
    private var accessToken = ""
    private var streamingBaseUrl = defaultBaseUrl
    private var adStatesBySessionId: [String: [String: Any]] = [:]

    private static let defaultBaseUrl = CloudMatch.productionBaseURLString
    private static let persistedActiveSessionIdKey = "OpenNOW.Stream.ActiveSessionId"

    func setAccessToken(_ token: String) {
        lock.withLock { accessToken = token }
    }

    func setStreamingBaseUrl(_ url: String) {
        lock.withLock { streamingBaseUrl = CloudMatchRequestFactory.resolvedSessionBaseURL(streamingBaseURL: url, serverIP: "") }
    }

    func createSession(appId: String, internalTitle: String, settings: [String: Any], completion: @escaping (Bool, [String: Any], String) -> Void) {
        guard let launchAppId = OPNLaunchAppId.resolve(appId) else {
            OPNSentry.logErrorMessage(OPNSentry.formattedLogMessage(level: "error", area: "SessionManager", message: "Refusing session creation with invalid appId=\(escapedLogString(appId.trimmingCharacters(in: .whitespacesAndNewlines)))"))
            completion(false, [:], "This game does not include a launchable GeForce NOW app id.")
            return
        }
        let token = currentAccessToken()
        guard !token.isEmpty else {
            completion(false, [:], "No access token")
            return
        }

        clearPersistedActiveSessionId("")
        let baseUrl = currentStreamingBaseUrl()
        let clientId = UUID().uuidString.lowercased()
        let deviceId = OPNDeviceIdentity.stableCloudmatchDeviceId()
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        let effectiveSettings = settingsByApplyingCloudVariables(settings, capabilities: capabilities)
        let hdrEnabled = bool(effectiveSettings["enableHdr"]) && capabilities.hdrDisplaySupported
        let timezoneOffset = -TimeZone.current.secondsFromGMT() * 1000
        let selectedStore = string(effectiveSettings["selectedStore"]).isEmpty ? "unknown" : string(effectiveSettings["selectedStore"])

        OPNSentry.logInfoMessage(OPNSentry.formattedLogMessage(level: "info", area: "SessionManager", message: "Creating cloud session appId=\(launchAppId.stringValue) base=\(baseUrl) codec=\(string(effectiveSettings["codec"])) color=\(string(effectiveSettings["colorQuality"])) bitrate=\(int(effectiveSettings["maxBitrateMbps"], fallback: 50))Mbps l4s=\(bool(effectiveSettings["enableL4S"]) ? "on" : "off") networkTestSessionId=\(escapedLogString(string(effectiveSettings["networkTestSessionId"])))"))

        let sessionRequestData: [String: Any] = [
            "appId": launchAppId.stringValue,
            "internalTitle": internalTitle,
            "availableSupportedControllers": stringArray(effectiveSettings["availableSupportedControllers"]),
            "networkTestSessionId": networkTestSessionIdValue(effectiveSettings),
            "parentSessionId": NSNull(),
            "clientIdentification": "GFN-PC",
            "deviceHashId": deviceId,
            "clientVersion": "30.0",
            "sdkVersion": "1.0",
            "streamerVersion": 1,
            "clientPlatformName": "windows",
            "clientRequestMonitorSettings": [monitorSettings(effectiveSettings, capabilities: capabilities, hdrEnabled: hdrEnabled)],
            "useOps": true,
            "audioMode": 2,
            "metaData": [
                ["key": "SubSessionId", "value": UUID().uuidString.lowercased()],
                ["key": "wssignaling", "value": "1"],
                ["key": "GSStreamerType", "value": "WebRTC"],
                ["key": "networkType", "value": networkTypeValue(effectiveSettings)],
                ["key": "networkLatencyMs", "value": networkLatencyValue(effectiveSettings)],
                ["key": "ClientImeSupport", "value": "0"],
                ["key": "clientPhysicalResolution", "value": "{\"horizontalPixels\":\(max(0, capabilities.maxDisplayWidth)),\"verticalPixels\":\(max(0, capabilities.maxDisplayHeight))}"],
                ["key": "surroundAudioInfo", "value": "2"],
                ["key": "store", "value": selectedStore],
            ],
            "sdrHdrMode": hdrEnabled ? 1 : 0,
            "clientDisplayHdrCapabilities": clientDisplayHdrCapabilities(capabilities),
            "surroundAudioInfo": 0,
            "remoteControllersBitmap": int(effectiveSettings["remoteControllersBitmap"]),
            "clientTimezoneOffset": timezoneOffset,
            "enhancedStreamMode": 1,
            "appLaunchMode": 1,
            "secureRTSPSupported": false,
            "partnerCustomData": "",
            "accountLinked": bool(effectiveSettings["accountLinked"], fallback: true),
            "enablePersistingInGameSettings": true,
            "userAge": 26,
            "requestedStreamingFeatures": requestedStreamingFeatures(effectiveSettings, hdrEnabled: hdrEnabled),
        ]

        let layout = string(effectiveSettings["keyboardLayout"]).isEmpty ? "us" : string(effectiveSettings["keyboardLayout"])
        let language = string(effectiveSettings["gameLanguage"]).isEmpty ? OPNLocale.currentGFNLocale() : string(effectiveSettings["gameLanguage"])
        let body: [String: Any] = ["sessionRequestData": sessionRequestData]
        OPNProtocolDebug.logJSONObject(label: "session create request", object: body)
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(false, [:], "Failed to encode session create request")
            return
        }
        guard var request = CloudMatchRequestFactory.createSessionRequest(baseURLString: baseUrl, accessToken: token, deviceId: deviceId, keyboardLayout: layout, languageCode: language, body: bodyData) else {
            completion(false, [:], "Invalid session create URL")
            return
        }
        request.setValue("https://play.geforcenow.com", forHTTPHeaderField: "Origin")

        nonisolated(unsafe) let createCompletion = completion
        nonisolated(unsafe) let createEffectiveSettings = effectiveSettings
        let networkStart = OPNNetworkLog.start(&request, operation: "cloudmatch.createSession")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { [weak self] data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.createSession", startedAt: networkStart, data: data, response: response, error: error)
            guard let self else { return }
            if let error {
                createCompletion(false, [:], error.localizedDescription)
                return
            }
            guard let data else {
                createCompletion(false, [:], "No session response")
                return
            }
            OPNProtocolDebug.logJSONData(label: "session create response", data: data)
            let http = response as? HTTPURLResponse
            guard http?.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                let errorMessage = "HTTP \(http?.statusCode ?? 0): \(body)"
                if let json = CloudMatchResponseParser.jsonDictionary(data), CloudMatchResponseParser.isSessionLimitExceededResponse(json), let selected = self.selectSessionLimitReuseEntry(self.activeSessionEntries(from: array(json["otherUserSessions"]), streamingBaseUrl: baseUrl), requestedAppId: launchAppId.intValue) {
                    if self.isReadyActiveSessionStatus(int(selected["status"])) {
                        self.claimSession(sessionId: string(selected["sessionId"]), serverIp: string(selected["serverIp"]), appId: string(selected["appId"]).isEmpty ? launchAppId.stringValue : string(selected["appId"]), settings: createEffectiveSettings, recoveryMode: true, completion: createCompletion)
                    } else {
                        self.pollClaimSession(sessionId: string(selected["sessionId"]), serverIp: string(selected["serverIp"]), deviceId: deviceId, clientId: clientId, initialProfile: [:], completion: createCompletion)
                    }
                    return
                }
                createCompletion(false, [:], errorMessage)
                return
            }
            guard let json = CloudMatchResponseParser.jsonDictionary(data), CloudMatchResponseParser.requestSucceeded(json) else {
                createCompletion(false, [:], CloudMatchResponseParser.requestStatusError(data: data, fallback: "Failed to parse session response"))
                return
            }
            guard let session = json["session"] as? [String: Any] else {
                createCompletion(false, [:], "No session in response")
                return
            }
            var info = self.sessionInfo(from: session, requestedSessionId: "", baseUrl: baseUrl, clientId: clientId, deviceId: deviceId, initialProfile: [:])
            self.mergeAndStoreAdState(&info)
            createCompletion(true, info, "")
        }.resume()
    }

    func pollSession(sessionId: String, serverIp: String, completion: @escaping (Bool, [String: Any], String) -> Void) {
        let token = currentAccessToken()
        guard !token.isEmpty else {
            completion(false, [:], "No access token")
            return
        }
        guard isValidSessionId(sessionId) else {
            completion(false, [:], "Invalid session id for poll: \(escapedLogString(sessionId))")
            return
        }
        let base = CloudMatchRequestFactory.resolvedSessionBaseURL(streamingBaseURL: currentStreamingBaseUrl(), serverIP: serverIp)
        guard var request = CloudMatchRequestFactory.pollSessionRequest(baseURLString: base, sessionId: sessionId, accessToken: token, deviceId: OPNDeviceIdentity.stableCloudmatchDeviceId()) else {
            completion(false, [:], "Invalid poll URL")
            return
        }
        nonisolated(unsafe) let completion = completion
        let networkStart = OPNNetworkLog.start(&request, operation: "cloudmatch.pollSession")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { [weak self] data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.pollSession", startedAt: networkStart, data: data, response: response, error: error)
            guard let self else { return }
            if let error {
                completion(false, [:], error.localizedDescription)
                return
            }
            guard let data, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(false, [:], "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
                return
            }
            guard let json = CloudMatchResponseParser.jsonDictionary(data), let session = json["session"] as? [String: Any] else {
                completion(false, [:], "No session in poll response")
                return
            }
            var info = self.sessionInfo(from: session, requestedSessionId: sessionId, baseUrl: base, clientId: "", deviceId: "", initialProfile: [:])
            guard string(info["sessionId"]) == sessionId else {
                completion(false, [:], "SESSION_ID_MISMATCH: requested \(escapedLogString(sessionId)) but response contained \(escapedLogString(string(info["sessionId"])))")
                return
            }
            self.mergeAndStoreAdState(&info)
            self.logPollSessionSummary(httpStatus: http.statusCode, info: info)
            completion(true, info, "")
        }.resume()
    }

    func stopSession(sessionId: String, serverIp: String, completion: @escaping (Bool, String) -> Void) {
        let token = currentAccessToken()
        guard !token.isEmpty else {
            completion(false, "No access token")
            return
        }
        clearPersistedActiveSessionId(sessionId)
        let base = CloudMatchRequestFactory.resolvedSessionBaseURL(streamingBaseURL: currentStreamingBaseUrl(), serverIP: serverIp)
        guard var request = CloudMatchRequestFactory.stopSessionRequest(baseURLString: base, sessionId: sessionId, accessToken: token, deviceId: OPNDeviceIdentity.stableCloudmatchDeviceId()) else {
            completion(false, "Invalid stop session URL")
            return
        }
        nonisolated(unsafe) let completion = completion
        let networkStart = OPNNetworkLog.start(&request, operation: "cloudmatch.stopSession")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.stopSession", startedAt: networkStart, data: data, response: response, error: error)
            if let error {
                completion(false, error.localizedDescription)
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(false, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
                return
            }
            completion(true, "")
        }.resume()
    }

    func getActiveSessions(completion: @escaping (Bool, [[String: Any]], String) -> Void) {
        let token = currentAccessToken()
        guard !token.isEmpty else {
            completion(false, [], "No access token")
            return
        }
        let base = currentStreamingBaseUrl()
        guard var request = CloudMatchRequestFactory.activeSessionsRequest(baseURLString: base, accessToken: token, deviceId: OPNDeviceIdentity.stableCloudmatchDeviceId()) else {
            completion(false, [], "Invalid sessions URL")
            return
        }
        nonisolated(unsafe) let completion = completion
        let networkStart = OPNNetworkLog.start(&request, operation: "cloudmatch.activeSessions")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { [weak self] data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.activeSessions", startedAt: networkStart, data: data, response: response, error: error)
            guard let self else { return }
            if let error {
                completion(false, [], error.localizedDescription)
                return
            }
            guard let data, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                completion(false, [], "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return
            }
            guard let json = CloudMatchResponseParser.jsonDictionary(data), CloudMatchResponseParser.requestSucceeded(json) else {
                completion(false, [], "API error from sessions endpoint")
                return
            }
            completion(true, self.activeSessionEntries(from: array(json["sessions"]), streamingBaseUrl: base), "")
        }.resume()
    }

    func reportSessionAd(session: [String: Any], adId: String, action: String, watchedTimeInMs: Int, pausedTimeInMs: Int, cancelReason: String, completion: @escaping (Bool, [String: Any], String) -> Void) {
        let token = currentAccessToken()
        let sessionId = string(session["sessionId"])
        let actionCode = adActionCode(action)
        guard !token.isEmpty else {
            completion(false, [:], "No access token")
            return
        }
        guard !sessionId.isEmpty, !adId.isEmpty, actionCode != 0 else {
            completion(false, [:], "Invalid ad update request")
            return
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
            completion(false, [:], "Failed to encode ad update request")
            return
        }
        guard var request = CloudMatchRequestFactory.adUpdateRequest(baseURLString: base, sessionId: sessionId, accessToken: token, deviceId: string(session["deviceId"]).isEmpty ? OPNDeviceIdentity.stableCloudmatchDeviceId() : string(session["deviceId"]), body: bodyData) else {
            completion(false, [:], "Invalid ad update URL")
            return
        }
        nonisolated(unsafe) let completion = completion
        nonisolated(unsafe) let adSession = session
        let networkStart = OPNNetworkLog.start(&request, operation: "cloudmatch.reportSessionAd")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { [weak self] data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.reportSessionAd", startedAt: networkStart, data: data, response: response, error: error)
            guard let self else { return }
            if let error {
                completion(false, [:], error.localizedDescription)
                return
            }
            guard let data, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(false, [:], "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
                return
            }
            guard let json = CloudMatchResponseParser.jsonDictionary(data), CloudMatchResponseParser.requestSucceeded(json) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                completion(false, [:], "Ad update API error: \(body)")
                return
            }
            var updated = adSession
            if let sessionJson = json["session"] as? [String: Any] {
                updated["status"] = int(sessionJson["status"])
                updated["queuePosition"] = OPNSessionJSONParser.parseSessionProgress(from: sessionJson as NSDictionary).queuePosition
                updated["seatSetupStep"] = OPNSessionJSONParser.parseSessionProgress(from: sessionJson as NSDictionary).seatSetupStep
                updated["progressState"] = OPNSessionJSONParser.parseSessionProgress(from: sessionJson as NSDictionary).progressState
                updated["negotiatedStreamProfile"] = self.negotiatedStreamProfile(from: sessionJson)
                updated["adState"] = self.sessionAdState(from: sessionJson)
                self.mergeAndStoreAdState(&updated)
            }
            completion(true, updated, "")
        }.resume()
    }

    func claimSession(sessionId: String, serverIp: String, appId: String, settings: [String: Any], recoveryMode: Bool, completion: @escaping (Bool, [String: Any], String) -> Void) {
        guard let launchAppId = OPNLaunchAppId.resolve(appId) else {
            OPNSentry.logErrorMessage(OPNSentry.formattedLogMessage(level: "error", area: "ClaimSession", message: "Refusing claim with invalid appId=\(escapedLogString(appId.trimmingCharacters(in: .whitespacesAndNewlines))) sessionId=\(escapedLogString(sessionId))"))
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
        guard var validationRequest = CloudMatchRequestFactory.pollSessionRequest(baseURLString: base, sessionId: sessionId, accessToken: token, deviceId: deviceId, timeoutInterval: 30) else {
            completion(false, [:], "Invalid validation URL")
            return
        }
        OPNSentry.logInfoMessage(OPNSentry.formattedLogMessage(level: "info", area: "ClaimSession", message: "Starting claim sessionId=\(sessionId) serverIp=\(serverIp) appId=\(launchAppId.stringValue) codec=\(string(settings["codec"])) color=\(string(settings["colorQuality"])) bitrate=\(int(settings["maxBitrateMbps"], fallback: 50))Mbps l4s=\(bool(settings["enableL4S"]) ? "on" : "off") recovery=\(recoveryMode)"))
        nonisolated(unsafe) let completion = completion
        nonisolated(unsafe) let claimSettings = settings
        let validationNetworkStart = OPNNetworkLog.start(&validationRequest, operation: "cloudmatch.validateSessionClaim")
        let tracedValidationRequest = validationRequest
        URLSession.shared.dataTask(with: tracedValidationRequest) { [weak self] data, response, error in
            OPNNetworkLog.finish(tracedValidationRequest, operation: "cloudmatch.validateSessionClaim", startedAt: validationNetworkStart, data: data, response: response, error: error)
            guard let self else { return }
            var preClaimStatus = 0
            if let error {
                OPNSentry.logErrorMessage(OPNSentry.formattedLogMessage(level: "error", area: "ClaimSession", message: "Validation request failed error=\(error.localizedDescription)"))
            } else if let data {
                let json = CloudMatchResponseParser.jsonDictionary(data)
                let session = json?["session"] as? [String: Any]
                preClaimStatus = int(session?["status"])
                let requestStatus = json?["requestStatus"] as? [String: Any]
                let statusCode = int(requestStatus?["statusCode"])
                let http = response as? HTTPURLResponse
                if (http?.statusCode ?? 0) >= 400 || (statusCode != 0 && statusCode != 1 && preClaimStatus == 0) {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    if let staleMessage = CloudMatchResponseParser.staleActiveSessionClaimMessage(data) {
                        self.clearPersistedActiveSessionId(sessionId)
                        completion(false, [:], staleMessage)
                        return
                    }
                    completion(false, [:], "STALE_ACTIVE_SESSION: validation HTTP \(http?.statusCode ?? 0): \(body)")
                    return
                }
            } else {
            }
            self.sendClaimSession(sessionId: sessionId, serverIp: serverIp, appId: launchAppId, settings: claimSettings, token: token, deviceId: deviceId, clientId: clientId, completion: completion)
        }.resume()
    }

    private func sendClaimSession(sessionId: String, serverIp: String, appId: OPNResolvedLaunchAppId, settings: [String: Any], token: String, deviceId: String, clientId: String, completion: @escaping (Bool, [String: Any], String) -> Void) {
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        let hdrEnabled = bool(settings["enableHdr"]) && capabilities.hdrDisplaySupported
        let selectedStore = string(settings["selectedStore"]).isEmpty ? "unknown" : string(settings["selectedStore"])
        let payload: [String: Any] = [
            "action": 2,
            "data": "RESUME",
            "sessionRequestData": [
                "audioMode": 2,
                "remoteControllersBitmap": int(settings["remoteControllersBitmap"]),
                "sdrHdrMode": hdrEnabled ? 1 : 0,
                "networkTestSessionId": networkTestSessionIdValue(settings),
                "availableSupportedControllers": stringArray(settings["availableSupportedControllers"]),
                "clientVersion": "30.0",
                "deviceHashId": deviceId,
                "internalTitle": NSNull(),
                "clientPlatformName": "windows",
                "clientRequestMonitorSettings": [monitorSettings(settings, capabilities: capabilities, hdrEnabled: hdrEnabled)],
                "metaData": [
                    ["key": "SubSessionId", "value": UUID().uuidString.lowercased()],
                    ["key": "wssignaling", "value": "1"],
                    ["key": "GSStreamerType", "value": "WebRTC"],
                    ["key": "networkType", "value": networkTypeValue(settings)],
                    ["key": "networkLatencyMs", "value": networkLatencyValue(settings)],
                    ["key": "ClientImeSupport", "value": "0"],
                    ["key": "surroundAudioInfo", "value": "2"],
                    ["key": "store", "value": selectedStore],
                ],
                "surroundAudioInfo": 0,
                "clientTimezoneOffset": -TimeZone.current.secondsFromGMT() * 1000,
                "clientIdentification": "GFN-PC",
                "parentSessionId": NSNull(),
                "appId": appId.intValue,
                "streamerVersion": 1,
                "appLaunchMode": 1,
                "sdkVersion": "1.0",
                "enhancedStreamMode": 1,
                "useOps": true,
                "clientDisplayHdrCapabilities": clientDisplayHdrCapabilities(capabilities),
                "accountLinked": bool(settings["accountLinked"], fallback: true),
                "partnerCustomData": "",
                "enablePersistingInGameSettings": true,
                "secureRTSPSupported": false,
                "userAge": 26,
                "requestedStreamingFeatures": requestedStreamingFeatures(settings, hdrEnabled: hdrEnabled),
            ],
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
        guard var request = CloudMatchRequestFactory.claimSessionRequest(baseURLString: base, sessionId: sessionId, accessToken: token, deviceId: deviceId, keyboardLayout: layout, languageCode: language, body: bodyData) else {
            completion(false, [:], "Invalid claim URL")
            return
        }
        nonisolated(unsafe) let completion = completion
        let networkStart = OPNNetworkLog.start(&request, operation: "cloudmatch.claimSession")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { [weak self] data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.claimSession", startedAt: networkStart, data: data, response: response, error: error)
            guard let self else { return }
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
                if CloudMatchResponseParser.isSessionNotPausedResponse(data) || body.contains("SESSION_NOT_PAUSED") || body.contains("\"statusCode\":34") {
                    completion(false, [:], "Session is not paused and cannot be resumed.")
                    return
                }
                if let staleMessage = CloudMatchResponseParser.staleActiveSessionClaimMessage(data) {
                    self.clearPersistedActiveSessionId(sessionId)
                    completion(false, [:], staleMessage)
                    return
                }
                completion(false, [:], "Claim HTTP \(http?.statusCode ?? 0): \(body)")
                return
            }
            guard let json = CloudMatchResponseParser.jsonDictionary(data), CloudMatchResponseParser.requestSucceeded(json) else {
                let requestStatus = CloudMatchResponseParser.jsonDictionary(data)?["requestStatus"] as? [String: Any]
                let statusCode = int(requestStatus?["statusCode"])
                let description = string(requestStatus?["statusDescription"])
                if description.contains("SESSION_NOT_PAUSED") || statusCode == 34 {
                    completion(false, [:], "Session is not paused and cannot be resumed.")
                    return
                }
                if let staleMessage = CloudMatchResponseParser.staleActiveSessionClaimMessage(data) {
                    self.clearPersistedActiveSessionId(sessionId)
                    completion(false, [:], staleMessage)
                    return
                }
                completion(false, [:], "Claim API error \(statusCode): \(description.isEmpty ? "unknown" : description)")
                return
            }
            let claimProfile = (json["session"] as? [String: Any]).map { self.negotiatedStreamProfile(from: $0) } ?? [:]
            self.pollClaimSession(sessionId: sessionId, serverIp: serverIp, deviceId: deviceId, clientId: clientId, initialProfile: claimProfile, completion: completion)
        }.resume()
    }

    private func pollClaimSession(sessionId: String, serverIp: String, deviceId: String, clientId: String, initialProfile: [String: Any], completion: @escaping (Bool, [String: Any], String) -> Void) {
        OPNPollClaimSessionContext(manager: self,
                                   sessionId: sessionId,
                                   base: CloudMatchRequestFactory.resolvedSessionBaseURL(streamingBaseURL: currentStreamingBaseUrl(), serverIP: serverIp),
                                   token: currentAccessToken(),
                                   deviceId: deviceId,
                                   clientId: clientId,
                                   initialProfile: initialProfile,
                                   completion: completion).poll(attempt: 0)
    }

    fileprivate func pollClaimSessionRequestFinished(context: OPNPollClaimSessionContext, attempt: Int, data: Data?, error: Error?) {
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
            var info = sessionInfo(from: session, requestedSessionId: context.sessionId, baseUrl: context.base, clientId: context.clientId, deviceId: context.deviceId, initialProfile: context.initialProfile)
            mergeAndStoreAdState(&info)
            context.complete(true, info, "")
        } else if canContinuePollingActiveSessionStatus(status) {
            context.retry(after: pollDelay(attempt), attempt: attempt + 1)
        } else {
            context.complete(false, [:], "Session in terminal error state")
        }
    }

    private func sessionInfo(from session: [String: Any], requestedSessionId: String, baseUrl: String, clientId: String, deviceId: String, initialProfile: [String: Any]) -> [String: Any] {
        let responseSessionId = string(session["sessionId"])
        let resolvedSessionId = responseSessionId.isEmpty ? requestedSessionId : responseSessionId
        if !resolvedSessionId.isEmpty { storePersistedActiveSessionId(resolvedSessionId) }
        let streamProfile = initialProfile.isEmpty ? negotiatedStreamProfile(from: session) : negotiatedStreamProfile(from: session, applying: initialProfile)
        var info: [String: Any] = [
            "sessionId": resolvedSessionId,
            "status": int(session["status"]),
            "queuePosition": 0,
            "seatSetupStep": 0,
            "progressState": 0,
            "zone": baseUrl,
            "streamingBaseUrl": baseUrl,
            "serverIp": "",
            "signalingServer": "",
            "signalingUrl": "",
            "iceServers": iceServers(from: session),
            "gpuType": string(session["gpuType"]),
            "mediaConnectionInfo": ["ip": "", "port": 0],
            "negotiatedStreamProfile": streamProfile,
            "adState": sessionAdState(from: session),
            "remainingPlaytimeHours": 0.0,
            "remainingPlaytimeAvailable": false,
            "remainingPlaytimeUnlimited": false,
            "clientId": clientId,
            "deviceId": deviceId,
        ]
        let progress = OPNSessionJSONParser.parseSessionProgress(from: session as NSDictionary)
        info["queuePosition"] = progress.queuePosition
        info["seatSetupStep"] = progress.seatSetupStep
        info["progressState"] = progress.progressState
        if progress.remainingPlaytimeAvailable {
            info["remainingPlaytimeHours"] = progress.remainingPlaytimeHours
            info["remainingPlaytimeAvailable"] = true
        }
        applyConnectionInfo(session, to: &info)
        if string(info["serverIp"]).isEmpty, let controlInfo = session["sessionControlInfo"] as? [String: Any] {
            info["serverIp"] = usableEndpointHost(string(controlInfo["ip"]))
        }
        return info
    }

    private func applyConnectionInfo(_ session: [String: Any], to info: inout [String: Any]) {
        var media: [String: Any] = ["ip": "", "port": 0]
        for connection in array(session["connectionInfo"]).compactMap({ $0 as? [String: Any] }) {
            let usage = int(connection["usage"])
            let ip = string(connection["ip"])
            let port = int(connection["port"])
            let resourcePath = string(connection["resourcePath"])
            if usage == 14, let serverIp = usableEndpointHost(ip).isEmpty ? extractHost(from: resourcePath) : usableEndpointHost(ip), !serverIp.isEmpty {
                info["serverIp"] = serverIp
                info["signalingServer"] = "\(serverIp):\(port > 0 ? port : 443)"
                if resourcePath.hasPrefix("rtsps://") {
                    let host = String(resourcePath.dropFirst(8)).split(separator: ":").first.map(String.init) ?? serverIp
                    info["signalingUrl"] = "wss://\(host)/nvst/"
                } else if resourcePath.hasPrefix("wss://") {
                    info["signalingUrl"] = resourcePath
                } else {
                    info["signalingUrl"] = "wss://\(serverIp):443\(resourcePath.isEmpty ? "/nvst/" : resourcePath)"
                }
                if port > 0 { media = ["ip": serverIp, "port": port] }
            }
            if usage == 2 {
                let mediaIp = usableEndpointHost(ip).isEmpty ? extractHost(from: resourcePath) : usableEndpointHost(ip)
                if let mediaIp, !mediaIp.isEmpty, port > 0 { media = ["ip": mediaIp, "port": port] }
            }
        }
        info["mediaConnectionInfo"] = media
    }

    private func negotiatedStreamProfile(from session: [String: Any]) -> [String: Any] {
        let parsed = OPNSessionJSONParser.parseNegotiatedStreamProfile(from: session as NSDictionary)
        return [
            "resolution": parsed.resolution,
            "fps": parsed.fps,
            "codec": parsed.codec,
            "colorQuality": parsed.colorQuality,
            "bitDepth": parsed.bitDepth,
            "chromaFormat": parsed.chromaFormat,
            "prefilterMode": parsed.prefilterMode,
            "prefilterSharpness": parsed.prefilterSharpness,
            "prefilterDenoise": parsed.prefilterDenoise,
            "prefilterModel": parsed.prefilterModel,
        ]
    }

    private func negotiatedStreamProfile(from session: [String: Any], applying initialProfile: [String: Any]) -> [String: Any] {
        var profile = initialProfile
        let negotiated = dictionary(session["negotiatedStreamProfile"])
        let resolution = string(negotiated["resolution"])
        if !resolution.isEmpty { profile["resolution"] = resolution }
        let codec = string(negotiated["codec"])
        if !codec.isEmpty { profile["codec"] = codec }
        if negotiated["fps"] != nil { profile["fps"] = int(negotiated["fps"]) }

        let features = dictionary(session["finalizedStreamingFeatures"])
        var colorChanged = false
        if features["bitDepth"] != nil {
            profile["bitDepth"] = int(features["bitDepth"], fallback: int(profile["bitDepth"], fallback: -1))
            colorChanged = true
        }
        if features["chromaFormat"] != nil {
            profile["chromaFormat"] = int(features["chromaFormat"], fallback: int(profile["chromaFormat"], fallback: -1))
            colorChanged = true
        }
        if colorChanged {
            profile["colorQuality"] = colorQuality(bitDepth: int(profile["bitDepth"], fallback: -1), chromaFormat: int(profile["chromaFormat"], fallback: -1))
        }
        if features["prefilterMode"] != nil { profile["prefilterMode"] = min(max(int(features["prefilterMode"]), 0), 2) }
        if features["prefilterSharpness"] != nil { profile["prefilterSharpness"] = min(max(int(features["prefilterSharpness"]), 0), 10) }
        if features["prefilterNoiseReduction"] != nil { profile["prefilterDenoise"] = min(max(int(features["prefilterNoiseReduction"]), 0), 10) }
        if features["prefilterModel"] != nil { profile["prefilterModel"] = max(int(features["prefilterModel"]), 0) }
        return profile
    }

    private func colorQuality(bitDepth: Int, chromaFormat: Int) -> String {
        let tenBit = bitDepth >= 10
        let fourFourFour = chromaFormat == 2
        if tenBit && fourFourFour { return "10bit_444" }
        if tenBit { return "10bit_420" }
        if fourFourFour { return "8bit_444" }
        return "8bit_420"
    }

    private func sessionAdState(from session: [String: Any]) -> [String: Any] {
        let parsed = OPNSessionJSONParser.parseSessionAdState(from: session as NSDictionary)
        return [
            "isAdsRequired": parsed.isAdsRequired,
            "sessionAdsRequired": parsed.sessionAdsRequired,
            "isQueuePaused": parsed.isQueuePaused,
            "serverSentEmptyAds": parsed.serverSentEmptyAds,
            "gracePeriodSeconds": parsed.gracePeriodSeconds,
            "message": parsed.message,
            "sessionAds": parsed.sessionAds.map { ad in
                [
                    "adId": ad.adId,
                    "adState": ad.adState,
                    "adUrl": ad.adUrl,
                    "mediaUrl": ad.mediaUrl,
                    "adMediaFiles": ad.adMediaFiles.map { ["mediaFileUrl": $0.mediaFileUrl, "encodingProfile": $0.encodingProfile] },
                    "clickThroughUrl": ad.clickThroughUrl,
                    "adLengthInSeconds": ad.adLengthInSeconds,
                    "durationMs": ad.durationMs,
                    "title": ad.title,
                    "description": ad.adDescription,
                ]
            },
        ]
    }

    private func iceServers(from session: [String: Any]) -> [[String: Any]] {
        array(session["iceServers"]).compactMap { item -> [String: Any]? in
            guard let dictionary = item as? [String: Any] else { return nil }
            let urls = array(dictionary["urls"]).compactMap { $0 as? String }
            var server: [String: Any] = ["urls": urls]
            let username = string(dictionary["username"])
            let credential = string(dictionary["credential"])
            if !username.isEmpty { server["username"] = username }
            if !credential.isEmpty { server["credential"] = credential }
            return server
        }
    }

    private func mergeAndStoreAdState(_ info: inout [String: Any]) {
        let sessionId = string(info["sessionId"])
        guard !sessionId.isEmpty else { return }
        lock.withLock {
            var adState = info["adState"] as? [String: Any] ?? [:]
            let previous = adStatesBySessionId[sessionId]
            if bool(adState["isAdsRequired"]), bool(adState["serverSentEmptyAds"]), array(adState["sessionAds"]).isEmpty, let previousAds = previous?["sessionAds"] {
                adState["sessionAds"] = previousAds
            }
            adStatesBySessionId[sessionId] = adState
            info["adState"] = adState
        }
    }

    private func activeSessionEntries(from sessions: [Any], streamingBaseUrl: String) -> [[String: Any]] {
        sessions.compactMap { item -> [String: Any]? in
            guard let session = item as? [String: Any] else { return nil }
            guard let descriptor = CloudMatchActiveSessionParser.descriptor(from: session, streamingBaseURL: streamingBaseUrl) else { return nil }
            return [
                "sessionId": descriptor.sessionId,
                "appId": descriptor.appId,
                "status": descriptor.status,
                "serverIp": descriptor.resumeServer,
                "gpuType": descriptor.gpuType,
                "streamingBaseUrl": descriptor.streamingBaseURL,
                "signalingUrl": descriptor.signalingURL,
            ]
        }
    }

    func selectSessionLimitReuseEntry(_ sessions: [[String: Any]], requestedAppId: Int) -> [String: Any]? {
        let validSessions = sessions.filter { int($0["appId"]) > 0 }
        return validSessions.first { int($0["appId"]) == requestedAppId && isReadyActiveSessionStatus(int($0["status"])) }
            ?? validSessions.first { isReadyActiveSessionStatus(int($0["status"])) }
            ?? validSessions.first { int($0["appId"]) == requestedAppId && int($0["status"]) == 1 }
            ?? validSessions.first { int($0["status"]) == 1 }
    }

    private func currentAccessToken() -> String { lock.withLock { accessToken } }
    private func currentStreamingBaseUrl() -> String { lock.withLock { streamingBaseUrl.isEmpty ? Self.defaultBaseUrl : streamingBaseUrl } }

    private func isReadyActiveSessionStatus(_ status: Int) -> Bool { CloudMatchSessionState(rawValue: status)?.isReadyForConnection == true }

    private func canContinuePollingActiveSessionStatus(_ status: Int) -> Bool { CloudMatchSessionState(rawValue: status)?.canContinuePolling == true }

    private func pollDelay(_ attempt: Int) -> TimeInterval {
        attempt <= 12 ? 0.3 : (attempt <= 20 ? 0.5 : 1.0)
    }

    private func logPollSessionSummary(httpStatus: Int, info: [String: Any]) {
        var summary = "status=\(int(info["status"])) sessionId=\(string(info["sessionId"]).prefix(8))"
        if httpStatus != 200 { summary += " http=\(httpStatus)" }
        let queuePosition = int(info["queuePosition"])
        if queuePosition > 0 { summary += " queue=\(queuePosition)" }
        if let adState = info["adState"] as? [String: Any], bool(adState["isAdsRequired"]) { summary += " ads=required" }
        OPNSentry.logInfoMessage(OPNSentry.formattedLogMessage(level: "info", area: "PollSession", message: summary))
    }

    private func storePersistedActiveSessionId(_ sessionId: String) {
        guard !sessionId.isEmpty else { return }
        let current = UserDefaults.standard.string(forKey: Self.persistedActiveSessionIdKey) ?? ""
        guard current != sessionId else { return }
        UserDefaults.standard.set(sessionId, forKey: Self.persistedActiveSessionIdKey)
        UserDefaults.standard.synchronize()
        OPNSentry.logInfoMessage(OPNSentry.formattedLogMessage(level: "info", area: "SessionManager", message: "Persisted active sessionId=\(sessionId)"))
    }

    private func clearPersistedActiveSessionId(_ sessionId: String) {
        let current = UserDefaults.standard.string(forKey: Self.persistedActiveSessionIdKey) ?? ""
        guard !current.isEmpty, sessionId.isEmpty || current == sessionId else { return }
        UserDefaults.standard.removeObject(forKey: Self.persistedActiveSessionIdKey)
        UserDefaults.standard.synchronize()
        OPNSentry.logInfoMessage(OPNSentry.formattedLogMessage(level: "info", area: "SessionManager", message: "Cleared persisted active sessionId=\(current)"))
    }
}

private final class OPNPollClaimSessionContext: @unchecked Sendable {
    fileprivate let manager: OPNSessionManager
    fileprivate let sessionId: String
    fileprivate let base: String
    fileprivate let token: String
    fileprivate let deviceId: String
    fileprivate let clientId: String
    fileprivate let initialProfile: [String: Any]
    private let completion: (Bool, [String: Any], String) -> Void
    private let maxRetries = 60

    init(manager: OPNSessionManager, sessionId: String, base: String, token: String, deviceId: String, clientId: String, initialProfile: [String: Any], completion: @escaping (Bool, [String: Any], String) -> Void) {
        self.manager = manager
        self.sessionId = sessionId
        self.base = base
        self.token = token
        self.deviceId = deviceId
        self.clientId = clientId
        self.initialProfile = initialProfile
        self.completion = completion
    }

    func poll(attempt: Int) {
        guard attempt < maxRetries else {
            complete(false, [:], "Timeout polling for session ready")
            return
        }
        guard var request = CloudMatchRequestFactory.pollSessionRequest(baseURLString: base, sessionId: sessionId, accessToken: token, deviceId: deviceId) else {
            complete(false, [:], "Invalid poll claim URL")
            return
        }
        let networkStart = OPNNetworkLog.start(&request, operation: "cloudmatch.pollClaimSession")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { [self] data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.pollClaimSession", startedAt: networkStart, data: data, response: response, error: error)
            manager.pollClaimSessionRequestFinished(context: self, attempt: attempt, data: data, error: error)
        }.resume()
    }

    func retry(after delay: TimeInterval, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in poll(attempt: attempt) }
    }

    func complete(_ success: Bool, _ session: [String: Any], _ error: String) {
        completion(success, session, error)
    }
}

private func settingsByApplyingCloudVariables(_ settings: [String: Any], capabilities: OPNStreamDeviceCapabilities) -> [String: Any] {
    let resolved = WebRTCMediaStreamSettingsResolver.resolve(
        profile: webRTCMediaProfile(from: settings),
        capabilities: webRTCMediaCapabilities(from: capabilities),
        cloudVariables: webRTCMediaCloudVariables(from: OPNStreamPreferences.loadCachedCloudVariables()),
        libWebRTCAvailable: true
    )
    var result = settings
    result.merge(resolved.dictionary(gameLanguage: string(settings["gameLanguage"]), accountLinked: bool(settings["accountLinked"], fallback: true), selectedStore: string(settings["selectedStore"]))) { _, new in new }
    return result
}

private func monitorSettings(_ settings: [String: Any], capabilities: OPNStreamDeviceCapabilities, hdrEnabled: Bool) -> [String: Any] {
    let parts = string(settings["resolution"]).split(separator: "x").compactMap { Int($0) }
    let width = max(640, parts.first ?? 1920)
    let height = max(360, parts.count > 1 ? parts[1] : 1080)
    return [
        "monitorId": 0,
        "positionX": 0,
        "positionY": 0,
        "widthInPixels": width,
        "heightInPixels": height,
        "framesPerSecond": int(settings["fps"], fallback: 60),
        "sdrHdrMode": hdrEnabled ? 1 : 0,
        "displayData": hdrEnabled && capabilities.hdrDisplaySupported ? ["desiredContentMaxLuminance": 1000, "desiredContentMinLuminance": 0, "desiredContentMaxFrameAverageLuminance": 400] : [:],
        "hdr10PlusGamingData": NSNull(),
        "dpi": max(0, capabilities.displayDpi),
    ]
}

private func requestedStreamingFeatures(_ settings: [String: Any], hdrEnabled: Bool) -> [String: Any] {
    let colorQuality = string(settings["colorQuality"])
    let bitDepth = colorQuality == "10bit_420" || colorQuality == "10bit_444" ? 1 : 0
    let chromaFormat = colorQuality == "8bit_444" || colorQuality == "10bit_444" ? 2 : 0
    return [
        "reflex": bool(settings["enableReflex"], fallback: true),
        "bitDepth": bitDepth,
        "cloudGsync": bool(settings["enableCloudGsync"]),
        "enabledL4S": bool(settings["enableL4S"]),
        "mouseMovementFlags": 0,
        "trueHdr": hdrEnabled,
        "supportedHidDevices": int(settings["supportedHidDevices"]),
        "profile": 0,
        "fallbackToLogicalResolution": false,
        "hidDevices": NSNull(),
        "chromaFormat": chromaFormat,
        "prefilterMode": min(max(int(settings["prefilterMode"]), 0), 2),
        "prefilterSharpness": min(max(int(settings["prefilterSharpness"]), 0), 10),
        "prefilterNoiseReduction": min(max(int(settings["prefilterDenoise"]), 0), 10),
        "prefilterModel": max(int(settings["prefilterModel"]), 0),
        "hudStreamingMode": 0,
        "sdrColorSpace": 2,
        "hdrColorSpace": 0,
    ]
}

private func clientDisplayHdrCapabilities(_ capabilities: OPNStreamDeviceCapabilities) -> [String: Any] {
    [
        "hdrSupported": capabilities.hdrDisplaySupported,
        "bitDepth": capabilities.hdrDisplaySupported ? 10 : 8,
        "maxDisplayWidth": max(0, capabilities.maxDisplayWidth),
        "maxDisplayHeight": max(0, capabilities.maxDisplayHeight),
        "maxDisplayRefreshRate": max(0, capabilities.maxDisplayRefreshRate),
        "supportedHdrModes": capabilities.hdrDisplaySupported ? ["HDR"] : [],
    ]
}

private func networkTestSessionIdValue(_ settings: [String: Any]) -> Any {
    let value = string(settings["networkTestSessionId"])
    return value.isEmpty ? NSNull() : value
}

private func networkTypeValue(_ settings: [String: Any]) -> String {
    let value = string(settings["networkType"])
    return value.isEmpty ? "Unknown" : value
}

private func networkLatencyValue(_ settings: [String: Any]) -> String {
    let latency = int(settings["networkLatencyMs"], fallback: -1)
    return latency >= 0 ? String(latency) : "Unknown"
}

private func adActionCode(_ action: String) -> Int {
    switch action {
    case "start": 1
    case "pause": 2
    case "resume": 3
    case "finish": 4
    case "cancel": 5
    default: 0
    }
}

private func extractHost(from value: String) -> String? {
    guard !value.isEmpty else { return nil }
    if let host = URL(string: value)?.host, !host.isEmpty { return host }
    for prefix in ["rtsps://", "rtsp://", "wss://", "https://"] where value.hasPrefix(prefix) {
        let remainder = String(value.dropFirst(prefix.count))
        let end = remainder.firstIndex(where: { $0 == ":" || $0 == "/" }) ?? remainder.endIndex
        let host = String(remainder[..<end])
        return host.isEmpty || host.hasPrefix(".") ? nil : host
    }
    return nil
}

private func usableEndpointHost(_ host: String) -> String {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let hostname = trimmed.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
    guard !trimmed.isEmpty, !hostname.isEmpty, !hostname.hasPrefix("."), !hostname.hasSuffix("."), !trimmed.contains("/") else { return "" }
    guard hostname.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }) else { return "" }
    return trimmed
}

private func isValidSessionId(_ sessionId: String) -> Bool {
    !sessionId.isEmpty && sessionId.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7f }
}

private func escapedLogString(_ value: String) -> String {
    value.isEmpty ? "(empty)" : value
}

private func dictionary(_ value: Any?) -> [String: Any] {
    value as? [String: Any] ?? [:]
}

private func array(_ value: Any?) -> [Any] {
    value as? [Any] ?? []
}

private func stringArray(_ value: Any?) -> [String] {
    if let value = value as? String { return value.isEmpty ? [] : [value] }
    if let value = value as? [String] { return value }
    if let value = value as? NSArray { return value.compactMap { string($0) }.filter { !$0.isEmpty } }
    return []
}

private func string(_ value: Any?) -> String {
    if let value = value as? String { return value }
    if let value = value as? NSString { return value as String }
    if let value = value as? NSNumber { return value.stringValue }
    return ""
}

private func int(_ value: Any?, fallback: Int = 0) -> Int {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) ?? fallback }
    return fallback
}

private func double(_ value: Any?, fallback: Double = 0.0) -> Double {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) ?? fallback }
    return fallback
}

private func bool(_ value: Any?, fallback: Bool = false) -> Bool {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String { return (value as NSString).boolValue }
    return fallback
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
