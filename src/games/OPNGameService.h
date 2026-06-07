#pragma once

#include <string>
#include <functional>
#include <vector>
#include <Foundation/Foundation.h>
#include "../common/OPNAuthTypes.h"
#include "../common/OPNGameTypes.h"
#include "../streaming/OPNStreamTypes.h"

namespace OPN {

using PanelCallback = std::function<void(bool success, const std::vector<PanelResult> &panels,
                                           const std::string &error)>;
using CatalogCallback = std::function<void(bool success, const std::vector<GameInfo> &games,
                                               const std::string &error)>;
using CatalogBrowseCallback = std::function<void(bool success, const CatalogBrowseResult &result,
                                                 const std::string &error)>;
using LaunchCallback = std::function<void(bool success, const SessionInfo &session,
                                             const std::string &offerSdp,
                                             const std::string &error)>;
using LaunchProgressCallback = std::function<void(const std::string &message, const SessionInfo &session)>;
using SubscriptionCallback = std::function<void(bool success, const SubscriptionInfo &subscription,
                                                  const std::string &error)>;
using StoreURLCallback = std::function<void(bool success, const std::string &storeURL,
                                              const std::string &error)>;
using ProviderInfoCallback = std::function<void(bool success, const GameProviderInfo &providerInfo,
                                                 const GameProviderEndpoint &selectedEndpoint,
                                                 const std::string &error)>;
using OwnershipActionCallback = std::function<void(bool success, const std::string &error)>;
using UserAccountCallback = std::function<void(bool success, const UserAccountInfo &accountInfo,
                                               const std::string &error)>;
using StoreDefinitionsCallback = std::function<void(bool success, const std::vector<StoreDefinition> &definitions,
                                                    const std::string &error)>;

class GameService {
public:
    static GameService &Shared();

    void SetAccessToken(const std::string &token);
    void SetAccountLinkingToken(const std::string &token);
    void SetVpcId(const std::string &id);
    void SetUserId(const std::string &id);
    void SetStreamingBaseUrl(const std::string &url);
    std::string ProviderStreamingBaseUrl() const;

    void FetchProviderInfo(const std::string &idpId, ProviderInfoCallback completion);
    void FetchMarqueePanels(PanelCallback completion);
    void FetchMainPanels(PanelCallback completion);
    void BrowseCatalogGames(const std::string &searchQuery,
                            const std::string &sortId,
                            const std::vector<std::string> &filterIds,
                            int fetchCount,
                            CatalogBrowseCallback completion);
    void FetchCatalogGames(CatalogCallback completion);
    void FetchPublicGames(CatalogCallback completion);
    void FetchLibraryGames(CatalogCallback completion);
    void FetchSubscriptionInfo(const std::string &userId, SubscriptionCallback completion);
    void ResolveStoreURL(const GameInfo &game, int variantIndex, StoreURLCallback completion);
    void FetchUserAccount(UserAccountCallback completion);
    void FetchStoreDefinitions(StoreDefinitionsCallback completion);
    void AddOwnedVariant(const std::string &variantId, OwnershipActionCallback completion);
    void RemoveOwnedVariant(const std::string &variantId, OwnershipActionCallback completion);
    void SelectOwnedVariant(const std::string &variantId, OwnershipActionCallback completion);
    void SyncAccountProvider(const std::string &store, OwnershipActionCallback completion);
    void StartAccountLinking(const std::string &store, OwnershipActionCallback completion);
    void PrewarmLaunchData();

    void LaunchGame(const std::string &appId,
                    const std::string &internalTitle,
                    const StreamSettings &settings,
                    bool recoveryMode,
                    LaunchProgressCallback progress,
                    LaunchCallback completion);

    static std::string OptimizeImageURL(const std::string &url, int width = 272);

private:
    GameService();

    void postGraphQL(const std::string &operationName,
                     const std::string &queryHash,
                     NSDictionary *variables,
                     std::function<void(NSDictionary *, NSString *)> completion);

    void postGraphQlJson(const std::string &query,
                          NSDictionary *variables,
                          std::function<void(NSDictionary *, NSString *)> completion);

    void ownedVariantMutation(const std::string &mutationName,
                              const std::string &fieldName,
                              const std::string &variantId,
                              OwnershipActionCallback completion);

    GameInfo parseGameItem(NSDictionary *item);
    std::vector<PanelResult> parsePanelResults(NSArray *rawPanels);
    void fetchAppMetadata(NSArray<NSString *> *appIds,
                          NSString *vpcId,
                          std::function<void(NSDictionary *, NSString *)> completion);
    NSDictionary *baseHeaders();

    std::string m_accessToken;
    std::string m_accountLinkingToken;
    std::string m_vpcId;
    std::string m_userId;
    std::string m_graphqlURL;
    std::string m_streamingBaseUrl;
    std::string m_providerStreamingBaseUrl;
};

}
