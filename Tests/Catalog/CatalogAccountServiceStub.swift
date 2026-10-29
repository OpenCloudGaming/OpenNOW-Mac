import Foundation
@testable import OpenNOW

final class CatalogAccountServiceStub: CatalogGameServing, @unchecked Sendable {
    struct SessionCredentials: Equatable, Sendable {
        let accessToken: String
        let idToken: String
        let userID: String
    }

    private let lock = NSLock()
    private var subscriptions: [OPNSubscriptionCallback] = []
    private var sessionCredentials: SessionCredentials?
    private var subscriptionUsers: [String] = []

    var subscriptionRequestCount: Int { lock.withLock { subscriptions.count } }
    var configuredCredentials: SessionCredentials? { lock.withLock { sessionCredentials } }
    var subscriptionUserIDs: [String] { lock.withLock { subscriptionUsers } }

    @MainActor
    func completeSubscription(at index: Int, subscription: OPNSubscriptionInfo, isSuccessful: Bool = true) {
        let completion = lock.withLock { subscriptions[index] }
        completion(isSuccessful, subscription, isSuccessful ? "" : "Membership unavailable")
    }

    func configureCatalogSession(accessToken: String, idToken: String, userId: String) {
        lock.withLock {
            sessionCredentials = SessionCredentials(accessToken: accessToken, idToken: idToken, userID: userId)
        }
    }

    func fetchSubscriptionInfo(userId: String, completion: @escaping OPNSubscriptionCallback) {
        lock.withLock {
            subscriptions.append(completion)
            subscriptionUsers.append(userId)
        }
    }

    func fetchUserAccount(completion: @escaping OPNUserAccountCallback) {
        Task { @MainActor in completion(true, OPNUserAccountInfo(), "") }
    }

    func browseCatalogObject(searchQuery: String, sortId: String, filterIds: [String], fetchCount: Int, completion: @escaping @MainActor @Sendable (Bool, OPNCatalogBrowseResultObject, String) -> Void) {
        Task { @MainActor in completion(false, OPNCatalogBrowseResultObject(), "Unused browse") }
    }

    func browseCatalogObject(searchQuery: String, sortId: String, filterIds: [String], fetchCount: Int, forceRefresh: Bool, completion: @escaping @MainActor @Sendable (Bool, OPNCatalogBrowseResultObject, String) -> Void) {
        browseCatalogObject(searchQuery: searchQuery, sortId: sortId, filterIds: filterIds, fetchCount: fetchCount, completion: completion)
    }

    func browseCatalogObject(searchQuery: String, sortId: String, filterIds: [String], fetchCount: Int, forceRefresh: Bool, cursor: String, completion: @escaping @MainActor @Sendable (Bool, OPNCatalogBrowseResultObject, String) -> Void) {
        browseCatalogObject(searchQuery: searchQuery, sortId: sortId, filterIds: filterIds, fetchCount: fetchCount, completion: completion)
    }

    func fetchMarqueePanelObjects(completion: @escaping @MainActor @Sendable (Bool, [OPNCatalogPanelObject], String) -> Void) {
        Task { @MainActor in completion(false, [], "Unused marquee") }
    }

    func fetchMainPanelObjects(completion: @escaping @MainActor @Sendable (Bool, [OPNCatalogPanelObject], String) -> Void) {
        Task { @MainActor in completion(false, [], "Unused panels") }
    }

    func fetchLibraryGameObjects(completion: @escaping @MainActor @Sendable (Bool, [OPNCatalogGameObject], String) -> Void) {
        Task { @MainActor in completion(false, [], "Unused library") }
    }

    func fetchFavoriteGameObjects(completion: @escaping @MainActor @Sendable (Bool, [OPNCatalogGameObject], String) -> Void) {
        Task { @MainActor in completion(false, [], "Unused favorites") }
    }

    func fetchGameObjectByCMSId(_ cmsId: String, completion: @escaping @MainActor @Sendable (Bool, OPNCatalogGameObject?, String) -> Void) {
        Task { @MainActor in completion(false, nil, "Unused game lookup") }
    }

    func fetchStoreDefinitions(completion: @escaping OPNStoreDefinitionsCallback) {
        Task { @MainActor in completion(false, [], "Unused stores") }
    }

    func fetchSubscriptionDefinitions(completion: @escaping OPNSubscriptionDefinitionsCallback) {
        Task { @MainActor in completion(false, [], "Unused subscriptions") }
    }

    func fetchAppPatchStatuses(appIds: [String], completion: @escaping OPNAppPatchStatusesCallback) {
        Task { @MainActor in completion(false, [:], "Unused patch statuses") }
    }

    func fetchLibraryPatchStatuses(completion: @escaping OPNAppPatchStatusesCallback) {
        Task { @MainActor in completion(false, [:], "Unused patch statuses") }
    }

    func addOwnedVariant(_ variantId: String, completion: @escaping OPNOwnershipActionCallback) {
        Task { @MainActor in completion(false, "Unused ownership mutation") }
    }

    func removeOwnedVariant(_ variantId: String, completion: @escaping OPNOwnershipActionCallback) {
        Task { @MainActor in completion(false, "Unused ownership mutation") }
    }

    func selectOwnedVariant(_ variantId: String, completion: @escaping OPNOwnershipActionCallback) {
        Task { @MainActor in completion(false, "Unused ownership mutation") }
    }

    func addFavoriteApp(_ appId: String, completion: @escaping OPNFavoriteActionCallback) {
        Task { @MainActor in completion(false, "Unused favorite mutation") }
    }

    func removeFavoriteApp(_ appId: String, completion: @escaping OPNFavoriteActionCallback) {
        Task { @MainActor in completion(false, "Unused favorite mutation") }
    }

    func syncAccountProvider(store: String, completion: @escaping OPNOwnershipActionCallback) {
        Task { @MainActor in completion(false, "Unused store sync") }
    }

    func startAccountLinking(store: String, completion: @escaping OPNOwnershipActionCallback) {
        Task { @MainActor in completion(false, "Unused store linking") }
    }

    func resolveStoreURL(game: OPNGameInfo, variantIndex: Int, completion: @escaping OPNStoreURLCallback) {
        Task { @MainActor in completion(false, "", "Unused store URL") }
    }

    func fetchProviderInfo(idpId: String, completion: @escaping OPNProviderInfoCallback) {
        Task { @MainActor in completion(false, OPNGameProviderInfo(), OPNGameProviderEndpoint(), "Unused provider") }
    }

    func providerStreamingBaseURL() -> String { OPNGameService.defaultStreamingBaseUrl }
}
