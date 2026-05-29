#include "OPNGameService.h"
#include "OPNGameDataCache.h"
#include "streaming/OPNSessionManager.h"
#include "streaming/OPNSignalingClient.h"
#include "streaming/OPNStreamPreferences.h"
#include "streaming/OPNStreamSession.h"
#include "common/OPNLocale.h"
#include <CommonCrypto/CommonCrypto.h>
#include <algorithm>
#include <cctype>
#include <cstring>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include "common/OPNSentry.h"

namespace OPN {


static dispatch_queue_t GameServiceWorkQueue() {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.opennow.game-service.work", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void DispatchCatalogBrowseCallback(const CatalogBrowseCallback &completion,
                                          bool success,
                                          const CatalogBrowseResult &result,
                                          const std::string &error) {
    if (!completion) return;
    CatalogBrowseCallback completionCopy = completion;
    CatalogBrowseResult resultCopy = result;
    std::string errorCopy = error;
    dispatch_async(dispatch_get_main_queue(), ^{
        completionCopy(success, resultCopy, errorCopy);
    });
}

static void DispatchCatalogCallback(const CatalogCallback &completion,
                                    bool success,
                                    const std::vector<GameInfo> &games,
                                    const std::string &error) {
    if (!completion) return;
    CatalogCallback completionCopy = completion;
    std::vector<GameInfo> gamesCopy = games;
    std::string errorCopy = error;
    dispatch_async(dispatch_get_main_queue(), ^{
        completionCopy(success, gamesCopy, errorCopy);
    });
}

static void DispatchPanelCallback(const PanelCallback &completion,
                                  bool success,
                                  const std::vector<PanelResult> &panels,
                                  const std::string &error) {
    if (!completion) return;
    PanelCallback completionCopy = completion;
    std::vector<PanelResult> panelsCopy = panels;
    std::string errorCopy = error;
    dispatch_async(dispatch_get_main_queue(), ^{
        completionCopy(success, panelsCopy, errorCopy);
    });
}

static void DispatchSubscriptionCallback(const SubscriptionCallback &completion,
                                         bool success,
                                         const SubscriptionInfo &subscription,
                                         const std::string &error) {
    if (!completion) return;
    SubscriptionCallback completionCopy = completion;
    SubscriptionInfo subscriptionCopy = subscription;
    std::string errorCopy = error;
    dispatch_async(dispatch_get_main_queue(), ^{
        completionCopy(success, subscriptionCopy, errorCopy);
    });
}

static void DispatchStoreURLCallback(const StoreURLCallback &completion,
                                     bool success,
                                     const std::string &storeURL,
                                     const std::string &error) {
    if (!completion) return;
    StoreURLCallback completionCopy = completion;
    std::string storeURLCopy = storeURL;
    std::string errorCopy = error;
    dispatch_async(dispatch_get_main_queue(), ^{
        completionCopy(success, storeURLCopy, errorCopy);
    });
}

static void DispatchProviderInfoCallback(const ProviderInfoCallback &completion,
                                         bool success,
                                         const GameProviderInfo &providerInfo,
                                         const GameProviderEndpoint &selectedEndpoint,
                                         const std::string &error) {
    if (!completion) return;
    ProviderInfoCallback completionCopy = completion;
    GameProviderInfo providerInfoCopy = providerInfo;
    GameProviderEndpoint selectedEndpointCopy = selectedEndpoint;
    std::string errorCopy = error;
    dispatch_async(dispatch_get_main_queue(), ^{
        completionCopy(success, providerInfoCopy, selectedEndpointCopy, errorCopy);
    });
}

static void DispatchGraphQLCallback(const std::function<void(NSDictionary *, NSString *)> &completion,
                                    NSDictionary *payload,
                                    NSString *message) {
    if (!completion) return;
    std::function<void(NSDictionary *, NSString *)> completionCopy = completion;
    NSDictionary *payloadCopy = payload;
    NSString *messageCopy = [message copy] ?: @"";
    dispatch_async(GameServiceWorkQueue(), ^{
        completionCopy(payloadCopy, messageCopy);
    });
}


static NSString *kPanelsHash = @"f8e26265a5db5c20e1334a6872cf04b6e3970507697f6ae55a6ddefa5420daf0";
static NSString *kMarqueeHash = @"dd4bddfdef4707dfe340cc2040d6bb9c4c45f706976fca15b2ef33221c385d7f";
static NSString *kLibraryWithTimeHash = @"039e8c0d553972975485fee56e59f2549d2fdb518e247a42ab5022056a74406f";
static NSString *kAppMetaDataHash = @"cf8b620dfd03617017ba7c858cee65197e1ace5180e41be194b39227227ced63";


static NSString *kNvClientId = @"ec7e38d4-03af-4b58-b131-cfb0495903ab";
static NSString *kNvClientVersion = @"2.0.80.173";
static NSString *const kProviderServiceUrlsEndpoint = @"https://pcs.geforcenow.com/v1/serviceUrls";
static constexpr const char *kDefaultSubscriptionVpcId = "NP-AMS-08";
static constexpr int kDefaultCatalogFetchCount = 96;
static constexpr int kMaxCatalogPages = 3;
static constexpr NSTimeInterval kCatalogCacheFreshSeconds = 15.0 * 60.0;
static constexpr NSTimeInterval kCatalogDefinitionsFreshSeconds = 24.0 * 60.0 * 60.0;
static void GetServerVpcId(const std::string &token,
                           const std::string &providerStreamingBaseUrl,
                           std::function<void(const std::string &vpcId)> completion);
static NSString *SafeStr(id value);
static int SafeInt(id value);
static NSString *NSStringFromStdString(const std::string &value, NSString *fallback = @"");

GameService &GameService::Shared() {
    static GameService instance;
    return instance;
}

GameService::GameService() {
    m_graphqlURL = "https://games.geforce.com/graphql";
    m_providerStreamingBaseUrl = DefaultStreamingBaseUrl();
}

void GameService::SetAccessToken(const std::string &token) {
    m_accessToken = token;
}

void GameService::SetVpcId(const std::string &id) {
    m_vpcId = id;
}

void GameService::SetUserId(const std::string &id) {
    m_userId = id;
}

void GameService::SetStreamingBaseUrl(const std::string &url) {
    m_streamingBaseUrl = url;
    SessionManager::Shared().SetStreamingBaseUrl(url);
}

std::string GameService::ProviderStreamingBaseUrl() const {
    return m_providerStreamingBaseUrl.empty() ? DefaultStreamingBaseUrl() : m_providerStreamingBaseUrl;
}

static std::string NormalizeStreamingBaseUrl(const std::string &url) {
    if (url.empty()) return DefaultStreamingBaseUrl();
    return url.back() == '/' ? url : url + "/";
}

static std::vector<std::string> SafeStringVector(id value) {
    std::vector<std::string> out;
    if (![value isKindOfClass:[NSArray class]]) return out;
    for (id item in (NSArray *)value) {
        NSString *text = SafeStr(item);
        if (text.length > 0) out.push_back([text UTF8String]);
    }
    return out;
}

static bool SafeBool(id value) {
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value boolValue];
    if ([value isKindOfClass:[NSString class]]) {
        NSString *lower = [(NSString *)value lowercaseString];
        return [lower isEqualToString:@"true"] || [lower isEqualToString:@"1"] || [lower isEqualToString:@"yes"];
    }
    return false;
}

static NSDictionary *ProviderInfoDictionary(NSDictionary *json) {
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *info = [json[@"gfnServiceInfo"] isKindOfClass:[NSDictionary class]] ? json[@"gfnServiceInfo"] : nil;
    if (info) return info;
    NSDictionary *data = [json[@"data"] isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
    if (data) {
        info = [data[@"gfnServiceInfo"] isKindOfClass:[NSDictionary class]] ? data[@"gfnServiceInfo"] : nil;
        if (info) return info;
        NSDictionary *serviceUrls = [data[@"serviceUrls"] isKindOfClass:[NSDictionary class]] ? data[@"serviceUrls"] : nil;
        info = [serviceUrls[@"gfnServiceInfo"] isKindOfClass:[NSDictionary class]] ? serviceUrls[@"gfnServiceInfo"] : nil;
        if (info) return info;
    }
    return json;
}

static GameProviderInfo ParseGameProviderInfo(NSDictionary *json) {
    NSDictionary *infoRaw = ProviderInfoDictionary(json);
    GameProviderInfo info;
    if (!infoRaw) return info;

    NSString *defaultProvider = SafeStr(infoRaw[@"defaultProvider"]);
    NSString *loggedInProvider = SafeStr(infoRaw[@"loggedInProvider"]);
    info.defaultProvider = defaultProvider ? [defaultProvider UTF8String] : "";
    info.loggedInProvider = loggedInProvider ? [loggedInProvider UTF8String] : "";
    info.loginRequired = SafeBool(infoRaw[@"loginRequired"]);
    info.loginPreferredProviders = SafeStringVector(infoRaw[@"loginPreferredProviders"]);

    NSArray *endpoints = [infoRaw[@"gfnServiceEndpoints"] isKindOfClass:[NSArray class]] ? infoRaw[@"gfnServiceEndpoints"] : @[];
    for (NSDictionary *entry in endpoints) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        GameProviderEndpoint endpoint;
        if (NSString *value = SafeStr(entry[@"loginProvider"])) endpoint.loginProvider = [value UTF8String];
        if (NSString *value = SafeStr(entry[@"loginProviderCode"])) endpoint.loginProviderCode = [value UTF8String];
        if (NSString *value = SafeStr(entry[@"loginProviderDisplayName"])) endpoint.loginProviderDisplayName = [value UTF8String];
        if (NSString *value = SafeStr(entry[@"streamingServiceUrl"])) endpoint.streamingServiceUrl = NormalizeStreamingBaseUrl([value UTF8String]);
        if (NSString *value = SafeStr(entry[@"idpId"])) endpoint.idpId = [value UTF8String];
        if (NSString *value = SafeStr(entry[@"redeemRedirectUrl"])) endpoint.redeemRedirectUrl = [value UTF8String];
        endpoint.priority = SafeInt(entry[@"loginProviderPriority"]);
        if (!endpoint.streamingServiceUrl.empty()) info.endpoints.push_back(endpoint);
    }
    std::sort(info.endpoints.begin(), info.endpoints.end(), [](const GameProviderEndpoint &lhs, const GameProviderEndpoint &rhs) {
        return lhs.priority < rhs.priority;
    });
    return info;
}

static GameProviderEndpoint SelectGameProviderEndpoint(const GameProviderInfo &info, const std::string &idpId) {
    if (!idpId.empty()) {
        for (const GameProviderEndpoint &endpoint : info.endpoints) {
            if (endpoint.idpId == idpId) return endpoint;
        }
    }
    if (!info.loggedInProvider.empty()) {
        for (const GameProviderEndpoint &endpoint : info.endpoints) {
            if (endpoint.loginProvider == info.loggedInProvider || endpoint.loginProviderCode == info.loggedInProvider) return endpoint;
        }
    }
    if (!info.defaultProvider.empty()) {
        for (const GameProviderEndpoint &endpoint : info.endpoints) {
            if (endpoint.loginProvider == info.defaultProvider || endpoint.loginProviderCode == info.defaultProvider) return endpoint;
        }
    }
    for (const GameProviderEndpoint &endpoint : info.endpoints) {
        if (!endpoint.streamingServiceUrl.empty()) return endpoint;
    }
    GameProviderEndpoint fallback;
    fallback.loginProvider = info.defaultProvider;
    fallback.streamingServiceUrl = DefaultStreamingBaseUrl();
    return fallback;
}

void GameService::FetchProviderInfo(const std::string &idpId, ProviderInfoCallback completion) {
    std::string idpIdCopy = idpId;
    NSURL *url = [NSURL URLWithString:kProviderServiceUrlsEndpoint];
    if (!url) {
        DispatchProviderInfoCallback(completion, false, GameProviderInfo{}, GameProviderEndpoint{}, "Invalid provider info URL");
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 10.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 GFN-PC/2.0.80.173" forHTTPHeaderField:@"User-Agent"];

    ProviderInfoCallback callback = completion;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (error || !data || http.statusCode != 200) {
            GameProviderInfo info;
            GameProviderEndpoint endpoint;
            endpoint.streamingServiceUrl = DefaultStreamingBaseUrl();
            this->m_providerStreamingBaseUrl = endpoint.streamingServiceUrl;
            std::string message = error ? [[error localizedDescription] UTF8String] : "Provider info request failed";
            DispatchProviderInfoCallback(callback, false, info, endpoint, message);
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        GameProviderInfo info = ParseGameProviderInfo(json);
        GameProviderEndpoint endpoint = SelectGameProviderEndpoint(info, idpIdCopy);
        if (endpoint.streamingServiceUrl.empty()) endpoint.streamingServiceUrl = DefaultStreamingBaseUrl();
        this->m_providerStreamingBaseUrl = NormalizeStreamingBaseUrl(endpoint.streamingServiceUrl);
        endpoint.streamingServiceUrl = this->m_providerStreamingBaseUrl;
        DispatchProviderInfoCallback(callback, true, info, endpoint, "");
    }] resume];
}





