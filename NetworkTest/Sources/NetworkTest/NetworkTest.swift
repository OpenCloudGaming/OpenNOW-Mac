import Foundation

public enum NetworkTest: Sendable {
    public static let systemName = "NetworkTest"
    public static let routePath = "/v2/nettestsession"
    public static let defaultUserAgent = "GFN-PC/1.0 (WebRTC) NetworkTest/0.0.51 "
}

public extension NetworkTest {
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
