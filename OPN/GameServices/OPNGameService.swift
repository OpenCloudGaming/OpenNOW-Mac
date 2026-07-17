import AppKit
import Foundation

typealias OPNPanelCallback = @Sendable (_ success: Bool, _ panels: [OPNPanelResult], _ error: String) -> Void
typealias OPNCatalogCallback = @Sendable (_ success: Bool, _ games: [OPNGameInfo], _ error: String) -> Void
typealias OPNCatalogBrowseCallback = @Sendable (_ success: Bool, _ result: OPNCatalogBrowseResult, _ error: String) -> Void
typealias OPNSubscriptionCallback = @Sendable (_ success: Bool, _ subscription: OPNSubscriptionInfo, _ error: String) -> Void
typealias OPNStoreURLCallback = @Sendable (_ success: Bool, _ storeURL: String, _ error: String) -> Void
typealias OPNLaunchAppIdCallback = @Sendable (_ appId: String) -> Void
typealias OPNProviderInfoCallback = @Sendable (_ success: Bool, _ providerInfo: OPNGameProviderInfo, _ selectedEndpoint: OPNGameProviderEndpoint, _ error: String) -> Void
typealias OPNOwnershipActionCallback = @Sendable (_ success: Bool, _ error: String) -> Void
typealias OPNFavoriteActionCallback = @Sendable (_ success: Bool, _ error: String) -> Void
typealias OPNUserAccountCallback = @Sendable (_ success: Bool, _ accountInfo: OPNUserAccountInfo, _ error: String) -> Void
typealias OPNStoreDefinitionsCallback = @Sendable (_ success: Bool, _ definitions: [OPNStoreDefinition], _ error: String) -> Void
typealias OPNAppPatchStatusesCallback = @Sendable (_ success: Bool, _ statuses: [String: OPNAppPatchStatus], _ error: String) -> Void

public struct OPNAppPatchStatus: Equatable, Sendable {
    public var appId = ""
    public var isPatching = false
    public var variantPatchingById: [String: Bool] = [:]
}

final class OPNGameService: @unchecked Sendable {
    static let shared = OPNGameService()

    private static let panelsHash = "f8e26265a5db5c20e1334a6872cf04b6e3970507697f6ae55a6ddefa5420daf0"
    private static let favoritesPanelHash = "46ec15f267a056e7d5e46e629efa929529e5e7542a4850faece90b9f8fa5f810"
    private static let marqueeHash = "dd4bddfdef4707dfe340cc2040d6bb9c4c45f706976fca15b2ef33221c385d7f"
    private static let appMetaDataHash = "cf8b620dfd03617017ba7c858cee65197e1ace5180e41be194b39227227ced63"
    private static let nvClientId = "ec7e38d4-03af-4b58-b131-cfb0495903ab"
    private static let nvClientVersion = "2.0.80.173"
    private static let defaultStreamingBaseUrl = CloudMatch.productionBaseURLString + "/"
    private static let providerServiceUrlsEndpoint = "https://pcs.geforcenow.com/v1/serviceUrls"
    private static let accountLinkingServer = "https://als.geforcenow.com"
    private static let accountLinkingClientId = "gfn-pc"
    private static let defaultSubscriptionVpcId = "NP-AMS-08"
    private static let defaultBrowseSortId = "a_to_z"
    private static let defaultSearchSortId = "relevance"
    private static let defaultCatalogFetchCount = 96
    private static let maxCatalogPages = 150
    private static let catalogCacheFreshSeconds: TimeInterval = 15 * 60
    private static let libraryCatalogFilterId = "gfn-library-owned"
    private static let catalogDefinitionsFreshSeconds: TimeInterval = TimeInterval(LCARS.RequestType.staticAppData.cachePolicy.maxAgeSeconds)
    private static let accountLinkingRequestTimeoutSeconds: TimeInterval = 15
    private static let accountLinkingCallbackTimeoutSeconds: TimeInterval = 5 * 60
    private static let serverVpcCacheFreshSeconds: TimeInterval = 5 * 60
    private static let workQueue = DispatchQueue(label: "com.opennow.game-service.swift.work")

    private struct VpcCacheEntry {
        let vpcId: String
        let timestamp: Date
    }

    private static let vpcLock = NSLock()
    nonisolated(unsafe) private static var vpcCache: [String: VpcCacheEntry] = [:]
    nonisolated(unsafe) private static var pendingVpcCallbacks: [String: [(String) -> Void]] = [:]

    private var accessToken = ""
    private var accountLinkingToken = ""
    private var vpcId = ""
    private var userId = ""
    private var graphqlURL = "https://games.geforce.com/graphql"
    private var streamingBaseUrl = ""
    private var providerStreamingBaseUrl = OPNGameService.defaultStreamingBaseUrl

    private init() {}

    func setAccessToken(_ token: String) { accessToken = token }
    func setAccountLinkingToken(_ token: String) { accountLinkingToken = token }
    func setVpcId(_ id: String) { vpcId = id }
    func setUserId(_ id: String) { userId = id }
    func setStreamingBaseUrl(_ url: String) {
        streamingBaseUrl = url
        OPNSessionManager.shared.setStreamingBaseUrl(url)
    }
    func providerStreamingBaseURL() -> String { providerStreamingBaseUrl.isEmpty ? Self.defaultStreamingBaseUrl : providerStreamingBaseUrl }

