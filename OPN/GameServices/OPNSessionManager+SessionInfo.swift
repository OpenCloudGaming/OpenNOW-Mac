//
//  OPNSessionManager+SessionInfo.swift
//  OpenNOW
//
//  Reading a seat's session payload: connection info, the negotiated stream profile, ad state
//  and the small status predicates around them. Split out of OPNSessionManager.swift.
//

@preconcurrency import Foundation

extension OPNSessionManager {
    func sessionInfo(from session: [String: Any], requestedSessionId: String, baseUrl: String, clientId: String, deviceId: String, initialProfile: [String: Any]) -> [String: Any] {
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
            "signalingQueryParameters": "",
            "signalingHeaders": [],
            "iceServers": iceServers(from: session),
            "gpuType": string(session["gpuType"]),
            "mediaConnectionInfo": ["ip": "", "port": 0],
            "negotiatedStreamProfile": streamProfile,
            "adState": sessionAdState(from: session),
            "remainingPlaytimeHours": 0.0,
            "remainingPlaytimeAvailable": false,
            "remainingPlaytimeUnlimited": false,
            "remainingSessionLimitSeconds": 0,
            "clientId": clientId,
            "deviceId": deviceId,
            "rawSessionJSON": rawSessionJSON(session),
        ]
        let progress = OPNSessionJSONParser.parseSessionProgress(from: session as NSDictionary)
        info["queuePosition"] = progress.queuePosition
        info["seatSetupStep"] = progress.seatSetupStep
        info["progressState"] = progress.progressState
        if progress.remainingPlaytimeAvailable {
            info["remainingPlaytimeHours"] = progress.remainingPlaytimeHours
            info["remainingPlaytimeAvailable"] = true
        }
        info["remainingSessionLimitSeconds"] = progress.remainingSessionLimitSeconds
        applyConnectionInfo(session, to: &info)
        if string(info["serverIp"]).isEmpty, let controlInfo = session["sessionControlInfo"] as? [String: Any] {
            info["serverIp"] = usableEndpointHost(string(controlInfo["ip"]))
        }
        return info
    }

    func rawSessionJSON(_ session: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(session),
              let data = try? JSONSerialization.data(withJSONObject: session),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    func applyConnectionInfo(_ session: [String: Any], to info: inout [String: Any]) {
        var signalingMediaFallback: [String: Any] = ["ip": "", "port": 0]
        var videoMedia: [String: Any]?
        var bundledMedia: [String: Any]?
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
                info["signalingQueryParameters"] = string(connection["queryParameters"])
                info["signalingHeaders"] = signalingHeaderTokens(from: connection["headers"])
                if port > 0 { signalingMediaFallback = ["ip": serverIp, "port": port] }
            }
            if usage == 2 || usage == 17 {
                let mediaIp = usableEndpointHost(ip).isEmpty ? extractHost(from: resourcePath) : usableEndpointHost(ip)
                if let mediaIp, !mediaIp.isEmpty, port > 0 {
                    let candidate: [String: Any] = ["ip": mediaIp, "port": port]
                    if usage == 2 { videoMedia = candidate }
                    else { bundledMedia = candidate }
                }
            }
        }
        info["mediaConnectionInfo"] = videoMedia ?? bundledMedia ?? signalingMediaFallback
    }

    func signalingHeaderTokens(from value: Any?) -> [String] {
        if let tokens = value as? [String] {
            return tokens.filter { !$0.isEmpty }
        }
        if let headers = value as? [String: String] {
            return headers.map { "\($0.key).\($0.value)" }.filter { !$0.isEmpty }.sorted()
        }
        if let headers = value as? [String: Any] {
            return headers.map { "\($0.key).\(string($0.value))" }.filter { !$0.isEmpty }.sorted()
        }
        if let entries = value as? [[String: Any]] {
            return entries.compactMap { entry in
                let key = string(entry["key"])
                let value = string(entry["value"])
                return key.isEmpty || value.isEmpty ? nil : "\(key).\(value)"
            }
        }
        return []
    }

    func negotiatedStreamProfile(from session: [String: Any]) -> [String: Any] {
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

    func negotiatedStreamProfile(from session: [String: Any], applying initialProfile: [String: Any]) -> [String: Any] {
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

    func colorQuality(bitDepth: Int, chromaFormat: Int) -> String {
        let tenBit = bitDepth >= 10
        let fourFourFour = chromaFormat == 1
        if tenBit && fourFourFour { return "10bit_444" }
        if tenBit { return "10bit_420" }
        if fourFourFour { return "8bit_444" }
        return "8bit_420"
    }

    func sessionAdState(from session: [String: Any]) -> [String: Any] {
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

    func iceServers(from session: [String: Any]) -> [[String: Any]] {
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

    func mergeAndStoreAdState(_ info: inout [String: Any]) {
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

    func activeSessionEntries(from sessions: [Any], streamingBaseUrl: String) -> [[String: Any]] {
        sessions.compactMap { item -> [String: Any]? in
            guard let session = item as? [String: Any] else { return nil }
            guard let descriptor = CloudMatchActiveSessionParser.descriptor(from: session, streamingBaseURL: streamingBaseUrl) else { return nil }
            return [
                "sessionId": descriptor.sessionId,
                "appId": descriptor.appId,
                "status": descriptor.status,
                "isResumable": descriptor.state.isVendorResumable,
                "serverIp": descriptor.resumeServer,
                "gpuType": descriptor.gpuType,
                "streamingBaseUrl": descriptor.streamingBaseURL,
                "signalingUrl": descriptor.signalingURL,
            ]
        }
    }

    func selectSessionLimitReuseEntry(_ sessions: [[String: Any]], requestedAppId: Int) -> [String: Any]? {
        let validSessions = sessions.filter { int($0["appId"]) > 0 }
        if let session = validSessions.first(where: { int($0["appId"]) == requestedAppId && isResumableActiveSessionStatus(int($0["status"])) }) { return session }
        if let session = validSessions.first(where: { isResumableActiveSessionStatus(int($0["status"])) }) { return session }
        if let session = validSessions.first(where: { int($0["appId"]) == requestedAppId && int($0["status"]) == 1 }) { return session }
        if let session = validSessions.first(where: { int($0["status"]) == 1 }) { return session }
        if let session = validSessions.first(where: { int($0["appId"]) == requestedAppId }) { return session }
        return validSessions.first
    }

    func currentAccessToken() -> String { lock.withLock { accessToken } }
    func currentStreamingBaseUrl() -> String { lock.withLock { streamingBaseUrl.isEmpty ? Self.defaultBaseUrl : streamingBaseUrl } }

    func isReadyActiveSessionStatus(_ status: Int) -> Bool { CloudMatchSessionState(rawValue: status)?.isReadyForConnection == true }

    func isResumableActiveSessionStatus(_ status: Int) -> Bool { CloudMatchSessionState(rawValue: status)?.isVendorResumable == true }

    func canContinuePollingActiveSessionStatus(_ status: Int) -> Bool { CloudMatchSessionState(rawValue: status)?.canContinuePolling == true }

    func pollDelay(_ attempt: Int) -> TimeInterval {
        attempt <= 12 ? 0.3 : (attempt <= 20 ? 0.5 : 1.0)
    }

    func logPollSessionSummary(httpStatus: Int, info: [String: Any]) {
        var summary = "status=\(int(info["status"])) sessionId=\(string(info["sessionId"]).prefix(8))"
        if httpStatus != 200 { summary += " http=\(httpStatus)" }
        let queuePosition = int(info["queuePosition"])
        if queuePosition > 0 { summary += " queue=\(queuePosition)" }
        if let adState = info["adState"] as? [String: Any], bool(adState["isAdsRequired"]) { summary += " ads=required" }
        OPNSentry.logInfoMessage(OPNSentry.formattedLogMessage(level: "info", area: "PollSession", message: summary))
    }

    func storePersistedActiveSessionId(_ sessionId: String) {
        guard !sessionId.isEmpty else { return }
        let current = OPNAppPreferenceStorage.standard.string(forKey: Self.persistedActiveSessionIdKey) ?? ""
        guard current != sessionId else { return }
        OPNAppPreferenceStorage.standard.set(sessionId, forKey: Self.persistedActiveSessionIdKey)
        OPNAppPreferenceStorage.standard.synchronize()
        OPNSentry.logInfoMessage(OPNSentry.formattedLogMessage(level: "info", area: "SessionManager", message: "Persisted active sessionId=\(sessionId)"))
    }

    func clearPersistedActiveSessionId(_ sessionId: String) {
        let current = OPNAppPreferenceStorage.standard.string(forKey: Self.persistedActiveSessionIdKey) ?? ""
        guard !current.isEmpty, sessionId.isEmpty || current == sessionId else { return }
        OPNAppPreferenceStorage.standard.removeObject(forKey: Self.persistedActiveSessionIdKey)
        OPNAppPreferenceStorage.standard.synchronize()
        OPNSentry.logInfoMessage(OPNSentry.formattedLogMessage(level: "info", area: "SessionManager", message: "Cleared persisted active sessionId=\(current)"))
    }
}
