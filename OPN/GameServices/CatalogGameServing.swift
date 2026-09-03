import Foundation

protocol CatalogGameServing {
    func configureCatalogSession(accessToken: String, idToken: String, userId: String)

    func browseCatalogObject(searchQuery: String, sortId: String, filterIds: [String], fetchCount: Int, completion: @escaping @MainActor @Sendable (Bool, OPNCatalogBrowseResultObject, String) -> Void)
    func browseCatalogObject(searchQuery: String, sortId: String, filterIds: [String], fetchCount: Int, forceRefresh: Bool, completion: @escaping @MainActor @Sendable (Bool, OPNCatalogBrowseResultObject, String) -> Void)
    func browseCatalogObject(searchQuery: String, sortId: String, filterIds: [String], fetchCount: Int, forceRefresh: Bool, cursor: String, completion: @escaping @MainActor @Sendable (Bool, OPNCatalogBrowseResultObject, String) -> Void)
    func fetchMarqueePanelObjects(completion: @escaping @MainActor @Sendable (Bool, [OPNCatalogPanelObject], String) -> Void)
    func fetchMainPanelObjects(completion: @escaping @MainActor @Sendable (Bool, [OPNCatalogPanelObject], String) -> Void)
    func fetchLibraryGameObjects(completion: @escaping @MainActor @Sendable (Bool, [OPNCatalogGameObject], String) -> Void)
    func fetchFavoriteGameObjects(completion: @escaping @MainActor @Sendable (Bool, [OPNCatalogGameObject], String) -> Void)
    func fetchGameObjectByCMSId(_ cmsId: String, completion: @escaping @MainActor @Sendable (Bool, OPNCatalogGameObject?, String) -> Void)

    func fetchUserAccount(completion: @escaping OPNUserAccountCallback)
    func fetchStoreDefinitions(completion: @escaping OPNStoreDefinitionsCallback)
    func fetchSubscriptionDefinitions(completion: @escaping OPNSubscriptionDefinitionsCallback)
    func fetchSubscriptionInfo(userId: String, completion: @escaping OPNSubscriptionCallback)

    func fetchAppPatchStatuses(appIds: [String], completion: @escaping OPNAppPatchStatusesCallback)
    func fetchLibraryPatchStatuses(completion: @escaping OPNAppPatchStatusesCallback)

    func addOwnedVariant(_ variantId: String, completion: @escaping OPNOwnershipActionCallback)
    func removeOwnedVariant(_ variantId: String, completion: @escaping OPNOwnershipActionCallback)
    func selectOwnedVariant(_ variantId: String, completion: @escaping OPNOwnershipActionCallback)
    func addFavoriteApp(_ appId: String, completion: @escaping OPNFavoriteActionCallback)
    func removeFavoriteApp(_ appId: String, completion: @escaping OPNFavoriteActionCallback)
    func syncAccountProvider(store: String, completion: @escaping OPNOwnershipActionCallback)
    func startAccountLinking(store: String, completion: @escaping OPNOwnershipActionCallback)

    func resolveStoreURL(game: OPNGameInfo, variantIndex: Int, completion: @escaping OPNStoreURLCallback)
    func fetchProviderInfo(idpId: String, completion: @escaping OPNProviderInfoCallback)
    func providerStreamingBaseURL() -> String
}

protocol GameProviderInfoServing {
    func fetchProviderInfo(idpId: String, completion: @escaping OPNProviderInfoCallback)
}

extension OPNGameService: CatalogGameServing {}
extension OPNGameService: GameProviderInfoServing {}
