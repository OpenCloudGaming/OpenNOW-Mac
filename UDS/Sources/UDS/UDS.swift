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