    func fetchProviderInfo(idpId: String, completion: @escaping OPNProviderInfoCallback) {
        guard let url = URL(string: Self.providerServiceUrlsEndpoint) else {
            dispatchProviderInfo(completion, false, OPNGameProviderInfo(), OPNGameProviderEndpoint(), "Invalid provider info URL")
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.gfnUserAgent, forHTTPHeaderField: "User-Agent")
        let networkStart = OPNNetworkLog.start(&request, operation: "provider.serviceUrls")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { [weak self] data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "provider.serviceUrls", startedAt: networkStart, data: data, response: response, error: error)
            guard let self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, let data, statusCode == 200 else {
                var endpoint = OPNGameProviderEndpoint()
                endpoint.streamingServiceUrl = Self.defaultStreamingBaseUrl
                self.providerStreamingBaseUrl = endpoint.streamingServiceUrl
                self.dispatchProviderInfo(completion, false, OPNGameProviderInfo(), endpoint, error?.localizedDescription ?? "Provider info request failed")
                return
            }

            let json = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
            let info = self.parseGameProviderInfo(json)
            var endpoint = self.selectGameProviderEndpoint(info, idpId: idpId)
            if endpoint.streamingServiceUrl.isEmpty { endpoint.streamingServiceUrl = Self.defaultStreamingBaseUrl }
            self.providerStreamingBaseUrl = self.normalizeStreamingBaseUrl(endpoint.streamingServiceUrl)
            if self.providerStreamingBaseUrl.isEmpty { self.providerStreamingBaseUrl = Self.defaultStreamingBaseUrl }
            endpoint.streamingServiceUrl = self.providerStreamingBaseUrl
            self.dispatchProviderInfo(completion, true, info, endpoint, "")
        }.resume()
    }

    func fetchMarqueePanels(completion: @escaping OPNPanelCallback) {
        fetchPanels(operationName: "panels/Marquee", hash: Self.marqueeHash, panelNames: ["MARQUEE"], missingMessage: "No panels in marquee response", completion: completion)
    }

    func fetchMainPanels(completion: @escaping OPNPanelCallback) {
        fetchPanels(operationName: "panels/MainV2", hash: Self.panelsHash, panelNames: ["MAIN"], missingMessage: "No panels in response", completion: completion)
    }

    func fetchCatalogGames(completion: @escaping OPNCatalogCallback) {
        browseCatalogGames(searchQuery: "", sortId: Self.defaultBrowseSortId, filterIds: [], fetchCount: 200, forceRefresh: false) { success, result, error in
            completion(success, result.games, error)
        }
    }

    func browseCatalogGames(searchQuery: String, sortId: String, filterIds: [String], fetchCount: Int, forceRefresh: Bool = false, completion: @escaping OPNCatalogBrowseCallback) {
        let token = accessToken
        let accountIdentifier = userId
        let providerBaseUrl = providerStreamingBaseURL()
        let locale = Self.currentGFNCatalogLocale()
        getServerVpcId(token: token, providerStreamingBaseUrl: providerBaseUrl) { [weak self] resolvedVpcId in
            guard let self else { return }
            self.continueBrowseCatalogGames(
                accountIdentifier: accountIdentifier,
                providerBaseUrl: providerBaseUrl,
                locale: locale,
                resolvedVpcId: resolvedVpcId,
                searchQuery: searchQuery,
                sortId: sortId,
                filterIds: filterIds,
                fetchCount: fetchCount,
                forceRefresh: forceRefresh,
                completion: completion
            )
        }
    }

    private func continueBrowseCatalogGames(
        accountIdentifier: String,
        providerBaseUrl: String,
        locale: String,
        resolvedVpcId: String,
        searchQuery: String,
        sortId: String,
        filterIds: [String],
        fetchCount: Int,
        forceRefresh: Bool,
        completion: @escaping OPNCatalogBrowseCallback
    ) {
        let requestedSortId = sortId.isEmpty ? Self.defaultSortId(searchQuery: searchQuery) : sortId
        let requestedFetchCount = max(24, min(fetchCount > 0 ? fetchCount : Self.defaultCatalogFetchCount, 200))
        let catalogCacheKey = OPNGameDataCache.shared.catalogKey(
            accountIdentifier: accountIdentifier,
            searchQuery: searchQuery,
            sortId: requestedSortId,
            filterIds: filterIds,
            fetchCount: requestedFetchCount,
            locale: locale,
            providerStreamingBaseUrl: providerBaseUrl,
            vpcId: resolvedVpcId
        )

        let parameters = CatalogDefinitionParameters(
            requestedSortId: requestedSortId,
            filterIds: filterIds,
            requestedFetchCount: requestedFetchCount,
            searchQuery: searchQuery,
            resolvedVpcId: resolvedVpcId,
            locale: locale,
            catalogCacheKey: catalogCacheKey
        )

        if forceRefresh {
            continueBrowseAfterFreshCacheMiss(parameters: parameters, allowCachedCatalog: false, completion: completion)
            return
        }

        OPNGameDataCache.shared.loadFreshCatalogAndDefinitions(
            key: catalogCacheKey,
            locale: locale,
            catalogMaxAgeSeconds: Self.catalogCacheFreshSeconds,
            definitionsMaxAgeSeconds: Self.catalogDefinitionsFreshSeconds
        ) { [weak self] freshCatalog, freshDefinitions in
            guard let self else { return }
            if var fresh = freshCatalog, let definitions = freshDefinitions {
                _ = self.parseCatalogDefinitions(definitions, result: &fresh)
                self.dispatchCatalogBrowse(completion, true, fresh, "")
                return
            }

            self.continueBrowseAfterFreshCacheMiss(parameters: parameters, allowCachedCatalog: true, completion: completion)
        }
    }

    private func continueBrowseAfterFreshCacheMiss(parameters: CatalogDefinitionParameters, allowCachedCatalog: Bool, completion: @escaping OPNCatalogBrowseCallback) {
        let deliveredCachedResult = AtomicFlag()
        let loadDefinitions: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            OPNGameDataCache.shared.loadCatalogDefinitionsAsync(locale: parameters.locale, maxAgeSeconds: Self.catalogDefinitionsFreshSeconds) { [weak self] cachedDefinitions in
                guard let self else { return }
                if let cachedDefinitions {
                    self.handleCatalogDefinitions(cachedDefinitions, "", parameters: parameters, deliveredCachedResult: deliveredCachedResult, completion: completion)
                    return
                }

                let definitionsQuery = """
                query GetFilterGroupAndSortOrderDefinitions($locale: String!) {
                    filterGroupDefinitions(language: $locale) { id label filters { id label filters } }
                    sortOrderDefinitions(language: $locale) { id label orderBy }
                }
                """
                self.postGraphQlJson(query: definitionsQuery, variables: ["locale": parameters.locale] as NSDictionary) { [weak self] data, error in
                    guard let self else { return }
                    if error.isEmpty, let data { OPNGameDataCache.shared.saveCatalogDefinitionsAsync(locale: parameters.locale, definitions: data) }
                    self.handleCatalogDefinitions(data, error, parameters: parameters, deliveredCachedResult: deliveredCachedResult, completion: completion)
                }
            }
        }
        guard allowCachedCatalog else {
            loadDefinitions()
            return
        }
        OPNGameDataCache.shared.loadCatalogAsync(key: parameters.catalogCacheKey) { [weak self] cached in
            guard let self else { return }
            if let cached {
                deliveredCachedResult.setTrue()
                self.dispatchCatalogBrowse(completion, true, cached, "")
            }
            loadDefinitions()
        }
    }

    private func handleCatalogDefinitions(
        _ definitionsData: NSDictionary?,
        _ definitionsError: String,
        parameters: CatalogDefinitionParameters,
        deliveredCachedResult: AtomicFlag,
        completion: @escaping OPNCatalogBrowseCallback
    ) {
        if !definitionsError.isEmpty {
            if !deliveredCachedResult.value { dispatchCatalogBrowse(completion, false, OPNCatalogBrowseResult(), definitionsError) }
            return
        }
        let definitionsBox = definitionsData.map(NSDictionaryBox.init)
        Self.workQueue.async { [weak self, definitionsBox] in
            guard let self else { return }
            var result = OPNCatalogBrowseResult()
            let filterPayloadById = self.parseCatalogDefinitions(definitionsBox?.value, result: &result)
            var selectedSort = Self.defaultSortOption(searchQuery: parameters.searchQuery)
            for option in result.sortOptions where option.id == parameters.requestedSortId {
                selectedSort = option
                break
            }

            var filters: [String: Any] = [:]
            for filterId in parameters.filterIds {
                guard let payload = filterPayloadById[filterId] else { continue }
                self.deepMergeDictionary(into: &filters, source: payload)
                result.selectedFilterIds.append(filterId)
            }
            let trimmedSearch = parameters.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            result.searchQuery = trimmedSearch
            result.selectedSortId = selectedSort.id
            self.fetchCatalogPages(
                baseResult: result,
                query: trimmedSearch.isEmpty ? Self.catalogQuery : Self.catalogSearchQuery,
                vpcId: parameters.resolvedVpcId,
                locale: parameters.locale,
                sortString: selectedSort.orderBy,
                fetchCount: parameters.requestedFetchCount,
                searchString: trimmedSearch,
                filters: filters as NSDictionary,
                catalogCacheKey: parameters.catalogCacheKey,
                deliveredCachedResult: deliveredCachedResult,
                completion: completion
            )
        }
    }

    private static func defaultSortId(searchQuery: String) -> String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultBrowseSortId : defaultSearchSortId
    }

    private static func defaultSortOption(searchQuery: String) -> OPNCatalogSortOption {
        if defaultSortId(searchQuery: searchQuery) == defaultSearchSortId {
            return OPNCatalogSortOption(id: defaultSearchSortId, label: "Relevance", orderBy: "itemMetadata.relevance:DESC,sortName:ASC")
        }
        return OPNCatalogSortOption(id: defaultBrowseSortId, label: "A-Z", orderBy: "sortName:ASC")
    }

    func fetchLibraryGames(completion: @escaping OPNCatalogCallback) {
        let accountIdentifier = userId
        let providerBaseUrl = providerStreamingBaseURL()
        let locale = Self.currentGFNCatalogLocale()
        getServerVpcId(token: accessToken, providerStreamingBaseUrl: providerBaseUrl) { [weak self] resolvedVpcId in
            guard let self else { return }
            var result = OPNCatalogBrowseResult()
            result.selectedSortId = Self.defaultBrowseSortId
            result.selectedFilterIds = [Self.libraryCatalogFilterId]
            let catalogCacheKey = OPNGameDataCache.shared.catalogKey(
                accountIdentifier: accountIdentifier,
                searchQuery: "",
                sortId: Self.defaultBrowseSortId,
                filterIds: result.selectedFilterIds,
                fetchCount: 200,
                locale: locale,
                providerStreamingBaseUrl: providerBaseUrl,
                vpcId: resolvedVpcId
            )
            self.fetchCatalogPages(
                baseResult: result,
                query: Self.catalogQuery,
                vpcId: resolvedVpcId,
                locale: locale,
                sortString: "sortName:ASC",
                fetchCount: 200,
                searchString: "",
                filters: Self.libraryCatalogFilter,
                catalogCacheKey: catalogCacheKey,
                deliveredCachedResult: AtomicFlag()
            ) { [weak self] success, browseResult, error in
                self?.dispatchCatalog(completion, success, browseResult.games, error)
            }
        }
    }

    func fetchFavoriteGames(completion: @escaping OPNCatalogCallback) {
        getServerVpcId(token: accessToken, providerStreamingBaseUrl: providerStreamingBaseURL()) { [weak self] resolvedVpcId in
            guard let self else { return }
            let variables: NSDictionary = ["vpcId": resolvedVpcId, "locale": Self.currentGFNCatalogLocale(), "panelNames": ["FAVORITES"]]
            let flatten: @Sendable (NSDictionary?, String) -> Void = { [weak self] data, error in
                guard let self else { return }
                if !error.isEmpty {
                    self.dispatchCatalog(completion, false, [], error)
                    return
                }
                guard let panels = data?["panels"] as? [NSDictionary] else {
                    self.dispatchCatalog(completion, false, [], "No panels in favorites response")
                    return
                }
                let games = self.parsePanelResults(panels).flatMap { $0.sections }.flatMap { $0.games }
                self.enrichGames(games, vpcId: resolvedVpcId) { enriched in
                    self.dispatchCatalog(completion, true, self.deduplicateGames(enriched), "")
                }
            }
            self.postGraphQL(operationName: "panels/Favorites", queryHash: Self.favoritesPanelHash, variables: variables, authenticatedHuId: true, completion: flatten)
        }
    }

    func fetchPublicGames(completion: @escaping OPNCatalogCallback) {
        let locales = Self.currentGFNLocaleURLPathComponentFallbacks()
        fetchPublicGamesLocale(locales: locales.isEmpty ? ["en-US"] : locales, index: 0, completion: completion)
    }

    func fetchSubscriptionInfo(userId: String, completion: @escaping OPNSubscriptionCallback) {
        let token = accessToken
        guard !token.isEmpty else {
            dispatchSubscription(completion, false, OPNSubscriptionInfo(), "No access token")
            return
        }
        guard !userId.isEmpty else {
            dispatchSubscription(completion, false, OPNSubscriptionInfo(), "No user ID")
            return
        }

        getServerVpcId(token: token, providerStreamingBaseUrl: providerStreamingBaseURL()) { [weak self] resolvedVpcId in
            guard let self else { return }
            var components = URLComponents(string: "https://mes.geforcenow.com/v4/subscriptions")
            components?.queryItems = [
                URLQueryItem(name: "serviceName", value: "gfn_pc"),
                URLQueryItem(name: "languageCode", value: Self.currentGFNLocale()),
                URLQueryItem(name: "vpcId", value: resolvedVpcId == "GFN-PC" ? Self.defaultSubscriptionVpcId : resolvedVpcId),
                URLQueryItem(name: "userId", value: userId),
            ]
            guard let url = components?.url else {
                self.dispatchSubscription(completion, false, OPNSubscriptionInfo(), "Invalid subscription URL")
                return
            }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "GET"
            request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            Self.applyClientHeaders(to: &request, includeBrowserHeaders: false)
            let networkStart = OPNNetworkLog.start(&request, operation: "mes.subscriptions")
            let tracedRequest = request
            URLSession.shared.dataTask(with: tracedRequest) { data, response, error in
                OPNNetworkLog.finish(tracedRequest, operation: "mes.subscriptions", startedAt: networkStart, data: data, response: response, error: error)
                Self.workQueue.async {
                    if let error {
                        self.dispatchSubscription(completion, false, OPNSubscriptionInfo(), error.localizedDescription)
                        return
                    }
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? NSDictionary
                    guard statusCode == 200, let json else {
                        self.dispatchSubscription(completion, false, OPNSubscriptionInfo(), "Subscription API failed (\(statusCode))")
                        return
                    }
                    self.dispatchSubscription(completion, true, self.parseSubscriptionInfo(json), "")
                }
            }.resume()
        }
    }

    func resolveStoreURL(game: OPNGameInfo, variantIndex: Int, completion: @escaping OPNStoreURLCallback) {
        if let localStoreURL = storeURLForKnownGame(game, variantIndex: variantIndex), !localStoreURL.isEmpty {
            dispatchStoreURL(completion, true, localStoreURL, "")
            return
        }
        let appId = game.uuid.isEmpty ? game.id : game.uuid
        guard !appId.isEmpty else {
            dispatchStoreURL(completion, false, "", "No app ID available for store URL lookup")
            return
        }
        guard !accessToken.isEmpty else {
            dispatchStoreURL(completion, false, "", "No access token")
            return
        }
        let selectedVariant = game.variants.indices.contains(variantIndex) ? game.variants[variantIndex] : nil
        getServerVpcId(token: accessToken, providerStreamingBaseUrl: providerStreamingBaseURL()) { [weak self] resolvedVpcId in
            guard let self else { return }
            self.fetchAppMetadata(appIds: [appId], vpcId: resolvedVpcId.isEmpty ? "GFN-PC" : resolvedVpcId) { data, error in
                if !error.isEmpty {
                    self.dispatchStoreURL(completion, false, "", error)
                    return
                }
                guard let items = (data?["apps"] as? NSDictionary)?["items"] as? [NSDictionary] else {
                    self.dispatchStoreURL(completion, false, "", "No app metadata in store URL response")
                    return
                }
                let metadataApp = items.first { self.safeString($0["id"]) == appId } ?? items.first
                guard let metadataApp else {
                    self.dispatchStoreURL(completion, false, "", "No matching app metadata for store URL lookup")
                    return
                }
                let metadataGame = self.parseGameItem(metadataApp)
                let storeURL = self.storeURLForMetadataGame(metadataGame, variantId: selectedVariant?.id ?? "", store: selectedVariant?.appStore ?? "")
                if storeURL.isEmpty {
                    self.dispatchStoreURL(completion, false, "", "No store URL found for selected variant")
                    return
                }
                self.dispatchStoreURL(completion, true, storeURL, "")
            }
        }
    }

    func resolveLaunchAppId(game: OPNGameInfo, variantIndex: Int, completion: @escaping OPNLaunchAppIdCallback) {
        if let appId = launchableAppId(for: game, variantIndex: variantIndex) {
            completion(appId)
            return
        }
        let metadataAppId = game.uuid.isEmpty ? game.id : game.uuid
        guard !metadataAppId.isEmpty, !accessToken.isEmpty else {
            completion("")
            return
        }
        let selectedVariant = game.variants.indices.contains(variantIndex) ? game.variants[variantIndex] : nil
        getServerVpcId(token: accessToken, providerStreamingBaseUrl: providerStreamingBaseURL()) { [weak self] resolvedVpcId in
            guard let self else { return }
            self.fetchAppMetadata(appIds: [metadataAppId], vpcId: resolvedVpcId.isEmpty ? "GFN-PC" : resolvedVpcId) { data, error in
                guard error.isEmpty,
                      let items = (data?["apps"] as? NSDictionary)?["items"] as? [NSDictionary] else {
                    completion("")
                    return
                }
                let metadataApp = items.first { self.safeString($0["id"]) == metadataAppId } ?? items.first
                let metadataGame = self.parseGameItem(metadataApp)
                completion(self.launchableAppId(for: metadataGame, preferredStore: selectedVariant?.appStore ?? "") ?? "")
            }
        }
    }

    func fetchUserAccount(completion: @escaping OPNUserAccountCallback) {
        let query = """
        query GetUserAccount {
          userAccount {
            subscriptions { id }
            storesData { store accountLinkingData { userDisplayName expiresIn userIdentifier accountSyncingData { totalNumberOfSyncedGfnGames syncState syncDate } } }
          }
        }
        """
        postGraphQlJson(query: query, variables: [:] as NSDictionary) { [weak self] data, error in
            guard let self else { return }
            if !error.isEmpty {
                self.dispatchUserAccount(completion, false, OPNUserAccountInfo(), error)
                return
            }
            self.dispatchUserAccount(completion, true, self.parseUserAccountInfo(data), "")
        }
    }

    func fetchStoreDefinitions(completion: @escaping OPNStoreDefinitionsCallback) {
        let query = """
        query GetStoreDefinitions($locale: String!) {
          appStoreDefinitions(language: $locale) {
            store label sortOrder smallImageUrl
            features {
              __typename
              ... on AccountLinkingSso { displayProposition supported }
              ... on AccountGamesSyncing { displayProposition supported }
              ... on AccountSubscriptions { displayProposition }
            }
            accountLinkingMetadata { supportedVariantIds isSupported isRequired label }
          }
        }
        """
        postGraphQlJson(query: query, variables: ["locale": Self.currentGFNCatalogLocale()] as NSDictionary) { [weak self] data, error in
            guard let self else { return }
            if !error.isEmpty {
                self.dispatchStoreDefinitions(completion, false, [], error)
                return
            }
            self.dispatchStoreDefinitions(completion, true, self.parseStoreDefinitions(data), "")
        }
    }

    func fetchAppPatchStatuses(appIds: [String], completion: @escaping OPNAppPatchStatusesCallback) {
        let uniqueAppIds = Array(Set(appIds.filter { !$0.isEmpty })).sorted()
        guard !uniqueAppIds.isEmpty else {
            dispatchAppPatchStatuses(completion, true, [:], "")
            return
        }
        getServerVpcId(token: accessToken, providerStreamingBaseUrl: providerStreamingBaseURL()) { [weak self] resolvedVpcId in
            guard let self else { return }
            let query = """
            query GetAppsPatchInfoForAppIds($vpcId: String!, $locale: String!, $appIds: [String]!) {
              apps(vpcId: $vpcId, language: $locale, appIds: $appIds) {
                items {
                  id
                  variants {
                    id
                    gfn {
                      status
                      library { status }
                      stateDetails {
                        ... on VariantGfnAutoPatchingMetadata { subType startTime endTime historicalEtaMins etaPredictionType }
                        ... on VariantGfnManualPatchingMetadata { subType startTime endTime }
                        ... on VariantGfnMaintenanceMetadata { subType }
                      }
                    }
                  }
                }
              }
            }
            """
            let variables: NSDictionary = ["vpcId": resolvedVpcId.isEmpty ? "GFN-PC" : resolvedVpcId, "locale": Self.currentGFNCatalogLocale(), "appIds": uniqueAppIds]
            self.postGraphQlJson(query: query, variables: variables) { [weak self] data, error in
                guard let self else { return }
                guard error.isEmpty else {
                    self.dispatchAppPatchStatuses(completion, false, [:], error)
                    return
                }
                let items = (data?["apps"] as? NSDictionary)?["items"] as? [NSDictionary] ?? []
                self.dispatchAppPatchStatuses(completion, true, self.parseAppPatchStatuses(items), "")
            }
        }
    }

    func addOwnedVariant(_ variantId: String, completion: @escaping OPNOwnershipActionCallback) {
        ownedVariantMutation(mutationName: "AddOwnedVariant", fieldName: "addOwnedVariant", variantId: variantId, completion: completion)
    }

    func removeOwnedVariant(_ variantId: String, completion: @escaping OPNOwnershipActionCallback) {
        ownedVariantMutation(mutationName: "RemoveOwnedVariant", fieldName: "removeOwnedVariant", variantId: variantId, completion: completion)
    }

    func selectOwnedVariant(_ variantId: String, completion: @escaping OPNOwnershipActionCallback) {
        ownedVariantMutation(mutationName: "SelectOwnedVariant", fieldName: "selectOwnedVariant", variantId: variantId, completion: completion)
    }

    func addFavoriteApp(_ appId: String, completion: @escaping OPNFavoriteActionCallback) {
        favoriteAppMutation(mutationName: "AddFavoriteApp", fieldName: "addFavoriteApp", appId: appId, completion: completion)
    }

    func removeFavoriteApp(_ appId: String, completion: @escaping OPNFavoriteActionCallback) {
        favoriteAppMutation(mutationName: "RemoveFavoriteApp", fieldName: "removeFavoriteApp", appId: appId, completion: completion)
    }

    func syncAccountProvider(store: String, completion: @escaping OPNOwnershipActionCallback) {
        let token = accountLinkingToken.isEmpty ? accessToken : accountLinkingToken
        guard !token.isEmpty else {
            dispatchOwnership(completion, false, "Missing account-linking token")
            return
        }
        guard !store.isEmpty else {
            dispatchOwnership(completion, false, "Missing store for sync")
            return
        }
        let encodedStore = percentEncodeQueryValue(store)
        guard let url = URL(string: "\(Self.accountLinkingServer)/v1/sync/\(encodedStore)") else {
            dispatchOwnership(completion, false, "Invalid ALS sync URL")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: Self.accountLinkingRequestTimeoutSeconds)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let networkStart = OPNNetworkLog.start(&request, operation: "als.sync")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { [weak self] data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "als.sync", startedAt: networkStart, data: data, response: response, error: error)
            guard let self else { return }
            if let error {
                self.dispatchOwnership(completion, false, error.localizedDescription)
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode != 202 {
                let message = statusCode > 0 ? "ALS sync returned HTTP \(statusCode)" : "Missing ALS sync response"
                _ = self.accountLinkingResponseSnippet(data)
                self.dispatchOwnership(completion, false, message)
                return
            }
            self.dispatchOwnership(completion, true, "")
        }.resume()
    }

    func startAccountLinking(store: String, completion: @escaping OPNOwnershipActionCallback) {
        let token = accountLinkingToken.isEmpty ? accessToken : accountLinkingToken
        guard !token.isEmpty else {
            dispatchOwnership(completion, false, "Missing account-linking token")
            return
        }
        guard !store.isEmpty else {
            dispatchOwnership(completion, false, "Missing store for account linking")
            return
        }
        guard let listener = AccountLinkingCallbackListener() else {
            dispatchOwnership(completion, false, "No available port for account linking callback")
            return
        }

        let redirectURI = "http://localhost:\(listener.port)/"
        var components = URLComponents(string: "\(Self.accountLinkingServer)/v1/login_url")
        components?.queryItems = [
            URLQueryItem(name: "platform", value: store),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "client_id", value: Self.accountLinkingClientId),
        ]
        guard let url = components?.url else {
            listener.close()
            dispatchOwnership(completion, false, "Invalid ALS login URL request")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: Self.accountLinkingRequestTimeoutSeconds)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        let networkStart = OPNNetworkLog.start(&request, operation: "als.loginUrl")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { [weak self] data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "als.loginUrl", startedAt: networkStart, data: data, response: response, error: error)
            guard let self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, statusCode == 200, let data else {
                listener.close()
                self.dispatchOwnership(completion, false, error?.localizedDescription ?? "ALS login URL request failed")
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
            guard let loginURLText = self.safeString(json?["login_url"]), let loginURL = URL(string: loginURLText) else {
                listener.close()
                self.dispatchOwnership(completion, false, "ALS login URL response did not include login_url")
                return
            }
            listener.wait(timeout: Self.accountLinkingCallbackTimeoutSeconds, completion: completion)
            DispatchQueue.main.async { NSWorkspace.shared.open(loginURL) }
        }.resume()
    }

    func prewarmLaunchData() {
        let token = accessToken
        if !token.isEmpty { getServerVpcId(token: token, providerStreamingBaseUrl: providerStreamingBaseURL()) { _ in } }
    }

    static func optimizeImageURL(_ url: String, width: Int = 272) -> String {
        if url.isEmpty { return url }
        if url.contains("img.nvidiagrid.net") { return "\(url);f=webp;w=\(width)" }
        return url
    }

    private func fetchPanels(operationName: String, hash: String, panelNames: [String], missingMessage: String, completion: @escaping OPNPanelCallback) {
        getServerVpcId(token: accessToken, providerStreamingBaseUrl: providerStreamingBaseURL()) { [weak self] resolvedVpcId in
            guard let self else { return }
            let variables: NSDictionary = ["vpcId": resolvedVpcId, "locale": Self.currentGFNCatalogLocale(), "panelNames": panelNames]
            self.postGraphQL(operationName: operationName, queryHash: hash, variables: variables) { data, error in
                if !error.isEmpty {
                    self.dispatchPanel(completion, false, [], error)
                    return
                }
                guard let rawPanels = data?["panels"] as? [NSDictionary] else {
                    self.dispatchPanel(completion, false, [], missingMessage)
                    return
                }
                let panels = self.parsePanelResults(rawPanels)
                self.enrichPanelResults(panels, vpcId: resolvedVpcId) { enrichedPanels in
                    self.dispatchPanel(completion, true, enrichedPanels, "")
                }
            }
        }
    }

    private func postGraphQL(operationName: String, queryHash: String, variables: NSDictionary?, authenticatedHuId: Bool = false, completion: @escaping @Sendable (NSDictionary?, String) -> Void) {
        let huIdUserId = authenticatedHuId ? userId : ""
        guard let request = LCARSRequestFactory.persistedQueryRequest(operationName: operationName, queryHash: queryHash, variables: variables, accessToken: accessToken, configuration: LCARSConfiguration(baseURLString: graphqlURL), userId: huIdUserId) else {
            dispatchGraphQL(completion, nil, "Invalid URL")
            return
        }
        runGraphQLRequest(request, operationName: operationName, queryHash: queryHash, variables: variables, completion: completion)
    }

    private func postGraphQlJson(query: String, variables: NSDictionary?, completion: @escaping @Sendable (NSDictionary?, String) -> Void) {
        guard let request = LCARSRequestFactory.inlineGraphQLRequest(query: query, variables: variables, accessToken: accessToken, configuration: LCARSConfiguration(baseURLString: graphqlURL)) else {
            dispatchGraphQL(completion, nil, "Invalid URL")
            return
        }
        runGraphQLRequest(request, operationName: Self.graphQLOperationName(query), queryHash: "inline", variables: variables, completion: completion)
    }

    private func runGraphQLRequest(_ request: URLRequest, operationName: String, queryHash: String, variables: NSDictionary?, completion: @escaping @Sendable (NSDictionary?, String) -> Void) {
        var requestWithTrace = request
        let networkStart = OPNNetworkLog.graphQLStart(&requestWithTrace, operationName: operationName, queryHash: queryHash, variables: variables)
        let tracedRequest = requestWithTrace
        URLSession.shared.dataTask(with: tracedRequest) { data, response, error in
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

    private func fetchAppMetadata(appIds: [String], vpcId: String, completion: @escaping @Sendable (NSDictionary?, String) -> Void) {
        let variables: NSDictionary = ["vpcId": vpcId.isEmpty ? "GFN-PC" : vpcId, "locale": Self.currentGFNCatalogLocale(), "appIds": appIds]
        postGraphQL(operationName: "appMetaData", queryHash: Self.appMetaDataHash, variables: variables, completion: completion)
    }

    private func fetchCampaignPromoTags(vpcId: String, locale: String, completion: @escaping @Sendable ([String: String]) -> Void) {
        let query = """
        query GetCampaignsInfo($locale: String!, $vpcId: String!) {
          campaigns(vpcId: $vpcId, language: $locale) {
            items { id promoText { tag } }
          }
        }
        """
        let variables: NSDictionary = ["vpcId": vpcId.isEmpty ? "GFN-PC" : vpcId, "locale": locale]
        postGraphQlJson(query: query, variables: variables) { [weak self] data, _ in
            guard let self else {
                completion([:])
                return
            }
            var tagsByCampaignId: [String: String] = [:]
            let items = (data?["campaigns"] as? NSDictionary)?["items"] as? [NSDictionary] ?? []
            for item in items {
                guard let id = self.safeString(item["id"]), !id.isEmpty else { continue }
                let promoText = item["promoText"] as? NSDictionary
                let tag = self.safeString(promoText?["tag"]) ?? ""
                if !tag.isEmpty { tagsByCampaignId[id] = tag }
            }
            completion(tagsByCampaignId)
        }
    }

    private func fetchCatalogPages(baseResult: OPNCatalogBrowseResult, query: String, vpcId: String, locale: String, sortString: String, fetchCount: Int, searchString: String, filters: NSDictionary, catalogCacheKey: String, deliveredCachedResult: AtomicFlag, completion: @escaping OPNCatalogBrowseCallback) {
        let state = CatalogPageState(result: baseResult)
        let filterBox = NSDictionaryBox(filters)
        let fetchPage = RecursiveCatalogPageFetcher()
        fetchPage.action = { [weak self, state, fetchPage] page, cursor in
            guard let self else { return }
            var variables: [String: Any] = ["vpcId": vpcId, "locale": locale, "sortString": sortString, "fetchCount": fetchCount, "cursor": cursor, "filters": filterBox.value]
            if !searchString.isEmpty { variables["searchString"] = searchString }
            postGraphQlJson(query: query, variables: variables as NSDictionary) { [weak self] data, error in
                guard let self else { return }
                let dataBox = data.map(NSDictionaryBox.init)
                Self.workQueue.async { [dataBox] in
                    if !error.isEmpty {
                        if !deliveredCachedResult.value { self.dispatchCatalogBrowse(completion, false, OPNCatalogBrowseResult(), error) }
                        return
                    }
                    guard let apps = dataBox?.value["apps"] as? NSDictionary else {
                        if !deliveredCachedResult.value { self.dispatchCatalogBrowse(completion, false, OPNCatalogBrowseResult(), "No apps data") }
                        return
                    }
                    if let items = apps["items"] as? [NSDictionary] { state.collectedApps.append(contentsOf: items) }
                    state.result.numberReturned += self.safeInt(apps["numberReturned"])
                    state.result.numberSupported = self.safeInt(apps["numberSupported"])
                    let pageInfo = apps["pageInfo"] as? NSDictionary
                    let hasNextPage = self.safeBool(pageInfo?["hasNextPage"])
                    let endCursor = self.safeString(pageInfo?["endCursor"]) ?? ""
                    state.result.totalCount = self.safeInt(pageInfo?["totalCount"])
                    state.result.hasNextPage = hasNextPage
                    if !endCursor.isEmpty { state.result.endCursor = endCursor }
                    if hasNextPage, !endCursor.isEmpty, page + 1 < Self.maxCatalogPages {
                        fetchPage.action?(page + 1, endCursor)
                        return
                    }
                    let games = state.collectedApps.map { self.parseGameItem($0) }.filter { !$0.id.isEmpty && !$0.title.isEmpty && !$0.variants.isEmpty }
                    state.result.numberSupported = max(state.result.numberSupported, games.count)
                    state.result.totalCount = max(state.result.totalCount, games.count)
                    self.enrichGames(games, vpcId: vpcId) { enriched in
                        var finalResult = state.result
                        finalResult.games = enriched
                        OPNGameDataCache.shared.saveCatalogAsync(key: catalogCacheKey, result: finalResult)
                        self.dispatchCatalogBrowse(completion, true, finalResult, "")
                    }
                }
            }
        }
        fetchPage.action?(0, "")
    }

    private func enrichGames(_ games: [OPNGameInfo], vpcId: String, completion: @escaping @Sendable ([OPNGameInfo]) -> Void) {
        let appIds = Array(Set(games.map(\.uuid).filter { !$0.isEmpty }))
        if appIds.isEmpty {
            completion(games)
            return
        }
        let metadataState = MetadataState()
        let chunks = stride(from: 0, to: appIds.count, by: 40).map { Array(appIds[$0..<min($0 + 40, appIds.count)]) }
        let group = DispatchGroup()
        for chunk in chunks {
            group.enter()
            fetchAppMetadata(appIds: chunk, vpcId: vpcId) { [weak self] data, _ in
                if let self, let items = (data?["apps"] as? NSDictionary)?["items"] as? [NSDictionary] {
                    let itemsBox = NSDictionaryArrayBox(items)
                    Self.workQueue.async { [itemsBox] in
                        for item in itemsBox.values {
                            if let appId = self.safeString(item["id"]) { metadataState.metadataById[appId] = item }
                        }
                        group.leave()
                    }
                } else {
                    group.leave()
                }
            }
        }
        group.notify(queue: Self.workQueue) {
            let enriched = games.map { game in
                guard let metadata = metadataState.metadataById[game.uuid] else { return game }
                var merged = game
                let metadataGame = self.parseGameItem(metadata)
                self.mergeMissingStoreMetadata(target: &merged, metadata: metadataGame)
                if merged.promoTag.isEmpty { merged.promoTag = metadataGame.promoTag }
                if merged.campaignIds.isEmpty { merged.campaignIds = metadataGame.campaignIds }
                if merged.skuTags.isEmpty { merged.skuTags = metadataGame.skuTags }
                if !metadataGame.description.isEmpty { merged.description = metadataGame.description }
                if merged.shortDescription.isEmpty { merged.shortDescription = metadataGame.shortDescription }
                if merged.longDescription.isEmpty { merged.longDescription = metadataGame.longDescription }
                if merged.genres.isEmpty { merged.genres = metadataGame.genres }
                if merged.featureLabels.isEmpty { merged.featureLabels = metadataGame.featureLabels }
                if merged.developerName.isEmpty { merged.developerName = metadataGame.developerName }
                if merged.publisherName.isEmpty { merged.publisherName = metadataGame.publisherName }
                if merged.releaseDate.isEmpty { merged.releaseDate = metadataGame.releaseDate }
                if merged.imageUrl.isEmpty { merged.imageUrl = metadataGame.imageUrl }
                if merged.heroImageUrl.isEmpty { merged.heroImageUrl = metadataGame.heroImageUrl }
                if !metadataGame.screenshotUrls.isEmpty { merged.screenshotUrls = metadataGame.screenshotUrls }
                for (key, value) in metadataGame.imageUrlsByType where merged.imageUrlsByType[key] == nil { merged.imageUrlsByType[key] = value }
                if merged.maxLocalPlayers <= 0 { merged.maxLocalPlayers = metadataGame.maxLocalPlayers }
                if merged.maxOnlinePlayers <= 0 { merged.maxOnlinePlayers = metadataGame.maxOnlinePlayers }
                if merged.supportedControls.isEmpty { merged.supportedControls = metadataGame.supportedControls }
                if merged.contentRatings.isEmpty { merged.contentRatings = metadataGame.contentRatings }
                if merged.ratingSystemName.isEmpty { merged.ratingSystemName = metadataGame.ratingSystemName }
                if merged.ratingCategoryKey.isEmpty { merged.ratingCategoryKey = metadataGame.ratingCategoryKey }
                if merged.ratingCategoryTitle.isEmpty { merged.ratingCategoryTitle = metadataGame.ratingCategoryTitle }
                if merged.ratingDescriptors.isEmpty { merged.ratingDescriptors = metadataGame.ratingDescriptors }
                if merged.ratingInteractiveElements.isEmpty { merged.ratingInteractiveElements = metadataGame.ratingInteractiveElements }
                if merged.ratingImageUrl.isEmpty { merged.ratingImageUrl = metadataGame.ratingImageUrl }
                if merged.nvidiaTech.isEmpty { merged.nvidiaTech = metadataGame.nvidiaTech }
                if !merged.displaysOwnRatingDuringGameplay { merged.displaysOwnRatingDuringGameplay = metadataGame.displaysOwnRatingDuringGameplay }
                return merged
            }
            self.fetchCampaignPromoTags(vpcId: vpcId, locale: Self.currentGFNCatalogLocale()) { tagsByCampaignId in
                let campaignEnriched = enriched.map { game in
                    guard game.promoTag.isEmpty else { return game }
                    var merged = game
                    merged.promoTag = game.campaignIds.compactMap { tagsByCampaignId[$0] }.first ?? ""
                    return merged
                }
                self.enrichRatingMetadata(campaignEnriched, locale: Self.currentGFNCatalogLocale(), completion: completion)
            }
        }
    }

    private func enrichRatingMetadata(_ games: [OPNGameInfo], locale: String, completion: @escaping @Sendable ([OPNGameInfo]) -> Void) {
        guard games.contains(where: { !$0.ratingSystemName.isEmpty }) else {
            completion(games)
            return
        }
        fetchRatingDefinitions(locale: locale) { metadataByType in
            let enriched = games.map { game in
                guard let metadata = metadataByType[game.ratingSystemName.uppercased()] else { return game }
                var output = game
                metadata.apply(to: &output)
                return output
            }
            completion(enriched)
        }
    }

    private func fetchRatingDefinitions(locale: String, completion: @escaping @Sendable ([String: RatingMetadata]) -> Void) {
        let query = """
        query GetRatingDefinitions($locale: String!) {
          ratingDefinitions(language: $locale) {
            ratingSystem
            label
            displayInterval
            contentDescriptors { key label sortOrder }
            interactiveElements { key label sortOrder }
            ratings { categoryKey description label minimumAge largeImageUrl smallImageUrl }
          }
        }
        """
        let variables: NSDictionary = ["locale": locale]
        postGraphQlJson(query: query, variables: variables) { [weak self] data, _ in
            guard let self else {
                completion([:])
                return
            }
            var metadataByType: [String: RatingMetadata] = [:]
            for item in data?["ratingDefinitions"] as? [NSDictionary] ?? [] {
                guard let type = self.safeString(item["ratingSystem"]), !type.isEmpty else { continue }
                metadataByType[type.uppercased()] = self.parseRatingMetadata(item)
            }
            completion(metadataByType)
        }
    }

    private func enrichPanelResults(_ panels: [OPNPanelResult], vpcId: String, completion: @escaping @Sendable ([OPNPanelResult]) -> Void) {
        let games = panels.flatMap(\.sections).flatMap(\.games)
        guard !games.isEmpty else {
            completion(panels)
            return
        }
        enrichGames(games, vpcId: vpcId) { enrichedGames in
            var enrichedById: [String: OPNGameInfo] = [:]
            for game in enrichedGames {
                let key = game.uuid.isEmpty ? game.id : game.uuid
                if !key.isEmpty { enrichedById[key] = game }
            }
            let enrichedPanels = panels.map { panel in
                var outputPanel = panel
                outputPanel.sections = panel.sections.map { section in
                    var outputSection = section
                    outputSection.games = section.games.map { game in
                        enrichedById[game.uuid.isEmpty ? game.id : game.uuid] ?? game
                    }
                    return outputSection
                }
                return outputPanel
            }
            completion(enrichedPanels)
        }
    }

    private func parseGameItem(_ app: NSDictionary?) -> OPNGameInfo {
        guard let app else { return OPNGameInfo() }
        var game = OPNGameInfo()
        game.id = safeString(app["id"]) ?? ""
        game.uuid = game.id
        game.title = safeString(app["title"]) ?? ""
        game.shortName = safeString(app["shortName"]) ?? ""
        game.promoTag = safeString(app["promoTag"]) ?? ""
        game.shortDescription = firstSafeString(app, keys: ["shortDescription", "summary"]) ?? ""
        game.longDescription = firstSafeString(app, keys: ["longDescription", "description"]) ?? ""
        game.description = game.longDescription.isEmpty ? game.shortDescription : game.longDescription
        game.developerName = safeString(app["developerName"]) ?? ""
        game.publisherName = safeString(app["publisherName"]) ?? ""
        game.releaseDate = firstSafeString(app, keys: ["streetDate", "releaseDate", "releasedAt"]) ?? ""
        game.maxLocalPlayers = safeInt(app["maxLocalPlayers"])
        game.maxOnlinePlayers = safeInt(app["maxOnlinePlayers"])
        game.displaysOwnRatingDuringGameplay = safeBool(app["displaysOwnRatingDuringGameplay"])
        appendStringValues(&game.supportedControls, app["supportedControls"])
        assignContentRatings(app["contentRatings"], to: &game)
        game.nvidiaTech = parseFeatureFlags(app["nvidiaTech"])
        if let itemMetadata = app["itemMetadata"] as? NSDictionary {
            if game.shortDescription.isEmpty { game.shortDescription = firstSafeString(itemMetadata, keys: ["shortDescription", "summary"]) ?? "" }
            if game.longDescription.isEmpty { game.longDescription = firstSafeString(itemMetadata, keys: ["longDescription", "description"]) ?? "" }
            if game.description.isEmpty { game.description = game.longDescription.isEmpty ? game.shortDescription : game.longDescription }
        }
        if let itemMetadata = app["itemMetadata"] as? NSDictionary {
            appendStringValues(&game.campaignIds, itemMetadata["campaignIds"])
            if game.promoTag.isEmpty { game.promoTag = safeString(itemMetadata["promoTag"]) ?? "" }
        }
        if let gfn = app["gfn"] as? NSDictionary {
            game.playabilityState = safeString(gfn["playabilityState"]) ?? ""
            game.membershipTierLabel = safeString(gfn["minimumMembershipTierLabel"]) ?? ""
            game.playType = safeString(gfn["playType"]) ?? ""
            game.isPatching = isAppPatchingStatus(gfn["playabilityState"])
            if game.promoTag.isEmpty { game.promoTag = safeString(gfn["promoTag"]) ?? "" }
            if let catalogSkuStrings = gfn["catalogSkuStrings"] as? NSDictionary {
                appendStringValues(&game.skuTags, catalogSkuStrings["SKU_BASED_TAG"])
            }
        }
        if let images = app["images"] as? NSDictionary {
            for case let key as String in images.allKeys {
                let urls = imageStrings(from: images[key]).map { Self.optimizeImageURL($0, width: 1200) }.uniqueValues()
                if !urls.isEmpty { game.imageUrlsByType[key] = urls }
            }
            let landscape = firstLandscapeImageString(images)
            let poster = firstPosterImageString(images)
            let primary = landscape ?? poster
            if let landscape { game.heroImageUrl = Self.optimizeImageURL(landscape, width: 1200) }
            if let primary { game.imageUrl = Self.optimizeImageURL(primary, width: 900) }
            game.screenshotUrls = imageStrings(from: images["SCREENSHOTS"]).map { Self.optimizeImageURL($0, width: 720) }.uniqueValues()
        }
        appendDirectImage(firstSafeString(app, keys: ["marqueeHeroImage", "marqueeHeroImageUrl", "marqueeImage", "marqueeImageUrl"]), type: "MARQUEE_HERO_IMAGE", width: 1920, game: &game)
        appendDirectImage(firstSafeString(app, keys: ["heroImage", "heroImageUrl"]), type: "HERO_IMAGE", width: 1920, game: &game)
        appendDirectImage(firstSafeString(app, keys: ["logoImage", "logoImageUrl", "gameLogo", "gameLogoUrl"]), type: "GAME_LOGO", width: 620, game: &game)
        appendDirectImage(firstSafeString(app, keys: ["imageUrl", "tileImage", "tileImageUrl"]), type: "KEY_IMAGE", width: 900, game: &game)
        if let marqueeHeroImage = game.imageUrlsByType["MARQUEE_HERO_IMAGE"]?.first, !marqueeHeroImage.isEmpty {
            game.heroImageUrl = marqueeHeroImage
        } else if let heroImage = game.imageUrlsByType["HERO_IMAGE"]?.first, !heroImage.isEmpty {
            game.heroImageUrl = heroImage
        }
        if game.imageUrl.isEmpty {
            game.imageUrl = game.imageUrlsByType["TV_BANNER"]?.first ?? game.imageUrlsByType["KEY_IMAGE"]?.first ?? game.imageUrlsByType["GAME_BOX_ART"]?.first ?? ""
        }
        if let variants = app["variants"] as? [NSDictionary] {
            for item in variants {
                var variant = OPNGameVariant()
                variant.id = safeString(item["id"]) ?? ""
                variant.shortName = safeString(item["shortName"]) ?? ""
                variant.appStore = Self.normalizedVariantAppStore(safeString(item["appStore"]) ?? "")
                variant.storeUrl = safeString(item["storeUrl"]) ?? ""
                variant.developerName = safeString(item["developerName"]) ?? ""
                variant.publisherName = safeString(item["publisherName"]) ?? ""
                variant.releaseDate = firstSafeString(item, keys: ["streetDate", "releaseDate", "releasedAt"]) ?? ""
                appendStringValues(&variant.supportedControls, item["supportedControls"])
                appendStringValues(&variant.subscriptionIds, item["subscriptions"])
                variant.paymentModelTypes = parsePaymentModelTypes(item["paymentModels"])
                variant.minimumSizeInBytes = safeInt(item["minimumSizeInBytes"])
                variant.cloudSaveSupported = safeBool(item["cloudSaveSupported"])
                if let appStoreInfo = item["appStoreInfo"] as? NSDictionary {
                    variant.appStoreLabel = safeString(appStoreInfo["label"]) ?? ""
                    variant.appStoreSmallImageUrl = safeString(appStoreInfo["smallImageUrl"]) ?? ""
                }
                if let gfn = item["gfn"] as? NSDictionary {
                    variant.serviceStatus = safeString(gfn["status"]) ?? ""
                    variant.isPatching = isAppPatchingStatus(gfn["status"]) || isAppPatchingStatus(gfn["playabilityState"]) || isAppPatchingStatus(gfn["stateDetails"])
                    variant.installTimeInMinutes = safeInt(gfn["installTimeInMinutes"])
                    variant.supportedLanguages = parseSupportedLanguages(gfn["supportedLanguages"])
                    variant.gfnFeatureLabels = parseGfnFeatureLabels(gfn["features"])
                    if let library = gfn["library"] as? NSDictionary {
                        let libraryStatus = firstSafeString(library, keys: ["status"]) ?? ""
                        variant.libraryStatus = libraryStatus
                        variant.libraryPlayStatus = safeString(library["playStatus"]) ?? ""
                        variant.libraryInstalled = safeBool(library["installed"])
                        variant.librarySubscription = safeString(library["subscription"]) ?? ""
                        variant.serviceStatus = libraryStatus.isEmpty ? variant.serviceStatus : libraryStatus
                        variant.isPatching = variant.isPatching || isAppPatchingStatus(library["status"])
                        variant.librarySelected = safeBool(library["selected"])
                        if variant.librarySelected || Self.libraryStatusIsOwned(libraryStatus) { variant.inLibrary = true }
                    }
                }
                if game.contentRatings.isEmpty { assignContentRatings(item["contentRatings"], to: &game) }
                guard Self.variantIsRelevant(variant) else { continue }
                if let index = game.variants.firstIndex(where: { variantMatchesStoreMetadata(target: $0, metadata: variant) }) {
                    _ = mergeVariantFromSameStore(target: &game.variants[index], source: variant)
                } else {
                    if !variant.appStore.isEmpty { game.availableStores.append(variant.appStore) }
                    game.variants.append(variant)
                }
            }
        }
        var firstNumericVariant = ""
        for variant in game.variants {
            if variant.inLibrary { game.isInLibrary = true }
            if variant.isPatching { game.isPatching = true }
            let numeric = !variant.id.isEmpty && variant.id.allSatisfy(\.isNumber)
            if numeric, variant.librarySelected { game.launchAppId = variant.id }
            if numeric, firstNumericVariant.isEmpty { firstNumericVariant = variant.id }
        }
        if game.launchAppId.isEmpty { game.launchAppId = firstNumericVariant }
        if let genres = app["genres"] as? [Any] {
            for item in genres {
                if let text = item as? String { appendUnique(&game.genres, text) }
                if let dictionary = item as? NSDictionary { appendUnique(&game.genres, safeString(dictionary["name"]) ?? "") }
            }
        }
        if let features = (app["featureLabels"] ?? app["features"]) as? [String] {
            for feature in features { appendUnique(&game.featureLabels, feature) }
        }
        return game
    }

    private func parsePanelResults(_ rawPanels: [NSDictionary]) -> [OPNPanelResult] {
        rawPanels.compactMap { panel in
            var result = OPNPanelResult()
            result.id = safeString(panel["id"]) ?? ""
            result.title = safeString(panel["name"]) ?? ""
            if result.id.isEmpty { result.id = result.title }
            result.typename = safeString(panel["__typename"]) ?? ""
            let sections = panel["sections"] as? [NSDictionary] ?? []
            result.sections = sections.compactMap { section in
                var panelSection = OPNPanelSection()
                panelSection.id = safeString(section["id"]) ?? ""
                panelSection.title = safeString(section["title"]) ?? ""
                panelSection.typename = safeString(section["__typename"]) ?? ""
                if let seeMoreInfo = section["seeMoreInfo"] as? NSDictionary {
                    panelSection.seeMoreFilterIds = safeStringArray(seeMoreInfo["filterIds"])
                    panelSection.seeMoreSortId = safeString(seeMoreInfo["sortOrderId"]) ?? ""
                    panelSection.seeMoreTitle = safeString(seeMoreInfo["title"]) ?? ""
                }
                let items = section["items"] as? [NSDictionary] ?? []
                panelSection.games = items.compactMap { item in
                    guard safeString(item["__typename"]) == "GameItem", let app = item["app"] as? NSDictionary else { return nil }
                    let game = parseGameItem(app)
                    return !game.id.isEmpty && !game.title.isEmpty && !game.variants.isEmpty ? game : nil
                }
                return panelSection.games.isEmpty ? nil : panelSection
            }
            return result.sections.isEmpty ? nil : result
        }
    }

    private func parseCatalogDefinitions(_ definitionsData: NSDictionary?, result: inout OPNCatalogBrowseResult) -> [String: [String: Any]] {
        var filterPayloadById: [String: [String: Any]] = [:]
        let groups = definitionsData?["filterGroupDefinitions"] as? [NSDictionary] ?? []
        for groupRaw in groups {
            var group = OPNCatalogFilterGroup()
            group.id = safeString(groupRaw["id"]) ?? ""
            group.label = safeString(groupRaw["label"]) ?? ""
            let filters = groupRaw["filters"] as? [NSDictionary] ?? []
            for entry in filters {
                let filterId = safeString(entry["id"]) ?? ""
                if filterId.isEmpty { continue }
                var mergedPayload: [String: Any] = [:]
                for payloadString in entry["filters"] as? [String] ?? [] {
                    guard let data = payloadString.data(using: .utf8), let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                    deepMergeDictionary(into: &mergedPayload, source: payload)
                }
                if mergedPayload.isEmpty { continue }
                filterPayloadById[filterId] = mergedPayload
                group.options.append(OPNCatalogFilterOption(id: filterId, rawId: filterId, label: safeString(entry["label"]) ?? filterId, groupId: group.id, groupLabel: group.label))
            }
            if !group.options.isEmpty { result.filterGroups.append(group) }
        }
        let sorts = definitionsData?["sortOrderDefinitions"] as? [NSDictionary] ?? []
        for sort in sorts {
            let id = safeString(sort["id"]) ?? ""
            let orderBy = safeString(sort["orderBy"]) ?? ""
            if !id.isEmpty, !orderBy.isEmpty {
                result.sortOptions.append(OPNCatalogSortOption(id: id, label: safeString(sort["label"]) ?? id, orderBy: orderBy))
            }
        }
        return filterPayloadById
    }

    private func parseUserAccountInfo(_ data: NSDictionary?) -> OPNUserAccountInfo {
        var info = OPNUserAccountInfo()
        guard let userAccount = data?["userAccount"] as? NSDictionary else { return info }
        info.subscriptions = (userAccount["subscriptions"] as? [NSDictionary] ?? []).compactMap { safeString($0["id"]) }.filter { !$0.isEmpty }
        for storeData in userAccount["storesData"] as? [NSDictionary] ?? [] {
            var storeInfo = OPNStoreAccountInfo()
            storeInfo.store = safeString(storeData["store"]) ?? ""
            if let linkingData = storeData["accountLinkingData"] as? NSDictionary {
                storeInfo.hasAccountLinkingData = true
                storeInfo.userDisplayName = safeString(linkingData["userDisplayName"]) ?? ""
                storeInfo.expiresIn = safeString(linkingData["expiresIn"]) ?? ""
                storeInfo.userIdentifier = safeString(linkingData["userIdentifier"]) ?? ""
                if let syncingData = linkingData["accountSyncingData"] as? NSDictionary {
                    storeInfo.hasAccountSyncingData = true
                    storeInfo.syncing.totalNumberOfSyncedGfnGames = safeInt(syncingData["totalNumberOfSyncedGfnGames"])
                    storeInfo.syncing.syncState = safeString(syncingData["syncState"]) ?? ""
                    storeInfo.syncing.syncDate = safeString(syncingData["syncDate"]) ?? ""
                }
            }
            if !storeInfo.store.isEmpty { info.stores.append(storeInfo) }
        }
        return info
    }

    private func parseStoreDefinitions(_ data: NSDictionary?) -> [OPNStoreDefinition] {
        var definitions: [OPNStoreDefinition] = []
        for storeData in data?["appStoreDefinitions"] as? [NSDictionary] ?? [] {
            var definition = OPNStoreDefinition()
            definition.store = safeString(storeData["store"]) ?? ""
            definition.label = safeString(storeData["label"]) ?? ""
            definition.smallImageUrl = safeString(storeData["smallImageUrl"]) ?? ""
            definition.sortOrder = safeInt(storeData["sortOrder"])
            for featureData in storeData["features"] as? [NSDictionary] ?? [] {
                let feature = OPNStoreFeatureInfo(type: safeString(featureData["__typename"]) ?? "", displayProposition: safeString(featureData["displayProposition"]) ?? "", supported: safeBool(featureData["supported"]))
                if !feature.type.isEmpty { definition.features.append(feature) }
            }
            if let metadata = storeData["accountLinkingMetadata"] as? NSDictionary {
                definition.accountLinkingMetadata.supportedVariantIds = safeStringArray(metadata["supportedVariantIds"])
                definition.accountLinkingMetadata.isSupported = safeBool(metadata["isSupported"])
                definition.accountLinkingMetadata.isRequired = safeBool(metadata["isRequired"])
                definition.accountLinkingMetadata.label = safeString(metadata["label"]) ?? ""
            }
            if !definition.store.isEmpty { definitions.append(definition) }
        }
        return definitions.sorted { $0.sortOrder == $1.sortOrder ? $0.store < $1.store : $0.sortOrder < $1.sortOrder }
    }

    private func parseAppPatchStatuses(_ apps: [NSDictionary]) -> [String: OPNAppPatchStatus] {
        var statuses: [String: OPNAppPatchStatus] = [:]
        for app in apps {
            let appId = safeString(app["id"]) ?? ""
            guard !appId.isEmpty else { continue }
            var status = OPNAppPatchStatus(appId: appId)
            for variantData in app["variants"] as? [NSDictionary] ?? [] {
                let variantId = safeString(variantData["id"]) ?? ""
                guard !variantId.isEmpty else { continue }
                let gfn = variantData["gfn"] as? NSDictionary
                let library = gfn?["library"] as? NSDictionary
                let variantIsPatching = isAppPatchingStatus(gfn?["status"]) || isAppPatchingStatus(gfn?["stateDetails"]) || isAppPatchingStatus(library?["status"])
                status.variantPatchingById[variantId] = variantIsPatching
                status.isPatching = status.isPatching || variantIsPatching
            }
            statuses[appId] = status
        }
        return statuses
    }

    private func parseSubscriptionInfo(_ json: NSDictionary) -> OPNSubscriptionInfo {
        var info = OPNSubscriptionInfo()
        info.membershipTier = safeString(json["membershipTier"]).flatMap { $0.isEmpty ? nil : $0 } ?? "Free"
        info.subscriptionType = safeString(json["type"]) ?? ""
        info.subscriptionSubType = safeString(json["subType"]) ?? ""
        info.allottedHours = safeMinutesAsHours(json["allottedTimeInMinutes"])
        info.purchasedHours = safeMinutesAsHours(json["purchasedTimeInMinutes"])
        info.rolledOverHours = safeMinutesAsHours(json["rolledOverTimeInMinutes"])
        let fallbackTotal = info.allottedHours + info.purchasedHours + info.rolledOverHours
        info.totalHours = safeMinutesAsHours(json["totalTimeInMinutes"])
        if info.totalHours <= 0 { info.totalHours = fallbackTotal }
        info.remainingHours = safeMinutesAsHours(json["remainingTimeInMinutes"])
        info.usedHours = max(0, info.totalHours - info.remainingHours)
        info.isUnlimited = info.subscriptionSubType == "UNLIMITED"
        if let state = json["currentSubscriptionState"] as? NSDictionary {
            info.isGamePlayAllowed = state["isGamePlayAllowed"] as? Bool ?? true
        }
        return info
    }

    fileprivate func parseGameProviderInfo(_ json: NSDictionary?) -> OPNGameProviderInfo {
        let raw = providerInfoDictionary(json)
        var info = OPNGameProviderInfo()
        guard let raw else { return info }
        info.defaultProvider = safeString(raw["defaultProvider"]) ?? ""
        info.loggedInProvider = safeString(raw["loggedInProvider"]) ?? ""
        info.loginRequired = safeBool(raw["loginRequired"])
        info.loginPreferredProviders = safeStringArray(raw["loginPreferredProviders"])
        let endpoints = raw["gfnServiceEndpoints"] as? [NSDictionary] ?? []
        for entry in endpoints {
            var endpoint = OPNGameProviderEndpoint()
            endpoint.loginProvider = safeString(entry["loginProvider"]) ?? ""
            endpoint.loginProviderCode = safeString(entry["loginProviderCode"]) ?? ""
            endpoint.loginProviderDisplayName = safeString(entry["loginProviderDisplayName"]) ?? ""
            endpoint.streamingServiceUrl = normalizeStreamingBaseUrl(safeString(entry["streamingServiceUrl"]) ?? "")
            endpoint.idpId = safeString(entry["idpId"]) ?? ""
            endpoint.redeemRedirectUrl = safeString(entry["redeemRedirectUrl"]) ?? ""
            endpoint.priority = safeInt(entry["loginProviderPriority"])
            if !endpoint.streamingServiceUrl.isEmpty { info.endpoints.append(endpoint) }
        }
        info.endpoints.sort { $0.priority < $1.priority }
        return info
    }

    private func providerInfoDictionary(_ json: NSDictionary?) -> NSDictionary? {
        guard let json else { return nil }
        if let info = json["gfnServiceInfo"] as? NSDictionary { return info }
        if let data = json["data"] as? NSDictionary {
            if let info = data["gfnServiceInfo"] as? NSDictionary { return info }
            if let serviceUrls = data["serviceUrls"] as? NSDictionary, let info = serviceUrls["gfnServiceInfo"] as? NSDictionary { return info }
        }
        return json
    }

    fileprivate func selectGameProviderEndpoint(_ info: OPNGameProviderInfo, idpId: String) -> OPNGameProviderEndpoint {
        if !idpId.isEmpty, let endpoint = info.endpoints.first(where: { $0.idpId == idpId }) { return endpoint }
        if !info.loggedInProvider.isEmpty, let endpoint = info.endpoints.first(where: { $0.loginProvider == info.loggedInProvider || $0.loginProviderCode == info.loggedInProvider }) { return endpoint }
        if !info.defaultProvider.isEmpty, let endpoint = info.endpoints.first(where: { $0.loginProvider == info.defaultProvider || $0.loginProviderCode == info.defaultProvider }) { return endpoint }
        if let endpoint = info.endpoints.first(where: { !$0.streamingServiceUrl.isEmpty }) { return endpoint }
        var fallback = OPNGameProviderEndpoint()
        fallback.loginProvider = info.defaultProvider
        fallback.streamingServiceUrl = Self.defaultStreamingBaseUrl
        return fallback
    }

    private func ownedVariantMutation(mutationName: String, fieldName: String, variantId: String, completion: @escaping OPNOwnershipActionCallback) {
        guard !variantId.isEmpty else {
            dispatchOwnership(completion, false, "Missing variant ID")
            return
        }
        let mutation = "mutation \(mutationName)($cmsId: String!, $locale: String!) { \(fieldName) (language: $locale, variantId: $cmsId) { app { id } } }"
        let variables: NSDictionary = ["cmsId": variantId, "locale": Self.currentGFNCatalogLocale()]
        postGraphQlJson(query: mutation, variables: variables) { [weak self] data, error in
            guard let self else { return }
            if !error.isEmpty {
                self.dispatchOwnership(completion, false, error)
                return
            }
            let app = (data?[fieldName] as? NSDictionary)?["app"] as? NSDictionary
            guard let appId = self.safeString(app?["id"]), !appId.isEmpty else {
                self.dispatchOwnership(completion, false, "Ownership mutation response did not include an app ID")
                return
            }
            self.dispatchOwnership(completion, true, "")
        }
    }

    private func favoriteAppMutation(mutationName: String, fieldName: String, appId: String, completion: @escaping OPNFavoriteActionCallback) {
        guard !appId.isEmpty else {
            dispatchFavorite(completion, false, "Missing app ID")
            return
        }
        let mutation = "mutation \(mutationName)($appId: String!, $locale: String!) { \(fieldName) (language: $locale, appId: $appId) { app { id } } }"
        let variables: NSDictionary = ["appId": appId, "locale": Self.currentGFNCatalogLocale()]
        postGraphQlJson(query: mutation, variables: variables) { [weak self] data, error in
            guard let self else { return }
            if !error.isEmpty {
                self.dispatchFavorite(completion, false, error)
                return
            }
            let app = (data?[fieldName] as? NSDictionary)?["app"] as? NSDictionary
            guard let responseAppId = self.safeString(app?["id"]), !responseAppId.isEmpty else {
                self.dispatchFavorite(completion, false, "Favorite mutation response did not include an app ID")
                return
            }
            self.dispatchFavorite(completion, true, "")
        }
    }

    private func getServerVpcId(token: String, providerStreamingBaseUrl: String, completion: @escaping @Sendable (String) -> Void) {
        let normalized = normalizeStreamingBaseUrl(providerStreamingBaseUrl)
        let cacheKey = "\(normalized)|\(token.hashValue)"
        Self.vpcLock.lock()
        if let entry = Self.vpcCache[cacheKey], Date().timeIntervalSince(entry.timestamp) <= Self.serverVpcCacheFreshSeconds {
            Self.vpcLock.unlock()
            completion(entry.vpcId)
            return
        }
        if Self.pendingVpcCallbacks[cacheKey] != nil {
            Self.pendingVpcCallbacks[cacheKey]?.append(completion)
            Self.vpcLock.unlock()
            return
        }
        Self.pendingVpcCallbacks[cacheKey] = [completion]
        Self.vpcLock.unlock()

        let finish: @Sendable (String) -> Void = { vpcId in
            let resolved = vpcId.isEmpty ? "GFN-PC" : vpcId
            Self.vpcLock.lock()
            Self.vpcCache[cacheKey] = VpcCacheEntry(vpcId: resolved, timestamp: Date())
            let callbacks = Self.pendingVpcCallbacks.removeValue(forKey: cacheKey) ?? []
            Self.vpcLock.unlock()
            for callback in callbacks { callback(resolved) }
        }

        guard let url = URL(string: normalized + String(CloudMatch.Endpoint.serverInfo.path.dropFirst())) else {
            finish("GFN-PC")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization")
        Self.applyClientHeaders(to: &request, includeBrowserHeaders: false)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173", forHTTPHeaderField: "User-Agent")
        let networkStart = OPNNetworkLog.start(&request, operation: "cloudmatch.serverInfo")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.serverInfo", startedAt: networkStart, data: data, response: response, error: error)
            guard error == nil, let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
                finish("GFN-PC")
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let serverInfo = json.map(CloudMatchServerInfoParser.parse)
            let requestStatus = json?["requestStatus"] as? [String: Any]
            let serverId = requestStatus?["serverId"] as? String
            finish(serverInfo?.vpcId.isEmpty == false ? serverInfo?.vpcId ?? "GFN-PC" : serverId ?? "GFN-PC")
        }.resume()
    }

    private static func applyClientHeaders(to request: inout URLRequest, includeBrowserHeaders: Bool) {
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

    private static var gfnUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 GFN-PC/2.0.80.173"
    }

    private static func graphQLOperationName(_ query: String) -> String {
        let compact = query.replacingOccurrences(of: "\n", with: " ")
        let tokens = compact.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == "{" }).map(String.init)
        guard let operationKeywordIndex = tokens.firstIndex(where: { $0 == "query" || $0 == "mutation" }), tokens.indices.contains(operationKeywordIndex + 1) else {
            return "inlineGraphQL"
        }
        return tokens[operationKeywordIndex + 1]
    }

    private func normalizeStreamingBaseUrl(_ url: String) -> String {
        if url.isEmpty { return Self.defaultStreamingBaseUrl }
        guard let components = URLComponents(string: url), components.scheme?.lowercased() == "https", components.host?.isEmpty == false else { return "" }
        return url.hasSuffix("/") ? url : "\(url)/"
    }

    private func safeString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return value as? String
    }

    private func safeStringArray(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { safeString($0) }.filter { !$0.isEmpty }
    }

    private func safeInt(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private func safeBool(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["true", "1", "yes"].contains(string.lowercased()) }
        return false
    }

    private func isAppPatchingStatus(_ value: Any?) -> Bool {
        if let text = safeString(value)?.lowercased(), !text.isEmpty {
            return text.contains("patch") || text.contains("application_patching") || text.contains("app_patching") || text.contains("autopatching") || text.contains("manualpatching")
        }
        if let dictionary = value as? NSDictionary {
            return dictionary.allValues.contains { isAppPatchingStatus($0) }
        }
        return false
    }

    private func safeMinutesAsHours(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue / 60 }
        if let string = value as? String { return (Double(string) ?? 0) / 60 }
        return 0
    }

    private func firstSafeString(_ dictionary: NSDictionary, keys: [String]) -> String? {
        for key in keys {
            if let value = safeString(dictionary[key]), !value.isEmpty { return value }
        }
        return nil
    }

    private func appendDirectImage(_ value: String?, type: String, width: Int, game: inout OPNGameInfo) {
        guard let value, !value.isEmpty else { return }
        var urls = game.imageUrlsByType[type] ?? []
        appendUnique(&urls, Self.optimizeImageURL(value, width: width))
        if !urls.isEmpty { game.imageUrlsByType[type] = urls }
    }

    private func imageStrings(from rawValue: Any?) -> [String] {
        guard let rawValue, !(rawValue is NSNull) else { return [] }
        if let text = rawValue as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let array = rawValue as? [Any] { return array.flatMap { imageStrings(from: $0) }.uniqueValues() }
        guard let dictionary = rawValue as? NSDictionary else { return [] }
        if let directURL = firstSafeString(dictionary, keys: ["url", "URL", "src", "href", "imageUrl", "imageURL", "thumbnailUrl", "thumbnailURL", "contentUrl", "contentURL"]) {
            return imageStrings(from: directURL)
        }
        return dictionary.allValues.flatMap { imageStrings(from: $0) }.uniqueValues()
    }

    private func firstImageString(_ images: NSDictionary, keys: [String]) -> String? {
        for key in keys {
            if let url = imageStrings(from: images[key]).first, !url.isEmpty { return url }
        }
        return nil
    }

    private func firstLandscapeImageString(_ images: NSDictionary) -> String? {
        firstImageString(images, keys: ["MARQUEE_HERO_IMAGE", "HERO_IMAGE", "TV_BANNER", "FEATURE_IMAGE", "KEY_IMAGE", "KEY_ART"])
    }

    private func firstPosterImageString(_ images: NSDictionary) -> String? {
        firstImageString(images, keys: ["GAME_BOX_ART", "KEY_IMAGE", "KEY_ART"])
    }

    private func appendStringValues(_ values: inout [String], _ rawValue: Any?) {
        if let text = rawValue as? String {
            appendUnique(&values, text)
            return
        }
        for item in rawValue as? [Any] ?? [] {
            if let text = item as? String { appendUnique(&values, text) }
            if let dictionary = item as? NSDictionary { appendUnique(&values, firstSafeString(dictionary, keys: ["name", "label", "value", "rating", "control", "type"]) ?? "") }
        }
    }

    private func assignContentRatings(_ rawValue: Any?, to game: inout OPNGameInfo) {
        guard let rawValue, !(rawValue is NSNull) else { return }
        var values: [String] = []
        let entries = rawValue as? [Any] ?? [rawValue]
        for entry in entries {
            if let text = entry as? String {
                appendUnique(&values, readableMetadataLabel(text))
                continue
            }
            guard let dictionary = entry as? NSDictionary else { continue }
            let categoryKey = firstSafeString(dictionary, keys: ["categoryKey", "ratingCategoryKey", "rating", "category", "label", "name"]) ?? ""
            let type = firstSafeString(dictionary, keys: ["type", "ratingSystem", "system"]) ?? ""
            let categoryLabel = ratingCategoryLabel(categoryKey: categoryKey, type: type) ?? ""
            if game.ratingSystemName.isEmpty { game.ratingSystemName = readableRatingSystem(type) }
            if game.ratingCategoryKey.isEmpty { game.ratingCategoryKey = categoryKey }
            if game.ratingCategoryTitle.isEmpty { game.ratingCategoryTitle = categoryLabel }
            if game.ratingImageUrl.isEmpty { game.ratingImageUrl = ratingImageString(dictionary["rating"] ?? dictionary["image"] ?? dictionary["images"] ?? dictionary["largeImageUrl"]) }
            if !categoryLabel.isEmpty { appendUnique(&values, categoryLabel) }
            appendUnique(&values, readableRatingSystem(type))
            appendMetadataLabels(&game.ratingDescriptors, dictionary["contentDescriptorKeys"])
            appendMetadataLabels(&game.ratingInteractiveElements, dictionary["interactiveElementKeys"])
            for descriptor in game.ratingDescriptors { appendUnique(&values, descriptor) }
            for element in game.ratingInteractiveElements { appendUnique(&values, element) }
        }
        game.contentRatings = values.filter { !$0.isEmpty }
    }

    private func parseFeatureFlags(_ rawValue: Any?) -> [String] {
        guard let rawValue, !(rawValue is NSNull) else { return [] }
        if let dictionary = rawValue as? NSDictionary {
            var values: [String] = []
            for case let key as String in dictionary.allKeys where safeBool(dictionary[key]) {
                appendUnique(&values, readableMetadataLabel(key))
            }
            return values
        }
        var values: [String] = []
        appendStringValues(&values, rawValue)
        return values.map(readableMetadataLabel)
    }

    private func parsePaymentModelTypes(_ rawValue: Any?) -> [String] {
        var values: [String] = []
        for item in rawValue as? [Any] ?? [] {
            if let text = item as? String { appendUnique(&values, text) }
            if let dictionary = item as? NSDictionary { appendUnique(&values, safeString(dictionary["__typename"]) ?? "") }
        }
        return values
    }

    private func parseSupportedLanguages(_ rawValue: Any?) -> [String] {
        var values: [String] = []
        for item in rawValue as? [Any] ?? [] {
            if let text = item as? String { appendUnique(&values, text) }
            if let dictionary = item as? NSDictionary { appendUnique(&values, safeString(dictionary["language"]) ?? "") }
        }
        return values
    }

    private func parseGfnFeatureLabels(_ rawValue: Any?) -> [String] {
        var values: [String] = []
        for item in rawValue as? [Any] ?? [] {
            if let text = item as? String { appendUnique(&values, readableMetadataLabel(text)) }
            guard let dictionary = item as? NSDictionary else { continue }
            let key = safeString(dictionary["key"]) ?? safeString(dictionary["__typename"]) ?? ""
            if !key.isEmpty { appendUnique(&values, readableMetadataLabel(key)) }
            appendStringValues(&values, dictionary["values"])
            appendStringValues(&values, dictionary["value"])
        }
        return values
    }

    private func parseRatingMetadata(_ dictionary: NSDictionary?) -> RatingMetadata {
        var metadata = RatingMetadata()
        for entry in dictionary?["ratings"] as? [NSDictionary] ?? [] {
            let key = (safeString(entry["categoryKey"]) ?? "").uppercased()
            guard !key.isEmpty else { continue }
            metadata.ratingsByCategoryKey[key] = RatingCategoryMetadata(
                label: safeString(entry["label"]) ?? "",
                largeImageUrl: safeString(entry["largeImageUrl"]) ?? "",
                smallImageUrl: safeString(entry["smallImageUrl"]) ?? ""
            )
        }
        for entry in dictionary?["contentDescriptors"] as? [NSDictionary] ?? [] {
            let key = (safeString(entry["key"]) ?? "").uppercased()
            let label = safeString(entry["label"]) ?? ""
            if !key.isEmpty, !label.isEmpty { metadata.contentDescriptorsByKey[key] = label }
        }
        for entry in dictionary?["interactiveElements"] as? [NSDictionary] ?? [] {
            let key = (safeString(entry["key"]) ?? "").uppercased()
            let label = safeString(entry["label"]) ?? ""
            if !key.isEmpty, !label.isEmpty { metadata.interactiveElementsByKey[key] = label }
        }
        return metadata
    }

    private func appendMetadataLabels(_ values: inout [String], _ rawValue: Any?) {
        for value in safeStringArray(rawValue) {
            appendUnique(&values, readableMetadataLabel(value))
        }
    }

    private func ratingCategoryLabel(categoryKey: String, type: String) -> String? {
        let key = categoryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let normalized = key.uppercased().replacingOccurrences(of: "-", with: "_")
        let esrbLabels: [String: String] = [
            "EARLY_CHILDHOOD": "Early Childhood",
            "EVERYONE": "Everyone",
            "EVERYONE_10": "Everyone 10+",
            "EVERYONE_10_PLUS": "Everyone 10+",
            "TEEN": "Teen",
            "MATURE": "Mature 17+",
            "MATURE_17": "Mature 17+",
            "MATURE_17_PLUS": "Mature 17+",
            "ADULTS_ONLY": "Adults Only 18+",
            "ADULTS_ONLY_18": "Adults Only 18+",
            "ADULTS_ONLY_18_PLUS": "Adults Only 18+",
            "RATING_PENDING": "Rating Pending"
        ]
        if type.uppercased() == "ESRB", let label = esrbLabels[normalized] { return label }
        return readableMetadataLabel(key)
    }

    private func readableRatingSystem(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 8 ? trimmed.uppercased() : readableMetadataLabel(trimmed)
    }

    private func ratingImageString(_ rawValue: Any?) -> String {
        if let text = safeString(rawValue) { return text }
        guard let dictionary = rawValue as? NSDictionary else { return "" }
        return firstSafeString(dictionary, keys: ["largeImageUrl", "smallImageUrl", "imageUrl", "url", "src"]) ?? ""
    }

    private func readableMetadataLabel(_ value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return normalized
            .split(separator: " ")
            .map { word in word.prefix(1).uppercased() + word.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    private func appendUnique(_ values: inout [String], _ value: String) {
        if !value.isEmpty, !values.contains(value) { values.append(value) }
    }

    private func deepMergeDictionary(into target: inout [String: Any], source: [String: Any]) {
        for (key, value) in source {
            if var targetDictionary = target[key] as? [String: Any], let sourceDictionary = value as? [String: Any] {
                deepMergeDictionary(into: &targetDictionary, source: sourceDictionary)
                target[key] = targetDictionary
            } else {
                target[key] = value
            }
        }
    }

    private func mergeVariantFromSameStore(target: inout OPNGameVariant, source: OPNGameVariant) -> Bool {
        var changed = false
        if !source.id.isEmpty, target.id.isEmpty || (!target.librarySelected && source.librarySelected) { target.id = source.id; changed = true }
        if target.shortName.isEmpty, !source.shortName.isEmpty { target.shortName = source.shortName; changed = true }
        if target.appStoreLabel.isEmpty, !source.appStoreLabel.isEmpty { target.appStoreLabel = source.appStoreLabel; changed = true }
        if target.appStoreSmallImageUrl.isEmpty, !source.appStoreSmallImageUrl.isEmpty { target.appStoreSmallImageUrl = source.appStoreSmallImageUrl; changed = true }
        if target.storeUrl.isEmpty, !source.storeUrl.isEmpty { target.storeUrl = source.storeUrl; changed = true }
        if target.developerName.isEmpty, !source.developerName.isEmpty { target.developerName = source.developerName; changed = true }
        if target.publisherName.isEmpty, !source.publisherName.isEmpty { target.publisherName = source.publisherName; changed = true }
        if target.releaseDate.isEmpty, !source.releaseDate.isEmpty { target.releaseDate = source.releaseDate; changed = true }
        if target.supportedControls.isEmpty, !source.supportedControls.isEmpty { target.supportedControls = source.supportedControls; changed = true }
        if !source.serviceStatus.isEmpty, target.serviceStatus.isEmpty || (!target.librarySelected && source.librarySelected) { target.serviceStatus = source.serviceStatus; changed = true }
        if target.libraryStatus.isEmpty, !source.libraryStatus.isEmpty { target.libraryStatus = source.libraryStatus; changed = true }
        if target.libraryPlayStatus.isEmpty, !source.libraryPlayStatus.isEmpty { target.libraryPlayStatus = source.libraryPlayStatus; changed = true }
        if !target.libraryInstalled, source.libraryInstalled { target.libraryInstalled = true; changed = true }
        if target.librarySubscription.isEmpty, !source.librarySubscription.isEmpty { target.librarySubscription = source.librarySubscription; changed = true }
        if target.subscriptionIds.isEmpty, !source.subscriptionIds.isEmpty { target.subscriptionIds = source.subscriptionIds; changed = true }
        if target.paymentModelTypes.isEmpty, !source.paymentModelTypes.isEmpty { target.paymentModelTypes = source.paymentModelTypes; changed = true }
        if target.minimumSizeInBytes <= 0, source.minimumSizeInBytes > 0 { target.minimumSizeInBytes = source.minimumSizeInBytes; changed = true }
        if !target.cloudSaveSupported, source.cloudSaveSupported { target.cloudSaveSupported = true; changed = true }
        if target.installTimeInMinutes <= 0, source.installTimeInMinutes > 0 { target.installTimeInMinutes = source.installTimeInMinutes; changed = true }
        if target.supportedLanguages.isEmpty, !source.supportedLanguages.isEmpty { target.supportedLanguages = source.supportedLanguages; changed = true }
        if target.gfnFeatureLabels.isEmpty, !source.gfnFeatureLabels.isEmpty { target.gfnFeatureLabels = source.gfnFeatureLabels; changed = true }
        if !target.librarySelected, source.librarySelected { target.librarySelected = true; changed = true }
        if !target.inLibrary, source.inLibrary { target.inLibrary = true; changed = true }
        return changed
    }

    private func mergeMissingStoreMetadata(target: inout OPNGameInfo, metadata: OPNGameInfo) {
        if target.launchAppId.isEmpty { target.launchAppId = metadata.launchAppId }
        if !target.displaysOwnRatingDuringGameplay { target.displaysOwnRatingDuringGameplay = metadata.displaysOwnRatingDuringGameplay }
        for store in metadata.availableStores where !target.availableStores.contains(where: { $0.caseInsensitiveCompare(store) == .orderedSame }) { target.availableStores.append(store) }
        for metadataVariant in metadata.variants {
            if let index = target.variants.firstIndex(where: { variantMatchesStoreMetadata(target: $0, metadata: metadataVariant) }) {
                if target.variants[index].id.isEmpty { target.variants[index].id = metadataVariant.id }
                if target.variants[index].shortName.isEmpty { target.variants[index].shortName = metadataVariant.shortName }
                if target.variants[index].appStore.isEmpty { target.variants[index].appStore = metadataVariant.appStore }
                if target.variants[index].appStoreLabel.isEmpty { target.variants[index].appStoreLabel = metadataVariant.appStoreLabel }
                if target.variants[index].appStoreSmallImageUrl.isEmpty { target.variants[index].appStoreSmallImageUrl = metadataVariant.appStoreSmallImageUrl }
                if target.variants[index].storeUrl.isEmpty { target.variants[index].storeUrl = metadataVariant.storeUrl }
                if target.variants[index].developerName.isEmpty { target.variants[index].developerName = metadataVariant.developerName }
                if target.variants[index].publisherName.isEmpty { target.variants[index].publisherName = metadataVariant.publisherName }
                if target.variants[index].releaseDate.isEmpty { target.variants[index].releaseDate = metadataVariant.releaseDate }
                if target.variants[index].supportedControls.isEmpty { target.variants[index].supportedControls = metadataVariant.supportedControls }
                if target.variants[index].serviceStatus.isEmpty { target.variants[index].serviceStatus = metadataVariant.serviceStatus }
                if target.variants[index].libraryStatus.isEmpty { target.variants[index].libraryStatus = metadataVariant.libraryStatus }
                if target.variants[index].libraryPlayStatus.isEmpty { target.variants[index].libraryPlayStatus = metadataVariant.libraryPlayStatus }
                if !target.variants[index].libraryInstalled { target.variants[index].libraryInstalled = metadataVariant.libraryInstalled }
                if target.variants[index].librarySubscription.isEmpty { target.variants[index].librarySubscription = metadataVariant.librarySubscription }
                if target.variants[index].subscriptionIds.isEmpty { target.variants[index].subscriptionIds = metadataVariant.subscriptionIds }
                if target.variants[index].paymentModelTypes.isEmpty { target.variants[index].paymentModelTypes = metadataVariant.paymentModelTypes }
                if target.variants[index].minimumSizeInBytes <= 0 { target.variants[index].minimumSizeInBytes = metadataVariant.minimumSizeInBytes }
                if !target.variants[index].cloudSaveSupported { target.variants[index].cloudSaveSupported = metadataVariant.cloudSaveSupported }
                if target.variants[index].installTimeInMinutes <= 0 { target.variants[index].installTimeInMinutes = metadataVariant.installTimeInMinutes }
                if target.variants[index].supportedLanguages.isEmpty { target.variants[index].supportedLanguages = metadataVariant.supportedLanguages }
                if target.variants[index].gfnFeatureLabels.isEmpty { target.variants[index].gfnFeatureLabels = metadataVariant.gfnFeatureLabels }
                if !target.variants[index].librarySelected { target.variants[index].librarySelected = metadataVariant.librarySelected }
                if !target.variants[index].inLibrary { target.variants[index].inLibrary = metadataVariant.inLibrary }
            } else if !metadataVariant.appStore.isEmpty {
                target.variants.append(metadataVariant)
                if !target.availableStores.contains(where: { $0.caseInsensitiveCompare(metadataVariant.appStore) == .orderedSame }) { target.availableStores.append(metadataVariant.appStore) }
            }
        }
    }

    private func variantMatchesStoreMetadata(target: OPNGameVariant, metadata: OPNGameVariant) -> Bool {
        if !target.id.isEmpty, !metadata.id.isEmpty, target.id == metadata.id { return true }
        if !target.appStore.isEmpty, !metadata.appStore.isEmpty, target.appStore.caseInsensitiveCompare(metadata.appStore) == .orderedSame { return true }
        return false
    }

    private static var libraryCatalogFilter: NSDictionary {
        ["variants": ["gfn": ["library": ["status": ["notEquals": "NOT_OWNED"]]]]] as NSDictionary
    }

    private static func libraryStatusIsOwned(_ status: String) -> Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && normalized.caseInsensitiveCompare("NOT_OWNED") != .orderedSame
    }

    private static func normalizedVariantAppStore(_ appStore: String) -> String {
        let normalized = appStore.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.caseInsensitiveCompare("UNKNOWN") == .orderedSame { return "" }
        if normalized.caseInsensitiveCompare("NONE") == .orderedSame { return "" }
        return normalized
    }

    private static func variantIsRelevant(_ variant: OPNGameVariant) -> Bool {
        !variant.appStore.isEmpty || variant.inLibrary || variant.librarySelected || OPNLaunchAppId.resolve(variant.id) != nil
    }

    private func storeURLForKnownGame(_ game: OPNGameInfo, variantIndex: Int) -> String? {
        if game.variants.indices.contains(variantIndex), !game.variants[variantIndex].storeUrl.isEmpty { return game.variants[variantIndex].storeUrl }
        return game.variants.first { !$0.storeUrl.isEmpty }?.storeUrl
    }

    private func launchableAppId(for game: OPNGameInfo, variantIndex: Int) -> String? {
        if game.variants.indices.contains(variantIndex), let appId = validLaunchAppId(game.variants[variantIndex].id) { return appId }
        if let appId = validLaunchAppId(game.launchAppId) { return appId }
        if let appId = validLaunchAppId(game.id) { return appId }
        return game.variants.compactMap { validLaunchAppId($0.id) }.first
    }

    private func launchableAppId(for game: OPNGameInfo, preferredStore: String) -> String? {
        if !preferredStore.isEmpty, let appId = game.variants.first(where: { $0.appStore.caseInsensitiveCompare(preferredStore) == .orderedSame }).flatMap({ validLaunchAppId($0.id) }) { return appId }
        if let appId = validLaunchAppId(game.launchAppId) { return appId }
        if let appId = validLaunchAppId(game.id) { return appId }
        return game.variants.compactMap { validLaunchAppId($0.id) }.first
    }

    private func validLaunchAppId(_ value: String) -> String? {
        OPNLaunchAppId.resolve(value)?.stringValue
    }

    private func storeURLForMetadataGame(_ metadataGame: OPNGameInfo, variantId: String, store: String) -> String {
        if !variantId.isEmpty, let url = metadataGame.variants.first(where: { $0.id == variantId && !$0.storeUrl.isEmpty })?.storeUrl { return url }
        if !store.isEmpty, let url = metadataGame.variants.first(where: { $0.appStore.caseInsensitiveCompare(store) == .orderedSame && !$0.storeUrl.isEmpty })?.storeUrl { return url }
        return metadataGame.variants.first { !$0.storeUrl.isEmpty }?.storeUrl ?? ""
    }

    private func deduplicateGames(_ games: [OPNGameInfo]) -> [OPNGameInfo] {
        var byId: [String: OPNGameInfo] = [:]
        var orderedIds: [String] = []
        for game in games {
            guard !game.id.isEmpty else { continue }
            if var existing = byId[game.id] {
                let existingVariantIds = Set(existing.variants.map(\.id))
                existing.variants.append(contentsOf: game.variants.filter { !existingVariantIds.contains($0.id) })
                if existing.title.isEmpty { existing.title = game.title }
                if existing.imageUrl.isEmpty { existing.imageUrl = game.imageUrl }
                if existing.heroImageUrl.isEmpty { existing.heroImageUrl = game.heroImageUrl }
                if !game.screenshotUrls.isEmpty { existing.screenshotUrls = game.screenshotUrls }
                for (key, value) in game.imageUrlsByType where existing.imageUrlsByType[key] == nil { existing.imageUrlsByType[key] = value }
                if existing.description.isEmpty { existing.description = game.description }
                if existing.shortDescription.isEmpty { existing.shortDescription = game.shortDescription }
                if existing.longDescription.isEmpty { existing.longDescription = game.longDescription }
                byId[game.id] = existing
            } else {
                byId[game.id] = game
                orderedIds.append(game.id)
            }
        }
        return orderedIds.compactMap { byId[$0] }.filter { !$0.variants.isEmpty }
    }

    private func fetchPublicGamesLocale(locales: [String], index: Int, completion: @escaping OPNCatalogCallback) {
        if index >= locales.count {
            dispatchCatalog(completion, false, [], "No public game locale fallback succeeded")
            return
        }
        guard let url = URL(string: "https://static.nvidiagrid.net/supported-public-game-list/locales/gfnpc-\(locales[index]).json") else {
            fetchPublicGamesLocale(locales: locales, index: index + 1, completion: completion)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let networkStart = OPNNetworkLog.start(&request, operation: "static.publicGames")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { [weak self] data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "static.publicGames", startedAt: networkStart, data: data, response: response, error: error)
            guard let self else { return }
            Self.workQueue.async {
                guard error == nil,
                      let data,
                      let publicGames = try? JSONDecoder().decode([PublicGameListItem].self, from: data) else {
                    self.fetchPublicGamesLocale(locales: locales, index: index + 1, completion: completion)
                    return
                }
                let games = publicGames.compactMap { item -> OPNGameInfo? in
                    guard item.status == "AVAILABLE", !item.title.isEmpty else { return nil }
                    var game = OPNGameInfo()
                    game.title = item.title
                    game.shortDescription = item.shortDescription.isEmpty ? item.summary : item.shortDescription
                    game.longDescription = item.longDescription.isEmpty ? item.description : item.longDescription
                    game.description = game.longDescription.isEmpty ? game.shortDescription : game.longDescription
                    let sid = item.id.isEmpty ? item.title : item.id
                    let steamAppId = item.steamUrl.components(separatedBy: "/app/").dropFirst().first?.components(separatedBy: "/").first
                    let finalAppId = steamAppId?.isEmpty == false ? steamAppId ?? sid : sid
                    game.id = finalAppId
                    game.uuid = sid
                    if let steamAppId, !steamAppId.isEmpty {
                        game.heroImageUrl = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(steamAppId)/library_hero.jpg"
                        game.imageUrl = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(steamAppId)/header.jpg"
                    }
                    return game
                }
                self.dispatchCatalog(completion, true, games, "")
            }
        }.resume()
    }

    private func percentEncodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?#%+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func accountLinkingResponseSnippet(_ data: Data?) -> String {
        guard let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return "" }
        let normalized = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return normalized.count > 512 ? String(normalized.prefix(512)) : normalized
    }

    private static func currentGFNLocale() -> String {
        OPNLocale.currentGFNLocale()
    }

    private static func currentGFNCatalogLocale() -> String {
        OPNLocale.currentGFNCatalogLocale()
    }

    private static func currentGFNLocaleURLPathComponentFallbacks() -> [String] {
        OPNLocale.currentGFNLocaleURLPathComponentFallbacks()
    }

    private func dispatchGraphQL(_ completion: @escaping @Sendable (NSDictionary?, String) -> Void, _ payload: NSDictionary?, _ message: String) {
        let payloadBox = payload.map(NSDictionaryBox.init)
        Self.workQueue.async { [payloadBox] in completion(payloadBox?.value, message) }
    }

    private func dispatchPanel(_ completion: @escaping OPNPanelCallback, _ success: Bool, _ panels: [OPNPanelResult], _ error: String) {
        DispatchQueue.main.async { completion(success, panels, error) }
    }

    private func dispatchCatalog(_ completion: @escaping OPNCatalogCallback, _ success: Bool, _ games: [OPNGameInfo], _ error: String) {
        DispatchQueue.main.async { completion(success, games, error) }
    }

    private func dispatchCatalogBrowse(_ completion: @escaping OPNCatalogBrowseCallback, _ success: Bool, _ result: OPNCatalogBrowseResult, _ error: String) {
        DispatchQueue.main.async { completion(success, result, error) }
    }

    private func dispatchSubscription(_ completion: @escaping OPNSubscriptionCallback, _ success: Bool, _ subscription: OPNSubscriptionInfo, _ error: String) {
        DispatchQueue.main.async { completion(success, subscription, error) }
    }

    private func dispatchStoreURL(_ completion: @escaping OPNStoreURLCallback, _ success: Bool, _ storeURL: String, _ error: String) {
        DispatchQueue.main.async { completion(success, storeURL, error) }
    }

    private func dispatchProviderInfo(_ completion: @escaping OPNProviderInfoCallback, _ success: Bool, _ providerInfo: OPNGameProviderInfo, _ selectedEndpoint: OPNGameProviderEndpoint, _ error: String) {
        DispatchQueue.main.async { completion(success, providerInfo, selectedEndpoint, error) }
    }

    fileprivate func dispatchOwnership(_ completion: @escaping OPNOwnershipActionCallback, _ success: Bool, _ error: String) {
        DispatchQueue.main.async { completion(success, error) }
    }

    fileprivate func dispatchFavorite(_ completion: @escaping OPNFavoriteActionCallback, _ success: Bool, _ error: String) {
        DispatchQueue.main.async { completion(success, error) }
    }

    private func dispatchUserAccount(_ completion: @escaping OPNUserAccountCallback, _ success: Bool, _ accountInfo: OPNUserAccountInfo, _ error: String) {
        DispatchQueue.main.async { completion(success, accountInfo, error) }
    }

    private func dispatchStoreDefinitions(_ completion: @escaping OPNStoreDefinitionsCallback, _ success: Bool, _ definitions: [OPNStoreDefinition], _ error: String) {
        DispatchQueue.main.async { completion(success, definitions, error) }
    }

    private func dispatchAppPatchStatuses(_ completion: @escaping OPNAppPatchStatusesCallback, _ success: Bool, _ statuses: [String: OPNAppPatchStatus], _ error: String) {
        DispatchQueue.main.async { completion(success, statuses, error) }
    }
}