NSDictionary *GameService::baseHeaders() {
    NSMutableDictionary *h = [NSMutableDictionary dictionary];
    h[@"Origin"] = @"https://play.geforcenow.com";
    h[@"Referer"] = @"https://play.geforcenow.com/";
    h[@"Accept"] = @"application/json, text/plain, */*";
    h[@"nv-client-id"] = kNvClientId;
    h[@"nv-client-type"] = @"NATIVE";
    h[@"nv-client-version"] = kNvClientVersion;
    h[@"nv-client-streamer"] = @"NVIDIA-CLASSIC";
    h[@"nv-device-os"] = @"MACOS";
    h[@"nv-device-type"] = @"DESKTOP";
    h[@"nv-device-make"] = @"UNKNOWN";
    h[@"nv-device-model"] = @"UNKNOWN";
    h[@"nv-browser-type"] = @"CHROME";
    h[@"User-Agent"] = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 GFN-PC/2.0.80.173";

    if (!m_accessToken.empty()) {
        h[@"Authorization"] = [NSString stringWithFormat:@"GFNJWT %s", m_accessToken.c_str()];
    }
    return h;
}





void GameService::postGraphQL(const std::string &operationName,
                               const std::string &queryHash,
                               NSDictionary *variables,
                               std::function<void(NSDictionary *, NSString *)> completion) {

    NSString *varStr = @"{}";
    if (variables) {
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:variables options:0 error:nil];
        varStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    }

    NSDictionary *extDict = @{
        @"persistedQuery": @{
            @"sha256Hash": [NSString stringWithUTF8String:queryHash.c_str()]
        }
    };
    NSData *extData = [NSJSONSerialization dataWithJSONObject:extDict options:0 error:nil];
    NSString *extStr = [[NSString alloc] initWithData:extData encoding:NSUTF8StringEncoding];


    NSString *huId = [NSString stringWithFormat:@"%lx%@",
        (unsigned long)[[NSDate date] timeIntervalSince1970] * 1000,
        [[[[NSUUID UUID] UUIDString] stringByReplacingOccurrencesOfString:@"-" withString:@""] substringToIndex:8]];


    NSString *encodedRequestType = [[NSString stringWithUTF8String:operationName.c_str()]
        stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSString *encodedExtensions = [extStr stringByAddingPercentEncodingWithAllowedCharacters:
        NSCharacterSet.URLQueryAllowedCharacterSet];
    NSString *encodedVariables = [varStr stringByAddingPercentEncodingWithAllowedCharacters:
        NSCharacterSet.URLQueryAllowedCharacterSet];

    NSString *urlStr = [NSString stringWithFormat:@"https://games.geforce.com/graphql?requestType=%@&extensions=%@&huId=%@&variables=%@",
        encodedRequestType, encodedExtensions, huId, encodedVariables];

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        DispatchGraphQLCallback(completion, nil, @"Invalid URL");
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 20.0;


    NSDictionary *hdrs = baseHeaders();
    NSMutableDictionary *allHeaders = [hdrs mutableCopy];
    allHeaders[@"Content-Type"] = @"application/graphql";
    for (NSString *key in allHeaders) {
        [req setValue:allHeaders[key] forHTTPHeaderField:key];
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSDictionary *payload = nil;
            NSString *message = @"";
            if (error) {
                message = [error localizedDescription];
            } else {
                NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
                NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                if (!http || http.statusCode != 200 || !json) {
                    message = [NSString stringWithFormat:@"GraphQL error (%ld)", (long)(http ? http.statusCode : 0)];
                } else {
                    NSArray *errors = json[@"errors"];
                    if ([errors isKindOfClass:[NSArray class]] && errors.count > 0) {
                        NSDictionary *err = [errors[0] isKindOfClass:[NSDictionary class]] ? errors[0] : nil;
                        NSString *errMsg = [err[@"message"] isKindOfClass:[NSString class]] ? err[@"message"] : nil;
                        message = errMsg ?: @"GraphQL error";
                    } else {
                        NSDictionary *dataPayload = json[@"data"];
                        if ([dataPayload isKindOfClass:[NSDictionary class]]) {
                            payload = dataPayload;
                        } else {
                            message = @"No data in GraphQL response";
                        }
                    }
                }
            }
            DispatchGraphQLCallback(completion, payload, message);
        }];
    [task resume];
}





static NSString *SafeStr(id value) {
    if (!value || [value isKindOfClass:[NSNull class]]) return nil;
    if (![value isKindOfClass:[NSString class]]) return nil;
    return (NSString *)value;
}

static NSString *NSStringFromStdString(const std::string &value, NSString *fallback) {
    if (value.empty()) return fallback ?: @"";
    NSString *string = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
    return string ?: (fallback ?: @"");
}

static NSString *FirstSafeString(NSDictionary *dictionary, NSArray<NSString *> *keys) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
    for (NSString *key in keys) {
        NSString *value = SafeStr(dictionary[key]);
        if (value.length > 0) return value;
    }
    return nil;
}

static NSString *FirstLandscapeImageString(NSDictionary *images) {
    return FirstSafeString(images, @[
        @"MARQUEE_HERO_IMAGE",
        @"HERO_IMAGE",
        @"TV_BANNER",
        @"FEATURE_IMAGE",
        @"KEY_IMAGE",
        @"KEY_ART"
    ]);
}

static NSString *FirstPosterImageString(NSDictionary *images) {
    return FirstSafeString(images, @[
        @"GAME_BOX_ART",
        @"KEY_IMAGE",
        @"KEY_ART"
    ]);
}

static double SafeMinutesAsHours(id value) {
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value doubleValue] / 60.0;
    }
    if ([value isKindOfClass:[NSString class]]) {
        double minutes = [(NSString *)value doubleValue];
        return minutes / 60.0;
    }
    return 0.0;
}

static int SafeInt(id value) {
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value intValue];
    if ([value isKindOfClass:[NSString class]]) return [(NSString *)value intValue];
    return 0;
}

static void DeepMergeDictionaryInto(NSMutableDictionary *target, NSDictionary *source) {
    if (!target || ![source isKindOfClass:[NSDictionary class]]) return;
    for (id key in source) {
        id sourceValue = source[key];
        id targetValue = target[key];
        if ([targetValue isKindOfClass:[NSDictionary class]] && [sourceValue isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *merged = [(NSDictionary *)targetValue mutableCopy];
            DeepMergeDictionaryInto(merged, sourceValue);
            target[key] = merged;
        } else if (sourceValue) {
            target[key] = sourceValue;
        }
    }
}

static void ParseCatalogDefinitions(NSDictionary *definitionsData,
                                    CatalogBrowseResult &result,
                                    NSMutableDictionary<NSString *, NSDictionary *> *filterPayloadById) {
    NSArray *filterGroupsRaw = definitionsData[@"filterGroupDefinitions"];
    if ([filterGroupsRaw isKindOfClass:[NSArray class]]) {
        for (NSDictionary *groupRaw in filterGroupsRaw) {
            if (![groupRaw isKindOfClass:[NSDictionary class]]) continue;
            CatalogFilterGroup group;
            NSString *groupId = SafeStr(groupRaw[@"id"]);
            NSString *groupLabel = SafeStr(groupRaw[@"label"]);
            group.id = groupId ? [groupId UTF8String] : "";
            group.label = groupLabel ? [groupLabel UTF8String] : "";
            NSArray *filters = groupRaw[@"filters"];
            if ([filters isKindOfClass:[NSArray class]]) {
                for (NSDictionary *entry in filters) {
                    if (![entry isKindOfClass:[NSDictionary class]]) continue;
                    NSString *filterId = SafeStr(entry[@"id"]);
                    NSString *filterLabel = SafeStr(entry[@"label"]);
                    NSArray *payloads = [entry[@"filters"] isKindOfClass:[NSArray class]] ? entry[@"filters"] : @[];
                    NSMutableDictionary *mergedPayload = [NSMutableDictionary dictionary];
                    for (id rawPayload in payloads) {
                        NSString *payloadString = SafeStr(rawPayload);
                        if (payloadString.length == 0) continue;
                        NSData *payloadData = [payloadString dataUsingEncoding:NSUTF8StringEncoding];
                        NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:nil];
                        if (![payload isKindOfClass:[NSDictionary class]]) continue;
                        DeepMergeDictionaryInto(mergedPayload, payload);
                    }
                    if (filterId.length == 0 || mergedPayload.count == 0) continue;
                    filterPayloadById[filterId] = [mergedPayload copy];

                    CatalogFilterOption option;
                    option.id = [filterId UTF8String];
                    option.rawId = option.id;
                    option.label = filterLabel ? [filterLabel UTF8String] : option.id;
                    option.groupId = group.id;
                    option.groupLabel = group.label;
                    group.options.push_back(option);
                }
            }
            if (!group.options.empty()) result.filterGroups.push_back(group);
        }
    }

    NSArray *sortsRaw = definitionsData[@"sortOrderDefinitions"];
    if ([sortsRaw isKindOfClass:[NSArray class]]) {
        for (NSDictionary *sortRaw in sortsRaw) {
            if (![sortRaw isKindOfClass:[NSDictionary class]]) continue;
            NSString *sid = SafeStr(sortRaw[@"id"]);
            NSString *label = SafeStr(sortRaw[@"label"]);
            NSString *orderBy = SafeStr(sortRaw[@"orderBy"]);
            if (sid.length == 0 || orderBy.length == 0) continue;
            CatalogSortOption option;
            option.id = [sid UTF8String];
            option.label = label ? [label UTF8String] : option.id;
            option.orderBy = [orderBy UTF8String];
            result.sortOptions.push_back(option);
        }
    }
}

static void AppendUniqueString(std::vector<std::string> &values, NSString *value) {
    if (value.length == 0) return;
    std::string text = [value UTF8String];
    if (std::find(values.begin(), values.end(), text) == values.end()) values.push_back(text);
}

static void AppendUniqueStdString(std::vector<std::string> &values, const std::string &value) {
    if (value.empty()) return;
    if (std::find(values.begin(), values.end(), value) == values.end()) values.push_back(value);
}

static bool StringsEqualCaseInsensitive(const std::string &lhs, const std::string &rhs) {
    if (lhs.size() != rhs.size()) return false;
    for (size_t i = 0; i < lhs.size(); i++) {
        if (std::tolower((unsigned char)lhs[i]) != std::tolower((unsigned char)rhs[i])) return false;
    }
    return true;
}

static bool ContainsStringCaseInsensitive(const std::vector<std::string> &values, const std::string &candidate) {
    for (const std::string &value : values) {
        if (StringsEqualCaseInsensitive(value, candidate)) return true;
    }
    return false;
}

static bool VariantMatchesStoreMetadata(const GameVariant &target, const GameVariant &metadata) {
    if (!target.id.empty() && !metadata.id.empty() && target.id == metadata.id) return true;
    if (!target.appStore.empty() && !metadata.appStore.empty() && StringsEqualCaseInsensitive(target.appStore, metadata.appStore)) return true;
    return false;
}

static bool MergeMissingStoreMetadata(GameInfo &target, const GameInfo &metadata) {
    bool changed = false;
    if (target.launchAppId.empty() && !metadata.launchAppId.empty()) {
        target.launchAppId = metadata.launchAppId;
        changed = true;
    }
    for (const std::string &store : metadata.availableStores) {
        if (!ContainsStringCaseInsensitive(target.availableStores, store)) {
            target.availableStores.push_back(store);
            changed = true;
        }
    }

    for (const GameVariant &metadataVariant : metadata.variants) {
        bool merged = false;
        for (GameVariant &targetVariant : target.variants) {
            if (!VariantMatchesStoreMetadata(targetVariant, metadataVariant)) continue;
            if (targetVariant.id.empty() && !metadataVariant.id.empty()) {
                targetVariant.id = metadataVariant.id;
                changed = true;
            }
            if (targetVariant.appStore.empty() && !metadataVariant.appStore.empty()) {
                targetVariant.appStore = metadataVariant.appStore;
                changed = true;
            }
            if (targetVariant.storeUrl.empty() && !metadataVariant.storeUrl.empty()) {
                targetVariant.storeUrl = metadataVariant.storeUrl;
                changed = true;
            }
            if (targetVariant.serviceStatus.empty() && !metadataVariant.serviceStatus.empty()) {
                targetVariant.serviceStatus = metadataVariant.serviceStatus;
                changed = true;
            }
            if (!targetVariant.librarySelected && metadataVariant.librarySelected) {
                targetVariant.librarySelected = true;
                changed = true;
            }
            if (!targetVariant.inLibrary && metadataVariant.inLibrary) {
                targetVariant.inLibrary = true;
                changed = true;
            }
            merged = true;
            break;
        }
        if (!merged && !metadataVariant.appStore.empty()) {
            target.variants.push_back(metadataVariant);
            if (!ContainsStringCaseInsensitive(target.availableStores, metadataVariant.appStore)) {
                target.availableStores.push_back(metadataVariant.appStore);
            }
            changed = true;
        }
    }
    return changed;
}

