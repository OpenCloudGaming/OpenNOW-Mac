import Foundation

public enum CloudMatch: Sendable {
    public static let systemName = "CloudMatch"
    public static let productionBaseURLString = "https://prod.cloudmatchbeta.nvidiagrid.net"
    public static let sessionPath = "/v2/session"
}

public extension CloudMatch {
    enum Endpoint: String, CaseIterable, Sendable {
        case serviceUrls = "/v1/serviceUrls"
        case serverInfo = "/v2/serverInfo"
        case networkTestSession = "/v2/nettestsession"
        case subscriptions = "/v4/subscriptions"

        public var path: String { rawValue }

        public var cachePolicy: CloudMatchCachePolicy {
            switch self {
            case .serviceUrls, .serverInfo:
                CloudMatchCachePolicy(maxEntries: 10, maxAgeSeconds: 1_209_600)
            case .subscriptions:
                CloudMatchCachePolicy(maxEntries: 20, maxAgeSeconds: 604_800, flushCacheOnResponseCodes: [404])
            case .networkTestSession:
                CloudMatchCachePolicy(maxEntries: 0, maxAgeSeconds: 0)
            }
        }
    }
}

public struct CloudMatchCachePolicy: Equatable, Sendable {
    public let maxEntries: Int
    public let maxAgeSeconds: Int
    public let purgeOnQuotaError: Bool
    public let flushCacheOnResponseCodes: Set<Int>

    public init(maxEntries: Int, maxAgeSeconds: Int, purgeOnQuotaError: Bool = true, flushCacheOnResponseCodes: Set<Int> = []) {
        self.maxEntries = maxEntries
        self.maxAgeSeconds = maxAgeSeconds
        self.purgeOnQuotaError = purgeOnQuotaError
        self.flushCacheOnResponseCodes = flushCacheOnResponseCodes
    }

    public func shouldFlush(responseStatusCode: Int) -> Bool {
        flushCacheOnResponseCodes.contains(responseStatusCode)
    }

    public func isExpired(cachedAt: Date, now: Date = Date()) -> Bool {
        guard maxAgeSeconds > 0 else { return true }
        return now.timeIntervalSince(cachedAt) >= TimeInterval(maxAgeSeconds)
    }
}

public struct CloudMatchZone: Equatable, Sendable {
    public let name: String
    public let address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }
}

public struct CloudMatchServerInfo: Equatable, Sendable {
    public let vpcId: String
    public let serverType: String
    public let zones: [String: CloudMatchZone]
    public let defaultZone: CloudMatchZone?
    public let detectedLocalZone: CloudMatchZone?

    public init(vpcId: String = "", serverType: String = "", zones: [String: CloudMatchZone] = [:], defaultZone: CloudMatchZone? = nil, detectedLocalZone: CloudMatchZone? = nil) {
        self.vpcId = vpcId
        self.serverType = serverType
        self.zones = zones
        self.defaultZone = defaultZone
        self.detectedLocalZone = detectedLocalZone
    }
}

public struct CloudMatchRouteOverride: Equatable, Sendable {
    public let zone: CloudMatchZone
    public let isInternal: Bool
    public let runNetworkTest: Bool

    public init(zone: CloudMatchZone, isInternal: Bool = false, runNetworkTest: Bool = false) {
        self.zone = zone
        self.isInternal = isInternal
        self.runNetworkTest = runNetworkTest
    }
}

public enum CloudMatchRouteDecision: Equatable, Sendable {
    case useDefault(CloudMatchZone?)
    case useOverride(CloudMatchRouteOverride)
    case clearUnavailableOverride(CloudMatchRouteOverride)
}

public struct CloudMatchClientHeaders: Equatable, Sendable {
    public let clientId: String
    public let clientType: String
    public let clientVersion: String
    public let clientStreamer: String
    public let deviceOS: String
    public let deviceType: String
    public let deviceMake: String
    public let deviceModel: String
    public let browserType: String
    public let userAgent: String

    public init(clientId: String = "ec7e38d4-03af-4b58-b131-cfb0495903ab",
                clientType: String = "NATIVE",
                clientVersion: String = "2.0.80.173",
                clientStreamer: String = "NVIDIA-CLASSIC",
                deviceOS: String = "MACOS",
                deviceType: String = "DESKTOP",
                deviceMake: String = "UNKNOWN",
                deviceModel: String = "UNKNOWN",
                browserType: String = "CHROME",
                userAgent: String = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173") {
        self.clientId = clientId
        self.clientType = clientType
        self.clientVersion = clientVersion
        self.clientStreamer = clientStreamer
        self.deviceOS = deviceOS
        self.deviceType = deviceType
        self.deviceMake = deviceMake
        self.deviceModel = deviceModel
        self.browserType = browserType
        self.userAgent = userAgent
    }

