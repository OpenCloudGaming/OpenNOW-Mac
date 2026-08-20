//
//  MacForceNow
//

import AppKit
import Foundation

extension OPNGameService {
    func fetchLibraryGames(completion: @escaping OPNCatalogCallback) {
        let accountIdentifier = userId
        let providerBaseUrl = providerStreamingBaseURL()
        let locale = Self.currentGFNCatalogLocale()
        getServerVpcId(token: accessToken, providerStreamingBaseUrl: providerBaseUrl) { [weak self] resolvedVpcId in
            guard let self else { return }
            self.fetchDefaultLibrarySort(locale: locale) { [weak self] selectedSort in
                guard let self else { return }
                var result = OPNCatalogBrowseResult()
                result.selectedSortId = selectedSort.id
                result.sortOptions = [selectedSort]
                result.selectedFilterIds = [Self.libraryCatalogFilterId]
                let catalogCacheKey = self.dataCache.catalogKey(
                    accountIdentifier: accountIdentifier,
                    searchQuery: "",
                    sortId: selectedSort.id,
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
                    sortString: selectedSort.orderBy,
                    fetchCount: 200,
                    searchString: "",
                    filters: Self.libraryCatalogFilter,
                    catalogCacheKey: catalogCacheKey,
                    deliveredCachedResult: AtomicFlag(),
                    maxPages: Self.maxCatalogPages
                ) { [weak self] success, browseResult, error in
                    self?.dispatchCatalog(completion, success, browseResult.games, error)
                }
            }
        }
    }

    func fetchDefaultLibrarySort(locale: String, completion: @escaping @Sendable (OPNCatalogSortOption) -> Void) {
        let fallback = Self.defaultSortOption(searchQuery: "")
        self.dataCache.loadCatalogDefinitionsAsync(locale: locale, maxAgeSeconds: Self.catalogDefinitionsFreshSeconds) { [weak self] cachedDefinitions in
            guard let self else { return }
            if let cachedDefinitions {
                completion(self.defaultLibrarySort(from: cachedDefinitions, fallback: fallback))
                return
            }

            let query = """
            query GetFilterGroupAndSortOrderDefinitions($locale: String!) {
                filterGroupDefinitions(language: $locale) { id label filters { id label filters } }
                sortOrderDefinitions(language: $locale) { id label orderBy }
            }
            """
            self.postGraphQlJson(query: query, variables: ["locale": locale] as NSDictionary) { [weak self] data, error in
                guard let self else { return }
                if error.isEmpty, let data {
                    self.dataCache.saveCatalogDefinitionsAsync(locale: locale, definitions: data)
                    completion(self.defaultLibrarySort(from: data, fallback: fallback))
                } else {
                    completion(fallback)
                }
            }
        }
    }