static const GameVariant *GameVariantAtIndex(const GameInfo &game, int variantIndex) {
    if (variantIndex < 0 || variantIndex >= (int)game.variants.size()) return nullptr;
    return &game.variants[(size_t)variantIndex];
}

static std::string StoreURLForKnownGame(const GameInfo &game, int variantIndex) {
    const GameVariant *selectedVariant = GameVariantAtIndex(game, variantIndex);
    if (selectedVariant && !selectedVariant->storeUrl.empty()) return selectedVariant->storeUrl;
    for (const GameVariant &variant : game.variants) {
        if (!variant.storeUrl.empty()) return variant.storeUrl;
    }
    return "";
}

static std::string StoreURLForMetadataGame(const GameInfo &metadataGame,
                                           const std::string &variantId,
                                           const std::string &store) {
    if (!variantId.empty()) {
        for (const GameVariant &variant : metadataGame.variants) {
            if (variant.id == variantId && !variant.storeUrl.empty()) return variant.storeUrl;
        }
    }
    if (!store.empty()) {
        for (const GameVariant &variant : metadataGame.variants) {
            if (StringsEqualCaseInsensitive(variant.appStore, store) && !variant.storeUrl.empty()) return variant.storeUrl;
        }
    }
    for (const GameVariant &variant : metadataGame.variants) {
        if (!variant.storeUrl.empty()) return variant.storeUrl;
    }
    return "";
}

static bool MergeVariantFromSameStore(GameVariant &target, const GameVariant &source) {
    bool changed = false;
    if (!source.id.empty() && (target.id.empty() || (!target.librarySelected && source.librarySelected))) {
        target.id = source.id;
        changed = true;
    }
    if (target.storeUrl.empty() && !source.storeUrl.empty()) {
        target.storeUrl = source.storeUrl;
        changed = true;
    }
    if (!source.serviceStatus.empty() && (target.serviceStatus.empty() || (!target.librarySelected && source.librarySelected))) {
        target.serviceStatus = source.serviceStatus;
        changed = true;
    }
    if (!target.librarySelected && source.librarySelected) {
        target.librarySelected = true;
        changed = true;
    }
    if (!target.inLibrary && source.inLibrary) {
        target.inLibrary = true;
        changed = true;
    }
    return changed;
}

static void AppendStringValues(std::vector<std::string> &values, id rawValue) {
    if ([rawValue isKindOfClass:[NSString class]]) {
        AppendUniqueString(values, rawValue);
        return;
    }
    if (![rawValue isKindOfClass:[NSArray class]]) return;
    for (id item in (NSArray *)rawValue) {
        if ([item isKindOfClass:[NSString class]]) {
            AppendUniqueString(values, item);
        } else if ([item isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dictionary = (NSDictionary *)item;
            NSString *text = FirstSafeString(dictionary, @[@"name", @"label", @"value", @"rating", @"control", @"type"]);
            AppendUniqueString(values, text);
        }
    }
}

static bool HasVisibleVariants(const GameInfo &game) {
    return !game.variants.empty();
}

GameInfo GameService::parseGameItem(NSDictionary *app) {
    GameInfo g;
    if (!app) return g;

    { NSString *v = SafeStr(app[@"id"]); g.id = v ? [v UTF8String] : ""; g.uuid = g.id; }
    { NSString *v = SafeStr(app[@"title"]); g.title = v ? [v UTF8String] : ""; }
    { NSString *v = SafeStr(app[@"shortName"]); g.shortName = v ? [v UTF8String] : ""; }
    { NSString *v = FirstSafeString(app, @[@"description", @"longDescription", @"shortDescription", @"summary"]); g.description = v ? [v UTF8String] : ""; }
    { NSString *v = SafeStr(app[@"developerName"]); g.developerName = v ? [v UTF8String] : ""; }
    { NSString *v = SafeStr(app[@"publisherName"]); g.publisherName = v ? [v UTF8String] : ""; }
    g.maxLocalPlayers = SafeInt(app[@"maxLocalPlayers"]);
    g.maxOnlinePlayers = SafeInt(app[@"maxOnlinePlayers"]);
    AppendStringValues(g.supportedControls, app[@"supportedControls"]);
    AppendStringValues(g.contentRatings, app[@"contentRatings"]);
    AppendStringValues(g.nvidiaTech, app[@"nvidiaTech"]);

    NSDictionary *itemMetadata = app[@"itemMetadata"];
    if (g.description.empty() && [itemMetadata isKindOfClass:[NSDictionary class]]) {
        NSString *v = FirstSafeString(itemMetadata, @[@"description", @"longDescription", @"shortDescription", @"summary"]);
        if (v) g.description = [v UTF8String];
    }
    NSDictionary *serviceMeta = app[@"gfn"];
    if (serviceMeta && [serviceMeta isKindOfClass:[NSDictionary class]]) {
        { NSString *v = SafeStr(serviceMeta[@"playabilityState"]); g.playabilityState = v ? [v UTF8String] : ""; }
        { NSString *v = SafeStr(serviceMeta[@"minimumMembershipTierLabel"]); g.membershipTierLabel = v ? [v UTF8String] : ""; }
        { NSString *v = SafeStr(serviceMeta[@"playType"]); g.playType = v ? [v UTF8String] : ""; }
    }

    NSDictionary *images = app[@"images"];
    if (images && [images isKindOfClass:[NSDictionary class]]) {
        for (id rawKey in images) {
            NSString *key = [rawKey isKindOfClass:[NSString class]] ? (NSString *)rawKey : @"";
            if (key.length == 0) continue;
            id rawValue = images[key];
            std::vector<std::string> urls;
            if ([rawValue isKindOfClass:[NSString class]]) {
                NSString *url = SafeStr(rawValue);
                if (url.length > 0) AppendUniqueStdString(urls, OptimizeImageURL([url UTF8String], 1200));
            } else if ([rawValue isKindOfClass:[NSArray class]]) {
                for (id item in (NSArray *)rawValue) {
                    NSString *url = SafeStr(item);
                    if (url.length > 0) AppendUniqueStdString(urls, OptimizeImageURL([url UTF8String], 1200));
                }
            }
            if (!urls.empty()) g.imageUrlsByType[[key UTF8String]] = urls;
        }
        NSString *landscape = FirstLandscapeImageString(images);
        NSString *poster = FirstPosterImageString(images);
        NSString *primary = landscape ?: poster;
        if (landscape) {
            g.heroImageUrl = OptimizeImageURL([landscape UTF8String], 1200);
        }
        if (primary) {
            g.imageUrl = OptimizeImageURL([primary UTF8String], 900);
        }
        id screenshots = images[@"SCREENSHOTS"];
        if ([screenshots isKindOfClass:[NSArray class]]) {
            for (id screenshot in (NSArray *)screenshots) {
                NSString *url = SafeStr(screenshot);
                if (url.length == 0) continue;
                std::string optimizedUrl = OptimizeImageURL([url UTF8String], 720);
                if (std::find(g.screenshotUrls.begin(), g.screenshotUrls.end(), optimizedUrl) == g.screenshotUrls.end()) {
                    g.screenshotUrls.push_back(optimizedUrl);
                }
            }
        } else if ([screenshots isKindOfClass:[NSString class]]) {
            NSString *url = SafeStr(screenshots);
            if (url.length > 0) g.screenshotUrls.push_back(OptimizeImageURL([url UTF8String], 720));
        }
    }

    NSArray *variants = app[@"variants"];
    if (variants && [variants isKindOfClass:[NSArray class]]) {
        for (NSDictionary *v in variants) {
            if (![v isKindOfClass:[NSDictionary class]]) continue;
            GameVariant gv;
            { NSString *s = SafeStr(v[@"id"]); gv.id = s ? [s UTF8String] : ""; }
            { NSString *s = SafeStr(v[@"appStore"]); gv.appStore = s ? [s UTF8String] : ""; }
            { NSString *s = SafeStr(v[@"storeUrl"]); gv.storeUrl = s ? [s UTF8String] : ""; }

            NSDictionary *variantService = v[@"gfn"];
            if (variantService && [variantService isKindOfClass:[NSDictionary class]]) {
                NSDictionary *lib = variantService[@"library"];
                if (lib && [lib isKindOfClass:[NSDictionary class]]) {
                    { NSString *s = SafeStr(lib[@"status"]); gv.serviceStatus = s ? [s UTF8String] : ""; }
                    NSNumber *sel = lib[@"selected"];
                    gv.librarySelected = [sel isKindOfClass:[NSNumber class]] ? [sel boolValue] : false;
                    if (gv.librarySelected) gv.inLibrary = true;
                }
                { NSString *s = SafeStr(variantService[@"status"]); if (gv.serviceStatus.empty() && s) gv.serviceStatus = [s UTF8String]; }
            }

            if (!gv.appStore.empty() && gv.appStore != "UNKNOWN" && gv.appStore != "NONE") {
                bool mergedExistingStore = false;
                for (GameVariant &existing : g.variants) {
                    if (!StringsEqualCaseInsensitive(existing.appStore, gv.appStore)) continue;
                    MergeVariantFromSameStore(existing, gv);
                    mergedExistingStore = true;
                    break;
                }
                if (!mergedExistingStore) {
                    g.availableStores.push_back(gv.appStore);
                    g.variants.push_back(gv);
                }
            }
        }
    }


    {
        std::string firstNumericVariant;
        for (auto &v : g.variants) {
            if (v.inLibrary && !v.serviceStatus.empty()) {
                g.isInLibrary = true;
            }
            bool isNumeric = !v.id.empty() && v.id.find_first_not_of("0123456789") == std::string::npos;
            if (isNumeric) {
                if (v.librarySelected) {
                    g.launchAppId = v.id;
                } else if (firstNumericVariant.empty()) {
                    firstNumericVariant = v.id;
                }
            }
        }
        if (g.launchAppId.empty()) {
            g.launchAppId = firstNumericVariant;
        }
    }


    NSArray *genres = app[@"genres"];
    if (genres && [genres isKindOfClass:[NSArray class]]) {
        for (id item in genres) {
            if ([item isKindOfClass:[NSString class]]) {
                AppendUniqueString(g.genres, item);
            } else if ([item isKindOfClass:[NSDictionary class]]) {
                NSString *name = SafeStr(((NSDictionary *)item)[@"name"]);
                AppendUniqueString(g.genres, name);
            }
        }
    }


    NSArray *features = app[@"featureLabels"] ? app[@"featureLabels"] : app[@"features"];
    if (features && [features isKindOfClass:[NSArray class]]) {
        for (id item in features) {
            if ([item isKindOfClass:[NSString class]]) {
                AppendUniqueString(g.featureLabels, item);
            }
        }
    }

    return g;
}





void GameService::postGraphQlJson(const std::string &query,
                                   NSDictionary *variables,
                                   std::function<void(NSDictionary *, NSString *)> completion) {
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"query"] = [NSString stringWithUTF8String:query.c_str()];
    if (variables) {
        body[@"variables"] = variables;
    }

    NSData *jsonBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:m_graphqlURL.c_str()]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 20.0;
    [req setHTTPBody:jsonBody];

    NSDictionary *hdrs = baseHeaders();
    for (NSString *key in hdrs) {
        [req setValue:hdrs[key] forHTTPHeaderField:key];
    }
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSDictionary *payload = nil;
            NSString *message = @"";
            if (error) {
                message = [error localizedDescription];
            } else {
                NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
                NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                if (!http || http.statusCode != 200 || !json) {
                    message = [NSString stringWithFormat:@"GraphQL error (%ld)", (long)(http ? http.statusCode : 0)];
                } else {
                    NSArray *errors = json[@"errors"];
                    if ([errors isKindOfClass:[NSArray class]] && errors.count > 0) {
                        NSDictionary *err = [errors[0] isKindOfClass:[NSDictionary class]] ? errors[0] : nil;
                        NSString *errMsg = [err[@"message"] isKindOfClass:[NSString class]] ? err[@"message"] : nil;
                        message = errMsg ?: @"GraphQL error";
                    } else {
                        NSDictionary *dataPayload = json[@"data"];
                        if ([dataPayload isKindOfClass:[NSDictionary class]]) {
                            payload = dataPayload;
                        } else {
                            message = @"No data in GraphQL response";
                        }
                    }
                }
            }
            DispatchGraphQLCallback(completion, payload, message);
        }];
    [task resume];
}

void GameService::fetchAppMetadata(NSArray<NSString *> *appIds,
                                   NSString *vpcId,
                                   std::function<void(NSDictionary *, NSString *)> completion) {
    NSDictionary *variables = @{
        @"vpcId": vpcId.length > 0 ? vpcId : @"GFN-PC",
        @"locale": [NSString stringWithUTF8String:CurrentGFNLocale().c_str()],
        @"appIds": appIds ?: @[],
    };
    postGraphQL("appMetaData", [kAppMetaDataHash UTF8String], variables, completion);
}

