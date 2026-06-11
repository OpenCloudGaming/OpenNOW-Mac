@preconcurrency import Foundation

final class OPNSessionManager: NSObject, @unchecked Sendable {
    static let shared = OPNSessionManager()

    private let lock = NSLock()
    private var accessToken = ""
    private var streamingBaseUrl = defaultBaseUrl
    private var adStatesBySessionId: [String: [String: Any]] = [:]

    private static let defaultBaseUrl = "https://prod.cloudmatchbeta.nvidiagrid.net"
    private static let nvClientId = "ec7e38d4-03af-4b58-b131-cfb0495903ab"
    private static let nvClientVersion = "2.0.80.173"
    private static let persistedActiveSessionIdKey = "OpenNOW.Stream.ActiveSessionId"

    func setAccessToken(_ token: String) {
        lock.withLock { accessToken = token }
    }

    func setStreamingBaseUrl(_ url: String) {
        lock.withLock { streamingBaseUrl = resolveSessionBaseUrl(streamingBaseUrl: url, serverIp: "") }
    }

    func createSession(appId: String, internalTitle: String, settings: [String: Any], completion: @escaping (Bool, [String: Any], String) -> Void) {
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
        let effectiveSettings = settingsByApplyingCloudVariables(settings, requestedCodec: string(settings["codec"]), capabilities: capabilities)
        let hdrEnabled = bool(effectiveSettings["enableHdr"]) && capabilities.hdrDisplaySupported
        let timezoneOffset = -TimeZone.current.secondsFromGMT() * 1000
        let selectedStore = string(effectiveSettings["selectedStore"]).isEmpty ? "unknown" : string(effectiveSettings["selectedStore"])

        OPNSentry.logInfoMessage("[SessionManager] CreateSession called with appId=\(appId) codec=\(string(effectiveSettings["codec"])) color=\(string(effectiveSettings["colorQuality"])) bitrate=\(int(effectiveSettings["maxBitrateMbps"], fallback: 50))Mbps l4s=\(bool(effectiveSettings["enableL4S"]) ? "on" : "off")")

        let sessionRequestData: [String: Any] = [
            "appId": appId,
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
        guard let url = URL(string: "\(baseUrl)/v2/session?keyboardLayout=\(layout)&languageCode=\(language)") else {
            completion(false, [:], "Invalid session create URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyCommonCloudMatchHeaders(to: &request, token: token, deviceId: deviceId, includeOrigin: false)
        request.setValue("https://play.geforcenow.com", forHTTPHeaderField: "Origin")
        let body: [String: Any] = ["sessionRequestData": sessionRequestData]
        OPNProtocolDebug.logJSONObject(label: "session create request", object: body)
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(false, [:], "Failed to encode session create request")
            return
        }

        nonisolated(unsafe) let createCompletion = completion
        nonisolated(unsafe) let createEffectiveSettings = effectiveSettings
        let trace = OPNSentry.traceHTTPRequest(NSMutableURLRequest(url: url), name: "Cloudmatch create session")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                trace?.setStatus(false)
                trace?.finish()
                createCompletion(false, [:], error.localizedDescription)
                return
            }
            guard let data else {
                trace?.setStatus(false)
                trace?.finish()
                createCompletion(false, [:], "No session response")
                return
            }
            OPNProtocolDebug.logJSONData(label: "session create response", data: data)
            let http = response as? HTTPURLResponse
            guard http?.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                let errorMessage = "HTTP \(http?.statusCode ?? 0): \(body)"
                if let json = self.jsonDictionary(data), self.isSessionLimitExceededResponse(json), let selected = self.selectSessionLimitReuseEntry(self.activeSessionEntries(from: array(json["otherUserSessions"]), streamingBaseUrl: baseUrl), requestedAppId: Int(appId) ?? 0) {
                    trace?.setStatus(true)
                    trace?.finish()
                    if self.isReadyActiveSessionStatus(int(selected["status"])) {
                        self.claimSession(sessionId: string(selected["sessionId"]), serverIp: string(selected["serverIp"]), appId: string(selected["appId"]).isEmpty ? appId : string(selected["appId"]), settings: createEffectiveSettings, recoveryMode: true, completion: createCompletion)
                    } else {
                        self.pollClaimSession(sessionId: string(selected["sessionId"]), serverIp: string(selected["serverIp"]), deviceId: deviceId, clientId: clientId, initialProfile: [:], completion: createCompletion)
                    }
                    return
                }
                trace?.setStatus(false)
                trace?.finish()
                createCompletion(false, [:], errorMessage)
                return
            }
            guard let json = self.jsonDictionary(data), self.requestSucceeded(json) else {
                trace?.setStatus(false)
                trace?.finish()
                createCompletion(false, [:], self.requestStatusError(data: data, fallback: "Failed to parse session response"))
                return
            }
            guard let session = json["session"] as? [String: Any] else {
                trace?.setStatus(false)
                trace?.finish()
                createCompletion(false, [:], "No session in response")
                return
            }
            var info = self.sessionInfo(from: session, requestedSessionId: "", baseUrl: baseUrl, clientId: clientId, deviceId: deviceId, initialProfile: [:])
            self.mergeAndStoreAdState(&info)
            trace?.setStatus(true)
            trace?.finish()
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
        let base = resolveSessionBaseUrl(streamingBaseUrl: currentStreamingBaseUrl(), serverIp: serverIp)
        guard let url = URL(string: "\(base)/v2/session/\(sessionId)") else {
            completion(false, [:], "Invalid poll URL")
            return
        }
        var request = URLRequest(url: url)
        applyCommonCloudMatchHeaders(to: &request, token: token, deviceId: OPNDeviceIdentity.stableCloudmatchDeviceId(), includeOrigin: false)
        nonisolated(unsafe) let completion = completion
        let trace = OPNSentry.traceHTTPRequest(NSMutableURLRequest(url: url), name: "Cloudmatch poll session")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                trace?.setStatus(false)
                trace?.finish()
                completion(false, [:], error.localizedDescription)
                return
            }
            guard let data, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                trace?.setStatus(false)
                trace?.finish()
                completion(false, [:], "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
                return
            }
            guard let json = self.jsonDictionary(data), let session = json["session"] as? [String: Any] else {
                trace?.setStatus(false)
                trace?.finish()
                completion(false, [:], "No session in poll response")
                return
            }
            var info = self.sessionInfo(from: session, requestedSessionId: sessionId, baseUrl: base, clientId: "", deviceId: "", initialProfile: [:])
            guard string(info["sessionId"]) == sessionId else {
                trace?.setStatus(false)
                trace?.finish()
                completion(false, [:], "SESSION_ID_MISMATCH: requested \(escapedLogString(sessionId)) but response contained \(escapedLogString(string(info["sessionId"])))")
                return
            }
            self.mergeAndStoreAdState(&info)
            self.logPollSessionSummary(httpStatus: http.statusCode, info: info)
            trace?.setStatus(true)
            trace?.finish()
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
        let base = resolveSessionBaseUrl(streamingBaseUrl: currentStreamingBaseUrl(), serverIp: serverIp)
        guard let url = URL(string: "\(base)/v2/session/\(sessionId)") else {
            completion(false, "Invalid stop session URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyCommonCloudMatchHeaders(to: &request, token: token, deviceId: OPNDeviceIdentity.stableCloudmatchDeviceId(), includeOrigin: true)
        nonisolated(unsafe) let completion = completion
        let trace = OPNSentry.traceHTTPRequest(NSMutableURLRequest(url: url), name: "Cloudmatch stop session")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                trace?.setStatus(false)
                trace?.finish()
                completion(false, error.localizedDescription)
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                trace?.setStatus(false)
                trace?.finish()
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(false, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
                return
            }
            trace?.setStatus(true)
            trace?.finish()
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
        guard let url = URL(string: "\(base)/v2/session") else {
            completion(false, [], "Invalid sessions URL")
            return
        }
        var request = URLRequest(url: url)
        applyCommonCloudMatchHeaders(to: &request, token: token, deviceId: OPNDeviceIdentity.stableCloudmatchDeviceId(), includeOrigin: false)
        nonisolated(unsafe) let completion = completion
        let trace = OPNSentry.traceHTTPRequest(NSMutableURLRequest(url: url), name: "Cloudmatch active sessions")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                trace?.setStatus(false)
                trace?.finish()
                completion(false, [], error.localizedDescription)
                return
            }
            guard let data, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                trace?.setStatus(false)
                trace?.finish()
                completion(false, [], "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return
            }
            guard let json = self.jsonDictionary(data), self.requestSucceeded(json) else {
                trace?.setStatus(false)
                trace?.finish()
                completion(false, [], "API error from sessions endpoint")
                return
            }
            trace?.setStatus(true)
            trace?.finish()
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
        let base = resolveSessionBaseUrl(streamingBaseUrl: string(session["streamingBaseUrl"]).isEmpty ? currentStreamingBaseUrl() : string(session["streamingBaseUrl"]), serverIp: string(session["serverIp"]))
        guard let url = URL(string: "\(base)/v2/session/\(sessionId)") else {
            completion(false, [:], "Invalid ad update URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        applyCommonCloudMatchHeaders(to: &request, token: token, deviceId: string(session["deviceId"]).isEmpty ? OPNDeviceIdentity.stableCloudmatchDeviceId() : string(session["deviceId"]), includeOrigin: true)
        var adUpdate: [String: Any] = ["adId": adId, "adAction": actionCode, "clientTimestamp": Int(Date().timeIntervalSince1970)]
        if watchedTimeInMs >= 0 { adUpdate["watchedTimeInMs"] = watchedTimeInMs }
        if pausedTimeInMs >= 0 { adUpdate["pausedTimeInMs"] = pausedTimeInMs }
        if !cancelReason.isEmpty { adUpdate["cancelReason"] = cancelReason }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["action": 6, "adUpdates": [adUpdate]])
        } catch {
            completion(false, [:], "Failed to encode ad update request")
            return
        }
        nonisolated(unsafe) let completion = completion
        nonisolated(unsafe) let adSession = session
        let trace = OPNSentry.traceHTTPRequest(NSMutableURLRequest(url: url), name: "Cloudmatch report session ad")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                trace?.setStatus(false)
                trace?.finish()
                completion(false, [:], error.localizedDescription)
                return
            }
            guard let data, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                trace?.setStatus(false)
                trace?.finish()
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(false, [:], "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
                return
            }
            guard let json = self.jsonDictionary(data), self.requestSucceeded(json) else {
                trace?.setStatus(false)
                trace?.finish()
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
            trace?.setStatus(true)
            trace?.finish()
            completion(true, updated, "")
        }.resume()
    }

    func claimSession(sessionId: String, serverIp: String, appId: String, settings: [String: Any], recoveryMode: Bool, completion: @escaping (Bool, [String: Any], String) -> Void) {
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
        let base = resolveSessionBaseUrl(streamingBaseUrl: currentStreamingBaseUrl(), serverIp: serverIp)
        guard let validationUrl = URL(string: "\(base)/v2/session/\(sessionId)") else {
            completion(false, [:], "Invalid validation URL")
            return
        }
        OPNSentry.logInfoMessage("[ClaimSession] Starting claim sessionId=\(sessionId) serverIp=\(serverIp) appId=\(appId) codec=\(string(settings["codec"])) color=\(string(settings["colorQuality"])) bitrate=\(int(settings["maxBitrateMbps"], fallback: 50))Mbps l4s=\(bool(settings["enableL4S"]) ? "on" : "off") recovery=\(recoveryMode)")
        var validationRequest = URLRequest(url: validationUrl)
        validationRequest.timeoutInterval = 30
        applyCommonCloudMatchHeaders(to: &validationRequest, token: token, deviceId: deviceId, includeOrigin: false)
        nonisolated(unsafe) let completion = completion
        nonisolated(unsafe) let claimSettings = settings
        let validationTrace = OPNSentry.traceHTTPRequest(NSMutableURLRequest(url: validationUrl), name: "Cloudmatch validate session claim")
        URLSession.shared.dataTask(with: validationRequest) { [weak self] data, response, error in
            guard let self else { return }
            var preClaimStatus = 0
            if let error {
                OPNSentry.logErrorMessage("[ClaimSession] Validation request failed: \(error.localizedDescription)")
                validationTrace?.setStatus(false)
                validationTrace?.finish()
            } else if let data {
                let json = self.jsonDictionary(data)
                let session = json?["session"] as? [String: Any]
                preClaimStatus = int(session?["status"])
                let requestStatus = json?["requestStatus"] as? [String: Any]
                let statusCode = int(requestStatus?["statusCode"])
                let http = response as? HTTPURLResponse
                if (http?.statusCode ?? 0) >= 400 || (statusCode != 0 && statusCode != 1 && preClaimStatus == 0) {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    validationTrace?.setStatus(false)
                    validationTrace?.finish()
                    completion(false, [:], "STALE_ACTIVE_SESSION: validation HTTP \(http?.statusCode ?? 0): \(body)")
                    return
                }
                validationTrace?.setStatus(true)
                validationTrace?.finish()
            } else {
                validationTrace?.setStatus(false)
                validationTrace?.finish()
            }
            if preClaimStatus == 1 || self.isReadyActiveSessionStatus(preClaimStatus) {
                self.pollClaimSession(sessionId: sessionId, serverIp: serverIp, deviceId: deviceId, clientId: clientId, initialProfile: [:], completion: completion)
                return
            }
            self.sendClaimSession(sessionId: sessionId, serverIp: serverIp, appId: appId, settings: claimSettings, token: token, deviceId: deviceId, clientId: clientId, completion: completion)
        }.resume()
    }

    private func sendClaimSession(sessionId: String, serverIp: String, appId: String, settings: [String: Any], token: String, deviceId: String, clientId: String, completion: @escaping (Bool, [String: Any], String) -> Void) {
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        let hdrEnabled = bool(settings["enableHdr"]) && capabilities.hdrDisplaySupported
        let selectedStore = string(settings["selectedStore"]).isEmpty ? "unknown" : string(settings["selectedStore"])
        let payload: [String: Any] = [
            "action": 2,
            "data": "MANUAL",
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
                "appId": Int(appId) ?? 0,
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
        let base = resolveSessionBaseUrl(streamingBaseUrl: currentStreamingBaseUrl(), serverIp: serverIp)
        guard let url = URL(string: "\(base)/v2/session/\(sessionId)?keyboardLayout=\(layout)&languageCode=\(language)") else {
            completion(false, [:], "Invalid claim URL")
            return
        }
        OPNProtocolDebug.logJSONObject(label: "session claim request", object: payload)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpMethod = "PUT"
        applyCommonCloudMatchHeaders(to: &request, token: token, deviceId: deviceId, includeOrigin: true)
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(false, [:], "Failed to encode claim request")
            return
        }
        nonisolated(unsafe) let completion = completion
        let trace = OPNSentry.traceHTTPRequest(NSMutableURLRequest(url: url), name: "Cloudmatch claim session")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                trace?.setStatus(false)
                trace?.finish()
                completion(false, [:], error.localizedDescription)
                return
            }
            guard let data else {
                trace?.setStatus(false)
                trace?.finish()
                completion(false, [:], "No claim response")
                return
            }
            OPNProtocolDebug.logJSONData(label: "session claim response", data: data)
            let body = String(data: data, encoding: .utf8) ?? ""
            let http = response as? HTTPURLResponse
            guard http?.statusCode == 200 else {
                trace?.setStatus(false)
                trace?.finish()
                if body.contains("SESSION_NOT_PAUSED") || body.contains("\"statusCode\":34") {
                    self.pollClaimSession(sessionId: sessionId, serverIp: serverIp, deviceId: deviceId, clientId: clientId, initialProfile: [:], completion: completion)
                    return
                }
                completion(false, [:], "Claim HTTP \(http?.statusCode ?? 0): \(body)")
                return
            }
            guard let json = self.jsonDictionary(data), self.requestSucceeded(json) else {
                let requestStatus = self.jsonDictionary(data)?["requestStatus"] as? [String: Any]
                let statusCode = int(requestStatus?["statusCode"])
                let description = string(requestStatus?["statusDescription"])
                if description.contains("SESSION_NOT_PAUSED") || statusCode == 34 {
                    trace?.setStatus(true)
                    trace?.finish()
                    self.pollClaimSession(sessionId: sessionId, serverIp: serverIp, deviceId: deviceId, clientId: clientId, initialProfile: [:], completion: completion)
                    return
                }
                trace?.setStatus(false)
                trace?.finish()
                completion(false, [:], "Claim API error \(statusCode): \(description.isEmpty ? "unknown" : description)")
                return
            }
            trace?.setStatus(true)
            trace?.finish()
            let claimProfile = (json["session"] as? [String: Any]).map { self.negotiatedStreamProfile(from: $0) } ?? [:]
            self.pollClaimSession(sessionId: sessionId, serverIp: serverIp, deviceId: deviceId, clientId: clientId, initialProfile: claimProfile, completion: completion)
        }.resume()
    }

    private func pollClaimSession(sessionId: String, serverIp: String, deviceId: String, clientId: String, initialProfile: [String: Any], completion: @escaping (Bool, [String: Any], String) -> Void) {
        OPNPollClaimSessionContext(manager: self,
                                   sessionId: sessionId,
                                   base: resolveSessionBaseUrl(streamingBaseUrl: currentStreamingBaseUrl(), serverIp: serverIp),
                                   token: currentAccessToken(),
                                   deviceId: deviceId,
                                   clientId: clientId,
                                   initialProfile: initialProfile,
                                   completion: completion).poll(attempt: 0)
    }

    fileprivate func pollClaimSessionRequestFinished(context: OPNPollClaimSessionContext, attempt: Int, data: Data?, error: Error?) {
        guard error == nil, let data, let json = jsonDictionary(data), let session = json["session"] as? [String: Any] else {
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
        } else if status == 1 || status == 6 {
            context.retry(after: pollDelay(attempt), attempt: attempt + 1)
        } else {
            context.complete(false, [:], "Session in terminal error state")
        }
    }

    private func sessionInfo(from session: [String: Any], requestedSessionId: String, baseUrl: String, clientId: String, deviceId: String, initialProfile: [String: Any]) -> [String: Any] {
        let responseSessionId = string(session["sessionId"])
        let resolvedSessionId = responseSessionId.isEmpty ? requestedSessionId : responseSessionId
        if !resolvedSessionId.isEmpty { storePersistedActiveSessionId(resolvedSessionId) }
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
            "negotiatedStreamProfile": initialProfile.isEmpty ? negotiatedStreamProfile(from: session) : initialProfile,
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
        if initialProfile.isEmpty { info["negotiatedStreamProfile"] = negotiatedStreamProfile(from: session) }
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
            let sessionId = string(session["sessionId"])
            let status = int(session["status"])
            guard !sessionId.isEmpty, isReusableActiveSessionStatus(status) else { return nil }
            var streamingHost = ""
            for connection in array(session["connectionInfo"]).compactMap({ $0 as? [String: Any] }) where int(connection["usage"]) == 14 {
                let ip = usableEndpointHost(string(connection["ip"]))
                if !ip.isEmpty {
                    streamingHost = ip
                    break
                }
                if let host = extractHost(from: string(connection["resourcePath"])), !host.isEmpty {
                    streamingHost = host
                    break
                }
            }
            let controlInfo = session["sessionControlInfo"] as? [String: Any]
            let serverIp = string(controlInfo?["ip"]).isEmpty ? streamingHost : string(controlInfo?["ip"])
            guard !serverIp.isEmpty else { return nil }
            let requestData = session["sessionRequestData"] as? [String: Any]
            return [
                "sessionId": sessionId,
                "appId": int(requestData?["appId"]),
                "status": status,
                "serverIp": serverIp,
                "gpuType": string(session["gpuType"]),
                "streamingBaseUrl": streamingBaseUrl,
                "signalingUrl": streamingHost.isEmpty ? "" : "wss://\(streamingHost):443/nvst/",
            ]
        }
    }

    private func selectSessionLimitReuseEntry(_ sessions: [[String: Any]], requestedAppId: Int) -> [String: Any]? {
        sessions.first { int($0["appId"]) == requestedAppId && isReadyActiveSessionStatus(int($0["status"])) }
            ?? sessions.first { isReadyActiveSessionStatus(int($0["status"])) }
            ?? sessions.first { int($0["appId"]) == requestedAppId && int($0["status"]) == 1 }
            ?? sessions.first { int($0["status"]) == 1 }
    }

    private func currentAccessToken() -> String { lock.withLock { accessToken } }
    private func currentStreamingBaseUrl() -> String { lock.withLock { streamingBaseUrl.isEmpty ? Self.defaultBaseUrl : streamingBaseUrl } }

    private func requestSucceeded(_ json: [String: Any]) -> Bool {
        int((json["requestStatus"] as? [String: Any])?["statusCode"]) == 1
    }

    private func requestStatusError(data: Data, fallback: String) -> String {
        guard let json = jsonDictionary(data), let status = json["requestStatus"] as? [String: Any] else { return fallback }
        return "API error \(int(status["statusCode"])): \(string(status["statusDescription"]).isEmpty ? "unknown" : string(status["statusDescription"]))"
    }

    private func jsonDictionary(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func isSessionLimitExceededResponse(_ json: [String: Any]) -> Bool {
        let requestStatus = json["requestStatus"] as? [String: Any]
        let statusCode = int(requestStatus?["statusCode"])
        let description = string(requestStatus?["statusDescription"])
        return statusCode == 11 || description.contains("SESSION_LIMIT")
    }

    private func isReusableActiveSessionStatus(_ status: Int) -> Bool { [1, 2, 3, 6].contains(status) }
    private func isReadyActiveSessionStatus(_ status: Int) -> Bool { status == 2 || status == 3 }

    private func pollDelay(_ attempt: Int) -> TimeInterval {
        attempt <= 12 ? 0.3 : (attempt <= 20 ? 0.5 : 1.0)
    }

    private func logPollSessionSummary(httpStatus: Int, info: [String: Any]) {
        var summary = "[PollSession] status=\(int(info["status"])) \(string(info["sessionId"]).prefix(8))"
        if httpStatus != 200 { summary += " http=\(httpStatus)" }
        let queuePosition = int(info["queuePosition"])
        if queuePosition > 0 { summary += " queue=\(queuePosition)" }
        if let adState = info["adState"] as? [String: Any], bool(adState["isAdsRequired"]) { summary += " ads=required" }
        OPNSentry.logInfoMessage(summary)
    }

    private func storePersistedActiveSessionId(_ sessionId: String) {
        guard !sessionId.isEmpty else { return }
        let current = UserDefaults.standard.string(forKey: Self.persistedActiveSessionIdKey) ?? ""
        guard current != sessionId else { return }
        UserDefaults.standard.set(sessionId, forKey: Self.persistedActiveSessionIdKey)
        UserDefaults.standard.synchronize()
        OPNSentry.logInfoMessage("[SessionManager] Persisted active sessionId=\(sessionId)")
    }

    private func clearPersistedActiveSessionId(_ sessionId: String) {
        let current = UserDefaults.standard.string(forKey: Self.persistedActiveSessionIdKey) ?? ""
        guard !current.isEmpty, sessionId.isEmpty || current == sessionId else { return }
        UserDefaults.standard.removeObject(forKey: Self.persistedActiveSessionIdKey)
        UserDefaults.standard.synchronize()
        OPNSentry.logInfoMessage("[SessionManager] Cleared persisted active sessionId=\(current)")
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
        guard let url = URL(string: "\(base)/v2/session/\(sessionId)") else {
            complete(false, [:], "Invalid poll claim URL")
            return
        }
        var request = URLRequest(url: url)
        applyCommonCloudMatchHeaders(to: &request, token: token, deviceId: deviceId, includeOrigin: false)
        let trace = OPNSentry.traceHTTPRequest(NSMutableURLRequest(url: url), name: "Cloudmatch poll claim session")
        URLSession.shared.dataTask(with: request) { [self] data, _, error in
            trace?.setStatus(error == nil && data != nil)
            trace?.finish()
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

private func applyCommonCloudMatchHeaders(to request: inout URLRequest, token: String, deviceId: String, includeOrigin: Bool) {
    request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
    request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("ec7e38d4-03af-4b58-b131-cfb0495903ab", forHTTPHeaderField: "nv-client-id")
    request.setValue("NATIVE", forHTTPHeaderField: "nv-client-type")
    request.setValue("2.0.80.173", forHTTPHeaderField: "nv-client-version")
    request.setValue("NVIDIA-CLASSIC", forHTTPHeaderField: "nv-client-streamer")
    request.setValue("MACOS", forHTTPHeaderField: "nv-device-os")
    request.setValue("DESKTOP", forHTTPHeaderField: "nv-device-type")
    request.setValue("UNKNOWN", forHTTPHeaderField: "nv-device-make")
    request.setValue("UNKNOWN", forHTTPHeaderField: "nv-device-model")
    request.setValue("CHROME", forHTTPHeaderField: "nv-browser-type")
    request.setValue(deviceId, forHTTPHeaderField: "x-device-id")
    if includeOrigin {
        request.setValue("https://play.geforcenow.com", forHTTPHeaderField: "Origin")
        request.setValue("https://play.geforcenow.com/", forHTTPHeaderField: "Referer")
    }
}

private func resolveSessionBaseUrl(streamingBaseUrl: String, serverIp: String) -> String {
    func normalizedHTTPSBaseUrl(_ url: String) -> String {
        guard !url.isEmpty, let components = URLComponents(string: url), components.scheme?.lowercased() == "https", let host = components.host, !usableEndpointHost(host).isEmpty else { return "" }
        return url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    let fallbackBase = normalizedHTTPSBaseUrl(streamingBaseUrl)
    if serverIp.isEmpty {
        return fallbackBase.isEmpty ? "https://prod.cloudmatchbeta.nvidiagrid.net" : fallbackBase
    }
    if serverIp.hasPrefix("https://") || serverIp.hasPrefix("http://") {
        let base = normalizedHTTPSBaseUrl(serverIp)
        return base.isEmpty ? (fallbackBase.isEmpty ? "https://prod.cloudmatchbeta.nvidiagrid.net" : fallbackBase) : base
    }
    let host = usableEndpointHost(serverIp)
    return host.isEmpty ? (fallbackBase.isEmpty ? "https://prod.cloudmatchbeta.nvidiagrid.net" : fallbackBase) : "https://\(host)"
}

private func userAgent() -> String {
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173"
}

private func settingsByApplyingCloudVariables(_ settings: [String: Any], requestedCodec: String, capabilities: OPNStreamDeviceCapabilities) -> [String: Any] {
    var typed = OPNStreamSettings()
    typed.resolution = string(settings["resolution"]).isEmpty ? typed.resolution : string(settings["resolution"])
    typed.fps = int(settings["fps"], fallback: typed.fps)
    typed.codec = string(settings["codec"]).isEmpty ? typed.codec : string(settings["codec"])
    typed.colorQuality = string(settings["colorQuality"]).isEmpty ? typed.colorQuality : string(settings["colorQuality"])
    typed.maxBitrateMbps = int(settings["maxBitrateMbps"], fallback: typed.maxBitrateMbps)
    typed.prefilterMode = int(settings["prefilterMode"])
    typed.prefilterSharpness = int(settings["prefilterSharpness"])
    typed.prefilterDenoise = int(settings["prefilterDenoise"])
    typed.prefilterModel = int(settings["prefilterModel"])
    typed.enableCloudGsync = bool(settings["enableCloudGsync"])
    typed.enableL4S = bool(settings["enableL4S"])
    typed.enableReflex = bool(settings["enableReflex"], fallback: true)
    typed.lowLatencyMode = bool(settings["lowLatencyMode"])
    typed.enableHdr = bool(settings["enableHdr"])
    typed.microphoneMode = string(settings["microphoneMode"])
    typed.microphoneDeviceId = string(settings["microphoneDeviceId"])
    typed.microphonePushToTalkKeyCode = int(settings["microphonePushToTalkKeyCode"], fallback: 9)
    typed.microphonePushToTalkModifierMask = int(settings["microphonePushToTalkModifierMask"])
    typed.gameVolume = double(settings["gameVolume"], fallback: 1.0)
    typed.microphoneVolume = double(settings["microphoneVolume"], fallback: 1.0)
    typed.keyboardLayout = string(settings["keyboardLayout"])
    typed.gameLanguage = string(settings["gameLanguage"])
    typed.accountLinked = bool(settings["accountLinked"], fallback: true)
    typed.selectedStore = string(settings["selectedStore"])
    typed.networkTestSessionId = string(settings["networkTestSessionId"])
    typed.networkType = string(settings["networkType"])
    typed.networkLatencyMs = int(settings["networkLatencyMs"], fallback: -1)
    typed.remoteControllersBitmap = UInt32(int(settings["remoteControllersBitmap"]))
    typed.supportedHidDevices = UInt32(int(settings["supportedHidDevices"]))
    typed.availableSupportedControllers = stringArray(settings["availableSupportedControllers"])
    let applied = OPNStreamPreferences.settingsByApplyingCloudVariables(typed, variables: OPNStreamPreferences.loadCachedCloudVariables(), capabilities: capabilities)
    var result = settings
    result["resolution"] = applied.resolution
    result["fps"] = applied.fps
    result["codec"] = requestedCodec.isEmpty ? applied.codec : requestedCodec
    result["colorQuality"] = applied.colorQuality
    result["maxBitrateMbps"] = applied.maxBitrateMbps
    result["prefilterMode"] = applied.prefilterMode
    result["prefilterSharpness"] = applied.prefilterSharpness
    result["prefilterDenoise"] = applied.prefilterDenoise
    result["prefilterModel"] = applied.prefilterModel
    result["enableL4S"] = applied.enableL4S
    result["enableHdr"] = applied.enableHdr
    result["enableReflex"] = applied.enableReflex
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
        "displayData": hdrEnabled && capabilities.hdrDisplaySupported ? ["desiredContentMaxLuminance": 1000, "desiredContentMinLuminance": 0, "desiredContentMaxFrameAverageLuminance": 400] : NSNull(),
        "hdr10PlusGamingData": NSNull(),
        "dpi": max(0, capabilities.displayDpi),
    ]
}

private func requestedStreamingFeatures(_ settings: [String: Any], hdrEnabled: Bool) -> [String: Any] {
    let colorQuality = string(settings["colorQuality"])
    let bitDepth = colorQuality == "10bit_420" || colorQuality == "10bit_444" ? 10 : 0
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

private func dictionary(_ value: NSDictionary) -> [String: Any] {
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
