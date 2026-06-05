#pragma once

#include <string>
#include <vector>
#include <cstdint>
#include <map>

namespace OPN {

struct GameVariant {
    std::string id;
    std::string appStore;
    std::string storeUrl;
    std::string serviceStatus;
    bool librarySelected = false;
    bool inLibrary = false;
};

struct StoreAccountSyncingInfo {
    int totalNumberOfSyncedGfnGames = 0;
    std::string syncState;
    std::string syncDate;
};

struct StoreAccountInfo {
    std::string store;
    std::string userDisplayName;
    std::string expiresIn;
    std::string userIdentifier;
    bool hasAccountLinkingData = false;
    bool hasAccountSyncingData = false;
    StoreAccountSyncingInfo syncing;
};

struct UserAccountInfo {
    std::vector<std::string> subscriptions;
    std::vector<StoreAccountInfo> stores;
};

struct StoreFeatureInfo {
    std::string type;
    std::string displayProposition;
    bool supported = false;
};

struct StoreAccountLinkingMetadata {
    std::vector<std::string> supportedVariantIds;
    bool isSupported = false;
    bool isRequired = false;
    std::string label;
};

struct StoreDefinition {
    std::string store;
    std::string label;
    std::string smallImageUrl;
    int sortOrder = 0;
    std::vector<StoreFeatureInfo> features;
    StoreAccountLinkingMetadata accountLinkingMetadata;
};

struct GameInfo {
    std::string id;
    std::string uuid;
    std::string launchAppId;
    std::string title;
    std::string shortName;
    std::string description;
    std::string developerName;
    std::string publisherName;
    int maxLocalPlayers = 0;
    int maxOnlinePlayers = 0;
    std::string playType;
    std::string membershipTierLabel;
    std::string playabilityState;
    std::string imageUrl;
    std::string heroImageUrl;
    std::vector<std::string> screenshotUrls;
    std::map<std::string, std::vector<std::string>> imageUrlsByType;
    std::vector<std::string> genres;
    std::vector<std::string> featureLabels;
    std::vector<std::string> supportedControls;
    std::vector<std::string> contentRatings;
    std::vector<std::string> nvidiaTech;
    std::vector<std::string> availableStores;
    bool isInLibrary = false;
    std::vector<GameVariant> variants;
};

struct ActiveSessionEntry {
    std::string sessionId;
    int appId = 0;
    int status = 0;
    std::string serverIp;
    std::string gpuType;
    std::string streamingBaseUrl;
    std::string signalingUrl;
};

struct PanelSection {
    std::string id;
    std::string title;
    std::string __typename;
    std::vector<GameInfo> games;
};

struct PanelResult {
    std::string id;
    std::string title;
    std::string __typename;
    std::vector<PanelSection> sections;
};

struct CatalogFilterOption {
    std::string id;
    std::string rawId;
    std::string label;
    std::string groupId;
    std::string groupLabel;
};

struct CatalogFilterGroup {
    std::string id;
    std::string label;
    std::vector<CatalogFilterOption> options;
};

struct CatalogSortOption {
    std::string id;
    std::string label;
    std::string orderBy;
};

struct CatalogBrowseResult {
    std::vector<GameInfo> games;
    int numberReturned = 0;
    int numberSupported = 0;
    int totalCount = 0;
    bool hasNextPage = false;
    std::string endCursor;
    std::string searchQuery;
    std::string selectedSortId;
    std::vector<std::string> selectedFilterIds;
    std::vector<CatalogFilterGroup> filterGroups;
    std::vector<CatalogSortOption> sortOptions;
};

struct GameProviderEndpoint {
    std::string loginProvider;
    std::string loginProviderCode;
    std::string loginProviderDisplayName;
    std::string streamingServiceUrl;
    std::string idpId;
    std::string redeemRedirectUrl;
    int priority = 0;
};

struct GameProviderInfo {
    std::string defaultProvider;
    std::string loggedInProvider;
    bool loginRequired = false;
    std::vector<std::string> loginPreferredProviders;
    std::vector<GameProviderEndpoint> endpoints;
};

struct FeaturedGamesResult {
    std::vector<GameInfo> games;
    bool usedExplicitFeaturedSection = false;
};

}
