import Foundation

public enum NetworkTest: Sendable {
    public static let systemName = "NetworkTest"
    public static let routePath = "/v2/nettestsession"
    public static let defaultUserAgent = "GFN-PC/1.0 (WebRTC) NetworkTest/0.0.51 "
}

public extension NetworkTest {
    enum LifecycleState: String, CaseIterable, Sendable {
        case idle = "Idle"
        case started = "Started"
        case finished = "Finished"
        case cancelled = "Cancelled"
        case failed = "Failed"
    }

    enum EventName: String, CaseIterable, Sendable {
        case networkTest = "NetworkTest"
        case analytics = "NetworkTestAnalytics"
        case completed = "NetworkTestCompleted"
        case httpEvent = "NetworkTest_Http_Event"
        case exception = "NetworkTest_Exception_Event"
    }

    enum ErrorName: String, CaseIterable, Sendable {
        case cancelled = "NetworkTestCancelled"
        case failed = "NetworkTestFailed"
        case sdkError = "NetworkTestSdkError"
        case geronimoNetworkTestError = "GeronimoNetworkTestError"
    }
}

public struct NetworkTestLifecycle: Equatable, Sendable {
    public let state: NetworkTest.LifecycleState
    public let result: NetworkTestResult?
    public let errorName: NetworkTest.ErrorName?

    public init(state: NetworkTest.LifecycleState = .idle, result: NetworkTestResult? = nil, errorName: NetworkTest.ErrorName? = nil) {
        self.state = state
        self.result = result
        self.errorName = errorName
    }

    public func starting() -> NetworkTestLifecycle {
        NetworkTestLifecycle(state: .started)
    }

    public func finishing(result: NetworkTestResult) -> NetworkTestLifecycle {
        NetworkTestLifecycle(state: .finished, result: result)
    }

    public func cancelling() -> NetworkTestLifecycle {
        NetworkTestLifecycle(state: .cancelled, errorName: .cancelled)
    }

    public func failing(errorName: NetworkTest.ErrorName = .failed) -> NetworkTestLifecycle {
        NetworkTestLifecycle(state: .failed, errorName: errorName)
    }
}

public struct NetworkTestFingerprintRecord: Equatable, Sendable {
    public let fingerprint: String
    public let zoneAddress: String
    public let result: NetworkTestResult
    public let lastUpdatedEpochMs: Int64

    public init(fingerprint: String, zoneAddress: String, result: NetworkTestResult, lastUpdatedEpochMs: Int64) {
        self.fingerprint = fingerprint
        self.zoneAddress = zoneAddress
        self.result = result
        self.lastUpdatedEpochMs = lastUpdatedEpochMs
    }

    public var vendorKey: String {
        zoneAddress.isEmpty ? fingerprint : "\(fingerprint)_\(zoneAddress)"
    }
}

public struct NetworkTestConfiguration: Equatable, Sendable {
    public let baseURLString: String
    public let userAgent: String
    public let timeoutInterval: TimeInterval

    public init(baseURLString: String = "https://prod.cloudmatchbeta.nvidiagrid.net", userAgent: String = NetworkTest.defaultUserAgent, timeoutInterval: TimeInterval = 15) {
        self.baseURLString = baseURLString
        self.userAgent = userAgent
        self.timeoutInterval = timeoutInterval
    }

    public static let gfnPC = NetworkTestConfiguration()
}

public struct NetworkTestVideoProfile: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let frameRate: Int

    public init(width: Int = 1920, height: Int = 1080, frameRate: Int = 60) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.frameRate = max(1, frameRate)
    }

    public var jsonObject: [String: Any] {
        [
            "width": width,
            "height": height,
            "frameRate": frameRate,
        ]
    }

    public var vendorNetTestProfileObject: [String: Any] {
        [
            "widthInPixels": width,
            "heightInPixels": height,
            "framesPerSecond": frameRate,
        ]
    }

    public var monitorSettingsObject: [String: Any] {
        [
            "widthInPixels": width,
            "heightInPixels": height,
            "framesPerSecond": frameRate,
        ]
    }
}

public struct NetworkTestSessionRequestPayload: Equatable, Sendable {
    public let appId: Int
    public let videoProfile: NetworkTestVideoProfile

    public init(appId: Int = 0, videoProfile: NetworkTestVideoProfile = NetworkTestVideoProfile()) {
        self.appId = max(0, appId)
        self.videoProfile = videoProfile
    }

    public static let gfnPC = NetworkTestSessionRequestPayload()