    func defaultLibrarySort(from definitionsData: NSDictionary, fallback: OPNCatalogSortOption) -> OPNCatalogSortOption {
        var result = OPNCatalogBrowseResult()
        _ = parseCatalogDefinitions(definitionsData, result: &result)
        return result.sortOptions.first { $0.id == Self.defaultBrowseSortId } ?? fallback
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
                let games = self.parsePanelResults(panels).flatMap { $0.sections }.flatMap { $0.games }.map { game in
                    var favoritedGame = game
                    favoritedGame.isFavorited = true
                    return favoritedGame
                }
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

    func resolveLaunchAppId(game: OPNGameInfo, variantIndex: Int, completion: @escaping OPNLaunchAppIdCallback) {
        if let appId = launchableAppId(for: game, variantIndex: variantIndex) {
            Task { @MainActor in completion(appId) }
            return
        }
        let metadataAppId = game.uuid.isEmpty ? game.id : game.uuid
        guard !metadataAppId.isEmpty, !accessToken.isEmpty else {
            Task { @MainActor in completion("") }
            return
        }
        let selectedVariant = game.variants.indices.contains(variantIndex) ? game.variants[variantIndex] : nil
        getServerVpcId(token: accessToken, providerStreamingBaseUrl: providerStreamingBaseURL()) { [weak self] resolvedVpcId in
            guard let self else { return }
            self.fetchAppMetadata(appIds: [metadataAppId], vpcId: resolvedVpcId.isEmpty ? "GFN-PC" : resolvedVpcId) { data, error in
                let resolvedAppId: String
                if error.isEmpty, let items = (data?["apps"] as? NSDictionary)?["items"] as? [NSDictionary] {
                    let metadataApp = items.first { self.safeString($0["id"]) == metadataAppId } ?? items.first
                    let metadataGame = self.parseGameItem(metadataApp)
                    resolvedAppId = self.launchableAppId(for: metadataGame, preferredStore: selectedVariant?.appStore ?? "") ?? ""
                } else {
                    resolvedAppId = ""
                }
                Task { @MainActor in completion(resolvedAppId) }
            }
        }
    }

    func fetchGameByCMSId(_ cmsId: String, completion: @escaping OPNCatalogCallback) {
        guard let cmsValue = Int(cmsId.trimmingCharacters(in: .whitespacesAndNewlines)), cmsValue > 0 else {
            dispatchCatalog(completion, false, [], "Invalid CMS ID")
            return
        }
        getServerVpcId(token: accessToken, providerStreamingBaseUrl: providerStreamingBaseURL()) { [weak self] resolvedVpcId in
            guard let self else { return }
            let query = """
            query GetAppDataQueryForCmsId($vpcId: String!, $locale: String!, $cmsIds: [Int]!) {
              apps(vpcId: $vpcId, language: $locale, variantIds: $cmsIds) {
                items {
                  appStore contentRatings { categoryKey contentDescriptorKeys interactiveElementKeys type } developerName displaysOwnRatingDuringGameplay id genres library { favorited }
                  images { GAME_BOX_ART GAME_LOGO HERO_IMAGE SCREENSHOTS TV_BANNER KEY_ART }
                  nvidiaTech { PHOTO_MODE FREESTYLE HIGHLIGHTS }
                  title shortDescription longDescription maxLocalPlayers maxOnlinePlayers supportedControls publisherName sortName itemMetadata { campaignIds }
                  variants { streetDate appStore id shortName supportedControls storeUrl publisherName developerName subscriptions paymentModels { __typename } minimumSizeInBytes cloudSaveSupported gfn { installTimeInMinutes status features { ...feature } supportedLanguages { language ... on GfnLanguageSettings { availableFeatures setMethod } } library { installed status selected playStatus subscription } stateDetails { ... on VariantGfnAutoPatchingMetadata { subType startTime endTime historicalEtaMins etaPredictionType } ... on VariantGfnManualPatchingMetadata { subType startTime endTime } ... on VariantGfnMaintenanceMetadata { subType } } } }
                  gfn { playabilityState minimumMembershipTierLabel catalogSkuStrings { SKU_BASED_TAG SKU_BASED_PLAYABILITY_TEXT SKU_BASED_UNPLAYABLE_DIALOG_HEADER SKU_BASED_UNPLAYABLE_DIALOG_BODY_UPGRADE SKU_BASED_UNPLAYABLE_DIALOG_BODY_UPGRADE_ECOMM_RESTRICTED } playType }
                }
              }
            }
            fragment feature on GfnSubscriptionFeature { __typename ... on GfnSubscriptionFeatureValue { key value } ... on GfnSubscriptionFeatureValueList { key values } }
            """
            let variables: NSDictionary = ["vpcId": resolvedVpcId.isEmpty ? "GFN-PC" : resolvedVpcId, "locale": Self.currentGFNCatalogLocale(), "cmsIds": [cmsValue]]
            self.postGraphQlJson(query: query, variables: variables) { [weak self] data, error in
                guard let self else { return }
                guard error.isEmpty else {
                    self.dispatchCatalog(completion, false, [], error)
                    return
                }
                let items = (data?["apps"] as? NSDictionary)?["items"] as? [NSDictionary] ?? []
                let games = items.map { self.parseGameItem($0) }.filter { !$0.id.isEmpty && !$0.title.isEmpty && !$0.variants.isEmpty }
                self.enrichRatingMetadata(games, locale: Self.currentGFNCatalogLocale()) { enriched in
                    self.dispatchCatalog(completion, true, enriched, "")
                }
            }
        }
    }

    func launchableAppId(for game: OPNGameInfo, variantIndex: Int) -> String? {
        if game.variants.indices.contains(variantIndex), let appId = validLaunchAppId(game.variants[variantIndex].id) { return appId }
        if let appId = validLaunchAppId(game.launchAppId) { return appId }
        if let appId = validLaunchAppId(game.id) { return appId }
        return game.variants.compactMap { validLaunchAppId($0.id) }.first
    }

    func launchableAppId(for game: OPNGameInfo, preferredStore: String) -> String? {
        if !preferredStore.isEmpty, let appId = game.variants.first(where: { $0.appStore.caseInsensitiveCompare(preferredStore) == .orderedSame }).flatMap({ validLaunchAppId($0.id) }) { return appId }
        if let appId = validLaunchAppId(game.launchAppId) { return appId }
        if let appId = validLaunchAppId(game.id) { return appId }
        return game.variants.compactMap { validLaunchAppId($0.id) }.first
    }

    func validLaunchAppId(_ value: String) -> String? {
        OPNLaunchAppId.resolve(value)?.stringValue
    }

    func storeURLForMetadataGame(_ metadataGame: OPNGameInfo, variantId: String, store: String) -> String {
        if !variantId.isEmpty, let url = metadataGame.variants.first(where: { $0.id == variantId && !$0.storeUrl.isEmpty })?.storeUrl { return url }
        if !store.isEmpty, let url = metadataGame.variants.first(where: { $0.appStore.caseInsensitiveCompare(store) == .orderedSame && !$0.storeUrl.isEmpty })?.storeUrl { return url }
        return metadataGame.variants.first { !$0.storeUrl.isEmpty }?.storeUrl ?? ""
    }

    func fetchPublicGamesLocale(locales: [String], index: Int, completion: @escaping OPNCatalogCallback) {
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
        OPNSessionProxySessionProvider.shared.controlPlaneURLSession().dataTask(with: tracedRequest) { [weak self] data, response, error in
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

    enum CodingKeys: String, CodingKey {
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

    static func stringValue(for key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>) -> String {
        if let string = try? container.decode(String.self, forKey: key) { return string }
        if let int = try? container.decode(Int.self, forKey: key) { return String(int) }
        if let double = try? container.decode(Double.self, forKey: key), double.isFinite { return String(Int(double)) }
        return ""
    }
}