    public static let nativeGFNPC = CloudMatchClientHeaders()

    public static func browserWebRTC(clientId: String = "ec7e38d4-03af-4b58-b131-cfb0495903ab", clientVersion: String = "2.0.85.135", userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36") -> CloudMatchClientHeaders {
        CloudMatchClientHeaders(clientId: clientId, clientType: "BROWSER", clientVersion: clientVersion, clientStreamer: "WEBRTC", deviceOS: "WINDOWS", deviceType: "DESKTOP", deviceMake: "", deviceModel: "", browserType: "CHROME", userAgent: userAgent)
    }

    public func apply(to request: inout URLRequest, accessToken: String, deviceId: String = "", includeOrigin: Bool = false, accept: String = "application/json", contentType: String? = "application/json") {
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if !accessToken.isEmpty { request.setValue("GFNJWT \(accessToken)", forHTTPHeaderField: "Authorization") }
        if !clientId.isEmpty { request.setValue(clientId, forHTTPHeaderField: "nv-client-id") }
        if !clientType.isEmpty { request.setValue(clientType, forHTTPHeaderField: "nv-client-type") }
        if !clientVersion.isEmpty { request.setValue(clientVersion, forHTTPHeaderField: "nv-client-version") }
        if !clientStreamer.isEmpty { request.setValue(clientStreamer, forHTTPHeaderField: "nv-client-streamer") }
        if !deviceOS.isEmpty { request.setValue(deviceOS, forHTTPHeaderField: "nv-device-os") }
        if !deviceType.isEmpty { request.setValue(deviceType, forHTTPHeaderField: "nv-device-type") }
        if !deviceMake.isEmpty { request.setValue(deviceMake, forHTTPHeaderField: "nv-device-make") }
        if !deviceModel.isEmpty { request.setValue(deviceModel, forHTTPHeaderField: "nv-device-model") }
        if !browserType.isEmpty { request.setValue(browserType, forHTTPHeaderField: "nv-browser-type") }
        if !deviceId.isEmpty { request.setValue(deviceId, forHTTPHeaderField: "x-device-id") }
        if includeOrigin {
            request.setValue("https://play.geforcenow.com", forHTTPHeaderField: "Origin")
            request.setValue("https://play.geforcenow.com/", forHTTPHeaderField: "Referer")
        }
    }
}

public struct CloudMatchConfiguration: Equatable, Sendable {
    public let baseURLString: String
    public let headers: CloudMatchClientHeaders

    public var userAgent: String { headers.userAgent }

    public init(baseURLString: String = CloudMatch.productionBaseURLString, headers: CloudMatchClientHeaders = .nativeGFNPC) {
        self.baseURLString = baseURLString
        self.headers = headers
    }

    public init(baseURLString: String = CloudMatch.productionBaseURLString, userAgent: String) {
        self.init(baseURLString: baseURLString, headers: CloudMatchClientHeaders(userAgent: userAgent))
    }

    public static let gfnPC = CloudMatchConfiguration()
}

public enum CloudMatchRequestFactory {
    public static func request(endpoint: CloudMatch.Endpoint, accessToken: String = "", queryItems: [URLQueryItem] = [], configuration: CloudMatchConfiguration = .gfnPC, timeoutInterval: TimeInterval = 15, deviceId: String = "") -> URLRequest? {
        endpointRequest(path: endpoint.path, method: "GET", accessToken: accessToken, queryItems: queryItems, body: nil, configuration: configuration, timeoutInterval: timeoutInterval, deviceId: deviceId, includeOrigin: false)
    }

    public static func serverInfoRequest(baseURLString: String, accessToken: String = "", deviceId: String = "", headers: CloudMatchClientHeaders = .nativeGFNPC, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        let configuration = CloudMatchConfiguration(baseURLString: normalizedBaseURL(baseURLString), headers: headers)
        return request(endpoint: .serverInfo, accessToken: accessToken, configuration: configuration, timeoutInterval: timeoutInterval, deviceId: deviceId)
    }