void GameService::ResolveStoreURL(const GameInfo &game, int variantIndex, StoreURLCallback completion) {
    StoreURLCallback callback = completion;
    std::string localStoreURL = StoreURLForKnownGame(game, variantIndex);
    if (!localStoreURL.empty()) {
        DispatchStoreURLCallback(callback, true, localStoreURL, "");
        return;
    }

    std::string appId = game.uuid.empty() ? game.id : game.uuid;
    if (appId.empty()) {
        DispatchStoreURLCallback(callback, false, "", "No app ID available for store URL lookup");
        return;
    }

    std::string token = m_accessToken;
    if (token.empty()) {
        DispatchStoreURLCallback(callback, false, "", "No access token");
        return;
    }

    const GameVariant *selectedVariant = GameVariantAtIndex(game, variantIndex);
    std::string selectedVariantId = selectedVariant ? selectedVariant->id : "";
    std::string selectedStore = selectedVariant ? selectedVariant->appStore : "";

    GetServerVpcId(token, ProviderStreamingBaseUrl(), [this, callback, appId, selectedVariantId, selectedStore](const std::string &vpcId) {
        NSString *appIdString = [NSString stringWithUTF8String:appId.c_str()];
        NSString *vpcIdString = [NSString stringWithUTF8String:vpcId.empty() ? "GFN-PC" : vpcId.c_str()];
        fetchAppMetadata(@[appIdString], vpcIdString,
            [this, callback, appId, selectedVariantId, selectedStore](NSDictionary *metaData, NSString *metaError) {
                if (metaError.length > 0) {
                    DispatchStoreURLCallback(callback, false, "", [metaError UTF8String]);
                    return;
                }

                NSDictionary *apps = metaData[@"apps"];
                NSArray *metadataItems = [apps isKindOfClass:[NSDictionary class]] ? apps[@"items"] : nil;
                if (![metadataItems isKindOfClass:[NSArray class]]) {
                    DispatchStoreURLCallback(callback, false, "", "No app metadata in store URL response");
                    return;
                }

                NSDictionary *metadataApp = nil;
                for (NSDictionary *candidate in metadataItems) {
                    if (![candidate isKindOfClass:[NSDictionary class]]) continue;
                    NSString *candidateId = SafeStr(candidate[@"id"]);
                    if (candidateId.length > 0 && appId == [candidateId UTF8String]) {
                        metadataApp = candidate;
                        break;
                    }
                    if (!metadataApp) metadataApp = candidate;
                }

                if (!metadataApp) {
                    DispatchStoreURLCallback(callback, false, "", "No matching app metadata for store URL lookup");
                    return;
                }

                GameInfo metadataGame = parseGameItem(metadataApp);
                std::string storeURL = StoreURLForMetadataGame(metadataGame, selectedVariantId, selectedStore);
                if (storeURL.empty()) {
                    DispatchStoreURLCallback(callback, false, "", "No store URL found for selected variant");
                    return;
                }
                DispatchStoreURLCallback(callback, true, storeURL, "");
            });
    });
}





void GameService::BrowseCatalogGames(const std::string &searchQuery,
                                     const std::string &sortId,
                                     const std::vector<std::string> &filterIds,
                                     int fetchCount,
                                     CatalogBrowseCallback completion) {
    std::string token = m_accessToken;
    CatalogBrowseCallback callback = completion;
    NSString *catalogLocale = [NSString stringWithUTF8String:CurrentGFNLocale().c_str()];
    OPN::LogInfo(@"[GameService] BrowseCatalogGames start search=%s sort=%s filters=%lu fetchCount=%d", searchQuery.c_str(), sortId.c_str(), (unsigned long)filterIds.size(), fetchCount);
    std::string requestedSortIdForCache = sortId.empty() ? "last_played" : sortId;
    int requestedFetchCountForCache = std::max(24, std::min(fetchCount > 0 ? fetchCount : kDefaultCatalogFetchCount, 200));
    std::string catalogCacheKey = GameDataCache::Shared().CatalogKey(m_userId, searchQuery, requestedSortIdForCache, filterIds, requestedFetchCountForCache);

    CatalogBrowseResult freshCachedResult;
    NSDictionary *freshDefinitions = nil;
    if (GameDataCache::Shared().LoadFreshCatalog(catalogCacheKey, kCatalogCacheFreshSeconds, freshCachedResult) &&
        GameDataCache::Shared().LoadCatalogDefinitions(catalogLocale, kCatalogDefinitionsFreshSeconds, &freshDefinitions)) {
        NSMutableDictionary<NSString *, NSDictionary *> *unusedFilterPayloads = [NSMutableDictionary dictionary];
        ParseCatalogDefinitions(freshDefinitions, freshCachedResult, unusedFilterPayloads);
        OPN::LogInfo(@"[GameService] catalog fresh cache hit key=%s games=%lu", catalogCacheKey.c_str(), (unsigned long)freshCachedResult.games.size());
        DispatchCatalogBrowseCallback(callback, true, freshCachedResult, "");
        return;
    }

    dispatch_async(GameServiceWorkQueue(), ^{
        CatalogBrowseResult cachedResult;
        if (GameDataCache::Shared().LoadCatalog(catalogCacheKey, cachedResult)) {
            OPN::LogInfo(@"[GameService] catalog cache hit key=%s games=%lu", catalogCacheKey.c_str(), (unsigned long)cachedResult.games.size());
            DispatchCatalogBrowseCallback(callback, true, cachedResult, "");
        }
    });

    GetServerVpcId(token, ProviderStreamingBaseUrl(), [this, callback, searchQuery, sortId, filterIds, fetchCount, catalogCacheKey, catalogLocale](const std::string &vpcId) {
        NSString *vpcIdObj = [NSString stringWithUTF8String:vpcId.c_str()];
        std::string requestedSearch = searchQuery;
        std::string requestedSortId = sortId.empty() ? "last_played" : sortId;
        std::vector<std::string> requestedFilterIds = filterIds;
        int requestedFetchCount = std::max(24, std::min(fetchCount > 0 ? fetchCount : kDefaultCatalogFetchCount, 200));
        OPN::LogInfo(@"[GameService] BrowseCatalogGames vpc=%s requestedFetchCount=%d", vpcId.c_str(), requestedFetchCount);

        std::string definitionsQuery = R"(
        query GetFilterGroupAndSortOrderDefinitions($locale: String!) {
            filterGroupDefinitions(language: $locale) {
                id
                label
                filters { id label filters }
            }
            sortOrderDefinitions(language: $locale) { id label orderBy }
        }
        )";

        auto handleDefinitions = [this, callback, vpcIdObj, requestedSearch, requestedSortId, requestedFilterIds, requestedFetchCount, catalogCacheKey, catalogLocale](NSDictionary *definitionsData, NSString *definitionsError) {
                if (definitionsError.length > 0) {
                    OPN::LogError(@"[GameService] catalog definitions failed error=%@", definitionsError);
                    DispatchCatalogBrowseCallback(callback, false, CatalogBrowseResult{}, [definitionsError UTF8String]);
                    return;
                }

                dispatch_async(GameServiceWorkQueue(), ^{
                CatalogBrowseResult result;
                NSMutableDictionary<NSString *, NSDictionary *> *filterPayloadById = [NSMutableDictionary dictionary];
                ParseCatalogDefinitions(definitionsData, result, filterPayloadById);

                CatalogSortOption selectedSort;
                selectedSort.id = "relevance";
                selectedSort.label = "Relevance";
                selectedSort.orderBy = "itemMetadata.relevance:DESC,sortName:ASC";
                for (const CatalogSortOption &option : result.sortOptions) {
                    if (option.id == requestedSortId) { selectedSort = option; break; }
                }

                NSMutableDictionary *filters = [NSMutableDictionary dictionary];
                for (const std::string &filterId : requestedFilterIds) {
                    NSString *key = [NSString stringWithUTF8String:filterId.c_str()];
                    NSDictionary *payload = filterPayloadById[key];
                    if (!payload) continue;
                    DeepMergeDictionaryInto(filters, payload);
                    result.selectedFilterIds.push_back(filterId);
                }

                NSString *trimmedSearch = [[NSString stringWithUTF8String:requestedSearch.c_str()]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                result.searchQuery = trimmedSearch.length > 0 ? [trimmedSearch UTF8String] : "";
                result.selectedSortId = selectedSort.id;

        std::string query = R"(
        query GetFilterBrowseResults(
            $vpcId: String!,
            $locale: String!,
            $sortString: String!,
            $fetchCount: Int!,
            $cursor: String!,
            $filters: AppFilterFields!
        ) {
            apps(
                vpcId: $vpcId,
                language: $locale,
                orderBy: $sortString,
                first: $fetchCount,
                after: $cursor,
                filters: $filters
            ) {
                numberReturned
                numberSupported
                pageInfo { hasNextPage endCursor totalCount }
                items {
                    id
                    title
                    images { KEY_ART KEY_IMAGE GAME_BOX_ART TV_BANNER HERO_IMAGE MARQUEE_HERO_IMAGE FEATURE_IMAGE SCREENSHOTS }
                    variants {
                        id
                        appStore
                        storeUrl
                        supportedControls
                        gfn { status library { status selected } }
                    }
                    gfn { playabilityState minimumMembershipTierLabel catalogSkuStrings { SKU_BASED_TAG } }
                    itemMetadata { campaignIds }
                }
            }
        }
        )";

                std::string searchQueryText = R"(
        query GetSearchFilterResults(
            $vpcId: String!,
            $locale: String!,
            $sortString: String!,
            $fetchCount: Int!,
            $cursor: String!,
            $searchString: String!,
            $filters: AppFilterFields!
        ) {
            apps(
                vpcId: $vpcId,
                language: $locale,
                orderBy: $sortString,
                first: $fetchCount,
                after: $cursor,
                searchQuery: $searchString,
                filters: $filters
            ) {
                numberReturned
                numberSupported
                pageInfo { hasNextPage endCursor totalCount }
                items {
                    id
                    title
                    images { KEY_ART KEY_IMAGE GAME_BOX_ART TV_BANNER HERO_IMAGE MARQUEE_HERO_IMAGE FEATURE_IMAGE SCREENSHOTS }
                    variants {
                        id
                        appStore
                        storeUrl
                        supportedControls
                        gfn { status library { status selected } }
                    }
                    gfn { playabilityState minimumMembershipTierLabel catalogSkuStrings { SKU_BASED_TAG } }
                    itemMetadata { campaignIds }
                }
            }
        }
        )";

                std::string selectedQuery = result.searchQuery.empty() ? query : searchQueryText;
                NSString *sortString = [NSString stringWithUTF8String:selectedSort.orderBy.c_str()];
                NSMutableArray<NSDictionary *> *collectedApps = [NSMutableArray array];
                auto blockResult = std::make_shared<CatalogBrowseResult>(result);
                auto page = std::make_shared<NSInteger>(0);
                auto cursor = std::make_shared<NSString *>(@"");
                GameService *service = this;
                auto fetchPage = std::make_shared<std::function<void(void)>>();
                std::weak_ptr<std::function<void(void)>> weakFetchPage = fetchPage;

                *fetchPage = [=] {
                    NSMutableDictionary *vars = [@{
                        @"vpcId": vpcIdObj,
                        @"locale": catalogLocale,
                        @"sortString": sortString,
                        @"fetchCount": @(requestedFetchCount),
                        @"cursor": *cursor ?: @"",
                        @"filters": filters,
                    } mutableCopy];
                    if (trimmedSearch.length > 0) vars[@"searchString"] = trimmedSearch;

                    auto keepPaginationAlive = weakFetchPage.lock();
                 service->postGraphQlJson(selectedQuery, vars, ^(NSDictionary *data, NSString *error) {
                        (void)keepPaginationAlive;
                        dispatch_async(GameServiceWorkQueue(), ^{
                        if (error.length > 0) {
                            OPN::LogError(@"[GameService] catalog page failed page=%ld error=%@", (long)*page, error);
                            DispatchCatalogBrowseCallback(callback, false, CatalogBrowseResult{}, [error UTF8String]);
                            return;
                        }
                        NSDictionary *appsDict = data[@"apps"];
                        if (![appsDict isKindOfClass:[NSDictionary class]]) {
                            DispatchCatalogBrowseCallback(callback, false, CatalogBrowseResult{}, "No apps data");
                            return;
                        }
                        NSArray *items = appsDict[@"items"];
                        if ([items isKindOfClass:[NSArray class]]) [collectedApps addObjectsFromArray:items];
                        blockResult->numberReturned += SafeInt(appsDict[@"numberReturned"]);
                        blockResult->numberSupported = SafeInt(appsDict[@"numberSupported"]);
                        NSDictionary *pageInfo = appsDict[@"pageInfo"];
                        BOOL hasNextPage = [pageInfo isKindOfClass:[NSDictionary class]] && [pageInfo[@"hasNextPage"] boolValue];
                        NSString *endCursor = [pageInfo isKindOfClass:[NSDictionary class]] ? SafeStr(pageInfo[@"endCursor"]) : nil;
                        blockResult->totalCount = [pageInfo isKindOfClass:[NSDictionary class]] ? SafeInt(pageInfo[@"totalCount"]) : blockResult->totalCount;
                        blockResult->hasNextPage = hasNextPage;
                        if (endCursor.length > 0) blockResult->endCursor = [endCursor UTF8String];
                        OPN::LogInfo(@"[GameService] catalog page=%ld items=%lu collected=%lu returned=%d total=%d hasNext=%d", (long)*page, (unsigned long)([items isKindOfClass:[NSArray class]] ? items.count : 0), (unsigned long)collectedApps.count, blockResult->numberReturned, blockResult->totalCount, hasNextPage);

                        (*page)++;
                        if (hasNextPage && endCursor.length > 0 && *page < kMaxCatalogPages) {
                            *cursor = endCursor;
                            if (auto nextPage = weakFetchPage.lock()) {
                                (*nextPage)();
                                return;
                            }
                        }

                        NSMutableArray<NSString *> *appIdsNeedingMetadata = [NSMutableArray array];
                        NSMutableSet<NSString *> *seenMetadataIds = [NSMutableSet set];
                        for (NSDictionary *app in collectedApps) {
                            if (![app isKindOfClass:[NSDictionary class]]) continue;
                            GameInfo g = service->parseGameItem(app);
                            if (!g.id.empty() && !g.title.empty() && HasVisibleVariants(g)) {
                                if (!g.uuid.empty()) {
                                    NSString *uuid = [NSString stringWithUTF8String:g.uuid.c_str()];
                                    if (![seenMetadataIds containsObject:uuid]) {
                                        [seenMetadataIds addObject:uuid];
                                        [appIdsNeedingMetadata addObject:uuid];
                                    }
                                }
                                blockResult->games.push_back(g);
                                OPN::LogInfo(@"[GameService] parsed catalog game title=%@ id=%s uuid=%s desc=%d image=%d hero=%d variants=%lu", NSStringFromStdString(g.title, @"<untitled>"), g.id.c_str(), g.uuid.c_str(), !g.description.empty(), !g.imageUrl.empty(), !g.heroImageUrl.empty(), (unsigned long)g.variants.size());
                            }
                        }
                        blockResult->numberSupported = std::max(blockResult->numberSupported, (int)blockResult->games.size());
                        blockResult->totalCount = std::max(blockResult->totalCount, (int)blockResult->games.size());
                        if (appIdsNeedingMetadata.count == 0) {
                            OPN::LogInfo(@"[GameService] catalog no metadata enrichment needed games=%lu", (unsigned long)blockResult->games.size());
                            CatalogBrowseResult resultToDeliver = *blockResult;
                            dispatch_async(GameServiceWorkQueue(), ^{
                                GameDataCache::Shared().SaveCatalog(catalogCacheKey, resultToDeliver);
                                DispatchCatalogBrowseCallback(callback, true, resultToDeliver, "");
                            });
                            return;
                        }
                        OPN::LogInfo(@"[GameService] metadata enrichment start ids=%lu chunks=%lu", (unsigned long)appIdsNeedingMetadata.count, (unsigned long)((appIdsNeedingMetadata.count + 40 - 1) / 40));

                        NSMutableDictionary<NSString *, NSDictionary *> *metadataById = [NSMutableDictionary dictionary];
                        NSUInteger chunkSize = 40;
                        NSUInteger totalChunks = (appIdsNeedingMetadata.count + chunkSize - 1) / chunkSize;
                        __block NSUInteger completedChunks = 0;
                        auto mergeAndFinish = ^{
                                NSUInteger enrichedDescriptions = 0;
                                NSUInteger enrichedImages = 0;
                                for (OPN::GameInfo &game : blockResult->games) {
                                    if (game.uuid.empty()) continue;
                                    NSString *uuid = [NSString stringWithUTF8String:game.uuid.c_str()];
                                    NSDictionary *metadataApp = metadataById[uuid];
                                    if (!metadataApp) continue;
                                    GameInfo metadataGame = service->parseGameItem(metadataApp);
                                    MergeMissingStoreMetadata(game, metadataGame);
                                    if (!metadataGame.description.empty()) {
                                        game.description = metadataGame.description;
                                        enrichedDescriptions++;
                                    }
                                    if (game.genres.empty() && !metadataGame.genres.empty()) {
                                        game.genres = metadataGame.genres;
                                    }
                                    if (game.featureLabels.empty() && !metadataGame.featureLabels.empty()) {
                                        game.featureLabels = metadataGame.featureLabels;
                                    }
                                    if (game.developerName.empty()) game.developerName = metadataGame.developerName;
                                    if (game.publisherName.empty()) game.publisherName = metadataGame.publisherName;
                                    if (game.imageUrl.empty()) game.imageUrl = metadataGame.imageUrl;
                                    if (game.heroImageUrl.empty()) game.heroImageUrl = metadataGame.heroImageUrl;
                                    if (!metadataGame.screenshotUrls.empty()) game.screenshotUrls = metadataGame.screenshotUrls;
                                    if (!metadataGame.imageUrlsByType.empty()) game.imageUrlsByType = metadataGame.imageUrlsByType;
                                    if (!metadataGame.imageUrl.empty() || !metadataGame.heroImageUrl.empty()) enrichedImages++;
                                    if (game.maxLocalPlayers <= 0) game.maxLocalPlayers = metadataGame.maxLocalPlayers;
                                    if (game.maxOnlinePlayers <= 0) game.maxOnlinePlayers = metadataGame.maxOnlinePlayers;
                                    if (game.supportedControls.empty()) game.supportedControls = metadataGame.supportedControls;
                                    if (game.contentRatings.empty()) game.contentRatings = metadataGame.contentRatings;
                                    if (game.nvidiaTech.empty()) game.nvidiaTech = metadataGame.nvidiaTech;
                                }
                                OPN::LogInfo(@"[GameService] metadata enrichment complete games=%lu descriptions=%lu imageRecords=%lu", (unsigned long)blockResult->games.size(), (unsigned long)enrichedDescriptions, (unsigned long)enrichedImages);
                                CatalogBrowseResult resultToDeliver = *blockResult;
                                dispatch_async(GameServiceWorkQueue(), ^{
                                    GameDataCache::Shared().SaveCatalog(catalogCacheKey, resultToDeliver);
                                    DispatchCatalogBrowseCallback(callback, true, resultToDeliver, "");
                                });
                        };

                        for (NSUInteger start = 0; start < appIdsNeedingMetadata.count; start += chunkSize) {
                            NSUInteger length = MIN(chunkSize, appIdsNeedingMetadata.count - start);
                            NSArray<NSString *> *chunk = [appIdsNeedingMetadata subarrayWithRange:NSMakeRange(start, length)];
                            service->fetchAppMetadata(chunk, vpcIdObj,
                                ^(NSDictionary *metaData, NSString *metaError) {
                                    dispatch_async(GameServiceWorkQueue(), ^{
                                    if (metaError.length > 0) {
                                        OPN::LogError(@"[GameService] appMetaData enrichment failed: %@", metaError);
                                    }
                                    NSDictionary *apps = metaData[@"apps"];
                                    NSArray *metadataItems = [apps isKindOfClass:[NSDictionary class]] ? apps[@"items"] : nil;
                                    if ([metadataItems isKindOfClass:[NSArray class]]) {
                                        OPN::LogInfo(@"[GameService] metadata chunk returned start=%lu count=%lu", (unsigned long)start, (unsigned long)metadataItems.count);
                                        for (NSDictionary *metadataApp in metadataItems) {
                                            if (![metadataApp isKindOfClass:[NSDictionary class]]) continue;
                                            NSString *appId = SafeStr(metadataApp[@"id"]);
                                            if (appId.length > 0) metadataById[appId] = metadataApp;
                                        }
                                    }
                                    completedChunks++;
                                    if (completedChunks >= totalChunks) mergeAndFinish();
                                    });
                                });
                        }
                        });
                    });
                };
                (*fetchPage)();
                });
            };

        NSDictionary *cachedDefinitions = nil;
        if (GameDataCache::Shared().LoadCatalogDefinitions(catalogLocale, kCatalogDefinitionsFreshSeconds, &cachedDefinitions)) {
            OPN::LogInfo(@"[GameService] catalog definitions cache hit locale=%@", catalogLocale);
            dispatch_async(GameServiceWorkQueue(), ^{
                handleDefinitions(cachedDefinitions, @"");
            });
        } else {
            postGraphQlJson(definitionsQuery, @{@"locale": catalogLocale},
                [handleDefinitions, catalogLocale](NSDictionary *definitionsData, NSString *definitionsError) {
                    if (definitionsError.length == 0 && [definitionsData isKindOfClass:[NSDictionary class]]) {
                        GameDataCache::Shared().SaveCatalogDefinitions(catalogLocale, definitionsData);
                    }
                    handleDefinitions(definitionsData, definitionsError);
                });
        }
    });
}