@objc(OPNGameServiceSwiftAdapter)
public final class OPNGameServiceSwiftAdapter: NSObject {
    @objc(configureCatalogSessionWithAccessToken:idToken:userId:)
    public static func configureCatalogSession(accessToken: String, idToken: String, userId: String) {
        let token = idToken.isEmpty ? accessToken : idToken
        OPNGameService.shared.setAccessToken(token)
        OPNGameService.shared.setAccountLinkingToken(token)
        OPNGameService.shared.setUserId(userId)
        OPNGameService.shared.setVpcId("GFN-PC")
        OPNGameService.shared.prewarmLaunchData()
    }

    @objc(setAccessToken:)
    public static func setAccessToken(_ token: String) {
        OPNGameService.shared.setAccessToken(token)
    }

    @objc(setAccountLinkingToken:)
    public static func setAccountLinkingToken(_ token: String) {
        OPNGameService.shared.setAccountLinkingToken(token)
    }

    @objc(setVpcId:)
    public static func setVpcId(_ id: String) {
        OPNGameService.shared.setVpcId(id)
    }

    @objc(setUserId:)
    public static func setUserId(_ id: String) {
        OPNGameService.shared.setUserId(id)
    }

    @objc(setStreamingBaseUrl:)
    public static func setStreamingBaseUrl(_ url: String) {
        OPNGameService.shared.setStreamingBaseUrl(url)
    }