    public static func createSessionRequest(baseURLString: String, accessToken: String, deviceId: String, keyboardLayout: String, languageCode: String, body: Data?, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        let queryItems = [URLQueryItem(name: "keyboardLayout", value: keyboardLayout), URLQueryItem(name: "languageCode", value: languageCode)]
        return sessionRequest(baseURLString: baseURLString, sessionId: "", method: "POST", accessToken: accessToken, deviceId: deviceId, queryItems: queryItems, body: body, includeOrigin: false, timeoutInterval: timeoutInterval)
    }

    public static func pollSessionRequest(baseURLString: String, sessionId: String, accessToken: String, deviceId: String, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        sessionRequest(baseURLString: baseURLString, sessionId: sessionId, method: "GET", accessToken: accessToken, deviceId: deviceId, timeoutInterval: timeoutInterval)
    }

    public static func stopSessionRequest(baseURLString: String, sessionId: String, accessToken: String, deviceId: String, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        sessionRequest(baseURLString: baseURLString, sessionId: sessionId, method: "DELETE", accessToken: accessToken, deviceId: deviceId, includeOrigin: true, timeoutInterval: timeoutInterval)
    }

    public static func activeSessionsRequest(baseURLString: String, accessToken: String, deviceId: String, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        sessionRequest(baseURLString: baseURLString, sessionId: "", method: "GET", accessToken: accessToken, deviceId: deviceId, timeoutInterval: timeoutInterval)
    }

    public static func claimSessionRequest(baseURLString: String, sessionId: String, accessToken: String, deviceId: String, keyboardLayout: String, languageCode: String, body: Data?, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        let queryItems = [URLQueryItem(name: "keyboardLayout", value: keyboardLayout), URLQueryItem(name: "languageCode", value: languageCode)]
        return sessionRequest(baseURLString: baseURLString, sessionId: sessionId, method: "PUT", accessToken: accessToken, deviceId: deviceId, queryItems: queryItems, body: body, includeOrigin: true, timeoutInterval: timeoutInterval)
    }

    public static func adUpdateRequest(baseURLString: String, sessionId: String, accessToken: String, deviceId: String, body: Data?, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        sessionRequest(baseURLString: baseURLString, sessionId: sessionId, method: "PUT", accessToken: accessToken, deviceId: deviceId, body: body, includeOrigin: true, timeoutInterval: timeoutInterval)
    }

    public static func sessionRequest(baseURLString: String, sessionId: String, method: String, accessToken: String, deviceId: String, queryItems: [URLQueryItem] = [], body: Data? = nil, includeOrigin: Bool = false, timeoutInterval: TimeInterval = 15, headers: CloudMatchClientHeaders = .nativeGFNPC) -> URLRequest? {
        let path = sessionId.isEmpty ? CloudMatch.sessionPath : CloudMatch.sessionPath + "/" + encodedPathComponent(sessionId)
        return endpointRequest(path: path, method: method, accessToken: accessToken, queryItems: queryItems, body: body, configuration: CloudMatchConfiguration(baseURLString: normalizedBaseURL(baseURLString), headers: headers), timeoutInterval: timeoutInterval, deviceId: deviceId, includeOrigin: includeOrigin)
    }

    public static func normalizedBaseURL(_ value: String) -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return CloudMatch.productionBaseURLString }
        let withScheme = raw.hasPrefix("https://") || raw.hasPrefix("http://") ? raw : "https://\(raw)"
        return withScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static func resolvedSessionBaseURL(streamingBaseURL: String, serverIP: String) -> String {
        let fallbackBase = normalizedHTTPSBaseURL(streamingBaseURL)
        if serverIP.isEmpty { return fallbackBase.isEmpty ? CloudMatch.productionBaseURLString : fallbackBase }
        if serverIP.hasPrefix("https://") || serverIP.hasPrefix("http://") {
            let base = normalizedHTTPSBaseURL(serverIP)
            return base.isEmpty ? (fallbackBase.isEmpty ? CloudMatch.productionBaseURLString : fallbackBase) : base
        }
        let host = usableEndpointHost(serverIP)
        return host.isEmpty ? (fallbackBase.isEmpty ? CloudMatch.productionBaseURLString : fallbackBase) : "https://\(host)"
    }

    private static func endpointRequest(path: String, method: String, accessToken: String, queryItems: [URLQueryItem], body: Data?, configuration: CloudMatchConfiguration, timeoutInterval: TimeInterval, deviceId: String, includeOrigin: Bool) -> URLRequest? {
        var components = URLComponents(string: normalizedBaseURL(configuration.baseURLString) + path)
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = method
        configuration.headers.apply(to: &request, accessToken: accessToken, deviceId: deviceId, includeOrigin: includeOrigin)
        request.httpBody = body
        return request
    }

    private static func encodedPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func normalizedHTTPSBaseURL(_ value: String) -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !raw.isEmpty else { return "" }
        let withScheme = raw.hasPrefix("https://") || raw.hasPrefix("http://") ? raw : "https://\(raw)"
        guard let components = URLComponents(string: withScheme), components.scheme?.lowercased() == "https", let host = components.host, !usableEndpointHost(host).isEmpty else { return "" }
        return withScheme
    }
}