void GameService::FetchCatalogGames(CatalogCallback completion) {
    BrowseCatalogGames("", "relevance", {}, 200,
        [completion](bool success, const CatalogBrowseResult &result, const std::string &error) {
            completion(success, result.games, error);
        });
}





void GameService::FetchPublicGames(CatalogCallback completion) {
    auto locales = std::make_shared<std::vector<std::string>>(CurrentGFNLocaleURLPathComponentFallbacks());
    if (locales->empty()) locales->push_back("en-US");
    auto fetchLocale = std::make_shared<std::function<void(size_t)>>();
    *fetchLocale = [completion, locales, fetchLocale](size_t index) {
        if (index >= locales->size()) {
            DispatchCatalogCallback(completion, false, {}, "No public game locale fallback succeeded");
            return;
        }

        NSString *publicLocale = [NSString stringWithUTF8String:(*locales)[index].c_str()];
        NSURL *url = [NSURL URLWithString:
            [NSString stringWithFormat:@"https://static.nvidiagrid.net/supported-public-game-list/locales/gfnpc-%@.json", publicLocale]];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.timeoutInterval = 20.0;
        [req setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
   forHTTPHeaderField:@"User-Agent"];

        NSURLSessionDataTask *task = [[NSURLSession sharedSession]
            dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *, NSError *error) {
                dispatch_async(GameServiceWorkQueue(), ^{
                    NSArray *json = (!error && data) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                    if (![json isKindOfClass:[NSArray class]]) {
                        if (index + 1 < locales->size()) {
                            OPN::LogInfo(@"[GameService] public games locale %@ unavailable; trying fallback", publicLocale);
                            (*fetchLocale)(index + 1);
                            return;
                        }
                        NSString *localizedError = error ? [error localizedDescription] : nil;
                        std::string message = localizedError.length > 0 ? [localizedError UTF8String] : "Invalid public games JSON";
                        DispatchCatalogCallback(completion, false, {}, message);
                        return;
                    }

                    std::vector<GameInfo> games;
                    for (id item in json) {
                        if (![item isKindOfClass:[NSDictionary class]]) continue;
                        NSString *status = item[@"status"];
                        if (![status isEqualToString:@"AVAILABLE"]) continue;
                        NSString *title = item[@"title"];
                        if (![title isKindOfClass:[NSString class]] || title.length == 0) continue;

                        GameInfo g;
                        g.title = [title UTF8String];
                        { NSString *v = FirstSafeString(item, @[@"description", @"longDescription", @"shortDescription", @"summary"]); g.description = v ? [v UTF8String] : ""; }
                        id rawId = item[@"id"];
                        NSString *sid = [rawId isKindOfClass:[NSNumber class]]
                            ? [(NSNumber *)rawId stringValue]
                            : ([rawId isKindOfClass:[NSString class]] ? (NSString *)rawId : title);

                        NSString *steamAppId = nil;
                        NSString *steamUrl = item[@"steamUrl"];
                        if ([steamUrl isKindOfClass:[NSString class]]) {
                            NSArray *parts = [steamUrl componentsSeparatedByString:@"/app/"];
                            if (parts.count >= 2) {
                                steamAppId = [parts[1] componentsSeparatedByString:@"/"][0];
                            }
                        }
                        NSString *finalAppId = (steamAppId && steamAppId.length > 0)
                            ? steamAppId
                            : ([sid length] > 0 ? sid : title);
                        g.id = [finalAppId UTF8String];
                        g.uuid = [sid UTF8String];
                        if ([steamUrl isKindOfClass:[NSString class]]) {
                            NSString *steamAppId = nil;
                            NSArray *parts = [steamUrl componentsSeparatedByString:@"/app/"];
                            if (parts.count >= 2) {
                                steamAppId = [parts[1] componentsSeparatedByString:@"/"][0];
                            }
                            if (steamAppId && steamAppId.length > 0) {
                                NSString *heroUrl = [NSString stringWithFormat:
                                    @"https://cdn.cloudflare.steamstatic.com/steam/apps/%@/library_hero.jpg",
                                    steamAppId];
                                NSString *imgUrl = [NSString stringWithFormat:
                                    @"https://cdn.cloudflare.steamstatic.com/steam/apps/%@/header.jpg",
                                    steamAppId];
                                g.heroImageUrl = [heroUrl UTF8String];
                                g.imageUrl = [imgUrl UTF8String];
                            }
                        }

                        games.push_back(g);
                    }
                    DispatchCatalogCallback(completion, true, games, "");
                });
            }];
        [task resume];
    };
    (*fetchLocale)(0);
}

