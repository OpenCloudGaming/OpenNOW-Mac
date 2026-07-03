import Foundation
import OpenNOWTelemetry

public enum UDS: Sendable {
    public static let systemName = "UDS"
    public static let productionBaseURLString = "https://uds.geforcenow.com"
    public static let reportPath = "/v1/uds/session/reports"
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
        self.sessionDurationInSeconds = max(0, sessionDurationInSeconds)
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

    public func eventObject(useCase: UDS.UseCase) -> [String: Any] {
        var payload = jsonObject
        payload["useCase"] = useCase.rawValue
        payload["triggerSource"] = source.rawValue
        return payload
    }

    public var summonedQueryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "source", value: source.rawValue),
            URLQueryItem(name: "locale", value: locale),
        ]
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

public struct UDSEventReportResult: Equatable, Sendable {
    public let accepted: Bool
    public let status: String

    public init(accepted: Bool = false, status: String = "") {
        self.accepted = accepted
        self.status = status
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
}

public enum UDSEventReportParser {
    public static func parse(_ json: [String: Any]) -> UDSEventReportResult {
        UDSEventReportResult(
            accepted: boolValue(json["accepted"]) ?? boolValue(json["success"]) ?? false,
            status: stringValue(json["status"]) ?? stringValue(json["statusDescription"]) ?? ""
        )
    }
}

public struct UDSRetryConfiguration: Equatable, Sendable {
    public let defaultRetries: Int
    public let defaultTimeoutMilliseconds: Int
    public let exponentialBackoffMaxDelayMilliseconds: Int
    public let exponentialBackoffFirstRetryIntervalMilliseconds: Int
    public let exponentGrowthFactor: Double

    public init(defaultRetries: Int = 2, defaultTimeoutMilliseconds: Int = 5_000, exponentialBackoffMaxDelayMilliseconds: Int = 5_000, exponentialBackoffFirstRetryIntervalMilliseconds: Int = 4_000, exponentGrowthFactor: Double = 1) {
        self.defaultRetries = max(0, defaultRetries)
        self.defaultTimeoutMilliseconds = max(1, defaultTimeoutMilliseconds)
        self.exponentialBackoffMaxDelayMilliseconds = max(1, exponentialBackoffMaxDelayMilliseconds)
        self.exponentialBackoffFirstRetryIntervalMilliseconds = max(1, exponentialBackoffFirstRetryIntervalMilliseconds)
        self.exponentGrowthFactor = exponentGrowthFactor.isFinite ? max(0, exponentGrowthFactor) : 1
    }

    public static let production = UDSRetryConfiguration()

    public var timeoutInterval: TimeInterval {
        TimeInterval(defaultTimeoutMilliseconds) / 1_000
    }

    public func delayBeforeRetry(attempt: Int) -> TimeInterval {
        let multiplier = pow(1 + exponentGrowthFactor, Double(max(0, attempt)))
        let milliseconds = min(Double(exponentialBackoffMaxDelayMilliseconds), Double(exponentialBackoffFirstRetryIntervalMilliseconds) * multiplier)
        return milliseconds / 1_000
    }
}

public struct UDSClientHeaders: Equatable, Sendable {
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
                userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 GFN-PC/2.0.80.173") {
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

    public static let lcars = UDSClientHeaders()