    @objc(providerStreamingBaseURL)
    public static func providerStreamingBaseURL() -> String {
        OPNGameService.shared.providerStreamingBaseURL()
    }

    @objc(prewarmLaunchData)
    public static func prewarmLaunchData() {
        OPNGameService.shared.prewarmLaunchData()
    }

    @objc(fetchProviderInfoWithIdpId:completion:)
    static func fetchProviderInfo(idpId: String, completion: @escaping @Sendable (Bool, OPNParsedGameProviderInfo, OPNParsedGameProviderEndpoint, String) -> Void) {
        OPNGameService.shared.fetchProviderInfo(idpId: idpId) { success, info, endpoint, error in
            completion(success, OPNParsedGameProviderInfo(info: info), OPNParsedGameProviderEndpoint(endpoint: endpoint), error)
        }
    }

    public static func fetchGameProviderInfo(idpId: String, completion: @escaping @Sendable (Bool, OPNGameProviderInfo, OPNGameProviderEndpoint, String) -> Void) {
        OPNGameService.shared.fetchProviderInfo(idpId: idpId) { success, info, endpoint, error in
            completion(success, info, endpoint, error)
        }
    }

    public static func selectGameProviderEndpoint(from info: OPNGameProviderInfo, idpId: String) -> OPNGameProviderEndpoint {
        OPNGameService.shared.selectGameProviderEndpoint(info, idpId: idpId)
    }

