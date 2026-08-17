import Foundation

struct NativeNVSTNormalizedSessionSource {
    let rawSession: [String: Any]
    let sessionInfo: [String: Any]
    let settings: [String: Any]
    let requestData: [String: Any]
    let metadata: Any
    let metadataCount: Int
    let networkSessionId: String
    let persistingInGameSettings: Bool

    init(allocation: NativeNVSTSessionAllocation) {
        let rawSession = Self.jsonObject(from: allocation.rawSessionJSON)
        let sessionInfo = Self.jsonObject(from: allocation.sessionInfoJSON)
        let settings = Self.jsonObject(from: allocation.settingsJSON)
        let requestData = rawSession["sessionRequestData"] as? [String: Any] ?? [:]
        self.rawSession = rawSession
        self.sessionInfo = sessionInfo
        self.settings = settings
        self.requestData = requestData
        metadata = requestData["metaData"] ?? rawSession["metaData"] ?? []
        metadataCount = (metadata as? [Any])?.count ?? (metadata as? NSArray)?.count ?? 0
        networkSessionId = Self.firstNonEmpty(Self.string(rawSession["networkSessionId"]), Self.string(requestData["networkSessionId"]))
        persistingInGameSettings = Self.bool(
            rawSession["persistingInGameSettings"],
            rawSession["enablePersistingInGameSettings"],
            requestData["persistingInGameSettings"],
            requestData["enablePersistingInGameSettings"],
            settings["persistingInGameSettings"],
            settings["enablePersistingInGameSettings"]
        )
    }

    func applicationHeaders(allocation: NativeNVSTSessionAllocation) -> [Any] {
        var headers = Self.firstArray(rawSession["applicationHeaders"], requestData["applicationHeaders"])
        for value in allocation.signalingHeaders + [allocation.signalingQueryParameters] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !headers.contains(where: { ($0 as? String) == trimmed }) {
                headers.append(trimmed)
            }
        }
        return headers
    }

    private static func jsonObject(from json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func firstArray(_ values: Any?...) -> [Any] {
        for value in values {
            if let value = value as? [Any], !value.isEmpty { return value }
            if let value = value as? NSArray, value.count > 0 { return value.compactMap { $0 } }
        }
        return []
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSString { return (value as String).trimmingCharacters(in: .whitespacesAndNewlines) }
        return ""
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.isEmpty } ?? ""
    }

    private static func bool(_ values: Any?...) -> Bool {
        for value in values {
            if let value = value as? Bool { return value }
            if let value = value as? NSNumber { return value.boolValue }
            if let value = value as? String {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "1", "true", "yes", "enabled": return true
                case "0", "false", "no", "disabled": return false
                default: continue
                }
            }
        }
        return false
    }
}

struct NativeNVSTLaunchPayload: Equatable, Sendable {
    struct Prepare: Equatable, Sendable {
        let address: String
        let port: Int
        let deviceId: String
        let clientAppVersion: String
        let tokenType: String
        let hasToken: Bool
        let serverType: Int
        let serverAddress: String
        let traceParent: String
    }

    struct Start: Equatable, Sendable {
        let address: String
        let serverType: Int
        let port: Int
        let appId: Int
        let appName: String
        let appLaunchMode: Int
        let frameStatsEnabled: Bool
        let summaryStatsEnabled: Bool
        let deviceId: String
        let gameShortName: String
        let maxLocalPlayers: Int
        let advancedLatencyOptimization: Bool
        let streamingProfileJSON: String
        let networkPacketCaptureEnabled: Bool
        let metadataCount: Int
        let frameLossWarningTimeout: Int
        let frameLossErrorTimeout: Int
        let locale: String
        let digitalStore: String
        let accountLinked: Bool
        let persistingInGameSettings: Bool
        let networkSessionId: String
        let audioModeFormat: String
        let supportedControlsCount: Int
        let contentRatingCount: Int
        let heroImage: String
        let gameDisplayOwnRating: Bool
        let storeName: String
        let subscriptionLongDesc: String
        let providerName: String
        let zoneName: String
        let userAge: Int
        let serverLocation: String
        let hasGpuNameMap: Bool
        let hasStreamingDisplayDataInfo: Bool
        let hasCurrentPhysicalResolution: Bool
    }

    let prepare: Prepare
    let start: Start
    let missingFields: [String]

    var telemetryAttributes: [String: String] {
        [
            "nativePayloadMissingFields": missingFields.joined(separator: ","),
            "nativePayloadServerType": String(start.serverType),
            "nativePayloadAppLaunchMode": String(start.appLaunchMode),
            "nativePayloadHasToken": prepare.hasToken ? "true" : "false",
            "nativePayloadTokenType": prepare.tokenType,
            "nativePayloadNetworkSessionId": start.networkSessionId.isEmpty ? "missing" : "present",
            "nativePayloadAudioModeFormat": start.audioModeFormat,
            "nativePayloadSupportedControls": String(start.supportedControlsCount),
            "nativePayloadContentRatings": String(start.contentRatingCount),
        ]
    }

