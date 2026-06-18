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

    public init(baseURLString: String = "https://prod.cloudmatchbeta.nvidiagrid.net", userAgent: String = NetworkTest.defaultUserAgent) {
        self.baseURLString = baseURLString
        self.userAgent = userAgent
    }

    public static let gfnPC = NetworkTestConfiguration()
}

public enum NetworkTestRequestFactory {
    public static func sessionRequest(accessToken: String = "", queryItems: [URLQueryItem] = [], configuration: NetworkTestConfiguration = .gfnPC, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        var components = URLComponents(string: configuration.baseURLString + NetworkTest.routePath)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if !accessToken.isEmpty { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        return request
    }
}

public struct NetworkTestResult: Equatable, Sendable {
    public let sessionId: String
    public let zoneAddress: String
    public let zoneName: String
    public let downlinkBandwidth: Int
    public let maxPacketSize: Int
    public let rawStatus: String

    public var isCompleted: Bool {
        rawStatus.caseInsensitiveCompare("COMPLETED") == .orderedSame || rawStatus.caseInsensitiveCompare("SUCCESS") == .orderedSame
    }

    public init(sessionId: String = "", zoneAddress: String = "", zoneName: String = "", downlinkBandwidth: Int = 0, maxPacketSize: Int = 0, rawStatus: String = "") {
        self.sessionId = sessionId
        self.zoneAddress = zoneAddress
        self.zoneName = zoneName
        self.downlinkBandwidth = downlinkBandwidth
        self.maxPacketSize = maxPacketSize
        self.rawStatus = rawStatus
    }
}

public enum NetworkTestResultParser {
    public static func parse(_ json: [String: Any]) -> NetworkTestResult {
        let testResult = dictionaryValue(json["testResult"]) ?? dictionaryValue(json["test_result"]) ?? json
        let zone = dictionaryValue(json["zone"]) ?? dictionaryValue(testResult["zone"]) ?? [:]
        return NetworkTestResult(
            sessionId: stringValue(json["networkSessionId"]) ?? stringValue(json["network_session_id"]) ?? stringValue(json["sessionId"]) ?? "",
            zoneAddress: stringValue(zone["address"]) ?? stringValue(json["zoneAddress"]) ?? "",
            zoneName: stringValue(zone["name"]) ?? stringValue(json["zoneName"]) ?? "",
            downlinkBandwidth: intValue(testResult["downlinkBandwidth"]) ?? intValue(testResult["downlink_bandwidth"]) ?? 0,
            maxPacketSize: intValue(testResult["maxPacketSize"]) ?? intValue(testResult["max_packet_size"]) ?? 0,
            rawStatus: stringValue(json["status"]) ?? stringValue(testResult["status"]) ?? ""
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
}

public protocol NetworkTestHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct NetworkTestURLSessionTransport: NetworkTestHTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw NetworkTestServiceError.invalidHTTPResponse }
        return (data, httpResponse)
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

    public func startSession(accessToken: String = "", queryItems: [URLQueryItem] = []) async throws -> NetworkTestResult {
        lifecycle = lifecycle.starting()
        guard let request = NetworkTestRequestFactory.sessionRequest(accessToken: accessToken, queryItems: queryItems, configuration: configuration) else {
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