    @objc(fetchSubscriptionInfoWithUserId:completion:)
    public static func fetchSubscriptionInfo(userId: String, completion: @escaping @Sendable (Bool, OPNParsedSubscriptionInfo, String) -> Void) {
        OPNGameService.shared.fetchSubscriptionInfo(userId: userId) { success, subscription, error in
            completion(success, OPNParsedSubscriptionInfo(subscription: subscription), error)
        }
    }

    @objc(fetchMainPanelObjectsWithCompletion:)
    public static func fetchMainPanelObjects(completion: @escaping @Sendable (Bool, [OPNCatalogPanelObject], String) -> Void) {
        OPNGameService.shared.fetchMainPanels { success, panels, error in
            completion(success, panels.map(OPNCatalogPanelObject.init), error)
        }
    }

    @objc(fetchMarqueePanelObjectsWithCompletion:)
    public static func fetchMarqueePanelObjects(completion: @escaping @Sendable (Bool, [OPNCatalogPanelObject], String) -> Void) {
        OPNGameService.shared.fetchMarqueePanels { success, panels, error in
            completion(success, panels.map(OPNCatalogPanelObject.init), error)
        }
    }

    @objc(browseCatalogObjectWithSearchQuery:sortId:filterIds:fetchCount:completion:)
    public static func browseCatalogObject(searchQuery: String, sortId: String, filterIds: [String], fetchCount: Int, completion: @escaping @Sendable (Bool, OPNCatalogBrowseResultObject, String) -> Void) {
        OPNGameService.shared.browseCatalogGames(searchQuery: searchQuery, sortId: sortId, filterIds: filterIds, fetchCount: fetchCount, forceRefresh: false) { success, result, error in
            completion(success, OPNCatalogBrowseResultObject(result: result), error)
        }
    }