public enum CloudMatchServerInfoParser {
    public static func parse(_ json: [String: Any]) -> CloudMatchServerInfo {
        let metadata = metadataItems(from: json["metadata"] ?? json["metaData"])
        let values = Dictionary(uniqueKeysWithValues: metadata.compactMap { item -> (String, String)? in
            guard let key = item["key"], let value = item["value"] else { return nil }
            return (key, value)
        })
        let regionNames = regionNames(from: values)
        let zones = zones(from: values, regionNames: regionNames)
        let localZone = values["local-region"].flatMap { zone(matching: $0, zones: zones) }
        return CloudMatchServerInfo(
            vpcId: cloudMatchStringValue(json["vpcId"]) ?? cloudMatchStringValue(json["vpc_id"]) ?? "",
            serverType: cloudMatchStringValue(json["serverType"]) ?? cloudMatchStringValue(json["server_type"]) ?? "",
            zones: zones,
            defaultZone: localZone ?? firstZone(regionNames: regionNames, zones: zones),
            detectedLocalZone: localZone
        )
    }

    private static func metadataItems(from value: Any?) -> [[String: String]] {
        guard let array = value as? [[String: Any]] else { return [] }
        return array.map { item in
            var output: [String: String] = [:]
            if let key = cloudMatchStringValue(item["key"]) { output["key"] = key }
            if let value = cloudMatchStringValue(item["value"]) { output["value"] = value }
            return output
        }
    }