    public var jsonObject: [String: Any] {
        let requestData: [String: Any] = [
            "clientPlatformName": "gfn_browser_client",
            "netTestProfile": videoProfile.vendorNetTestProfileObject,
        ]
        return ["netTestRequestData": requestData]
    }
}

public enum NetworkTestRequestFactory {
    public static func sessionRequest(accessToken: String = "", queryItems: [URLQueryItem] = [], payload: NetworkTestSessionRequestPayload = .gfnPC, configuration: NetworkTestConfiguration = .gfnPC, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        var components = URLComponents(string: configuration.baseURLString + NetworkTest.routePath)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url,
              JSONSerialization.isValidJSONObject(payload.jsonObject),
              let body = try? JSONSerialization.data(withJSONObject: payload.jsonObject) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "x-nv-client-identity")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "nv-client-identity")
        request.setValue("1.0", forHTTPHeaderField: "x-nv-client-version")
        if !accessToken.isEmpty { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        return request
    }
}

public struct NetworkTestThreshold: Equatable, Sendable {
    public let bandwidthRecommended: Int
    public let bandwidthLimit: Int
    public let latencyRecommended: Int
    public let latencyLimit: Int
    public let packetLossRecommended: Double
    public let packetLossLimit: Double

    public init(bandwidthRecommended: Int = 0, bandwidthLimit: Int = 0, latencyRecommended: Int = 0, latencyLimit: Int = 0, packetLossRecommended: Double = 0, packetLossLimit: Double = 0) {
        self.bandwidthRecommended = bandwidthRecommended
        self.bandwidthLimit = bandwidthLimit
        self.latencyRecommended = latencyRecommended
        self.latencyLimit = latencyLimit
        self.packetLossRecommended = packetLossRecommended
        self.packetLossLimit = packetLossLimit
    }
}

public struct NetworkTestConnectionEndpoint: Equatable, Sendable {
    public let address: String
    public let port: Int
    public let appLevelProtocol: Int

    public init(address: String = "", port: Int = 0, appLevelProtocol: Int = 0) {
        self.address = address
        self.port = max(0, port)
        self.appLevelProtocol = appLevelProtocol
    }

    public var scheme: String {
        appLevelProtocol == 5 ? "https" : "http"
    }
}

public struct NetworkTestResult: Equatable, Sendable {
    public let sessionId: String
    public let zoneAddress: String
    public let zoneName: String
    public let serverId: String
    public let connectionEndpoint: NetworkTestConnectionEndpoint
    public let threshold: NetworkTestThreshold
    public let downlinkBandwidth: Int
    public let maxPacketSize: Int
    public let rawStatus: String

    public var isCompleted: Bool {
        rawStatus.caseInsensitiveCompare("COMPLETED") == .orderedSame || rawStatus.caseInsensitiveCompare("SUCCESS") == .orderedSame
    }

    public init(sessionId: String = "", zoneAddress: String = "", zoneName: String = "", serverId: String = "", connectionEndpoint: NetworkTestConnectionEndpoint = NetworkTestConnectionEndpoint(), threshold: NetworkTestThreshold = NetworkTestThreshold(), downlinkBandwidth: Int = 0, maxPacketSize: Int = 0, rawStatus: String = "") {
        self.sessionId = sessionId
        self.zoneAddress = zoneAddress
        self.zoneName = zoneName
        self.serverId = serverId
        self.connectionEndpoint = connectionEndpoint
        self.threshold = threshold
        self.downlinkBandwidth = downlinkBandwidth
        self.maxPacketSize = maxPacketSize
        self.rawStatus = rawStatus
    }
}

