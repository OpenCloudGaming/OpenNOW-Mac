import Foundation

public enum UDS: Sendable {
    public static let systemName = "UDS"
}

public extension UDS {
    enum UseCase: String, CaseIterable, Sendable {
        case uds = "UDS"
        case endOfSessionReport = "UdsEndOfSessionReport"
        case summonedReport = "UdsSummonedReport"
        case toastShown = "UDSToastShown"
        case suggestionFeedback = "UDSSuggestionFeedback"
        case dialogShown = "UDSDialogShown"
    }

    enum LaunchSource: String, CaseIterable, Sendable {
        case endOfSession = "EndOfSession"
        case mall = "Mall"
        case notification = "Notification"
    }

    enum TriggerSource: String, CaseIterable, Sendable {
        case endOfSession = "EndOfSession"
        case mall = "Mall"
        case notification = "Notification"
    }
}

public struct UDSNotificationState: Equatable, Sendable {
    public let canShowIcon: Bool
    public let hasNotification: Bool
    public let toastShown: Bool

    public init(canShowIcon: Bool = false, hasNotification: Bool = false, toastShown: Bool = false) {
        self.canShowIcon = canShowIcon
        self.hasNotification = hasNotification
        self.toastShown = toastShown
    }

    public func afterSummonedReportOpened() -> UDSNotificationState {
        UDSNotificationState(canShowIcon: false, hasNotification: false, toastShown: true)
    }
}

public struct UDSSnoozePolicy: Equatable, Sendable {
    public let durationInDays: Int
    public let disabled: Bool

    public init(durationInDays: Int, disabled: Bool = false) {
        self.durationInDays = max(0, durationInDays)
        self.disabled = disabled
    }

    public func stopDate(startingAt date: Date = Date()) -> Date? {
        guard !disabled, durationInDays > 0 else { return nil }
        return date.addingTimeInterval(TimeInterval(durationInDays * 24 * 60 * 60))
    }

    public func isSnoozed(until stopDate: Date?, now: Date = Date()) -> Bool {
        guard !disabled, let stopDate else { return false }
        return now < stopDate
    }
}

public struct UDSReportPayload: Equatable, Sendable {
    public let source: UDS.LaunchSource
    public let locale: String
    public let deviceId: String
    public let sessionId: String
    public let sessionDurationInSeconds: Int
    public let isVPN: Bool?

    public init(source: UDS.LaunchSource, locale: String = "", deviceId: String = "", sessionId: String = "", sessionDurationInSeconds: Int = 0, isVPN: Bool? = nil) {
        self.source = source
        self.locale = locale
        self.deviceId = deviceId
        self.sessionId = sessionId
        self.sessionDurationInSeconds = sessionDurationInSeconds
        self.isVPN = isVPN
    }

    public var jsonObject: [String: Any] {
        var payload: [String: Any] = [
            "source": source.rawValue,
            "locale": locale,
            "deviceId": deviceId,
            "sessionId": sessionId,
            "sessionDurationInSeconds": sessionDurationInSeconds,
        ]
        if let isVPN { payload["isVPN"] = isVPN }
        return payload
    }
}

public struct UDSDiagnosticReport: Equatable, Sendable {
    public let streamedAppName: String
    public let sessionId: String
    public let errorCode: String
    public let recommendationCount: Int
    public let areSAScoresGood: Bool

    public init(streamedAppName: String = "", sessionId: String = "", errorCode: String = "", recommendationCount: Int = 0, areSAScoresGood: Bool = false) {
        self.streamedAppName = streamedAppName
        self.sessionId = sessionId
        self.errorCode = errorCode
        self.recommendationCount = recommendationCount
        self.areSAScoresGood = areSAScoresGood
    }
}

public enum UDSDiagnosticReportParser {
    public static func parse(_ json: [String: Any]) -> UDSDiagnosticReport {
        let report = ((json["reports"] as? [[String: Any]])?.first) ?? json
        return UDSDiagnosticReport(
            streamedAppName: stringValue(report["streamedAppName"]) ?? "",
            sessionId: stringValue(report["sessionId"]) ?? "",
            errorCode: stringValue(report["errorCode"]) ?? stringValue(json["errorCode"]) ?? "",
            recommendationCount: (report["recommendationList"] as? [Any])?.count ?? 0,
            areSAScoresGood: boolValue(report["areSAScoresGood"]) ?? false
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }
}

public struct UDSConfiguration: Equatable, Sendable {
    public let serverURLString: String
    public let userAgent: String

    public init(serverURLString: String, userAgent: String = "NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173") {
        self.serverURLString = serverURLString
        self.userAgent = userAgent
    }
}

public enum UDSRequestFactory {
    public static func reportRequest(useCase: UDS.UseCase, payload: UDSReportPayload, accessToken: String = "", configuration: UDSConfiguration, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        request(path: "/report", method: useCase == .summonedReport ? "GET" : "POST", accessToken: accessToken, queryItems: [URLQueryItem(name: "serviceUseCase", value: useCase.rawValue)], body: useCase == .summonedReport ? nil : payload.jsonObject, configuration: configuration, timeoutInterval: timeoutInterval)
    }

    public static func request(path: String, method: String = "GET", accessToken: String = "", queryItems: [URLQueryItem] = [], body: [String: Any]? = nil, configuration: UDSConfiguration, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        var components = URLComponents(string: configuration.serverURLString + path)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = method
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if !accessToken.isEmpty { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
}