    private static func regionNames(from values: [String: String]) -> [String] {
        values["gfn-regions"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            ?? []
    }

    private static func zones(from values: [String: String], regionNames: [String]) -> [String: CloudMatchZone] {
        regionNames.reduce(into: [String: CloudMatchZone]()) { result, name in
            guard let rawAddress = values[name] else { return }
            let address = normalizedAddress(rawAddress)
            result[address] = CloudMatchZone(name: name, address: address)
        }
    }

    private static func zone(matching value: String, zones: [String: CloudMatchZone]) -> CloudMatchZone? {
        let normalizedValue = normalizedAddress(value)
        if let zone = zones[normalizedValue] { return zone }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return zones.values.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func firstZone(regionNames: [String], zones: [String: CloudMatchZone]) -> CloudMatchZone? {
        for name in regionNames {
            if let zone = zones.values.first(where: { $0.name == name }) { return zone }
        }
        return nil
    }

    private static func normalizedAddress(_ value: String) -> String {
        value.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

public enum CloudMatchRoutingPolicy {
    public static func decision(serverInfo: CloudMatchServerInfo, override: CloudMatchRouteOverride?) -> CloudMatchRouteDecision {
        guard let override else { return .useDefault(serverInfo.defaultZone) }
        if override.isInternal || serverInfo.zones.values.contains(override.zone) { return .useOverride(override) }
        return .clearUnavailableOverride(override)
    }
}

public enum CloudMatchSessionState: Int, Sendable {
    case initializing = 1
    case readyForConnection = 2
    case streaming = 3
    case pausedUnintentional = 4
    case pausedIntentional = 5
    case resuming = 6
    case finished = 7

    public var isVendorResumable: Bool {
        switch self {
        case .initializing, .readyForConnection, .streaming, .pausedUnintentional, .pausedIntentional, .resuming:
            true
        case .finished:
            false
        }
    }

    public var isReadyForConnection: Bool {
        self == .readyForConnection || self == .streaming
    }

    public var canContinuePolling: Bool {
        self == .initializing || self == .pausedUnintentional || self == .pausedIntentional || self == .resuming
    }
}

public struct CloudMatchActiveSessionDescriptor: Equatable, Sendable {
    public let sessionId: String
    public let appId: Int
    public let state: CloudMatchSessionState
    public let controlServer: String
    public let signalingHost: String
    public let streamingBaseURL: String
    public let gpuType: String

    public var status: Int { state.rawValue }
    public var resumeServer: String { controlServer.isEmpty ? signalingHost : controlServer }

    public var signalingURL: String {
        let host = signalingHost.isEmpty ? controlServer : signalingHost
        return host.isEmpty ? "" : "wss://\(host):443/nvst/"
    }

    public init(sessionId: String, appId: Int, state: CloudMatchSessionState, controlServer: String, signalingHost: String, streamingBaseURL: String, gpuType: String) {
        self.sessionId = sessionId
        self.appId = appId
        self.state = state
        self.controlServer = controlServer
        self.signalingHost = signalingHost
        self.streamingBaseURL = streamingBaseURL
        self.gpuType = gpuType
    }
}

public enum CloudMatchActiveSessionParser {
    public static func descriptor(from dictionary: [String: Any], streamingBaseURL: String) -> CloudMatchActiveSessionDescriptor? {
        let sessionId = cloudMatchStringValue(dictionary["sessionId"]) ?? ""
        guard !sessionId.isEmpty else { return nil }
        guard let state = CloudMatchSessionState(rawValue: intValue(dictionary["status"])), state.isVendorResumable else { return nil }

        let requestData = dictionary["sessionRequestData"] as? [String: Any]
        let controlInfo = dictionary["sessionControlInfo"] as? [String: Any]
        let controlServer = usableEndpointHost(cloudMatchStringValue(controlInfo?["ip"]) ?? "")
        let signalingHost = firstSignalingHost(from: dictionary)
        let resumeServer = controlServer.isEmpty ? signalingHost : controlServer
        guard !resumeServer.isEmpty else { return nil }

        return CloudMatchActiveSessionDescriptor(
            sessionId: sessionId,
            appId: intValue(requestData?["appId"]),
            state: state,
            controlServer: controlServer,
            signalingHost: signalingHost,
            streamingBaseURL: streamingBaseURL,
            gpuType: cloudMatchStringValue(dictionary["gpuType"]) ?? ""
        )
    }

    public static func descriptors(from sessions: [Any], streamingBaseURL: String) -> [CloudMatchActiveSessionDescriptor] {
        sessions.compactMap { item in
            guard let session = item as? [String: Any] else { return nil }
            return descriptor(from: session, streamingBaseURL: streamingBaseURL)
        }
    }

    private static func firstSignalingHost(from dictionary: [String: Any]) -> String {
        for item in arrayValue(dictionary["connectionInfo"]).compactMap({ $0 as? [String: Any] }) where intValue(item["usage"]) == 14 {
            let ip = usableEndpointHost(cloudMatchStringValue(item["ip"]) ?? "")
            if !ip.isEmpty { return ip }
            if let host = extractHost(from: cloudMatchStringValue(item["resourcePath"]) ?? ""), !host.isEmpty { return host }
        }
        return ""
    }
}

public struct CloudMatchRequestStatus: Equatable, Sendable {
    public let statusCode: Int
    public let statusDescription: String
    public let requestId: String
    public let serverId: String

    public init(statusCode: Int = 0, statusDescription: String = "", requestId: String = "", serverId: String = "") {
        self.statusCode = statusCode
        self.statusDescription = statusDescription
        self.requestId = requestId
        self.serverId = serverId
    }

    public var succeeded: Bool { statusCode == 1 }

    public static func parse(_ value: Any?) -> CloudMatchRequestStatus {
        let dictionary = value as? [String: Any]
        return CloudMatchRequestStatus(
            statusCode: intValue(dictionary?["statusCode"]),
            statusDescription: cloudMatchStringValue(dictionary?["statusDescription"]) ?? "",
            requestId: cloudMatchStringValue(dictionary?["requestId"]) ?? "",
            serverId: cloudMatchStringValue(dictionary?["serverId"]) ?? ""
        )
    }
}

public enum CloudMatchResponseParser {
    public static func requestStatus(from json: [String: Any]) -> CloudMatchRequestStatus {
        CloudMatchRequestStatus.parse(json["requestStatus"])
    }

    public static func requestSucceeded(_ json: [String: Any]) -> Bool {
        requestStatus(from: json).succeeded
    }

    public static func requestStatusError(data: Data, fallback: String) -> String {
        guard let json = jsonDictionary(data) else { return fallback }
        let status = requestStatus(from: json)
        return "API error \(status.statusCode): \(status.statusDescription.isEmpty ? "unknown" : status.statusDescription)"
    }

    public static func isSessionLimitExceededResponse(_ json: [String: Any]) -> Bool {
        let status = requestStatus(from: json)
        return status.statusCode == 11 || status.statusDescription.contains("SESSION_LIMIT")
    }

    public static func isSessionNotPausedResponse(_ data: Data?) -> Bool {
        guard let data, let json = jsonDictionary(data) else { return false }
        let status = requestStatus(from: json)
        return status.statusCode == 34 || status.statusDescription.contains("SESSION_NOT_PAUSED")
    }

    public static func staleActiveSessionClaimMessage(_ data: Data?) -> String? {
        guard let data, let json = jsonDictionary(data) else { return nil }
        let status = requestStatus(from: json)
        let session = json["session"] as? [String: Any]
        let sessionRequestData = session?["sessionRequestData"] as? [String: Any]
        guard let responseAppId = sessionRequestData?["appId"], intValue(responseAppId) <= 0 else { return nil }
        let isInternalSessionFailure = status.statusCode == 4 || status.statusDescription.contains("INTERNAL_ERROR_STATUS") || status.statusDescription.contains("8A8C0000")
        return isInternalSessionFailure ? "This GeForce NOW session is no longer resumable. End it and launch again." : nil
    }

    public static func jsonDictionary(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

public protocol CloudMatchHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct CloudMatchURLSessionTransport: CloudMatchHTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await OPNURLSessionHTTPTransport.send(request, operation: "cloudmatch.transport", invalidHTTPResponseError: CloudMatchServiceError.invalidHTTPResponse)
    }
}

public enum CloudMatchServiceError: LocalizedError, Equatable, Sendable {
    case invalidURL(CloudMatch.Endpoint)
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidJSONResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let endpoint): "Invalid CloudMatch URL for \(endpoint.rawValue)"
        case .invalidHTTPResponse: "Invalid CloudMatch HTTP response"
        case .httpStatus(let status): "CloudMatch HTTP status \(status)"
        case .invalidJSONResponse: "Invalid CloudMatch JSON response"
        }
    }
}

public struct CloudMatchService<Transport: CloudMatchHTTPTransport>: Sendable {
    private let configuration: CloudMatchConfiguration
    private let transport: Transport