    public static func browseCatalogObject(searchQuery: String, sortId: String, filterIds: [String], fetchCount: Int, forceRefresh: Bool, completion: @escaping @Sendable (Bool, OPNCatalogBrowseResultObject, String) -> Void) {
        OPNGameService.shared.browseCatalogGames(searchQuery: searchQuery, sortId: sortId, filterIds: filterIds, fetchCount: fetchCount, forceRefresh: forceRefresh) { success, result, error in
            completion(success, OPNCatalogBrowseResultObject(result: result), error)
        }
    }

    @objc(fetchLibraryGameObjectsWithCompletion:)
    public static func fetchLibraryGameObjects(completion: @escaping @Sendable (Bool, [OPNCatalogGameObject], String) -> Void) {
        OPNGameService.shared.fetchLibraryGames { success, games, error in
            completion(success, games.map(OPNCatalogGameObject.init), error)
        }
    }

    @objc(fetchFavoriteGameObjectsWithCompletion:)
    public static func fetchFavoriteGameObjects(completion: @escaping @Sendable (Bool, [OPNCatalogGameObject], String) -> Void) {
        OPNGameService.shared.fetchFavoriteGames { success, games, error in
            completion(success, games.map(OPNCatalogGameObject.init), error)
        }
    }

    @objc(fetchUserAccountDictionaryWithCompletion:)
    public static func fetchUserAccountDictionary(completion: @escaping @Sendable (Bool, NSDictionary, String) -> Void) {
        OPNGameService.shared.fetchUserAccount { success, account, error in
            completion(success, userAccountDictionary(account), error)
        }
    }

