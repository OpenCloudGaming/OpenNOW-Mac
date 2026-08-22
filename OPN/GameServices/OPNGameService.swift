import AppKit
import Foundation

import AppKit
import Foundation

typealias OPNPanelCallback = @MainActor @Sendable (_ success: Bool, _ panels: [OPNPanelResult], _ error: String) -> Void
typealias OPNCatalogCallback = @MainActor @Sendable (_ success: Bool, _ games: [OPNGameInfo], _ error: String) -> Void
typealias OPNCatalogBrowseCallback = @MainActor @Sendable (_ success: Bool, _ result: OPNCatalogBrowseResult, _ error: String) -> Void
typealias OPNSubscriptionCallback = @MainActor @Sendable (_ success: Bool, _ subscription: OPNSubscriptionInfo, _ error: String) -> Void
typealias OPNStoreURLCallback = @MainActor @Sendable (_ success: Bool, _ storeURL: String, _ error: String) -> Void
typealias OPNLaunchAppIdCallback = @MainActor @Sendable (_ appId: String) -> Void
typealias OPNProviderInfoCallback = @MainActor @Sendable (_ success: Bool, _ providerInfo: OPNGameProviderInfo, _ selectedEndpoint: OPNGameProviderEndpoint, _ error: String) -> Void
typealias OPNOwnershipActionCallback = @MainActor @Sendable (_ success: Bool, _ error: String) -> Void
typealias OPNFavoriteActionCallback = @MainActor @Sendable (_ success: Bool, _ error: String) -> Void
typealias OPNUserAccountCallback = @MainActor @Sendable (_ success: Bool, _ accountInfo: OPNUserAccountInfo, _ error: String) -> Void
typealias OPNStoreDefinitionsCallback = @MainActor @Sendable (_ success: Bool, _ definitions: [OPNStoreDefinition], _ error: String) -> Void
typealias OPNSubscriptionDefinitionsCallback = @MainActor @Sendable (_ success: Bool, _ definitions: [OPNSubscriptionDefinition], _ error: String) -> Void
typealias OPNAppPatchStatusesCallback = @MainActor @Sendable (_ success: Bool, _ statuses: [String: OPNAppPatchStatus], _ error: String) -> Void

public struct OPNAppPatchStatus: Equatable, Sendable {
    public var appId = ""
    public var isPatching = false
    public var variantPatchingById: [String: Bool] = [:]
    public var primaryTextByVariantId: [String: String] = [:]
    public var secondaryTextByVariantId: [String: String] = [:]
}

final class OPNGameService: @unchecked Sendable {
    static let shared = OPNGameService()

    let sessionManager: any StreamSessionManaging
    let dataCache: any CatalogDataCaching

    static let panelsHash = "46ec15f267a056e7d5e46e629efa929529e5e7542a4850faece90b9f8fa5f810"
    static let favoritesPanelHash = "46ec15f267a056e7d5e46e629efa929529e5e7542a4850faece90b9f8fa5f810"
    static let marqueeHash = "dd4bddfdef4707dfe340cc2040d6bb9c4c45f706976fca15b2ef33221c385d7f"
    static let appMetaDataHash = "cf8b620dfd03617017ba7c858cee65197e1ace5180e41be194b39227227ced63"
    static let nvClientId = GFNClientMetadata.clientId
    static let nvClientVersion = GFNClientMetadata.appVersion
    static let defaultStreamingBaseUrl = CloudMatch.productionBaseURLString + "/"
    static let providerServiceUrlsEndpoint = "https://pcs.geforcenow.com/v1/serviceUrls"
    static let accountLinkingServer = "https://als.geforcenow.com"
    static let accountLinkingClientId = "gfn-pc"
    static let defaultSubscriptionVpcId = "NP-AMS-08"
    static let defaultBrowseSortId = "a_to_z"
    static let defaultSearchSortId = "relevance"
    static let defaultCatalogFetchCount = 96
    static let maxCatalogPages = 150
    static let patchInfoFetchCount = 749
    static let catalogCacheFreshSeconds: TimeInterval = 15 * 60
    static let panelCacheFreshSeconds: TimeInterval = 7 * 24 * 60 * 60
    static let collectionsFilterGroupId = "collections"
    static let libraryCatalogFilterId = "my_library"
    static let favoritesCatalogFilterId = "my_favorites"
    static let catalogDefinitionsFreshSeconds: TimeInterval = TimeInterval(LCARS.RequestType.staticAppData.cachePolicy.maxAgeSeconds)
    static let accountLinkingRequestTimeoutSeconds: TimeInterval = 15
    static let accountLinkingCallbackTimeoutSeconds: TimeInterval = 5 * 60
    static let serverVpcCacheFreshSeconds: TimeInterval = 5 * 60
    static let workQueue = DispatchQueue(label: "com.macforce-now.game-service.swift.work")