    public func apply(to request: inout URLRequest, accessToken: String, deviceId: String, hasBody: Bool) {
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if hasBody { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if !accessToken.isEmpty { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if !deviceId.isEmpty { request.setValue(deviceId, forHTTPHeaderField: "NV-Device-ID") }
        if !clientId.isEmpty { request.setValue(clientId, forHTTPHeaderField: "NV-Client-ID") }
        if !clientType.isEmpty { request.setValue(clientType, forHTTPHeaderField: "NV-Client-Type") }
        if !clientVersion.isEmpty { request.setValue(clientVersion, forHTTPHeaderField: "NV-Client-Version") }
        if !clientStreamer.isEmpty { request.setValue(clientStreamer, forHTTPHeaderField: "NV-Client-Streamer") }
        if !deviceOS.isEmpty { request.setValue(deviceOS, forHTTPHeaderField: "NV-Device-OS") }
        if !deviceType.isEmpty { request.setValue(deviceType, forHTTPHeaderField: "NV-Device-Type") }
        if !deviceMake.isEmpty { request.setValue(deviceMake, forHTTPHeaderField: "NV-Device-Make") }
        if !deviceModel.isEmpty { request.setValue(deviceModel, forHTTPHeaderField: "NV-Device-Model") }
        if !browserType.isEmpty { request.setValue(browserType, forHTTPHeaderField: "NV-Browser-Type") }
    }
}

public struct UDSConfiguration: Equatable, Sendable {
    public let serverURLString: String
    public let headers: UDSClientHeaders
    public let retryConfiguration: UDSRetryConfiguration

    public var userAgent: String { headers.userAgent }

    public init(serverURLString: String = UDS.productionBaseURLString, headers: UDSClientHeaders = .lcars, retryConfiguration: UDSRetryConfiguration = .production) {
        self.serverURLString = UDSConfiguration.normalizedServerURLString(serverURLString)
        self.headers = headers
        self.retryConfiguration = retryConfiguration
    }

    public init(serverURLString: String = UDS.productionBaseURLString, userAgent: String) {
        self.init(serverURLString: serverURLString, headers: UDSClientHeaders(userAgent: userAgent))
    }

    public static let production = UDSConfiguration()

    private static func normalizedServerURLString(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? UDS.productionBaseURLString : trimmed
    }
}

public enum UDSRequestFactory {
    public static func reportRequest(useCase: UDS.UseCase, payload: UDSReportPayload, accessToken: String = "", deviceId: String = "", configuration: UDSConfiguration = .production, timeoutInterval: TimeInterval? = nil) -> URLRequest? {
        switch useCase {
        case .summonedReport:
            return request(path: UDS.reportPath, method: "GET", accessToken: accessToken, deviceId: deviceId.isEmpty ? payload.deviceId : deviceId, queryItems: payload.summonedQueryItems, body: nil, configuration: configuration, timeoutInterval: timeoutInterval ?? configuration.retryConfiguration.timeoutInterval)
        case .endOfSessionReport:
            return request(path: UDS.reportPath, method: "POST", accessToken: accessToken, deviceId: deviceId.isEmpty ? payload.deviceId : deviceId, body: payload.jsonObject, configuration: configuration, timeoutInterval: timeoutInterval ?? configuration.retryConfiguration.timeoutInterval)
        case .uds, .toastShown, .suggestionFeedback, .dialogShown:
            return request(path: UDS.reportPath, method: "POST", accessToken: accessToken, deviceId: deviceId.isEmpty ? payload.deviceId : deviceId, body: payload.eventObject(useCase: useCase), configuration: configuration, timeoutInterval: timeoutInterval ?? configuration.retryConfiguration.timeoutInterval)
        }
    }

    public static func request(path: String, method: String = "GET", accessToken: String = "", deviceId: String = "", queryItems: [URLQueryItem] = [], body: [String: Any]? = nil, configuration: UDSConfiguration = .production, timeoutInterval: TimeInterval? = nil) -> URLRequest? {
        var components = URLComponents(string: configuration.serverURLString + path)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval ?? configuration.retryConfiguration.timeoutInterval)
        request.httpMethod = method
        configuration.headers.apply(to: &request, accessToken: accessToken, deviceId: deviceId, hasBody: body != nil)
        if let body {
            guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
            request.httpBody = bodyData
        }
        return request
    }
}

public protocol UDSHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct UDSURLSessionTransport: UDSHTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var tracedRequest = request
        let networkStart = OPNNetworkLog.start(&tracedRequest, operation: "uds.transport")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: tracedRequest)
        } catch {
            OPNNetworkLog.finish(tracedRequest, operation: "uds.transport", startedAt: networkStart, data: nil, response: nil, error: error)
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            OPNNetworkLog.finish(tracedRequest, operation: "uds.transport", startedAt: networkStart, data: data, response: response, error: UDSServiceError.invalidHTTPResponse)
            throw UDSServiceError.invalidHTTPResponse
        }
        OPNNetworkLog.finish(tracedRequest, operation: "uds.transport", startedAt: networkStart, data: data, response: response, error: nil)
        return (data, httpResponse)
    }
}

public enum UDSServiceError: LocalizedError, Equatable, Sendable {
    case invalidRequest(UDS.UseCase)
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidJSONResponse

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let useCase): "Invalid UDS request for \(useCase.rawValue)"
        case .invalidHTTPResponse: "Invalid UDS HTTP response"
        case .httpStatus(let status): "UDS HTTP status \(status)"
        case .invalidJSONResponse: "Invalid UDS JSON response"
        }
    }
}

public actor UDSService<Transport: UDSHTTPTransport> {
    public private(set) var notificationState: UDSNotificationState

    private let configuration: UDSConfiguration
    private let transport: Transport

    public init(configuration: UDSConfiguration = .production, transport: Transport, notificationState: UDSNotificationState = UDSNotificationState()) {
        self.configuration = configuration
        self.transport = transport
        self.notificationState = notificationState
    }

    public func fetchSummonedReport(payload: UDSReportPayload, accessToken: String = "") async throws -> UDSDiagnosticReport {
        let json = try await performReportRequest(useCase: .summonedReport, payload: payload, accessToken: accessToken)
        notificationState = notificationState.afterSummonedReportOpened()
        return UDSDiagnosticReportParser.parse(json)
    }

    public func fetchEndOfSessionReport(payload: UDSReportPayload, accessToken: String = "") async throws -> UDSDiagnosticReport {
        UDSDiagnosticReportParser.parse(try await performReportRequest(useCase: .endOfSessionReport, payload: payload, accessToken: accessToken))
    }

    public func sendEvent(useCase: UDS.UseCase, payload: UDSReportPayload, accessToken: String = "") async throws -> UDSEventReportResult {
        UDSEventReportParser.parse(try await performReportRequest(useCase: useCase, payload: payload, accessToken: accessToken))
    }

    private func performReportRequest(useCase: UDS.UseCase, payload: UDSReportPayload, accessToken: String) async throws -> [String: Any] {
        guard let request = UDSRequestFactory.reportRequest(useCase: useCase, payload: payload, accessToken: accessToken, deviceId: payload.deviceId, configuration: configuration) else { throw UDSServiceError.invalidRequest(useCase) }
        return try await performJSONRequest(request)
    }

    private func performJSONRequest(_ request: URLRequest) async throws -> [String: Any] {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await transport.send(request)
                if response.statusCode == 200 {
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UDSServiceError.invalidJSONResponse }
                    return json
                }
                guard shouldRetry(statusCode: response.statusCode), attempt < configuration.retryConfiguration.defaultRetries else {
                    throw UDSServiceError.httpStatus(response.statusCode)
                }
            } catch let error as UDSServiceError {
                throw error
            } catch {
                guard attempt < configuration.retryConfiguration.defaultRetries else { throw error }
            }
            try await sleepBeforeRetry(attempt: attempt)
            attempt += 1
        }
    }

    private func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || statusCode >= 500
    }

    private func sleepBeforeRetry(attempt: Int) async throws {
        let seconds = configuration.retryConfiguration.delayBeforeRetry(attempt: attempt)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

private func stringValue(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

private func boolValue(_ value: Any?) -> Bool? {
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    return nil
}
