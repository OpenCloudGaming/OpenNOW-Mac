import Foundation
import OpenNOWTelemetry

public enum GDN: Sendable {
    public static let systemName = "GDN"
    public static let productName = "NVIDIAGDN"
    public static let serviceName = "GxTarget"
    public static let cloudVariablesURLString = "https://api.gdn.nvidia.com/cloudvariables/v3"
}

public extension GDN {
    enum Endpoint: String, CaseIterable, Sendable {
        case cloudVariables = "/cloudvariables/v3"

        public var path: String { rawValue }
    }

    enum Operation: String, CaseIterable, Sendable {
        case getFeatureRollout = "GetFeatureRollout"
        case getCloudVariable = "GetCloudVariable"
        case getSurveyFeature = "GetSurveyFeature"
        case other = "Other"
    }

    enum ExperienceUseCase: String, CaseIterable, Sendable {
        case getECommerceFeature = "GetECommerceFeature"
        case getSurveyFeature = "GetSurveyFeature"
        case getQueueETAConfig = "GetQueueETAConfig"
        case getAutohighlightFeature = "GetAutohighlightFeature"
        case getFreestyleFeature = "GetFreestyleFeature"
        case getStarfleetPhase1 = "GetStarfleetPhase1"
        case getStarfleetPhase2 = "GetStarfleetPhase2"
        case getKeyboardLayout = "GetKeyboardLayout"
        case getAnselFeature = "GetAnselFeature"
        case getGfnBroadcastFeature = "GetGfnBroadcastFeature"
        case getDeeplinkSupport = "GetDeeplinkSupport"
        case getKBLayoutsConfig = "GetKBLayoutsConfig"
        case getUpsellMessage = "GetUpsellMessage"
        case getAllCloudVariables = "GetAllCloudVariables"
        case getBrowserClientCanary = "GetBrowserClientCanary"
        case getReservedSKUEnabled = "GetReservedSKUEnabled"
        case getReservedSKUIBetaFlag = "GetReservedSKUIBetaFlag"
        case getPathToPurchaseConfig = "GetPathToPurchaseConfig"
        case getPunctualUIConfig = "GetPunctualUIConfig"
        case getEnableBrowserIGSS = "GetEnableBrowserIGSS"
        case getGuestFlowClientConfig = "GxTargetGetGuestFlowClientConfig"
        case getClientIMESupportedConfig = "GetClientIMESupportedConfig"
        case other = "Other"
    }

    enum ClientSource: String, CaseIterable, Sendable {
        case streamingClient = "StreamingClient"
        case mallClient = "MallClient"
        case storeLibrary = "StoreLibrary"
        case unknown = "Unknown"
        case backgroundAgent = "BackgroundAgent"
        case nvAppClient = "NvAppClient"
        case igo = "IGO"
    }

    enum CloudVariableStatus: String, CaseIterable, Sendable {
        case unknown = "Unknown"
        case active = "Active"
        case inactive = "Inactive"
    }
}

public enum GDNJSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: GDNJSONValue])
    case array([GDNJSONValue])
    case null

    public static func parse(_ value: Any?) -> GDNJSONValue {
        switch value {
        case let string as String:
            .string(string)
        case let bool as Bool:
            .bool(bool)
        case let number as NSNumber:
            .number(number.doubleValue)
        case let dictionary as [String: Any]:
            .object(dictionary.mapValues { parse($0) })
        case let array as [Any]:
            .array(array.map { parse($0) })
        case .none, _ as NSNull:
            .null
        default:
            .string(String(describing: value ?? ""))
        }
    }

    public var stringValue: String {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value ? String(Int64(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        case .object, .array, .null: ""
        }
    }
}

public struct GDNClientContext: Equatable, Sendable {
    public let clientId: String
    public let clientVersion: String
    public let userId: String
    public let idpId: String
    public let deviceId: String
    public let clientVariant: String
    public let clientType: String
    public let deviceOS: String
    public let deviceOSVersion: String
    public let deviceType: String
    public let deviceModel: String
    public let deviceMake: String
    public let browserType: String
    public let source: GDN.ClientSource