    public init(configuration: CloudMatchConfiguration = .gfnPC, transport: Transport) {
        self.configuration = configuration
        self.transport = transport
    }

    public func fetchServiceUrls(accessToken: String = "", queryItems: [URLQueryItem] = []) async throws -> [String: Any] {
        try await performEndpointRequest(.serviceUrls, accessToken: accessToken, queryItems: queryItems)
    }

    public func fetchServerInfo(accessToken: String = "", queryItems: [URLQueryItem] = []) async throws -> CloudMatchServerInfo {
        CloudMatchServerInfoParser.parse(try await performEndpointRequest(.serverInfo, accessToken: accessToken, queryItems: queryItems))
    }

    public func createNetworkTestSession(accessToken: String = "", queryItems: [URLQueryItem] = []) async throws -> [String: Any] {
        try await performEndpointRequest(.networkTestSession, accessToken: accessToken, queryItems: queryItems)
    }

    public func fetchSubscriptions(accessToken: String, queryItems: [URLQueryItem] = []) async throws -> [String: Any] {
        try await performEndpointRequest(.subscriptions, accessToken: accessToken, queryItems: queryItems)
    }

    private func performEndpointRequest(_ endpoint: CloudMatch.Endpoint, accessToken: String, queryItems: [URLQueryItem]) async throws -> [String: Any] {
        guard let request = CloudMatchRequestFactory.request(endpoint: endpoint, accessToken: accessToken, queryItems: queryItems, configuration: configuration) else { throw CloudMatchServiceError.invalidURL(endpoint) }
        return try await performJSONRequest(request)
    }

    private func performJSONRequest(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw CloudMatchServiceError.httpStatus(response.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudMatchServiceError.invalidJSONResponse }
        return json
    }
}

private func usableEndpointHost(_ host: String) -> String {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix(".") else { return "" }
    return trimmed
}

private func extractHost(from value: String) -> String? {
    if let host = URL(string: value)?.host, !host.isEmpty { return host }
    let withoutScheme = value.replacingOccurrences(of: "rtsps://", with: "").replacingOccurrences(of: "wss://", with: "")
    return withoutScheme.split(separator: "/").first?.split(separator: ":").first.map(String.init)
}

private func arrayValue(_ value: Any?) -> [Any] {
    value as? [Any] ?? []
}

private func cloudMatchStringValue(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    if let string = value as? NSString { return string as String }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

private func intValue(_ value: Any?) -> Int {
    if let int = value as? Int { return int }
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) ?? 0 }
    return 0
}
