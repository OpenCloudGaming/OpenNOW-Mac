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
        case networkTest = "NetworkTest"
        case networkTestHTTP = "NetworkTest_Http_Event"
        case networkTestException = "NetworkTest_Exception_Event"
        case udsDialogShown = "UDSDialogShown"
        case udsSuggestionFeedback = "UDSSuggestionFeedback"
        case gameLaunchEvent = "Game_Launch_Event"
        case gameLaunchMetrics = "Game_Launch_Metrics"

        public var gdprLevel: GDPRLevel {
            switch self {
            case .networkTest:
                .behavioral
            case .networkTestHTTP, .udsDialogShown, .udsSuggestionFeedback, .gameLaunchMetrics:
                .functional
            case .networkTestException, .gameLaunchEvent:
                .technical
            }
        }

        public var personalization: Personalization { .userPreferred }
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