    init(allocation: NativeNVSTSessionAllocation, streamingProfileJSON: String, clientAppVersion: String) {
        let source = NativeNVSTNormalizedSessionSource(allocation: allocation)
        let rawSession = source.rawSession
        let sessionInfo = source.sessionInfo
        let settings = source.settings
        let requestData = source.requestData
        let sessionControlInfo = rawSession["sessionControlInfo"] as? [String: Any] ?? [:]
        let streamingDisplayData = requestData["streamingDisplayDataInfo"] as? [String: Any] ?? rawSession["streamingDisplayDataInfo"] as? [String: Any] ?? [:]

        let address = Self.firstNonEmpty(Self.string(rawSession["serverAddress"]), Self.string(sessionControlInfo["ip"]), allocation.session.serverAddress)
        let port = Self.positiveInt(rawSession["port"], requestData["port"], sessionControlInfo["port"], fallback: 443)
        let deviceId = Self.firstNonEmpty(Self.string(requestData["deviceHashId"]), Self.string(rawSession["deviceId"]), OPNDeviceIdentity.stableCloudmatchDeviceId())
        let locale = Self.firstNonEmpty(Self.string(settings["gameLanguage"]), Self.string(rawSession["locale"]), OPNLocale.currentGFNLocale())
        let appId = Self.positiveInt(requestData["appId"], rawSession["appId"], fallback: Int(allocation.session.applicationID) ?? 0)
        let tokenType = Self.firstNonEmpty(Self.string(rawSession["tokenType"]), Self.string(rawSession["authType"]), Self.string((rawSession["auth"] as? [String: Any])?["type"]), allocation.authTokenType)
        let token = Self.firstNonEmpty(Self.string(rawSession["token"]), Self.string(rawSession["authToken"]), Self.string(rawSession["jwt"]), Self.string((rawSession["auth"] as? [String: Any])?["token"]), Self.string(rawSession["sessionToken"]), allocation.authToken)
        let audioMode = Self.firstNonEmpty(Self.string(rawSession["audioModeFormat"]), Self.string(requestData["audioModeFormat"]), Self.string(settings["audioModeFormat"]), "stereo")
        let serverType = Self.positiveInt(allocation.serverType, rawSession["serverType"], requestData["serverType"], fallback: 0)
        let traceParent = Self.firstNonEmpty(Self.string((rawSession["spanData"] as? [String: Any])?["traceparent"]), Self.string((requestData["spanData"] as? [String: Any])?["traceparent"]))

        prepare = Prepare(
            address: address,
            port: port,
            deviceId: deviceId,
            clientAppVersion: clientAppVersion,
            tokenType: tokenType,
            hasToken: !token.isEmpty,
            serverType: serverType,
            serverAddress: address,
            traceParent: traceParent
        )
        start = Start(
            address: address,
            serverType: serverType,
            port: port,
            appId: appId,
            appName: Self.firstNonEmpty(allocation.session.title, Self.string(requestData["appName"])),
            appLaunchMode: Self.positiveInt(requestData["appLaunchMode"], rawSession["appLaunchMode"], fallback: 0),
            frameStatsEnabled: Self.bool(rawSession["frameStatsEnabled"]),
            summaryStatsEnabled: Self.bool(rawSession["summaryStatsEnabled"], fallback: true),
            deviceId: deviceId,
            gameShortName: Self.string(requestData["gameShortName"]),
            maxLocalPlayers: Self.positiveInt(requestData["maxLocalPlayers"], rawSession["maxLocalPlayers"], fallback: 1),
            advancedLatencyOptimization: Self.bool(requestData["advancedLatencyOptimization"]),
            streamingProfileJSON: streamingProfileJSON,
            networkPacketCaptureEnabled: Self.bool(rawSession["networkPacketCaptureEnabled"], requestData["networkPacketCaptureEnabled"]),
            metadataCount: source.metadataCount,
            frameLossWarningTimeout: Self.positiveInt(rawSession["frameLossWarningTimeout"], requestData["frameLossWarningTimeout"], fallback: 500),
            frameLossErrorTimeout: Self.positiveInt(rawSession["frameLossErrorTimeout"], requestData["frameLossErrorTimeout"], fallback: 30_000),
            locale: locale,
            digitalStore: Self.firstNonEmpty(Self.string(rawSession["digitalStore"]), Self.string(requestData["digitalStore"])),
            accountLinked: Self.bool(rawSession["accountLinked"], requestData["accountLinked"]),
            persistingInGameSettings: source.persistingInGameSettings,
            networkSessionId: source.networkSessionId,
            audioModeFormat: audioMode,
            supportedControlsCount: Self.array(rawSession["supportedControls"], requestData["supportedControls"]).count,
            contentRatingCount: Self.array(rawSession["contentRating"], requestData["contentRating"]).count,
            heroImage: Self.firstNonEmpty(Self.string(rawSession["heroImage"]), Self.string(requestData["heroImage"])),
            gameDisplayOwnRating: Self.bool(rawSession["gameDisplayOwnRating"], requestData["gameDisplayOwnRating"]),
            storeName: Self.firstNonEmpty(Self.string(rawSession["storeName"]), Self.string(requestData["storeName"])),
            subscriptionLongDesc: Self.firstNonEmpty(Self.string(rawSession["subscriptionLongDesc"]), Self.string(requestData["subscriptionLongDesc"])),
            providerName: Self.firstNonEmpty(Self.string(rawSession["providerName"]), Self.string(requestData["providerName"]), "NVIDIA"),
            zoneName: Self.firstNonEmpty(Self.string(rawSession["zoneName"]), Self.string(requestData["zoneName"]), address.split(separator: ".").first.map { String($0).uppercased() } ?? ""),
            userAge: Self.positiveInt(rawSession["userAge"], requestData["userAge"], fallback: 0),
            serverLocation: Self.firstNonEmpty(Self.string(rawSession["serverLocation"]), Self.string(requestData["serverLocation"]), Self.string(rawSession["zoneName"])),
            hasGpuNameMap: rawSession["gpuNameMap"] != nil || requestData["gpuNameMap"] != nil,
            hasStreamingDisplayDataInfo: !streamingDisplayData.isEmpty,
            hasCurrentPhysicalResolution: rawSession["currentPhysicalResolution"] != nil || requestData["currentPhysicalResolution"] != nil || sessionInfo["currentPhysicalResolution"] != nil
        )

        var missing: [String] = []
        if prepare.address.isEmpty { missing.append("address") }
        if prepare.port <= 0 { missing.append("port") }
        if prepare.deviceId.isEmpty { missing.append("deviceId") }
        if prepare.clientAppVersion.isEmpty { missing.append("clientAppVersion") }
        if prepare.tokenType.isEmpty { missing.append("tokenType") }
        if !prepare.hasToken { missing.append("token") }
        if start.serverType <= 0 { missing.append("serverType") }
        if start.appId <= 0 { missing.append("appId") }
        if !Self.hasValidStreamingProfile(start.streamingProfileJSON) { missing.append("streamingProfile") }
        if start.audioModeFormat.isEmpty { missing.append("audioModeFormat") }
        missingFields = missing
    }