    public init(
        clientId: String = "",
        clientVersion: String = "",
        userId: String = "UNDEFINED",
        idpId: String = "UNDEFINED",
        deviceId: String = "",
        clientVariant: String = "UNDEFINED",
        clientType: String = "UNDEFINED",
        deviceOS: String = "",
        deviceOSVersion: String = "",
        deviceType: String = "",
        deviceModel: String = "",
        deviceMake: String = "",
        browserType: String = "",
        source: GDN.ClientSource = .mallClient
    ) {
        self.clientId = clientId
        self.clientVersion = clientVersion
        self.userId = userId.isEmpty ? "UNDEFINED" : userId
        self.idpId = idpId.isEmpty ? "UNDEFINED" : idpId
        self.deviceId = deviceId
        self.clientVariant = clientVariant.isEmpty ? "UNDEFINED" : clientVariant
        self.clientType = clientType.isEmpty ? "UNDEFINED" : clientType
        self.deviceOS = deviceOS
        self.deviceOSVersion = deviceOSVersion
        self.deviceType = deviceType
        self.deviceModel = deviceModel
        self.deviceMake = deviceMake
        self.browserType = browserType
        self.source = source
    }

    public var hasVendorRequiredFields: Bool {
        !clientId.isEmpty && !clientVersion.isEmpty && !deviceId.isEmpty
    }

    public var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "clientId", value: clientId),
            URLQueryItem(name: "clientVer", value: clientVersion),
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "idpId", value: idpId),
            URLQueryItem(name: "deviceId", value: deviceId),
            URLQueryItem(name: "clientVariant", value: clientVariant),
            URLQueryItem(name: "clientType", value: clientType),
            URLQueryItem(name: "deviceOS", value: deviceOS),
            URLQueryItem(name: "deviceOSVersion", value: deviceOSVersion),
            URLQueryItem(name: "deviceType", value: deviceType),
            URLQueryItem(name: "deviceModel", value: deviceModel),
            URLQueryItem(name: "deviceMake", value: deviceMake),
            URLQueryItem(name: "browserType", value: browserType),
            URLQueryItem(name: "source", value: source.rawValue),
        ].filter { item in
            item.value?.isEmpty == false
        }
    }
}

public struct GDNCloudVariable: Equatable, Sendable {
    public let name: String
    public let variation: String
    public let value: GDNJSONValue
    public let activity: [String: GDNJSONValue]
    public let metadata: [String: GDNJSONValue]
    public let isCachedResult: Bool
    public let state: GDN.CloudVariableStatus

    public init(name: String = "", variation: String = "", value: GDNJSONValue = .null, activity: [String: GDNJSONValue] = [:], metadata: [String: GDNJSONValue] = [:], isCachedResult: Bool = false, state: GDN.CloudVariableStatus = .unknown) {
        self.name = name
        self.variation = variation
        self.value = value
        self.activity = activity
        self.metadata = metadata
        self.isCachedResult = isCachedResult
        self.state = state
    }
}

public enum GDNCloudVariableParser {
    public static func parse(_ json: [String: Any], requestedName: String = "", isCachedResult: Bool = false) -> GDNCloudVariable {
        let payload = cloudVariablePayload(json, requestedName: requestedName)
        return GDNCloudVariable(
            name: stringValue(payload["name"]) ?? stringValue(payload["key"]) ?? requestedName,
            variation: stringValue(payload["variation"]) ?? stringValue(payload["result"]) ?? "",
            value: GDNJSONValue.parse(payload["value"]),
            activity: (dictionaryValue(payload["activity"]) ?? [:]).mapValues { GDNJSONValue.parse($0) },
            metadata: (dictionaryValue(payload["metadata"]) ?? [:]).mapValues { GDNJSONValue.parse($0) },
            isCachedResult: isCachedResult,
            state: GDN.CloudVariableStatus(rawValue: stringValue(payload["state"]) ?? "") ?? .unknown
        )
    }