    @objc(fetchStoreDefinitionDictionariesWithCompletion:)
    public static func fetchStoreDefinitionDictionaries(completion: @escaping @Sendable (Bool, [NSDictionary], String) -> Void) {
        OPNGameService.shared.fetchStoreDefinitions { success, definitions, error in
            completion(success, definitions.map(storeDefinitionDictionary), error)
        }
    }

    public static func fetchAppPatchStatuses(appIds: [String], completion: @escaping @Sendable (Bool, [String: OPNAppPatchStatus], String) -> Void) {
        OPNGameService.shared.fetchAppPatchStatuses(appIds: appIds, completion: completion)
    }

    @objc(addOwnedVariant:completion:)
    public static func addOwnedVariant(_ variantId: String, completion: @escaping @Sendable (Bool, String) -> Void) {
        OPNGameService.shared.addOwnedVariant(variantId, completion: completion)
    }

    @objc(removeOwnedVariant:completion:)
    public static func removeOwnedVariant(_ variantId: String, completion: @escaping @Sendable (Bool, String) -> Void) {
        OPNGameService.shared.removeOwnedVariant(variantId, completion: completion)
    }

    @objc(selectOwnedVariant:completion:)
    public static func selectOwnedVariant(_ variantId: String, completion: @escaping @Sendable (Bool, String) -> Void) {
        OPNGameService.shared.selectOwnedVariant(variantId, completion: completion)
    }

    @objc(addFavoriteApp:completion:)
    public static func addFavoriteApp(_ appId: String, completion: @escaping @Sendable (Bool, String) -> Void) {
        OPNGameService.shared.addFavoriteApp(appId, completion: completion)
    }

    @objc(removeFavoriteApp:completion:)
    public static func removeFavoriteApp(_ appId: String, completion: @escaping @Sendable (Bool, String) -> Void) {
        OPNGameService.shared.removeFavoriteApp(appId, completion: completion)
    }

    @objc(syncAccountProviderWithStore:completion:)
    public static func syncAccountProvider(store: String, completion: @escaping @Sendable (Bool, String) -> Void) {
        OPNGameService.shared.syncAccountProvider(store: store, completion: completion)
    }

    @objc(startAccountLinkingWithStore:completion:)
    public static func startAccountLinking(store: String, completion: @escaping @Sendable (Bool, String) -> Void) {
        OPNGameService.shared.startAccountLinking(store: store, completion: completion)
    }

