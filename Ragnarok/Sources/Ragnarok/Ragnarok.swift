import Foundation

public enum Ragnarok: Sendable {
    public static let systemName = "Ragnarok"
    public static let productionEventsURLString = "https://events.telemetry.data.nvidia.com/v1.1/events/json"
    public static let uatEventsURLString = "https://events.telemetry.data-uat.nvidia.com/v1.1/events/json"
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

    public init(name: String, timestamp: String = ISO8601DateFormatter().string(from: Date()), parameters: [String: String] = [:]) {
        self.name = name
        self.timestamp = timestamp
        self.parameters = parameters
    }

    public var jsonObject: [String: Any] {
        ["name": name, "ts": timestamp, "parameters": parameters]
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