    struct VpcCacheEntry {
        let vpcId: String
        let timestamp: Date
    }

    static let vpcLock = NSLock()
    nonisolated(unsafe) static var vpcCache: [String: VpcCacheEntry] = [:]
    nonisolated(unsafe) static var pendingVpcCallbacks: [String: [(String) -> Void]] = [:]

    struct ReferenceDataEntry<Value>: @unchecked Sendable {
        let value: Value
        let timestamp: Date
    }

    static let referenceDataFreshSeconds: TimeInterval = 10 * 60
    static let referenceDataLock = NSLock()
    nonisolated(unsafe) static var campaignPromoTagCache: [String: ReferenceDataEntry<[String: String]>] = [:]
    nonisolated(unsafe) static var pendingCampaignPromoTagCallbacks: [String: [@Sendable ([String: String]) -> Void]] = [:]
    nonisolated(unsafe) static var ratingDefinitionCache: [String: ReferenceDataEntry<[String: RatingMetadata]>] = [:]
    nonisolated(unsafe) static var pendingRatingDefinitionCallbacks: [String: [@Sendable ([String: RatingMetadata]) -> Void]] = [:]
    nonisolated(unsafe) static var providerInfoCache: [String: ReferenceDataEntry<(OPNGameProviderInfo, OPNGameProviderEndpoint)>] = [:]
    nonisolated(unsafe) static var pendingProviderInfoCallbacks: [String: [OPNProviderInfoCallback]] = [:]

    static let appMetadataLimiter = OPNRequestConcurrencyLimiter(limit: 4)

    static let panelFetchLock = NSLock()
    nonisolated(unsafe) static var pendingPanelFetches: [String: PanelFetchGroup] = [:]

    var accessToken = ""
    var accountLinkingToken = ""
    var vpcId = ""
    var userId = ""
    var graphqlURL = "https://games.geforce.com/graphql"
    var streamingBaseUrl = ""
    var providerStreamingBaseUrl = OPNGameService.defaultStreamingBaseUrl

    init(sessionManager: any StreamSessionManaging = OPNSessionManager.shared, dataCache: any CatalogDataCaching = OPNGameDataCache.shared) {
        self.sessionManager = sessionManager
        self.dataCache = dataCache
    }

    func setAccessToken(_ token: String) { accessToken = token }
    func setAccountLinkingToken(_ token: String) { accountLinkingToken = token }
    func setVpcId(_ id: String) { vpcId = id }
    func setUserId(_ id: String) { userId = id }
    func setStreamingBaseUrl(_ url: String) {
        streamingBaseUrl = url
        sessionManager.setStreamingBaseUrl(url)
    }
    func providerStreamingBaseURL() -> String { providerStreamingBaseUrl.isEmpty ? Self.defaultStreamingBaseUrl : providerStreamingBaseUrl }

    func prewarmLaunchData() {
        let token = accessToken
        if !token.isEmpty { getServerVpcId(token: token, providerStreamingBaseUrl: providerStreamingBaseURL()) { _ in } }
    }

    static func optimizeImageURL(_ url: String, width: Int = 272) -> String {
        if url.isEmpty { return url }
        if url.contains("img.nvidiagrid.net") { return "\(url);f=webp;w=\(width)" }
        return url
    }