public enum NetworkTestResultParser {
    public static func parse(_ json: [String: Any]) -> NetworkTestResult {
        let requestStatus = dictionaryValue(json["requestStatus"]) ?? [:]
        let netTestSession = dictionaryValue(json["netTestSession"]) ?? dictionaryValue(json["net_test_session"])
        let testResult = dictionaryValue(json["testResult"]) ?? dictionaryValue(json["test_result"]) ?? json
        let zone = dictionaryValue(json["zone"]) ?? dictionaryValue(testResult["zone"]) ?? [:]
        let connectionInfo = arrayValue(netTestSession?["connectionInfo"]).compactMap { dictionaryValue($0) }.first ?? [:]
        let endpoint = NetworkTestConnectionEndpoint(
            address: stringValue(connectionInfo["ip"]) ?? "",
            port: intValue(connectionInfo["port"]) ?? 0,
            appLevelProtocol: intValue(connectionInfo["appLevelProtocol"]) ?? 0
        )
        let thresholds = dictionaryValue(netTestSession?["netTestThresholds"]) ?? [:]
        return NetworkTestResult(
            sessionId: stringValue(netTestSession?["sessionId"]) ?? stringValue(json["networkSessionId"]) ?? stringValue(json["network_session_id"]) ?? stringValue(json["sessionId"]) ?? "",
            zoneAddress: endpoint.address.isEmpty ? (stringValue(zone["address"]) ?? stringValue(json["zoneAddress"]) ?? "") : endpoint.address,
            zoneName: stringValue(zone["name"]) ?? stringValue(json["zoneName"]) ?? stringValue(requestStatus["serverId"]) ?? "",
            serverId: stringValue(netTestSession?["serverId"]) ?? stringValue(requestStatus["serverId"]) ?? "",
            connectionEndpoint: endpoint,
            threshold: NetworkTestThreshold(
                bandwidthRecommended: intValue(thresholds["recommendedBandwidthMBPS"]) ?? 0,
                bandwidthLimit: intValue(thresholds["requiredBandwidthMBPS"]) ?? 0,
                latencyRecommended: intValue(thresholds["recommendedLatencyMS"]) ?? 0,
                latencyLimit: intValue(thresholds["requiredLatencyMS"]) ?? 0,
                packetLossRecommended: doubleValue(thresholds["recommendedPacketLossPct"]) ?? 0,
                packetLossLimit: doubleValue(thresholds["requiredPacketLossPct"]) ?? 0
            ),
            downlinkBandwidth: intValue(testResult["downlinkBandwidth"]) ?? intValue(testResult["downlink_bandwidth"]) ?? 0,
            maxPacketSize: intValue(testResult["maxPacketSize"]) ?? intValue(testResult["max_packet_size"]) ?? 0,
            rawStatus: stringValue(json["status"]) ?? stringValue(testResult["status"]) ?? stringValue(requestStatus["statusDescription"]) ?? ""
        )
    }

    private static func dictionaryValue(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func arrayValue(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }
}

public protocol NetworkTestHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct NetworkTestURLSessionTransport: NetworkTestHTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await OPNURLSessionHTTPTransport.send(request, operation: "networkTest.transport", invalidHTTPResponseError: NetworkTestServiceError.invalidHTTPResponse)
    }
}

public enum NetworkTestServiceError: LocalizedError, Equatable, Sendable {
    case invalidSessionURL
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidJSONResponse

    public var errorDescription: String? {
        switch self {
        case .invalidSessionURL: "Invalid NetworkTest session URL"
        case .invalidHTTPResponse: "Invalid NetworkTest HTTP response"
        case .httpStatus(let status): "NetworkTest HTTP status \(status)"
        case .invalidJSONResponse: "Invalid NetworkTest JSON response"
        }
    }
}

public actor NetworkTestService<Transport: NetworkTestHTTPTransport> {
    public private(set) var lifecycle: NetworkTestLifecycle

    private let configuration: NetworkTestConfiguration
    private let transport: Transport

    public init(configuration: NetworkTestConfiguration = .gfnPC, transport: Transport, lifecycle: NetworkTestLifecycle = NetworkTestLifecycle()) {
        self.configuration = configuration
        self.transport = transport
        self.lifecycle = lifecycle
    }

    public func startSession(accessToken: String = "", queryItems: [URLQueryItem] = [], payload: NetworkTestSessionRequestPayload = .gfnPC) async throws -> NetworkTestResult {
        lifecycle = lifecycle.starting()
        guard let request = NetworkTestRequestFactory.sessionRequest(accessToken: accessToken, queryItems: queryItems, payload: payload, configuration: configuration, timeoutInterval: configuration.timeoutInterval) else {
            lifecycle = lifecycle.failing(errorName: .sdkError)
            throw NetworkTestServiceError.invalidSessionURL
        }
        do {
            let json = try await performJSONRequest(request)
            let result = NetworkTestResultParser.parse(json)
            lifecycle = lifecycle.finishing(result: result)
            return result
        } catch {
            lifecycle = lifecycle.failing(errorName: .failed)
            throw error
        }
    }

    public func cancel() {
        lifecycle = lifecycle.cancelling()
    }

    private func performJSONRequest(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw NetworkTestServiceError.httpStatus(response.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NetworkTestServiceError.invalidJSONResponse }
        return json
    }
}