void GameService::FetchSubscriptionInfo(const std::string &userId, SubscriptionCallback completion) {
    if (m_accessToken.empty()) {
        DispatchSubscriptionCallback(completion, false, SubscriptionInfo{}, "No access token");
        return;
    }
    if (userId.empty()) {
        DispatchSubscriptionCallback(completion, false, SubscriptionInfo{}, "No user ID");
        return;
    }

    std::string token = m_accessToken;
    SubscriptionCallback callback = completion;
    GetServerVpcId(token, ProviderStreamingBaseUrl(), [token, userId, callback](const std::string &vpcId) {
        const std::string subscriptionVpcId = vpcId == "GFN-PC" ? kDefaultSubscriptionVpcId : vpcId;
        NSURLComponents *components = [NSURLComponents componentsWithString:@"https://mes.geforcenow.com/v4/subscriptions"];
        components.queryItems = @[
            [NSURLQueryItem queryItemWithName:@"serviceName" value:@"gfn_pc"],
            [NSURLQueryItem queryItemWithName:@"languageCode" value:[NSString stringWithUTF8String:CurrentGFNLocale().c_str()]],
            [NSURLQueryItem queryItemWithName:@"vpcId" value:[NSString stringWithUTF8String:subscriptionVpcId.c_str()]],
            [NSURLQueryItem queryItemWithName:@"userId" value:[NSString stringWithUTF8String:userId.c_str()]],
        ];
        NSURL *url = components.URL;
        if (!url) {
            DispatchSubscriptionCallback(callback, false, SubscriptionInfo{}, "Invalid subscription URL");
            return;
        }

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"GET";
        req.timeoutInterval = 20.0;
        [req setValue:[NSString stringWithFormat:@"GFNJWT %s", token.c_str()] forHTTPHeaderField:@"Authorization"];
        [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [req setValue:kNvClientId forHTTPHeaderField:@"nv-client-id"];
        [req setValue:@"NATIVE" forHTTPHeaderField:@"nv-client-type"];
        [req setValue:kNvClientVersion forHTTPHeaderField:@"nv-client-version"];
        [req setValue:@"NVIDIA-CLASSIC" forHTTPHeaderField:@"nv-client-streamer"];
        [req setValue:@"MACOS" forHTTPHeaderField:@"nv-device-os"];
        [req setValue:@"DESKTOP" forHTTPHeaderField:@"nv-device-type"];

        NSURLSessionDataTask *task = [[NSURLSession sharedSession]
            dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                dispatch_async(GameServiceWorkQueue(), ^{
                    if (error) {
                        DispatchSubscriptionCallback(callback, false, SubscriptionInfo{}, [[error localizedDescription] UTF8String]);
                        return;
                    }
                    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
                    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                    if (http.statusCode != 200 || ![json isKindOfClass:[NSDictionary class]]) {
                        NSString *message = [NSString stringWithFormat:@"Subscription API failed (%ld)", (long)http.statusCode];
                        DispatchSubscriptionCallback(callback, false, SubscriptionInfo{}, [message UTF8String]);
                        return;
                    }

                    SubscriptionInfo info;
                    NSString *tier = SafeStr(json[@"membershipTier"]);
                    info.membershipTier = tier.length > 0 ? [tier UTF8String] : "Free";
                    NSString *type = SafeStr(json[@"type"]);
                    if (type.length > 0) info.subscriptionType = [type UTF8String];
                    NSString *subType = SafeStr(json[@"subType"]);
                    if (subType.length > 0) info.subscriptionSubType = [subType UTF8String];
                    info.allottedHours = SafeMinutesAsHours(json[@"allottedTimeInMinutes"]);
                    info.purchasedHours = SafeMinutesAsHours(json[@"purchasedTimeInMinutes"]);
                    info.rolledOverHours = SafeMinutesAsHours(json[@"rolledOverTimeInMinutes"]);
                    double fallbackTotal = info.allottedHours + info.purchasedHours + info.rolledOverHours;
                    info.totalHours = SafeMinutesAsHours(json[@"totalTimeInMinutes"]);
                    if (info.totalHours <= 0) info.totalHours = fallbackTotal;
                    info.remainingHours = SafeMinutesAsHours(json[@"remainingTimeInMinutes"]);
                    info.usedHours = std::max(0.0, info.totalHours - info.remainingHours);
                    info.isUnlimited = info.subscriptionSubType == "UNLIMITED";
                    NSDictionary *state = [json[@"currentSubscriptionState"] isKindOfClass:[NSDictionary class]]
                        ? json[@"currentSubscriptionState"]
                        : nil;
                    NSNumber *allowed = [state[@"isGamePlayAllowed"] isKindOfClass:[NSNumber class]] ? state[@"isGamePlayAllowed"] : nil;
                    info.isGamePlayAllowed = allowed ? allowed.boolValue : true;
                    DispatchSubscriptionCallback(callback, true, info, "");
                });
            }];
        [task resume];
    });
}





static void GetServerVpcId(const std::string &token,
                            const std::string &providerStreamingBaseUrl,
                            std::function<void(const std::string &vpcId)> completion) {
    std::string normalized = NormalizeStreamingBaseUrl(providerStreamingBaseUrl);
    NSString *urlString = [NSString stringWithFormat:@"%sv2/serverInfo", normalized.c_str()];
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [req setValue:[NSString stringWithFormat:@"GFNJWT %s", token.c_str()] forHTTPHeaderField:@"Authorization"];
    [req setValue:kNvClientId forHTTPHeaderField:@"nv-client-id"];
    [req setValue:@"NATIVE" forHTTPHeaderField:@"nv-client-type"];
    [req setValue:kNvClientVersion forHTTPHeaderField:@"nv-client-version"];
    [req setValue:@"NVIDIA-CLASSIC" forHTTPHeaderField:@"nv-client-streamer"];
    [req setValue:@"MACOS" forHTTPHeaderField:@"nv-device-os"];
    [req setValue:@"DESKTOP" forHTTPHeaderField:@"nv-device-type"];
    [req setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173" forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            completion("GFN-PC");
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode != 200) {
            completion("GFN-PC");
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *serverId = json[@"requestStatus"][@"serverId"];
        if (![serverId isKindOfClass:[NSString class]] || serverId.length == 0) {
            completion("GFN-PC");
            return;
        }
        completion([serverId UTF8String]);
    }] resume];
}





void GameService::FetchLibraryGames(CatalogCallback completion) {
    std::string token = m_accessToken;
    CatalogCallback callback = completion;

    GetServerVpcId(token, ProviderStreamingBaseUrl(), [this, callback, token](const std::string &vpcId) {
        NSString *vpcIdObj = [NSString stringWithUTF8String:vpcId.c_str()];
        NSDictionary *vars = @{
            @"vpcId": vpcIdObj,
            @"locale": [NSString stringWithUTF8String:CurrentGFNLocale().c_str()],
            @"panelNames": @[@"LIBRARY"]
        };

        auto flattenAndEnrich = ^(NSDictionary *data, NSString *error) {
            if (error.length > 0) {
                DispatchCatalogCallback(callback, false, {}, [error UTF8String]);
                return;
            }

            NSArray *rawPanels = data[@"panels"];
            if (![rawPanels isKindOfClass:[NSArray class]]) {
                DispatchCatalogCallback(callback, false, {}, "No panels in library response");
                return;
            }

            std::vector<GameInfo> games;
            for (NSDictionary *p in rawPanels) {
                if (![p isKindOfClass:[NSDictionary class]]) continue;
                NSArray *sections = p[@"sections"];
                if (![sections isKindOfClass:[NSArray class]]) continue;
                for (NSDictionary *sec in sections) {
                    if (![sec isKindOfClass:[NSDictionary class]]) continue;
                    NSArray *items = sec[@"items"];
                    if (![items isKindOfClass:[NSArray class]]) continue;
                    for (NSDictionary *item in items) {
                        if (![item isKindOfClass:[NSDictionary class]]) continue;
                        if (![item[@"__typename"] isEqualToString:@"GameItem"]) continue;
                        NSDictionary *app = item[@"app"];
                        if (!app) continue;
                        GameInfo g = parseGameItem(app);
                        if (!g.id.empty() && !g.title.empty() && HasVisibleVariants(g)) {
                            games.push_back(g);
                        }
                    }
                }
            }

            if (games.empty()) {
                DispatchCatalogCallback(callback, true, games, "");
                return;
            }


            NSMutableArray<NSString *> *uuids = [NSMutableArray array];
            NSMutableSet *seen = [NSMutableSet set];
            for (auto &g : games) {
                if (!g.uuid.empty()) {
                    NSString *uuidStr = [NSString stringWithUTF8String:g.uuid.c_str()];
                    if (![seen containsObject:uuidStr]) {
                        [seen addObject:uuidStr];
                        [uuids addObject:uuidStr];
                    }
                }
            }

            if (uuids.count == 0) {
                DispatchCatalogCallback(callback, true, games, "");
                return;
            }

            NSMutableDictionary *appById = [NSMutableDictionary dictionary];
            NSUInteger chunkSize = 40;
            __block NSUInteger chunksCompleted = 0;
            NSUInteger totalChunks = (uuids.count + chunkSize - 1) / chunkSize;

            for (NSUInteger i = 0; i < uuids.count; i += chunkSize) {
                NSUInteger end = MIN(i + chunkSize, uuids.count);
                NSArray<NSString *> *chunk = [uuids subarrayWithRange:NSMakeRange(i, end - i)];
                fetchAppMetadata(chunk, vpcIdObj,
                    ^(NSDictionary *metaData, NSString *metaError) {
                        if (metaError.length == 0) {
                            NSDictionary *appsDict = metaData[@"apps"];
                            NSArray *items = [appsDict isKindOfClass:[NSDictionary class]] ? appsDict[@"items"] : nil;
                            if ([items isKindOfClass:[NSArray class]]) {
                                for (NSDictionary *app in items) {
                                    if (![app isKindOfClass:[NSDictionary class]]) continue;
                                    NSString *aid = SafeStr(app[@"id"]);
                                    if (aid) appById[aid] = app;
                                }
                            }
                        }
                        chunksCompleted++;
                        if (chunksCompleted >= totalChunks) {

                            std::vector<GameInfo> enriched;
                            for (auto &g : games) {
                                NSString *uuidStr = [NSString stringWithUTF8String:g.uuid.c_str()];
                                NSDictionary *meta = appById[uuidStr];
                                if (meta) {
                                    GameInfo merged = parseGameItem(meta);
                                    if (merged.imageUrl.empty() && !g.imageUrl.empty())
                                        merged.imageUrl = g.imageUrl;
                                    if (merged.heroImageUrl.empty() && !g.heroImageUrl.empty())
                                        merged.heroImageUrl = g.heroImageUrl;
                                    if (merged.screenshotUrls.empty() && !g.screenshotUrls.empty())
                                        merged.screenshotUrls = g.screenshotUrls;
                                    if (merged.imageUrlsByType.empty() && !g.imageUrlsByType.empty())
                                        merged.imageUrlsByType = g.imageUrlsByType;
                                    if (merged.description.empty() && !g.description.empty())
                                        merged.description = g.description;
                                    if (merged.variants.empty())
                                        merged.variants = g.variants;
                                    merged.isInLibrary = g.isInLibrary;
                                    if (HasVisibleVariants(merged)) {
                                        enriched.push_back(merged);
                                    }
                                } else {
                                    enriched.push_back(g);
                                }
                            }


                            std::unordered_map<std::string, GameInfo> byId;
                            for (auto &g : enriched) {
                                auto it = byId.find(g.id);
                                if (it == byId.end()) {
                                    byId[g.id] = g;
                                } else {
                                    GameInfo &existing = it->second;
                                    std::unordered_set<std::string> seenVariants;
                                    for (auto &v : existing.variants)
                                        seenVariants.insert(v.id);
                                    for (auto &v : g.variants) {
                                        if (seenVariants.find(v.id) == seenVariants.end()) {
                                            existing.variants.push_back(v);
                                            seenVariants.insert(v.id);
                                        }
                                    }
                                    if (existing.title.empty()) existing.title = g.title;
                                    if (existing.imageUrl.empty()) existing.imageUrl = g.imageUrl;
                                    if (existing.heroImageUrl.empty()) existing.heroImageUrl = g.heroImageUrl;
                                    if (!g.screenshotUrls.empty()) existing.screenshotUrls = g.screenshotUrls;
                                    for (const auto &imageEntry : g.imageUrlsByType) {
                                        if (existing.imageUrlsByType.find(imageEntry.first) == existing.imageUrlsByType.end()) {
                                            existing.imageUrlsByType[imageEntry.first] = imageEntry.second;
                                        }
                                    }
                                    if (existing.description.empty()) existing.description = g.description;
                                }
                            }
                            std::vector<GameInfo> finalGames;
                            for (auto &kv : byId) {
                                if (HasVisibleVariants(kv.second)) {
                                    finalGames.push_back(kv.second);
                                }
                            }
                            DispatchCatalogCallback(callback, true, finalGames, "");
                        }
                    });
            }
        };

        postGraphQL("panels/Library", [kLibraryWithTimeHash UTF8String], vars,
            ^(NSDictionary *data, NSString *error) {
                if (error.length == 0) {
                    flattenAndEnrich(data, error);
                } else {
                    postGraphQL("panels/Library", [kPanelsHash UTF8String], vars, flattenAndEnrich);
                }
            });
    });
}





