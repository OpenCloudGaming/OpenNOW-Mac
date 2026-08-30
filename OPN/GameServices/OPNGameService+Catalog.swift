//
//  OpenNOW
//

import AppKit
import Foundation

extension OPNGameService {
    func fetchCatalogGames(completion: @escaping OPNCatalogCallback) {
        browseCatalogGames(searchQuery: "", sortId: Self.defaultBrowseSortId, filterIds: [], fetchCount: 200, forceRefresh: false) { success, result, error in
            completion(success, result.games, error)
        }
    }

    func browseCatalogGames(searchQuery: String, sortId: String, filterIds: [String], fetchCount: Int, forceRefresh: Bool = false, cursor: String = "", completion: @escaping OPNCatalogBrowseCallback) {
        let token = accessToken
        let accountIdentifier = userId
        let providerBaseUrl = providerStreamingBaseURL()
        let locale = Self.currentGFNCatalogLocale()
        resolveCatalogVpcId(token: token, providerStreamingBaseUrl: providerBaseUrl) { [weak self] resolvedVpcId in
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
                cursor: cursor,
                completion: completion
            )
        }
    }

    func continueBrowseCatalogGames(
        accountIdentifier: String,
        providerBaseUrl: String,
        locale: String,
        resolvedVpcId: String,
        searchQuery: String,
        sortId: String,
        filterIds: [String],
        fetchCount: Int,
        forceRefresh: Bool,
        cursor: String,
        completion: @escaping OPNCatalogBrowseCallback
    ) {
        let requestedSortId = sortId.isEmpty ? Self.defaultSortId(searchQuery: searchQuery) : sortId
        let requestedFetchCount = max(24, min(fetchCount > 0 ? fetchCount : Self.defaultCatalogFetchCount, 200))
        let catalogCacheKey = self.dataCache.catalogKey(
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
            catalogCacheKey: catalogCacheKey,
            cursor: cursor
        )

        if forceRefresh || !cursor.isEmpty {
            continueBrowseAfterFreshCacheMiss(parameters: parameters, allowCachedCatalog: false, completion: completion)
            return
        }

        self.dataCache.loadFreshCatalogAndDefinitions(
            key: catalogCacheKey,
            locale: locale,
            catalogMaxAgeSeconds: Self.catalogCacheFreshSeconds,
            definitionsMaxAgeSeconds: Self.catalogDefinitionsFreshSeconds
        ) { [weak self] freshCatalog, freshDefinitions in
            guard let self else { return }
            if var fresh = freshCatalog, let definitions = freshDefinitions, self.hasValidFilterGroups(definitions) {
                _ = self.parseCatalogDefinitions(definitions, result: &fresh)
                self.dispatchCatalogBrowse(completion, true, fresh, "")
                return
            }

            self.continueBrowseAfterFreshCacheMiss(parameters: parameters, allowCachedCatalog: true, completion: completion)
        }
    }

    func continueBrowseAfterFreshCacheMiss(parameters: CatalogDefinitionParameters, allowCachedCatalog: Bool, completion: @escaping OPNCatalogBrowseCallback) {
        let deliveredCachedResult = AtomicFlag()
        let loadDefinitions: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.dataCache.loadCatalogDefinitionsAsync(locale: parameters.locale, maxAgeSeconds: Self.catalogDefinitionsFreshSeconds) { [weak self] cachedDefinitions in
                guard let self else { return }
                if let cachedDefinitions, self.hasValidFilterGroups(cachedDefinitions) {
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
                    if error.isEmpty, let data { self.dataCache.saveCatalogDefinitionsAsync(locale: parameters.locale, definitions: data) }
                    self.handleCatalogDefinitions(data, error, parameters: parameters, deliveredCachedResult: deliveredCachedResult, completion: completion)
                }
            }
        }
        guard allowCachedCatalog else {
            loadDefinitions()
            return
        }
        self.dataCache.loadCatalogAsync(key: parameters.catalogCacheKey) { [weak self] cached in
            guard let self else { return }
            if let cached {
                deliveredCachedResult.setTrue()
                self.dispatchCatalogBrowse(completion, true, cached, "")
            }
            loadDefinitions()
        }
    }

    func handleCatalogDefinitions(
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
                maxPages: Self.maxCatalogPages,
                callerDrivenPaging: true,
                startCursor: parameters.cursor,
                completion: completion
            )
        }
    }

    static func defaultSortId(searchQuery: String) -> String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultBrowseSortId : defaultSearchSortId
    }

    static func defaultSortOption(searchQuery: String) -> OPNCatalogSortOption {
        if defaultSortId(searchQuery: searchQuery) == defaultSearchSortId {
            return OPNCatalogSortOption(id: defaultSearchSortId, label: "Relevance", orderBy: "itemMetadata.relevance:DESC,sortName:ASC")
        }
        return OPNCatalogSortOption(id: defaultBrowseSortId, label: "A-Z", orderBy: "sortName:ASC")
    }

    func fetchAppMetadata(appIds: [String], vpcId: String, completion: @escaping @Sendable (NSDictionary?, String) -> Void) {
        let variables: NSDictionary = ["vpcId": vpcId.isEmpty ? "GFN-PC" : vpcId, "locale": Self.currentGFNCatalogLocale(), "appIds": appIds]
        postGraphQL(operationName: "appMetaData", queryHash: Self.appMetaDataHash, variables: variables, completion: completion)
    }

    // Campaign tags and rating definitions are per (vpcId, locale) reference data that
    // every enrichment pass needs, so an uncoalesced launch fetches each of them once
    // per panel and per browse page (measured four times each). Memoized with in-flight
    // coalescing so concurrent enrichments share one request.
    func fetchCampaignPromoTags(vpcId: String, locale: String, completion: @escaping @Sendable ([String: String]) -> Void) {
        let key = "\(vpcId)|\(locale)"
        Self.referenceDataLock.lock()
        if let entry = Self.campaignPromoTagCache[key], Date().timeIntervalSince(entry.timestamp) <= Self.referenceDataFreshSeconds {
            Self.referenceDataLock.unlock()
            completion(entry.value)
            return
        }
        if Self.pendingCampaignPromoTagCallbacks[key] != nil {
            Self.pendingCampaignPromoTagCallbacks[key]?.append(completion)
            Self.referenceDataLock.unlock()
            return
        }
        Self.pendingCampaignPromoTagCallbacks[key] = [completion]
        Self.referenceDataLock.unlock()

        fetchCampaignPromoTagsUncached(vpcId: vpcId, locale: locale) { tagsByCampaignId in
            Self.referenceDataLock.lock()
            Self.campaignPromoTagCache[key] = ReferenceDataEntry(value: tagsByCampaignId, timestamp: Date())
            let callbacks = Self.pendingCampaignPromoTagCallbacks.removeValue(forKey: key) ?? []
            Self.referenceDataLock.unlock()
            for callback in callbacks { callback(tagsByCampaignId) }
        }
    }

    func fetchCampaignPromoTagsUncached(vpcId: String, locale: String, completion: @escaping @Sendable ([String: String]) -> Void) {
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

    func fetchCatalogPages(baseResult: OPNCatalogBrowseResult, query: String, vpcId: String, locale: String, sortString: String, fetchCount: Int, searchString: String, filters: NSDictionary, catalogCacheKey: String, deliveredCachedResult: AtomicFlag, maxPages: Int, callerDrivenPaging: Bool = false, startCursor: String = "", completion: @escaping OPNCatalogBrowseCallback) {
        let state = CatalogPageState(result: baseResult)
        let filterBox = NSDictionaryBox(filters)
        let fetchPage = RecursiveCatalogPageFetcher()
        let deliveredFirstPage = AtomicFlag()
        fetchPage.action = { [weak self, state, fetchPage] page, cursor in
            guard let self else { return }
            var variables: [String: Any] = ["vpcId": vpcId, "locale": locale, "sortString": sortString, "fetchCount": fetchCount, "cursor": cursor, "filters": filterBox.value]
            if !searchString.isEmpty { variables["searchString"] = searchString }
            postGraphQlJson(query: query, variables: variables as NSDictionary) { [weak self] data, error in
                guard let self else { return }
                let dataBox = data.map(NSDictionaryBox.init)
                Self.workQueue.async { [dataBox] in
                    if !error.isEmpty {
                        if !deliveredCachedResult.value || deliveredFirstPage.value { self.dispatchCatalogBrowse(completion, false, OPNCatalogBrowseResult(), error) }
                        return
                    }
                    guard let apps = dataBox?.value["apps"] as? NSDictionary else {
                        if !deliveredCachedResult.value || deliveredFirstPage.value { self.dispatchCatalogBrowse(completion, false, OPNCatalogBrowseResult(), "No apps data") }
                        return
                    }
                    let pageItems = apps["items"] as? [NSDictionary] ?? []
                    let pageInfo = apps["pageInfo"] as? NSDictionary
                    let hasNextPage = self.safeBool(pageInfo?["hasNextPage"])
                    let endCursor = self.safeString(pageInfo?["endCursor"]) ?? ""
                    state.applyPage(items: pageItems) { result in
                        result.numberReturned += self.safeInt(apps["numberReturned"])
                        result.numberSupported = self.safeInt(apps["numberSupported"])
                        result.totalCount = self.safeInt(pageInfo?["totalCount"])
                        result.hasNextPage = hasNextPage
                        if !endCursor.isEmpty { result.endCursor = endCursor }
                    }

                    let pageGames = pageItems.map { self.parseGameItem($0) }.filter { !$0.id.isEmpty && !$0.title.isEmpty && !$0.variants.isEmpty }
                    self.enrichGames(pageGames, vpcId: vpcId) { enriched in
                        state.applyEnrichedGames(enriched)

                        let isCatalogFirstPage = page == 0 && startCursor.isEmpty
                        let isFinalPage = !hasNextPage || endCursor.isEmpty || page + 1 >= maxPages
                        let shouldDeliver = callerDrivenPaging || isFinalPage
                        // The filter groups and sort orders are parsed into `baseResult` on this
                        // path and on no other; the earlier cached-catalog delivery carries games
                        // only. Skipping this delivery purely to avoid repainting identical games
                        // therefore threw those definitions away, so any browse served from cache -
                        // in practice every search with an empty query - showed an empty filter bar
                        // and a placeholder sort label.
                        let carriesDefinitions = !baseResult.filterGroups.isEmpty || !baseResult.sortOptions.isEmpty
                        let isRedundantRepaint = callerDrivenPaging && isCatalogFirstPage && deliveredCachedResult.value && !carriesDefinitions
                        if shouldDeliver, !isRedundantRepaint {
                            let snapshot = state.snapshot()
                            if isCatalogFirstPage {
                                deliveredFirstPage.setTrue()
                            }
                            if startCursor.isEmpty, isCatalogFirstPage || isFinalPage {
                                self.dataCache.saveCatalogAsync(key: catalogCacheKey, result: snapshot)
                            }
                            self.dispatchCatalogBrowse(completion, true, snapshot, "")
                        }

                        if !isFinalPage, !callerDrivenPaging {
                            fetchPage.action?(page + 1, endCursor)
                        }
                    }
                }
            }
        }
        fetchPage.action?(0, startCursor)
    }

    func parseCatalogDefinitions(_ definitionsData: NSDictionary?, result: inout OPNCatalogBrowseResult) -> [String: [String: Any]] {
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
        applyCollectionsFilterFallback(result: &result, filterPayloadById: &filterPayloadById)
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

    /// Guarantees the My Library / My Favorites filters exist. They are normally part of the
    /// server's `collections` group; when a definitions response omits them we splice the known
    /// payloads in so the Show All page can still scope to a collection.
    func applyCollectionsFilterFallback(result: inout OPNCatalogBrowseResult, filterPayloadById: inout [String: [String: Any]]) {
        let fallbacks: [(id: String, label: String, payload: [String: Any])] = [
            (Self.favoritesCatalogFilterId, "My Favorites", Self.favoritesCatalogFilterPayload),
            (Self.libraryCatalogFilterId, "My Library", Self.libraryCatalogFilterPayload),
        ]
        let missing = fallbacks.filter { filterPayloadById[$0.id] == nil }
        guard !missing.isEmpty else { return }

        var groupIndex = result.filterGroups.firstIndex { $0.id == Self.collectionsFilterGroupId }
        if groupIndex == nil {
            var group = OPNCatalogFilterGroup()
            group.id = Self.collectionsFilterGroupId
            group.label = "Collections"
            result.filterGroups.insert(group, at: 0)
            groupIndex = 0
        }
        guard let index = groupIndex else { return }

        for fallback in missing {
            filterPayloadById[fallback.id] = fallback.payload
            result.filterGroups[index].options.append(
                OPNCatalogFilterOption(
                    id: fallback.id,
                    rawId: fallback.id,
                    label: fallback.label,
                    groupId: Self.collectionsFilterGroupId,
                    groupLabel: result.filterGroups[index].label
                )
            )
        }
    }

    func hasValidFilterGroups(_ definitions: NSDictionary?) -> Bool {
        guard let definitions else { return false }
        let groups = definitions["filterGroupDefinitions"] as? [NSDictionary] ?? []
        return !groups.isEmpty
    }

    func deduplicateGames(_ games: [OPNGameInfo]) -> [OPNGameInfo] {
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
}

struct CatalogDefinitionParameters: Sendable {
    let requestedSortId: String
    let filterIds: [String]
    let requestedFetchCount: Int
    let searchQuery: String
    let resolvedVpcId: String
    let locale: String
    let catalogCacheKey: String
    var cursor: String = ""
}

final class AtomicFlag: @unchecked Sendable {
    let lock = NSLock()
    var storage = false

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
    let lock = NSLock()
    var collectedApps: [NSDictionary] = []
    var enrichedGames: [OPNGameInfo] = []
    var result: OPNCatalogBrowseResult

    init(result: OPNCatalogBrowseResult) {
        self.result = result
    }

    func applyPage(items: [NSDictionary], update: (inout OPNCatalogBrowseResult) -> Void) {
        lock.withLock {
            collectedApps.append(contentsOf: items)
            update(&result)
        }
    }

    func applyEnrichedGames(_ games: [OPNGameInfo]) {
        lock.withLock {
            enrichedGames.append(contentsOf: games)
            result.numberSupported = max(result.numberSupported, enrichedGames.count)
            result.totalCount = max(result.totalCount, enrichedGames.count)
        }
    }

    func snapshot() -> OPNCatalogBrowseResult {
        lock.withLock {
            var snapshot = result
            snapshot.games = enrichedGames
            return snapshot
        }
    }
}


extension OPNGameService {
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
