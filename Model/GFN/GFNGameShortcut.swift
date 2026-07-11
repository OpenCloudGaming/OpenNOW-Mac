import Foundation

struct GFNGameShortcut: Equatable, Sendable {
    let sourceURL: URL?
    let displayName: String
    let cmsId: String
    let shortName: String
    let parentGameId: String
    let launchSource: String

    var lookupTitle: String {
        var title = displayName
        if Self.hasCaseInsensitiveSuffix(".gfnpc", in: title) {
            title = String(title.dropLast(6))
        }
        let suffix = " on GeForce NOW"
        if Self.hasCaseInsensitiveSuffix(suffix, in: title) {
            title = String(title.dropLast(suffix.count))
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var urlRoute: String {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "cmsId", value: cmsId),
            URLQueryItem(name: "launchSource", value: launchSource.isEmpty ? "External" : launchSource),
            URLQueryItem(name: "shortName", value: shortName),
            URLQueryItem(name: "parentGameId", value: parentGameId.isEmpty ? shortName : parentGameId)
        ]
        return "#?\(components.percentEncodedQuery ?? "")"
    }

    init(sourceURL: URL?, displayName: String, cmsId: String, shortName: String, parentGameId: String, launchSource: String = "External") {
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.cmsId = cmsId
        self.shortName = shortName
        self.parentGameId = parentGameId
        self.launchSource = launchSource
    }

    init(fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any], let route = dictionary["url-route"] as? String else {
            throw GFNGameShortcutError.invalidPayload
        }
        let values = Self.routeValues(from: route)
        let cmsId = values["cmsId"] ?? ""
        let shortName = values["shortName"] ?? ""
        let parentGameId = values["parentGameId"] ?? ""
        guard !cmsId.isEmpty || !shortName.isEmpty || !parentGameId.isEmpty else {
            throw GFNGameShortcutError.missingIdentifiers
        }
        self.init(
            sourceURL: fileURL,
            displayName: fileURL.deletingPathExtension().lastPathComponent,
            cmsId: cmsId,
            shortName: shortName,
            parentGameId: parentGameId,
            launchSource: values["launchSource"] ?? "External"
        )
    }

    func write(to url: URL) throws {
        let payload = ["url-route": urlRoute]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func routeValues(from route: String) -> [String: String] {
        let query: String
        if route.hasPrefix("#?") {
            query = String(route.dropFirst(2))
        } else if route.hasPrefix("?") || route.hasPrefix("#") {
            query = String(route.dropFirst())
        } else {
            query = route
        }
        var components = URLComponents()
        components.percentEncodedQuery = query
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            values[item.name] = item.value ?? ""
        }
        return values
    }

    private static func hasCaseInsensitiveSuffix(_ suffix: String, in value: String) -> Bool {
        value.range(of: suffix, options: [.caseInsensitive, .anchored, .backwards]) != nil
    }
}

enum GFNGameShortcutError: LocalizedError {
    case invalidPayload
    case missingIdentifiers

    var errorDescription: String? {
        switch self {
        case .invalidPayload: return "The file is not a valid GeForce NOW game shortcut."
        case .missingIdentifiers: return "The GeForce NOW shortcut does not contain a game identifier."
        }
    }
}
