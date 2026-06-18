import Foundation

public enum Ragnarok: Sendable {
    public static let systemName = "Ragnarok"
    public static let productionEventsURLString = "https://events.telemetry.data.nvidia.com/v1.1/events/json"
    public static let uatEventsURLString = "https://events.telemetry.data-uat.nvidia.com/v1.1/events/json"
}

public extension Ragnarok {
    enum GDPRLevel: String, CaseIterable, Sendable {
        case behavioral = "Behavioral"
        case functional = "Functional"
        case technical = "Technical"
    }

    enum Personalization: String, CaseIterable, Sendable {
        case userPreferred = "UserPreferred"
    }

    enum EventName: String, CaseIterable, Sendable {
        case applicationInstall = "Application_Install"
        case authenticationProvider = "AuthenticationProvider"
        case autoUpdate = "AutoUpdate"
        case checkGFN = "CheckGFN"
        case exception = "Exception"
        case gameQuitEvent = "Game_Quit_Event"
        case gfnSession = "GFNSession"
        case httpFailure = "HTTPFailure"
        case httpSuccess = "HTTPSuccess"
        case launchProcess = "LaunchProcess"
        case loginStart = "LoginStart"
        case networkTest = "NetworkTest"
        case networkTestHTTP = "NetworkTest_Http_Event"
        case networkTestException = "NetworkTest_Exception_Event"
        case pageLoadPerformanceMetrics = "PageLoadPerformanceMetrics"
        case popUpDialogClosed = "PopUpDialogClosed"
        case popUpDialogShown = "PopUpDialogShown"
        case routingStatus = "RoutingStatus"
        case settingSnapshot = "SettingSnapshot"
        case streamingProfile = "StreamingProfile"
        case streamingQualityChanged = "StreamingQualityChangedEvent"
        case systemInfo = "SystemInfo"
        case uiAction = "UIAction"
        case userSession = "UserSession"
        case udsDialogShown = "UDSDialogShown"
        case udsSuggestionFeedback = "UDSSuggestionFeedback"
        case gameLaunchEvent = "Game_Launch_Event"
        case gameLaunchMetrics = "Game_Launch_Metrics"

        public var gdprLevel: GDPRLevel {
            switch self {
            case .applicationInstall, .networkTest, .userSession:
                .behavioral
            case .authenticationProvider, .autoUpdate, .checkGFN, .exception, .gameQuitEvent, .gfnSession, .httpFailure, .httpSuccess, .launchProcess, .networkTestHTTP, .pageLoadPerformanceMetrics, .popUpDialogShown, .routingStatus, .streamingQualityChanged, .systemInfo, .uiAction, .udsDialogShown, .udsSuggestionFeedback, .gameLaunchMetrics:
                .functional
            case .gameLaunchEvent, .loginStart, .networkTestException, .popUpDialogClosed, .settingSnapshot, .streamingProfile:
                .technical
            }
        }

        public var personalization: Personalization { .userPreferred }
    }
}

public struct RagnarokCommonData: Equatable, Sendable {
    public let appId: String
    public let clientVersion: String
    public let deviceId: String
    public let locale: String
    public let sessionId: String

    public init(appId: String = "gfnpc", clientVersion: String = "", deviceId: String = "", locale: String = "", sessionId: String = "") {
        self.appId = appId
        self.clientVersion = clientVersion
        self.deviceId = deviceId
        self.locale = locale
        self.sessionId = sessionId
    }

    public var dictionary: [String: String] {
        [
            "appId": appId,
            "clientVersion": clientVersion,
            "deviceId": deviceId,
            "locale": locale,
            "sessionId": sessionId,
        ].filter { !$0.value.isEmpty }
    }
}

public struct RagnarokConfiguration: Equatable, Sendable {
    public let eventsURLString: String
    public let userAgent: String

    public init(eventsURLString: String = Ragnarok.productionEventsURLString, userAgent: String = "NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173") {
        self.eventsURLString = eventsURLString
        self.userAgent = userAgent
    }

    public static let production = RagnarokConfiguration()
}

public struct RagnarokEvent: Equatable, Sendable {
    public let name: String
    public let timestamp: String
    public let parameters: [String: String]
    public let gdprLevel: Ragnarok.GDPRLevel?
    public let personalization: Ragnarok.Personalization?

    public init(name: String, timestamp: String = ISO8601DateFormatter().string(from: Date()), parameters: [String: String] = [:], gdprLevel: Ragnarok.GDPRLevel? = nil, personalization: Ragnarok.Personalization? = nil) {
        self.name = name
        self.timestamp = timestamp
        self.parameters = parameters
        self.gdprLevel = gdprLevel
        self.personalization = personalization
    }

    public init(eventName: Ragnarok.EventName, timestamp: String = ISO8601DateFormatter().string(from: Date()), parameters: [String: String] = [:]) {
        self.init(name: eventName.rawValue, timestamp: timestamp, parameters: parameters, gdprLevel: eventName.gdprLevel, personalization: eventName.personalization)
    }

    public var jsonObject: [String: Any] {
        var object: [String: Any] = ["name": name, "ts": timestamp, "parameters": parameters]
        if let gdprLevel { object["gdprLevel"] = gdprLevel.rawValue }
        if let personalization { object["personalization"] = personalization.rawValue }
        return object
    }
}

public enum RagnarokRequestFactory {
    public static func eventsRequest(events: [RagnarokEvent], commonData: RagnarokCommonData, configuration: RagnarokConfiguration = .production, timeoutInterval: TimeInterval = 10) -> URLRequest? {
        eventsRequest(events: events, commonData: commonData.dictionary, configuration: configuration, timeoutInterval: timeoutInterval)
    }

    public static func eventsRequest(events: [RagnarokEvent], commonData: [String: String] = [:], configuration: RagnarokConfiguration = .production, timeoutInterval: TimeInterval = 10) -> URLRequest? {
        guard let url = URL(string: configuration.eventsURLString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = ["commonData": commonData, "events": events.map(\.jsonObject)]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}

public protocol RagnarokHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct RagnarokURLSessionTransport: RagnarokHTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw RagnarokServiceError.invalidHTTPResponse }
        return (data, httpResponse)
    }
}

public enum RagnarokServiceError: LocalizedError, Equatable, Sendable {
    case invalidEventsURL
    case invalidHTTPResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidEventsURL: "Invalid Ragnarok events URL"
        case .invalidHTTPResponse: "Invalid Ragnarok HTTP response"
        case .httpStatus(let status): "Ragnarok HTTP status \(status)"
        }
    }
}

public struct RagnarokService<Transport: RagnarokHTTPTransport>: Sendable {
    private let configuration: RagnarokConfiguration
    private let transport: Transport

    public init(configuration: RagnarokConfiguration = .production, transport: Transport) {
        self.configuration = configuration
        self.transport = transport
    }

    public func send(events: [RagnarokEvent], commonData: RagnarokCommonData = RagnarokCommonData()) async throws -> HTTPURLResponse {
        guard let request = RagnarokRequestFactory.eventsRequest(events: events, commonData: commonData, configuration: configuration) else { throw RagnarokServiceError.invalidEventsURL }
        let (_, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw RagnarokServiceError.httpStatus(response.statusCode) }
        return response
    }
}