std::string GameService::OptimizeImageURL(const std::string &url, int width) {
    if (url.empty()) return url;
    if (url.find("img.nvidiagrid.net") != std::string::npos) {
        return url + ";f=webp;w=" + std::to_string(width);
    }
    return url;
}





std::vector<PanelResult> GameService::parsePanelResults(NSArray *rawPanels) {
    std::vector<PanelResult> panels;
    for (NSDictionary *p in rawPanels) {
        if (![p isKindOfClass:[NSDictionary class]]) continue;
        PanelResult pr;
        { NSString *v = SafeStr(p[@"id"]); pr.id = v ? [v UTF8String] : ""; }
        { NSString *v = SafeStr(p[@"name"]); pr.title = v ? [v UTF8String] : ""; }
        if (pr.id.empty()) pr.id = pr.title;

        NSArray *sections = p[@"sections"];
        if (!sections || ![sections isKindOfClass:[NSArray class]]) continue;

        for (NSDictionary *sec in sections) {
            if (![sec isKindOfClass:[NSDictionary class]]) continue;
            PanelSection ps;
            { NSString *v = SafeStr(sec[@"id"]); ps.id = v ? [v UTF8String] : ""; }
            { NSString *v = SafeStr(sec[@"title"]); ps.title = v ? [v UTF8String] : ""; }

            NSArray *items = sec[@"items"];
            if (!items || ![items isKindOfClass:[NSArray class]]) continue;

            for (NSDictionary *item in items) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSString *type = SafeStr(item[@"__typename"]);
                if (![type isEqualToString:@"GameItem"]) continue;

                NSDictionary *app = item[@"app"];
                if (![app isKindOfClass:[NSDictionary class]]) continue;

                GameInfo game = parseGameItem(app);
                if (!game.id.empty() && !game.title.empty() && HasVisibleVariants(game)) {
                    ps.games.push_back(game);
                }
            }

            if (!ps.games.empty()) {
                pr.sections.push_back(ps);
            }
        }

        if (!pr.sections.empty()) {
            panels.push_back(pr);
        }
    }
    return panels;
}

void GameService::FetchMarqueePanels(PanelCallback completion) {
    std::string token = m_accessToken;
    PanelCallback callback = completion;

    GetServerVpcId(token, ProviderStreamingBaseUrl(), [this, callback](const std::string &vpcId) {
        NSString *vpcIdObj = [NSString stringWithUTF8String:vpcId.c_str()];
        NSDictionary *vars = @{
            @"vpcId": vpcIdObj,
            @"locale": [NSString stringWithUTF8String:CurrentGFNLocale().c_str()],
            @"panelNames": @[@"MARQUEE"]
        };

        postGraphQL("panels/Marquee", [kMarqueeHash UTF8String], vars,
            ^(NSDictionary *data, NSString *error) {
                if (error.length > 0) {
                    DispatchPanelCallback(callback, false, {}, [error UTF8String]);
                    return;
                }

                NSArray *rawPanels = data[@"panels"];
                if (!rawPanels || ![rawPanels isKindOfClass:[NSArray class]]) {
                    DispatchPanelCallback(callback, false, {}, "No panels in marquee response");
                    return;
                }

                DispatchPanelCallback(callback, true, this->parsePanelResults(rawPanels), "");
            });
    });
}




void GameService::FetchMainPanels(PanelCallback completion) {
    std::string token = m_accessToken;
    PanelCallback callback = completion;

    GetServerVpcId(token, ProviderStreamingBaseUrl(), [this, callback](const std::string &vpcId) {
        NSString *vpcIdObj = [NSString stringWithUTF8String:vpcId.c_str()];
        NSDictionary *vars = @{
            @"vpcId": vpcIdObj,
            @"locale": [NSString stringWithUTF8String:CurrentGFNLocale().c_str()],
            @"panelNames": @[@"MAIN"]
        };

        postGraphQL("panels/MainV2", [kPanelsHash UTF8String], vars,
            ^(NSDictionary *data, NSString *error) {
                if (error.length > 0) {
                    DispatchPanelCallback(callback, false, {}, [error UTF8String]);
                    return;
                }

                NSArray *rawPanels = data[@"panels"];
                if (!rawPanels || ![rawPanels isKindOfClass:[NSArray class]]) {
                    DispatchPanelCallback(callback, false, {}, "No panels in response");
                    return;
                }

                DispatchPanelCallback(callback, true, this->parsePanelResults(rawPanels), "");
            });
    });
}

static bool IsSessionReadyStatus(int status) {
    return status == 2 || status == 3;
}

static bool IsSessionLaunchProgressPending(const SessionInfo &session) {
    if (session.status != 1) return false;
    if (session.adState.isAdsRequired || session.queuePosition > 0 || session.seatSetupStep > 0) return true;
    return session.progressState == SessionProgressState::Connecting ||
           session.progressState == SessionProgressState::InQueue ||
           session.progressState == SessionProgressState::PreviousSessionCleanup ||
           session.progressState == SessionProgressState::WaitingForStorage ||
           session.progressState == SessionProgressState::SettingUp;
}

static SessionInfo SessionWithoutQueueBadge(SessionInfo session) {
    session.queuePosition = 0;
    return session;
}

static std::string QueueProgressMessage(int queuePosition) {
    if (queuePosition > 2) {
        return std::to_string(queuePosition - 1) + " gamers ahead of you.";
    }
    if (queuePosition == 2) {
        return "1 gamer ahead of you.";
    }
    if (queuePosition == 1) {
        return "You're next in queue.";
    }
    return "Waiting in queue...";
}

static std::string ProgressMessageForSession(const SessionInfo &session) {
    if (session.adState.isAdsRequired) {
        if (!session.adState.message.empty()) return session.adState.message;
        return session.adState.isQueuePaused ? "Session queue paused for ads." : "Ad playback is required while waiting in queue.";
    }
    if (session.status == 6) {
        return "Previous session is ending. Waiting for GeForce NOW to finish cleanup...";
    }

    switch (session.progressState) {
        case SessionProgressState::PreviousSessionCleanup:
            return "Previous session is ending. Waiting for GeForce NOW to finish cleanup...";
        case SessionProgressState::WaitingForStorage:
            return "Waiting for cloud storage to be ready...";
        case SessionProgressState::InQueue:
            return QueueProgressMessage(session.queuePosition);
        case SessionProgressState::Connecting:
            return "Connecting to GeForce NOW...";
        case SessionProgressState::SettingUp:
            return "Setting up cloud rig...";
        case SessionProgressState::Unknown:
            break;
    }

    if (session.queuePosition > 0) {
        return QueueProgressMessage(session.queuePosition);
    }
    return "Waiting for cloud session...";
}

static void DispatchLaunchCompletion(const LaunchCallback &completion,
                                     bool success,
                                     const SessionInfo &session,
                                     const std::string &offerSdp,
                                     const std::string &error) {
    if (!completion) return;
    LaunchCallback completionCopy = completion;
    SessionInfo sessionCopy = session;
    std::string offerCopy = offerSdp;
    std::string errorCopy = error;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!completionCopy) return;
        completionCopy(success, sessionCopy, offerCopy, errorCopy);
    });
}

static void ReportLaunchProgress(const LaunchProgressCallback &progress, const std::string &message) {
    if (!progress) return;
    LaunchProgressCallback progressCopy = progress;
    std::string messageCopy = message;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!progressCopy) return;
        progressCopy(messageCopy, SessionInfo{});
    });
}

static void ReportLaunchProgress(const LaunchProgressCallback &progress, const SessionInfo &session) {
    if (!progress) return;
    LaunchProgressCallback progressCopy = progress;
    std::string message = ProgressMessageForSession(session);
    SessionInfo sessionCopy = session;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!progressCopy) return;
        progressCopy(message, sessionCopy);
    });
}

static void ReportTeardownProgress(const LaunchProgressCallback &progress, const SessionInfo &session = SessionInfo{}) {
    if (!progress) return;
    LaunchProgressCallback progressCopy = progress;
    SessionInfo cleanupInfo = SessionWithoutQueueBadge(session);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (progressCopy) progressCopy("Previous session is ending. Waiting for GeForce NOW to finish cleanup...", cleanupInfo);
    });
}

static void PollSessionReady(std::string sessionId,
                               std::string serverIp,
                               int appId,
                               LaunchProgressCallback progress,
                               LaunchCallback completion) {
    (void)appId;
    auto retries = std::make_shared<int>(0);
    const int maxRetries = 60;
    auto lastPollWasPendingProgress = std::make_shared<bool>(false);

    auto pollBlock = std::make_shared<std::function<void()>>();

    void (^poller)(bool, const SessionInfo &, const std::string &) = ^(bool ok, const SessionInfo &pollInfo, const std::string &pollErr) {
        (void)pollErr;

        if (ok && IsSessionReadyStatus(pollInfo.status) && !pollInfo.serverIp.empty()) {
            ReportLaunchProgress(progress, pollInfo);
            DispatchLaunchCompletion(completion, true, pollInfo, "", "");
            return;
        }
        if (ok && pollInfo.status == 6) {
            ReportTeardownProgress(progress, pollInfo);
            *lastPollWasPendingProgress = true;
        } else if (ok) {
            ReportLaunchProgress(progress, pollInfo);
            *lastPollWasPendingProgress = IsSessionLaunchProgressPending(pollInfo);
        } else {
            *lastPollWasPendingProgress = false;
        }

        if (ok && pollInfo.status > 3 && pollInfo.status != 6) {
            DispatchLaunchCompletion(completion, false, SessionInfo{}, "", "Session in terminal error state");
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (*pollBlock) (*pollBlock)();
        });
    };

    *pollBlock = [=] {
        if (*retries >= maxRetries && !*lastPollWasPendingProgress) {
            DispatchLaunchCompletion(completion, false, SessionInfo{}, "", "Session poll timeout");
            return;
        }
        if (*retries >= maxRetries && *lastPollWasPendingProgress) {
            *retries = 0;
        }
        (*retries)++;
        SessionManager::Shared().PollSession(sessionId, serverIp,
            [poller](bool ok, const SessionInfo &info, const std::string &err) {
                poller(ok, info, err);
            });
    };
    (*pollBlock)();
}

static void WaitForSessionTeardown(std::string sessionId,
                                   int appId,
                                   LaunchProgressCallback progress,
                                   std::function<void(bool, const std::string &)> completion) {
    auto retries = std::make_shared<int>(0);
    auto polling = std::make_shared<bool>(false);
    const int maxRetries = 90;

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!timer) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(false, "Failed to create teardown wait timer");
        });
        return;
    }

    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(2 * NSEC_PER_SEC),
                              100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        if (*polling) return;
        if (*retries >= maxRetries) {
            dispatch_source_cancel(timer);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(false, "Timed out waiting for previous session cleanup");
            });
            return;
        }
        (*retries)++;
        *polling = true;
        ReportLaunchProgress(progress, "Previous session is ending. Waiting for GeForce NOW to finish cleanup...");
        SessionManager::Shared().GetActiveSessions([sessionId, appId, completion, timer, polling](bool ok, const std::vector<ActiveSessionEntry> &sessions, const std::string &error) {
            *polling = false;
            if (!ok) {
                OPN::LogError(@"[GameService] Teardown wait active-session poll failed: %s", error.c_str());
                return;
            }

            for (const auto &session : sessions) {
                if (session.sessionId == sessionId && session.status == 6) {
                    return;
                }
            }

            for (const auto &session : sessions) {
                if (session.appId == appId && session.status == 6) {
                    return;
                }
            }

            dispatch_source_cancel(timer);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(true, "");
            });
        });
    });
    dispatch_resume(timer);
}

static bool IsSessionLimitExceededError(const std::string &error) {
    return error.find("SESSION_LIMIT") != std::string::npos ||
           error.find("\"statusCode\":11") != std::string::npos;
}