    @objc(resolveStoreURLWithGameObject:variantIndex:completion:)
    public static func resolveStoreURL(game: OPNCatalogGameObject, variantIndex: Int, completion: @escaping @Sendable (Bool, String, String) -> Void) {
        OPNGameService.shared.resolveStoreURL(game: game.swiftValue, variantIndex: variantIndex, completion: completion)
    }

    @objc(optimizeImageURL:width:)
    public static func optimizeImageURL(_ url: String, width: Int) -> String {
        OPNGameService.optimizeImageURL(url, width: width)
    }

    @objc(parseProviderInfoFromJSON:)
    static func parseProviderInfo(from json: NSDictionary?) -> OPNParsedGameProviderInfo {
        OPNParsedGameProviderInfo(info: OPNGameService.shared.parseGameProviderInfo(json))
    }

    @objc(selectProviderEndpointFromInfo:idpId:)
    static func selectProviderEndpoint(from info: OPNParsedGameProviderInfo, idpId: String) -> OPNParsedGameProviderEndpoint {
        let swiftInfo = info.swiftValue
        return OPNParsedGameProviderEndpoint(endpoint: OPNGameService.shared.selectGameProviderEndpoint(swiftInfo, idpId: idpId))
    }

    private static func userAccountDictionary(_ account: OPNUserAccountInfo) -> NSDictionary {
        [
            "subscriptions": account.subscriptions,
            "stores": account.stores.map(storeAccountDictionary),
        ] as NSDictionary
    }

    private static func storeAccountDictionary(_ account: OPNStoreAccountInfo) -> NSDictionary {
        [
            "store": account.store,
            "userDisplayName": account.userDisplayName,
            "expiresIn": account.expiresIn,
            "userIdentifier": account.userIdentifier,
            "hasAccountLinkingData": account.hasAccountLinkingData,
            "hasAccountSyncingData": account.hasAccountSyncingData,
            "syncing": [
                "totalNumberOfSyncedGfnGames": account.syncing.totalNumberOfSyncedGfnGames,
                "syncState": account.syncing.syncState,
                "syncDate": account.syncing.syncDate,
            ],
        ] as NSDictionary
    }

    private static func storeDefinitionDictionary(_ definition: OPNStoreDefinition) -> NSDictionary {
        [
            "store": definition.store,
            "label": definition.label,
            "smallImageUrl": definition.smallImageUrl,
            "sortOrder": definition.sortOrder,
            "features": definition.features.map { ["type": $0.type, "displayProposition": $0.displayProposition, "supported": $0.supported] as NSDictionary },
            "accountLinkingMetadata": [
                "supportedVariantIds": definition.accountLinkingMetadata.supportedVariantIds,
                "isSupported": definition.accountLinkingMetadata.isSupported,
                "isRequired": definition.accountLinkingMetadata.isRequired,
                "label": definition.accountLinkingMetadata.label,
            ] as NSDictionary,
        ] as NSDictionary
    }

}

@objcMembers
public final class OPNParsedSubscriptionInfo: NSObject {
    public let membershipTier: String
    public let subscriptionType: String
    public let subscriptionSubType: String
    public let isUnlimited: Bool
    public let totalHours: Double
    public let usedHours: Double
    public let remainingHours: Double

    init(subscription: OPNSubscriptionInfo) {
        membershipTier = subscription.membershipTier
        subscriptionType = subscription.subscriptionType
        subscriptionSubType = subscription.subscriptionSubType
        isUnlimited = subscription.isUnlimited
        totalHours = subscription.totalHours
        usedHours = subscription.usedHours
        remainingHours = subscription.remainingHours
    }
}

@objcMembers
final class OPNParsedGameProviderEndpoint: NSObject {
    let loginProvider: String
    let loginProviderCode: String
    let loginProviderDisplayName: String
    let streamingServiceUrl: String
    let idpId: String
    let redeemRedirectUrl: String
    let priority: Int

    init(endpoint: OPNGameProviderEndpoint) {
        loginProvider = endpoint.loginProvider
        loginProviderCode = endpoint.loginProviderCode
        loginProviderDisplayName = endpoint.loginProviderDisplayName
        streamingServiceUrl = endpoint.streamingServiceUrl
        idpId = endpoint.idpId
        redeemRedirectUrl = endpoint.redeemRedirectUrl
        priority = endpoint.priority
    }

    var swiftValue: OPNGameProviderEndpoint {
        var endpoint = OPNGameProviderEndpoint()
        endpoint.loginProvider = loginProvider
        endpoint.loginProviderCode = loginProviderCode
        endpoint.loginProviderDisplayName = loginProviderDisplayName
        endpoint.streamingServiceUrl = streamingServiceUrl
        endpoint.idpId = idpId
        endpoint.redeemRedirectUrl = redeemRedirectUrl
        endpoint.priority = priority
        return endpoint
    }
}

@objcMembers
final class OPNParsedGameProviderInfo: NSObject {
    let defaultProvider: String
    let loggedInProvider: String
    let loginRequired: Bool
    let loginPreferredProviders: [String]
    let endpoints: [OPNParsedGameProviderEndpoint]

    init(info: OPNGameProviderInfo) {
        defaultProvider = info.defaultProvider
        loggedInProvider = info.loggedInProvider
        loginRequired = info.loginRequired
        loginPreferredProviders = info.loginPreferredProviders
        endpoints = info.endpoints.map(OPNParsedGameProviderEndpoint.init(endpoint:))
    }

    var swiftValue: OPNGameProviderInfo {
        var info = OPNGameProviderInfo()
        info.defaultProvider = defaultProvider
        info.loggedInProvider = loggedInProvider
        info.loginRequired = loginRequired
        info.loginPreferredProviders = loginPreferredProviders
        info.endpoints = endpoints.map(\.swiftValue)
        return info
    }
}

private struct CatalogDefinitionParameters: Sendable {
    let requestedSortId: String
    let filterIds: [String]
    let requestedFetchCount: Int
    let searchQuery: String
    let resolvedVpcId: String
    let locale: String
    let catalogCacheKey: String
}

private struct PublicGameListItem: Decodable, Sendable {
    let id: String
    let status: String
    let title: String
    let shortDescription: String
    let summary: String
    let longDescription: String
    let description: String
    let steamUrl: String

    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case title
        case shortDescription
        case summary
        case longDescription
        case description
        case steamUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = Self.stringValue(for: .id, in: container)
        status = Self.stringValue(for: .status, in: container)
        title = Self.stringValue(for: .title, in: container)
        shortDescription = Self.stringValue(for: .shortDescription, in: container)
        summary = Self.stringValue(for: .summary, in: container)
        longDescription = Self.stringValue(for: .longDescription, in: container)
        description = Self.stringValue(for: .description, in: container)
        steamUrl = Self.stringValue(for: .steamUrl, in: container)
    }

    private static func stringValue(for key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>) -> String {
        if let string = try? container.decode(String.self, forKey: key) { return string }
        if let int = try? container.decode(Int.self, forKey: key) { return String(int) }
        if let double = try? container.decode(Double.self, forKey: key), double.isFinite { return String(Int(double)) }
        return ""
    }
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func setTrue() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

private final class CatalogPageState: @unchecked Sendable {
    var collectedApps: [NSDictionary] = []
    var result: OPNCatalogBrowseResult

    init(result: OPNCatalogBrowseResult) {
        self.result = result
    }
}

private final class RecursiveCatalogPageFetcher: @unchecked Sendable {
    var action: (@Sendable (_ page: Int, _ cursor: String) -> Void)?
}

private final class MetadataState: @unchecked Sendable {
    var metadataById: [String: NSDictionary] = [:]
}

private struct RatingCategoryMetadata: Sendable {
    var label = ""
    var largeImageUrl = ""
    var smallImageUrl = ""
}

private struct RatingMetadata: Sendable {
    var ratingsByCategoryKey: [String: RatingCategoryMetadata] = [:]
    var contentDescriptorsByKey: [String: String] = [:]
    var interactiveElementsByKey: [String: String] = [:]

    func apply(to game: inout OPNGameInfo) {
        let normalizedCategory = game.ratingCategoryKey.uppercased().replacingOccurrences(of: "-", with: "_")
        let rating = ratingsByCategoryKey[normalizedCategory] ?? ratingsByCategoryKey.first { $0.value.label.caseInsensitiveCompare(game.ratingCategoryTitle) == .orderedSame }?.value
        if let rating {
            if !rating.label.isEmpty { game.ratingCategoryTitle = rating.label }
            if game.ratingImageUrl.isEmpty { game.ratingImageUrl = rating.largeImageUrl.isEmpty ? rating.smallImageUrl : rating.largeImageUrl }
        }
        game.ratingDescriptors = game.ratingDescriptors.map { contentDescriptorsByKey[$0.uppercased().replacingOccurrences(of: " ", with: "_")] ?? $0 }
        game.ratingInteractiveElements = game.ratingInteractiveElements.map { interactiveElementsByKey[$0.uppercased().replacingOccurrences(of: " ", with: "_")] ?? $0 }
        var contentRatings: [String] = []
        if !game.ratingCategoryTitle.isEmpty { contentRatings.append(game.ratingCategoryTitle) }
        if !game.ratingSystemName.isEmpty { contentRatings.append(game.ratingSystemName) }
        contentRatings.append(contentsOf: game.ratingDescriptors)
        contentRatings.append(contentsOf: game.ratingInteractiveElements)
        if !contentRatings.isEmpty { game.contentRatings = contentRatings }
    }
}

private final class NSDictionaryBox: @unchecked Sendable {
    let value: NSDictionary

    init(_ value: NSDictionary) {
        self.value = value
    }
}

private final class NSDictionaryArrayBox: @unchecked Sendable {
    let values: [NSDictionary]

    init(_ values: [NSDictionary]) {
        self.values = values
    }
}

private final class AccountLinkingCallbackListener: @unchecked Sendable {
    let port: Int32
    private let socketDescriptor: Int32
    private let service = OPNGameService.shared

    init?() {
        let candidatePorts: [Int32] = [2259, 6460, 7119, 8870, 9096]
        for candidate in candidatePorts {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            if descriptor < 0 { continue }
            var reuse: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
            address.sin_port = in_port_t(candidate).bigEndian
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindResult == 0, listen(descriptor, 1) == 0 {
                socketDescriptor = descriptor
                port = candidate
                return
            }
            Darwin.close(descriptor)
        }
        return nil
    }

    func close() {
        Darwin.close(socketDescriptor)
    }

    func wait(timeout: TimeInterval, completion: @escaping OPNOwnershipActionCallback) {
        let descriptor = socketDescriptor
        DispatchQueue.global(qos: .default).async { [self, service] in
            var readSet = fd_set()
            self.fdZero(&readSet)
            self.fdSet(descriptor, set: &readSet)
            var time = timeval(tv_sec: Int(timeout), tv_usec: 0)
            let ready = select(descriptor + 1, &readSet, nil, nil, &time)
            if ready <= 0 {
                Darwin.close(descriptor)
                service.dispatchOwnership(completion, false, ready == 0 ? "Timed out waiting for account linking callback" : "Account linking callback listener failed")
                return
            }
            let client = accept(descriptor, nil, nil)
            Darwin.close(descriptor)
            if client < 0 {
                service.dispatchOwnership(completion, false, "Failed to accept account linking callback")
                return
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = recv(client, &buffer, buffer.count - 1, 0)
            let request = bytesRead > 0 ? String(bytes: buffer.prefix(bytesRead), encoding: .utf8) ?? "" : ""
            let hasError = request.contains("error=") || request.contains("error_description=")
            self.sendCallbackPage(client: client, success: !hasError)
            Darwin.close(client)
            if bytesRead <= 0 {
                service.dispatchOwnership(completion, false, "Empty account linking callback request")
            } else if hasError {
                service.dispatchOwnership(completion, false, "Account linking was not completed")
            } else {
                service.dispatchOwnership(completion, true, "")
            }
        }
    }

    private func sendCallbackPage(client: Int32, success: Bool) {
        let successBody = "<!doctype html><html><head><meta charset=\"utf-8\"><title>OpenNOW Account Linking</title></head><body style=\"background:#050807;color:#f1fff7;font:16px -apple-system,BlinkMacSystemFont,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0\"><main><h1>Account link complete</h1><p>You can close this window and return to OpenNOW.</p></main><script>setTimeout(function(){window.close()},1200)</script></body></html>"
        let errorBody = "<!doctype html><html><head><meta charset=\"utf-8\"><title>OpenNOW Account Linking</title></head><body style=\"background:#140606;color:#fff0f0;font:16px -apple-system,BlinkMacSystemFont,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0\"><main><h1>Account link failed</h1><p>Return to OpenNOW to try again.</p></main></body></html>"
        let body = success ? successBody : errorBody
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        _ = response.withCString { send(client, $0, strlen($0), 0) }
    }

    private func fdZero(_ set: inout fd_set) {
        memset(&set, 0, MemoryLayout<fd_set>.size)
    }

    private func fdSet(_ descriptor: Int32, set: inout fd_set) {
        let intOffset = Int(descriptor) / 32
        let bitOffset = Int(descriptor) % 32
        withUnsafeMutablePointer(to: &set) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: MemoryLayout<fd_set>.size / MemoryLayout<Int32>.size) { values in
                values[intOffset] |= 1 << Int32(bitOffset)
            }
        }
    }
}

private extension Array where Element: Hashable {
    func uniqueValues() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension OPNGameService {
    static var catalogQuery: String {
        """
        query GetFilterBrowseResults($vpcId: String!, $locale: String!, $sortString: String!, $fetchCount: Int!, $cursor: String!, $filters: AppFilterFields!) {
            apps(vpcId: $vpcId, language: $locale, orderBy: $sortString, first: $fetchCount, after: $cursor, filters: $filters) {
                numberReturned numberSupported pageInfo { hasNextPage endCursor totalCount }
                items { id title shortDescription longDescription images { KEY_ART KEY_IMAGE GAME_BOX_ART TV_BANNER HERO_IMAGE MARQUEE_HERO_IMAGE FEATURE_IMAGE GAME_LOGO SCREENSHOTS } variants { id appStore storeUrl supportedControls gfn { status stateDetails { ... on VariantGfnAutoPatchingMetadata { subType startTime endTime historicalEtaMins etaPredictionType } ... on VariantGfnManualPatchingMetadata { subType startTime endTime } ... on VariantGfnMaintenanceMetadata { subType } } library { status selected } } } gfn { playabilityState minimumMembershipTierLabel catalogSkuStrings { SKU_BASED_TAG } } itemMetadata { campaignIds } }
            }
        }
        """
    }

    static var catalogSearchQuery: String {
        """
        query GetSearchFilterResults($vpcId: String!, $locale: String!, $sortString: String!, $fetchCount: Int!, $cursor: String!, $searchString: String!, $filters: AppFilterFields!) {
            apps(vpcId: $vpcId, language: $locale, orderBy: $sortString, first: $fetchCount, after: $cursor, searchQuery: $searchString, filters: $filters) {
                numberReturned numberSupported pageInfo { hasNextPage endCursor totalCount }
                items { id title shortDescription longDescription images { KEY_ART KEY_IMAGE GAME_BOX_ART TV_BANNER HERO_IMAGE MARQUEE_HERO_IMAGE FEATURE_IMAGE GAME_LOGO SCREENSHOTS } variants { id appStore storeUrl supportedControls gfn { status stateDetails { ... on VariantGfnAutoPatchingMetadata { subType startTime endTime historicalEtaMins etaPredictionType } ... on VariantGfnManualPatchingMetadata { subType startTime endTime } ... on VariantGfnMaintenanceMetadata { subType } } library { status selected } } } gfn { playabilityState minimumMembershipTierLabel catalogSkuStrings { SKU_BASED_TAG } } itemMetadata { campaignIds } }
            }
        }
        """
    }
}