    func postGraphQL(operationName: String, queryHash: String, variables: NSDictionary?, authenticatedHuId: Bool = false, completion: @escaping @Sendable (NSDictionary?, String) -> Void) {
        let huIdUserId = authenticatedHuId ? userId : ""
        guard let request = LCARSRequestFactory.persistedQueryRequest(operationName: operationName, queryHash: queryHash, variables: variables, accessToken: accessToken, configuration: LCARSConfiguration(baseURLString: graphqlURL), userId: huIdUserId) else {
            dispatchGraphQL(completion, nil, "Invalid URL")
            return
        }
        runGraphQLRequest(request, operationName: operationName, queryHash: queryHash, variables: variables, completion: completion)
    }

    func postGraphQlJson(query: String, variables: NSDictionary?, completion: @escaping @Sendable (NSDictionary?, String) -> Void) {
        guard let request = LCARSRequestFactory.inlineGraphQLRequest(query: query, variables: variables, accessToken: accessToken, configuration: LCARSConfiguration(baseURLString: graphqlURL)) else {
            dispatchGraphQL(completion, nil, "Invalid URL")
            return
        }
        runGraphQLRequest(request, operationName: Self.graphQLOperationName(query), queryHash: "inline", variables: variables, completion: completion)
    }

    func runGraphQLRequest(_ request: URLRequest, operationName: String, queryHash: String, variables: NSDictionary?, completion: @escaping @Sendable (NSDictionary?, String) -> Void) {
        var requestWithTrace = request
        let networkStart = OPNNetworkLog.graphQLStart(&requestWithTrace, operationName: operationName, queryHash: queryHash, variables: variables)
        let tracedRequest = requestWithTrace
        OPNSessionProxySessionProvider.shared.controlPlaneURLSession().dataTask(with: tracedRequest) { data, response, error in
            var payload: NSDictionary?
            var message = ""
            if let error {
                message = error.localizedDescription
            } else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? NSDictionary
                if statusCode != 200 || json == nil {
                    message = "GraphQL error (\(statusCode))"
                } else if let errors = json?["errors"] as? [NSDictionary], !errors.isEmpty {
                    message = errors.first?["message"] as? String ?? "GraphQL error"
                } else if let dataPayload = json?["data"] as? NSDictionary {
                    payload = dataPayload
                } else {
                    message = "No data in GraphQL response"
                }
            }
            OPNNetworkLog.graphQLFinish(tracedRequest, operationName: operationName, queryHash: queryHash, startedAt: networkStart, data: data, response: response, error: error, responseMessage: message)
            self.dispatchGraphQL(completion, payload, message)
        }.resume()
    }

    static func applyClientHeaders(to request: inout URLRequest, includeBrowserHeaders: Bool) {
        request.setValue(nvClientId, forHTTPHeaderField: "nv-client-id")
        request.setValue("NATIVE", forHTTPHeaderField: "nv-client-type")
        request.setValue(nvClientVersion, forHTTPHeaderField: "nv-client-version")
        request.setValue("NVIDIA-CLASSIC", forHTTPHeaderField: "nv-client-streamer")
        request.setValue("MACOS", forHTTPHeaderField: "nv-device-os")
        request.setValue("DESKTOP", forHTTPHeaderField: "nv-device-type")
        if includeBrowserHeaders {
            request.setValue("UNKNOWN", forHTTPHeaderField: "nv-device-make")
            request.setValue("UNKNOWN", forHTTPHeaderField: "nv-device-model")
            request.setValue("CHROME", forHTTPHeaderField: "nv-browser-type")
            request.setValue(gfnUserAgent, forHTTPHeaderField: "User-Agent")
        }
    }

    static var gfnUserAgent: String {
        GFNClientMetadata.nativeMacUserAgent
    }

    static func graphQLOperationName(_ query: String) -> String {
        let compact = query.replacingOccurrences(of: "\n", with: " ")
        let tokens = compact.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == "{" }).map(String.init)
        guard let operationKeywordIndex = tokens.firstIndex(where: { $0 == "query" || $0 == "mutation" }), tokens.indices.contains(operationKeywordIndex + 1) else {
            return "inlineGraphQL"
        }
        return tokens[operationKeywordIndex + 1]
    }

    static func isGraphQLNotFoundError(_ error: String) -> Bool {
        error.contains("(404)") || error.contains("HTTP 404")
    }

    func normalizeStreamingBaseUrl(_ url: String) -> String {
        if url.isEmpty { return Self.defaultStreamingBaseUrl }
        guard let components = URLComponents(string: url), components.scheme?.lowercased() == "https", components.host?.isEmpty == false else { return "" }
        return url.hasSuffix("/") ? url : "\(url)/"
    }

    func safeString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return value as? String
    }

    func safeStringArray(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { safeString($0) }.filter { !$0.isEmpty }
    }

    func safeInt(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    func safeBool(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["true", "1", "yes"].contains(string.lowercased()) }
        return false
    }

    static func currentGFNLocale() -> String {
        OPNLocale.currentGFNLocale()
    }

    static func currentGFNCatalogLocale() -> String {
        OPNLocale.currentGFNCatalogLocale()
    }

    static func currentGFNLocaleURLPathComponentFallbacks() -> [String] {
        OPNLocale.currentGFNLocaleURLPathComponentFallbacks()
    }

    func dispatchGraphQL(_ completion: @escaping @Sendable (NSDictionary?, String) -> Void, _ payload: NSDictionary?, _ message: String) {
        let payloadBox = payload.map(NSDictionaryBox.init)
        Self.workQueue.async { [payloadBox] in completion(payloadBox?.value, message) }
    }

    func dispatchPanel(_ completion: @escaping OPNPanelCallback, _ success: Bool, _ panels: [OPNPanelResult], _ error: String) {
        Task { @MainActor in completion(success, panels, error) }
    }

    func dispatchCatalog(_ completion: @escaping OPNCatalogCallback, _ success: Bool, _ games: [OPNGameInfo], _ error: String) {
        Task { @MainActor in completion(success, games, error) }
    }

    func dispatchCatalogBrowse(_ completion: @escaping OPNCatalogBrowseCallback, _ success: Bool, _ result: OPNCatalogBrowseResult, _ error: String) {
        Task { @MainActor in completion(success, result, error) }
    }

    func dispatchSubscription(_ completion: @escaping OPNSubscriptionCallback, _ success: Bool, _ subscription: OPNSubscriptionInfo, _ error: String) {
        Task { @MainActor in completion(success, subscription, error) }
    }

    func dispatchStoreURL(_ completion: @escaping OPNStoreURLCallback, _ success: Bool, _ storeURL: String, _ error: String) {
        Task { @MainActor in completion(success, storeURL, error) }
    }

    func dispatchProviderInfo(_ completion: @escaping OPNProviderInfoCallback, _ success: Bool, _ providerInfo: OPNGameProviderInfo, _ selectedEndpoint: OPNGameProviderEndpoint, _ error: String) {
        Task { @MainActor in completion(success, providerInfo, selectedEndpoint, error) }
    }

    func dispatchOwnership(_ completion: @escaping OPNOwnershipActionCallback, _ success: Bool, _ error: String) {
        Task { @MainActor in completion(success, error) }
    }

    func dispatchFavorite(_ completion: @escaping OPNFavoriteActionCallback, _ success: Bool, _ error: String) {
        Task { @MainActor in completion(success, error) }
    }

    func dispatchUserAccount(_ completion: @escaping OPNUserAccountCallback, _ success: Bool, _ accountInfo: OPNUserAccountInfo, _ error: String) {
        Task { @MainActor in completion(success, accountInfo, error) }
    }

    func dispatchStoreDefinitions(_ completion: @escaping OPNStoreDefinitionsCallback, _ success: Bool, _ definitions: [OPNStoreDefinition], _ error: String) {
        Task { @MainActor in completion(success, definitions, error) }
    }

    func dispatchSubscriptionDefinitions(_ completion: @escaping OPNSubscriptionDefinitionsCallback, _ success: Bool, _ definitions: [OPNSubscriptionDefinition], _ error: String) {
        Task { @MainActor in completion(success, definitions, error) }
    }

    func dispatchAppPatchStatuses(_ completion: @escaping OPNAppPatchStatusesCallback, _ success: Bool, _ statuses: [String: OPNAppPatchStatus], _ error: String) {
        Task { @MainActor in completion(success, statuses, error) }
    }
}