static std::string HostFromStreamingResourcePath(NSString *resourcePath) {
    if (resourcePath.length == 0) return "";
    std::string value = [resourcePath UTF8String];
    const char *prefixes[] = {"rtsps://", "rtsp://", "wss://", "https://"};
    for (const char *prefix : prefixes) {
        size_t prefixLength = strlen(prefix);
        if (value.rfind(prefix, 0) != 0) continue;
        std::string hostAndPath = value.substr(prefixLength);
        size_t colon = hostAndPath.find(':');
        size_t slash = hostAndPath.find('/');
        size_t end = std::min(colon, slash);
        std::string host = hostAndPath.substr(0, end);
        if (!host.empty() && host[0] != '.') return host;
        return "";
    }
    return "";
}

static ActiveSessionEntry ParseActiveSessionEntry(NSDictionary *session) {
    ActiveSessionEntry entry;
    if (![session isKindOfClass:[NSDictionary class]]) return entry;

    NSString *sessionId = SafeStr(session[@"sessionId"]);
    if (sessionId.length > 0) entry.sessionId = [sessionId UTF8String];
    entry.status = SafeInt(session[@"status"]);

    NSDictionary *requestData = [session[@"sessionRequestData"] isKindOfClass:[NSDictionary class]] ? session[@"sessionRequestData"] : nil;
    if (requestData) entry.appId = SafeInt(requestData[@"appId"]);

    NSString *gpuType = SafeStr(session[@"gpuType"]);
    if (gpuType.length > 0) entry.gpuType = [gpuType UTF8String];

    NSArray *connections = [session[@"connectionInfo"] isKindOfClass:[NSArray class]] ? session[@"connectionInfo"] : @[];
    NSString *connectionHost = nil;
    for (NSDictionary *connection in connections) {
        if (![connection isKindOfClass:[NSDictionary class]]) continue;
        if (SafeInt(connection[@"usage"]) != 14) continue;
        NSString *ip = SafeStr(connection[@"ip"]);
        if (ip.length > 0 && ![ip hasPrefix:@"."]) {
            connectionHost = ip;
            break;
        }
        std::string host = HostFromStreamingResourcePath(SafeStr(connection[@"resourcePath"]));
        if (!host.empty()) {
            connectionHost = [NSString stringWithUTF8String:host.c_str()];
            break;
        }
    }

    NSDictionary *controlInfo = [session[@"sessionControlInfo"] isKindOfClass:[NSDictionary class]] ? session[@"sessionControlInfo"] : nil;
    NSString *controlHost = SafeStr(controlInfo[@"ip"]);
    NSString *serverHost = controlHost.length > 0 ? controlHost : connectionHost;
    if (serverHost.length > 0) entry.serverIp = [serverHost UTF8String];
    if (connectionHost.length > 0) {
        entry.signalingUrl = [NSString stringWithFormat:@"wss://%@:443/nvst/", connectionHost].UTF8String;
    } else if (controlHost.length > 0) {
        entry.signalingUrl = [NSString stringWithFormat:@"wss://%@:443/nvst/", controlHost].UTF8String;
    }
    return entry;
}

static std::vector<ActiveSessionEntry> ActiveSessionsFromSessionLimitError(const std::string &error) {
    size_t jsonStart = error.find('{');
    if (jsonStart == std::string::npos) return {};

    std::string jsonText = error.substr(jsonStart);
    NSData *data = [[NSData alloc] initWithBytes:jsonText.data() length:jsonText.size()];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return {};

    NSArray *sessions = [json[@"otherUserSessions"] isKindOfClass:[NSArray class]] ? json[@"otherUserSessions"] : @[];
    std::vector<ActiveSessionEntry> entries;
    for (NSDictionary *session in sessions) {
        ActiveSessionEntry entry = ParseActiveSessionEntry(session);
        if (!entry.sessionId.empty() && !entry.serverIp.empty() && (entry.status == 1 || entry.status == 2 || entry.status == 3 || entry.status == 6)) {
            entries.push_back(entry);
        }
    }
    return entries;
}

static bool IsUnclaimableExistingSessionError(const std::string &error) {
    return error.find("STALE_ACTIVE_SESSION") != std::string::npos ||
           error.find("Claim HTTP 400") != std::string::npos ||
           error.find("\"statusCode\":0") != std::string::npos ||
           error.find("UNKNOWN 8A8C0000") != std::string::npos;
}

static void CreateSessionForLaunch(const std::string &appId,
                                   const std::string &internalTitle,
                                   const StreamSettings &settings,
                                   const LaunchProgressCallback &progress,
                                   const LaunchCallback &completion,
                                   const std::string &reason) {
    if (!reason.empty()) {
        OPN::LogInfo(@"[GameService] Creating fresh session after existing session could not be claimed: %s", reason.c_str());
        ReportLaunchProgress(progress, "Starting a fresh GeForce NOW session...");
    }

    SessionManager::Shared().CreateSession(appId, internalTitle, settings,
        [appId, progress, completion](bool success, const SessionInfo &info, const std::string &error) {
            if (!success) {
                DispatchLaunchCompletion(completion, false, SessionInfo{}, "", error);
                return;
            }
            if (IsSessionReadyStatus(info.status) && !info.serverIp.empty()) {
                ReportLaunchProgress(progress, info);
                DispatchLaunchCompletion(completion, true, info, "", "");
                return;
            }
            const int appIdNumber = atoi(appId.c_str());
            ReportLaunchProgress(progress, info);
            PollSessionReady(info.sessionId, info.serverIp, appIdNumber, progress, completion);
        });
}

static bool TryUseExistingSession(const std::vector<ActiveSessionEntry> &sessions,
                                  const std::string &appId,
                                  const std::string &internalTitle,
                                  const StreamSettings &settings,
                                  bool recoveryMode,
                                  const LaunchProgressCallback &progress,
                                  const LaunchCallback &completion) {
    int appIdNum = atoi(appId.c_str());

    for (const auto &s : sessions) {
        if (s.appId == appIdNum && IsSessionReadyStatus(s.status) && !s.serverIp.empty()) {
            OPN::LogInfo(@"[GameService] Claiming session %s status=%d", s.sessionId.c_str(), s.status);
            SessionManager::Shared().ClaimSession(s.sessionId, s.serverIp, appId, settings, recoveryMode,
                [appId, internalTitle, settings, progress, completion](bool success, const SessionInfo &info, const std::string &err) {
                    if (!success && IsUnclaimableExistingSessionError(err)) {
                        CreateSessionForLaunch(appId, internalTitle, settings, progress, completion, err);
                        return;
                    }
                    DispatchLaunchCompletion(completion, success, info, "", err);
                });
            return true;
        }
    }

    for (const auto &s : sessions) {
        if (IsSessionReadyStatus(s.status) && !s.sessionId.empty() && !s.serverIp.empty()) {
            OPN::LogInfo(@"[GameService] Claiming existing ready session %s for appId=%d instead of creating a second session", s.sessionId.c_str(), s.appId);
            std::string claimAppId = s.appId > 0 ? std::to_string(s.appId) : appId;
            SessionManager::Shared().ClaimSession(s.sessionId, s.serverIp, claimAppId, settings, recoveryMode,
                [appId, internalTitle, settings, progress, completion](bool success, const SessionInfo &info, const std::string &err) {
                    if (!success && IsUnclaimableExistingSessionError(err)) {
                        CreateSessionForLaunch(appId, internalTitle, settings, progress, completion, err);
                        return;
                    }
                    DispatchLaunchCompletion(completion, success, info, "", err);
                });
            return true;
        }
    }

    for (const auto &s : sessions) {
        if (s.appId == appIdNum && s.status == 6) {
            OPN::LogInfo(@"[GameService] Waiting for previous session %s to finish teardown", s.sessionId.c_str());
            WaitForSessionTeardown(s.sessionId, appIdNum, progress,
                [appId, internalTitle, settings, recoveryMode, progress, completion](bool teardownComplete, const std::string &teardownError) {
                    if (!teardownComplete) {
                        DispatchLaunchCompletion(completion, false, SessionInfo{}, "", teardownError);
                        return;
                    }
                    GameService::Shared().LaunchGame(appId, internalTitle, settings, recoveryMode, progress, completion);
                });
            return true;
        }
    }

    for (const auto &s : sessions) {
        if (s.appId == appIdNum && s.status == 1 && !s.serverIp.empty()) {
            OPN::LogInfo(@"[GameService] Polling existing session %s", s.sessionId.c_str());
            PollSessionReady(s.sessionId, s.serverIp, appIdNum, progress, completion);
            return true;
        }
    }

    for (const auto &s : sessions) {
        if (s.status == 1 && !s.sessionId.empty() && !s.serverIp.empty()) {
            OPN::LogInfo(@"[GameService] Polling existing queued session %s for appId=%d instead of creating a second session", s.sessionId.c_str(), s.appId);
            PollSessionReady(s.sessionId, s.serverIp, appIdNum, progress, completion);
            return true;
        }
    }

    return false;
}

static bool RetryExistingSessionAfterLimitError(const std::string &error,
                                                const std::string &appId,
                                                const std::string &internalTitle,
                                                const StreamSettings &settings,
                                                bool recoveryMode,
    const LaunchProgressCallback &progress,
    const LaunchCallback &completion) {
    if (!IsSessionLimitExceededError(error)) return false;
    OPN::LogInfo(@"[GameService] SESSION_LIMIT_EXCEEDED; retrying existing session lookup");
    std::vector<ActiveSessionEntry> embeddedSessions = ActiveSessionsFromSessionLimitError(error);
    if (TryUseExistingSession(embeddedSessions, appId, internalTitle, settings, recoveryMode, progress, completion)) {
        return true;
    }
    SessionManager::Shared().GetActiveSessions([appId, internalTitle, settings, recoveryMode, progress, completion, error](bool ok, const std::vector<ActiveSessionEntry> &sessions, const std::string &) {
        if (ok && TryUseExistingSession(sessions, appId, internalTitle, settings, recoveryMode, progress, completion)) {
            return;
        }
        DispatchLaunchCompletion(completion, false, SessionInfo{}, "", error);
    });
    return true;
}

void GameService::LaunchGame(const std::string &appId,
                              const std::string &internalTitle,
                              const StreamSettings &settings,
                              bool recoveryMode,
                              LaunchProgressCallback progress,
                              LaunchCallback completion) {
    OPN::LogInfo(@"[GameService] LaunchGame called with appId=%s recovery=%d", appId.c_str(), recoveryMode);
    SessionManager::Shared().SetAccessToken(m_accessToken);

    SessionManager::Shared().GetActiveSessions([appId, internalTitle, settings, recoveryMode, progress, completion](bool ok, const std::vector<ActiveSessionEntry> &sessions, const std::string &error) {
        (void)error;
        if (!ok) {
            OPN::LogError(@"[GameService] GetActiveSessions failed, falling through to CreateSession");
            SessionManager::Shared().CreateSession(appId, internalTitle, settings,
                [appId, internalTitle, settings, recoveryMode, progress, completion](bool success, const SessionInfo &info, const std::string &error) {
                    if (!success) {
                        if (RetryExistingSessionAfterLimitError(error, appId, internalTitle, settings, recoveryMode, progress, completion)) {
                            return;
                        }
                        DispatchLaunchCompletion(completion, false, SessionInfo{}, "", error);
                        return;
                    }
                    if (IsSessionReadyStatus(info.status) && !info.serverIp.empty()) {
                        ReportLaunchProgress(progress, info);
                        DispatchLaunchCompletion(completion, true, info, "", "");
                        return;
                    }
                    const int appIdNumber = atoi(appId.c_str());
                    ReportLaunchProgress(progress, info);
                    PollSessionReady(info.sessionId, info.serverIp, appIdNumber, progress, completion);
                });
            return;
        }

        if (TryUseExistingSession(sessions, appId, internalTitle, settings, recoveryMode, progress, completion)) {
            return;
        }

        OPN::LogInfo(@"[GameService] Creating new session");
        SessionManager::Shared().CreateSession(appId, internalTitle, settings,
            [appId, internalTitle, settings, recoveryMode, progress, completion](bool success, const SessionInfo &info, const std::string &error) {
                if (!success) {
                    if (RetryExistingSessionAfterLimitError(error, appId, internalTitle, settings, recoveryMode, progress, completion)) {
                        return;
                    }
                    DispatchLaunchCompletion(completion, false, SessionInfo{}, "", error);
                    return;
                }
                if (IsSessionReadyStatus(info.status) && !info.serverIp.empty()) {
                    ReportLaunchProgress(progress, info);
                    DispatchLaunchCompletion(completion, true, info, "", "");
                    return;
                }
                const int appIdNumber = atoi(appId.c_str());
                ReportLaunchProgress(progress, info);
                PollSessionReady(info.sessionId, info.serverIp, appIdNumber, progress, completion);
            });
    });
}

}