    private static func cloudVariablePayload(_ json: [String: Any], requestedName: String) -> [String: Any] {
        if let variable = dictionaryValue(json["cloudVariable"]) { return variable }
        if let variable = dictionaryValue(json["variable"]) { return variable }
        if let variables = json["variables"] as? [[String: Any]] {
            if !requestedName.isEmpty, let matched = variables.first(where: { stringValue($0["name"]) == requestedName || stringValue($0["key"]) == requestedName }) { return matched }
            if let first = variables.first { return first }
        }
        return json
    }

    private static func dictionaryValue(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

public struct GDNConfiguration: Equatable, Sendable {
    public let cloudVariablesURLString: String
    public let userAgent: String

    public init(cloudVariablesURLString: String = GDN.cloudVariablesURLString, userAgent: String = "NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173") {
        self.cloudVariablesURLString = cloudVariablesURLString
        self.userAgent = userAgent
    }

    public static let gfnPC = GDNConfiguration()
}

public enum GDNRequestFactory {
    public static func cloudVariablesQueryItems(product: String = GDN.productName, locale: String = "", additionalItems: [URLQueryItem] = []) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "product", value: product)]
        if !locale.isEmpty { items.append(URLQueryItem(name: "locale", value: locale)) }
        items.append(contentsOf: additionalItems)
        return items
    }

    public static func cloudVariablesRequest(queryItems: [URLQueryItem] = [], configuration: GDNConfiguration = .gfnPC, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        var components = URLComponents(string: configuration.cloudVariablesURLString)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    public static func cloudVariableRequest(name: String, context: GDNClientContext, additionalItems: [URLQueryItem] = [], configuration: GDNConfiguration = .gfnPC, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        var items = cloudVariablesQueryItems(additionalItems: [URLQueryItem(name: "name", value: name)] + context.queryItems)
        items.append(contentsOf: additionalItems)
        return cloudVariablesRequest(queryItems: items, configuration: configuration, timeoutInterval: timeoutInterval)
    }
}

public protocol GDNHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct GDNURLSessionTransport: GDNHTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await OPNURLSessionHTTPTransport.send(request, operation: "gdn.transport", invalidHTTPResponseError: GDNServiceError.invalidHTTPResponse)
    }
}

public enum GDNServiceError: LocalizedError, Equatable, Sendable {
    case invalidCloudVariablesURL
    case missingClientContext
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidJSONResponse

    public var errorDescription: String? {
        switch self {
        case .invalidCloudVariablesURL: "Invalid GDN cloud variables URL"
        case .missingClientContext: "Missing GDN client context"
        case .invalidHTTPResponse: "Invalid GDN HTTP response"
        case .httpStatus(let status): "GDN HTTP status \(status)"
        case .invalidJSONResponse: "Invalid GDN JSON response"
        }
    }
}

public struct GDNService<Transport: GDNHTTPTransport>: Sendable {
    private let configuration: GDNConfiguration
    private let transport: Transport

    public init(configuration: GDNConfiguration = .gfnPC, transport: Transport) {
        self.configuration = configuration
        self.transport = transport
    }

    public func fetchCloudVariables(product: String = GDN.productName, locale: String = "", additionalItems: [URLQueryItem] = []) async throws -> [String: Any] {
        let queryItems = GDNRequestFactory.cloudVariablesQueryItems(product: product, locale: locale, additionalItems: additionalItems)
        guard let request = GDNRequestFactory.cloudVariablesRequest(queryItems: queryItems, configuration: configuration) else { throw GDNServiceError.invalidCloudVariablesURL }
        return try await performJSONRequest(request)
    }

    public func fetchCloudVariable(name: String, context: GDNClientContext, additionalItems: [URLQueryItem] = []) async throws -> GDNCloudVariable {
        guard context.hasVendorRequiredFields else { throw GDNServiceError.missingClientContext }
        guard let request = GDNRequestFactory.cloudVariableRequest(name: name, context: context, additionalItems: additionalItems, configuration: configuration) else { throw GDNServiceError.invalidCloudVariablesURL }
        return GDNCloudVariableParser.parse(try await performJSONRequest(request), requestedName: name)
    }

    private func performJSONRequest(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw GDNServiceError.httpStatus(response.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GDNServiceError.invalidJSONResponse }
        return json
    }
}