extension OPNGameService {
    func configureCatalogSession(accessToken: String, idToken: String, userId: String) {
        let token = idToken.isEmpty ? accessToken : idToken
        setAccessToken(token)
        setAccountLinkingToken(token)
        setUserId(userId)
        setVpcId("GFN-PC")
        prewarmLaunchData()
    }

    func fetchMainPanelObjects(completion: @escaping @MainActor @Sendable (Bool, [OPNCatalogPanelObject], String) -> Void) {
        fetchMainPanels { success, panels, error in
            completion(success, panels.map(OPNCatalogPanelObject.init), error)
        }
    }

    func fetchMarqueePanelObjects(completion: @escaping @MainActor @Sendable (Bool, [OPNCatalogPanelObject], String) -> Void) {
        fetchMarqueePanels { success, panels, error in
            completion(success, panels.map(OPNCatalogPanelObject.init), error)
        }
    }

    func browseCatalogObject(searchQuery: String, sortId: String, filterIds: [String], fetchCount: Int, completion: @escaping @MainActor @Sendable (Bool, OPNCatalogBrowseResultObject, String) -> Void) {
        browseCatalogGames(searchQuery: searchQuery, sortId: sortId, filterIds: filterIds, fetchCount: fetchCount, forceRefresh: false) { success, result, error in
            completion(success, OPNCatalogBrowseResultObject(result: result), error)
        }
    }