    func validate() throws {
        guard missingFields.isEmpty else {
            throw NativeNVSTError.invalidSession("Native NVST launch payload is missing required fields: \(missingFields.joined(separator: ", ")).")
        }
        guard Self.isSupportedServerType(start.serverType) else {
            throw NativeNVSTError.invalidSession("Native NVST launch payload has unsupported server type \(start.serverType).")
        }
        guard Self.isSupportedAuthTokenType(prepare.tokenType) else {
            throw NativeNVSTError.invalidSession("Native NVST launch payload has an unsupported auth token type.")
        }
    }

    private static func isSupportedServerType(_ serverType: Int) -> Bool {
        (1...5).contains(serverType) || serverType == 1001
    }

    private static func isSupportedAuthTokenType(_ tokenType: String) -> Bool {
        switch tokenType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "7", "jarvis", "nvb_auth_jarvis", "8", "jwt", "nvb_auth_jwt", "9", "jwt_gfn", "jwt-gfn", "nvb_auth_jwt_gfn":
            true
        default:
            false
        }
    }

    private static func jsonObject(from json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func hasValidStreamingProfile(_ json: String) -> Bool {
        let profile = jsonObject(from: json)
        guard let selectedVideoMode = profile["selectedVideoMode"] as? [String: Any] else { return false }
        return int(selectedVideoMode["width"]) > 0 && int(selectedVideoMode["height"]) > 0 && int(selectedVideoMode["fps"]) > 0
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    private static func positiveInt(_ values: Any?..., fallback: Int) -> Int {
        for value in values {
            let parsed = int(value)
            if parsed > 0 { return parsed }
        }
        return fallback
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        return 0
    }

    private static func bool(_ values: Any?..., fallback: Bool = false) -> Bool {
        for value in values {
            if let value = value as? Bool { return value }
            if let value = value as? NSNumber { return value.boolValue }
            if let value = value as? String {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "1", "true", "yes", "enabled": return true
                case "0", "false", "no", "disabled": return false
                default: continue
                }
            }
        }
        return fallback
    }

    private static func array(_ values: Any?...) -> [Any] {
        for value in values {
            if let value = value as? [Any], !value.isEmpty { return value }
            if let value = value as? NSArray, value.count > 0 { return value.compactMap { $0 } }
        }
        return []
    }
}
