import Foundation

public enum CloudMatch: Sendable {
    public static let systemName = "CloudMatch"
    public static let productionBaseURLString = "https://prod.cloudmatchbeta.nvidiagrid.net"
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

public struct CloudMatchConfiguration: Equatable, Sendable {
    public let baseURLString: String
    public let userAgent: String

    public init(baseURLString: String = CloudMatch.productionBaseURLString, userAgent: String = "NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173") {
        self.baseURLString = baseURLString
        self.userAgent = userAgent
    }

    public static let gfnPC = CloudMatchConfiguration()
}

public enum CloudMatchRequestFactory {
    public static func request(endpoint: CloudMatch.Endpoint, accessToken: String = "", queryItems: [URLQueryItem] = [], configuration: CloudMatchConfiguration = .gfnPC, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        var components = URLComponents(string: configuration.baseURLString + endpoint.path)
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if !accessToken.isEmpty { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        return request
    }
}

public enum CloudMatchServerInfoParser {
    public static func parse(_ json: [String: Any]) -> CloudMatchServerInfo {
        let metadata = metadataItems(from: json["metadata"])
        let values = Dictionary(uniqueKeysWithValues: metadata.compactMap { item -> (String, String)? in
            guard let key = item["key"], let value = item["value"] else { return nil }
            return (key, value)
        })
        let zones = zones(from: values)
        let localZone = values["local-region"].flatMap { zones[normalizedAddress($0)] }
        return CloudMatchServerInfo(
            vpcId: stringValue(json["vpcId"]) ?? stringValue(json["vpc_id"]) ?? "",
            serverType: stringValue(json["serverType"]) ?? stringValue(json["server_type"]) ?? "",
            zones: zones,
            defaultZone: localZone ?? zones.values.first,
            detectedLocalZone: localZone
        )
    }

    private static func metadataItems(from value: Any?) -> [[String: String]] {
        guard let array = value as? [[String: Any]] else { return [] }
        return array.map { item in
            var output: [String: String] = [:]
            if let key = stringValue(item["key"]) { output["key"] = key }
            if let value = stringValue(item["value"]) { output["value"] = value }
            return output
        }
    }

    private static func zones(from values: [String: String]) -> [String: CloudMatchZone] {
        values["gfn-regions"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String: CloudMatchZone]()) { result, name in
                guard let rawAddress = values[name] else { return }
                let address = normalizedAddress(rawAddress)
                result[address] = CloudMatchZone(name: name, address: address)
            } ?? [:]
    }

    private static func normalizedAddress(_ value: String) -> String {
        value.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

public enum CloudMatchRoutingPolicy {
    public static func decision(serverInfo: CloudMatchServerInfo, override: CloudMatchRouteOverride?) -> CloudMatchRouteDecision {
        guard let override else { return .useDefault(serverInfo.defaultZone) }
        if override.isInternal || serverInfo.zones.values.contains(override.zone) { return .useOverride(override) }
        return .clearUnavailableOverride(override)
    }
}