    func browseCatalogObject(searchQuery: String, sortId: String, filterIds: [String], fetchCount: Int, forceRefresh: Bool, completion: @escaping @MainActor @Sendable (Bool, OPNCatalogBrowseResultObject, String) -> Void) {
        browseCatalogObject(searchQuery: searchQuery, sortId: sortId, filterIds: filterIds, fetchCount: fetchCount, forceRefresh: forceRefresh, cursor: "", completion: completion)
    }

    func browseCatalogObject(searchQuery: String, sortId: String, filterIds: [String], fetchCount: Int, forceRefresh: Bool, cursor: String, completion: @escaping @MainActor @Sendable (Bool, OPNCatalogBrowseResultObject, String) -> Void) {
        browseCatalogGames(searchQuery: searchQuery, sortId: sortId, filterIds: filterIds, fetchCount: fetchCount, forceRefresh: forceRefresh, cursor: cursor) { success, result, error in
            completion(success, OPNCatalogBrowseResultObject(result: result), error)
        }
    }

    func fetchLibraryGameObjects(completion: @escaping @MainActor @Sendable (Bool, [OPNCatalogGameObject], String) -> Void) {
        fetchLibraryGames { success, games, error in
            completion(success, games.map(OPNCatalogGameObject.init), error)
        }
    }

    func fetchFavoriteGameObjects(completion: @escaping @MainActor @Sendable (Bool, [OPNCatalogGameObject], String) -> Void) {
        fetchFavoriteGames { success, games, error in
            completion(success, games.map(OPNCatalogGameObject.init), error)
        }
    }

    func fetchGameObjectByCMSId(_ cmsId: String, completion: @escaping @MainActor @Sendable (Bool, OPNCatalogGameObject?, String) -> Void) {
        fetchGameByCMSId(cmsId) { success, games, error in
            completion(success, games.first.map(OPNCatalogGameObject.init), error)
        }
    }

    func resolveStoreURL(game: OPNCatalogGameObject, variantIndex: Int, completion: @escaping @MainActor @Sendable (Bool, String, String) -> Void) {
        resolveStoreURL(game: game.swiftValue, variantIndex: variantIndex, completion: completion)
    }
}
