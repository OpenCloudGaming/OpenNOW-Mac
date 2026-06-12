import Foundation

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
        case getCloudVariable = "GxTargetGetCloudVariable"
        case getSurvey = "GxTargetGetSurvey"
        case putSurvey = "GxTargetPutSurvey"
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
}
