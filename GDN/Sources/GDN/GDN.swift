import Foundation

public enum GDN: Sendable {
    public static let systemName = "GDN"
    public static let productName = "NVIDIAGDN"
    public static let cloudVariablesURLString = "https://api.gdn.nvidia.com/cloudvariables/v3"
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
