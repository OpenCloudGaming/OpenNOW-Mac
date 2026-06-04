#include "OPNGameDataCache.h"
#include "common/OPNSentry.h"
#include <CommonCrypto/CommonCrypto.h>
#include <algorithm>

namespace OPN {

static NSString *OPNStringFromStd(const std::string &value) {
    return value.empty() ? @"" : [NSString stringWithUTF8String:value.c_str()];
}

static std::string OPNStdFromString(id value) {
    NSString *stringValue = [value isKindOfClass:[NSString class]] ? (NSString *)value : @"";
    return stringValue.length > 0 ? [stringValue UTF8String] : "";
}

static NSArray<NSString *> *OPNArrayFromStrings(const std::vector<std::string> &values) {
    NSMutableArray<NSString *> *array = [NSMutableArray arrayWithCapacity:values.size()];
    for (const std::string &value : values) {
        if (!value.empty()) [array addObject:OPNStringFromStd(value)];
    }
    return array;
}

static std::vector<std::string> OPNStringsFromArray(id value) {
    std::vector<std::string> result;
    NSArray *array = [value isKindOfClass:[NSArray class]] ? (NSArray *)value : nil;
    if (!array) return result;
    for (id entry in array) {
        NSString *stringValue = [entry isKindOfClass:[NSString class]] ? (NSString *)entry : @"";
        if (stringValue.length > 0) result.push_back([stringValue UTF8String]);
    }
    return result;
}

static NSDictionary *OPNImageMapToDictionary(const std::map<std::string, std::vector<std::string>> &imageMap) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:imageMap.size()];
    for (const auto &entry : imageMap) {
        if (entry.first.empty() || entry.second.empty()) continue;
        dict[OPNStringFromStd(entry.first)] = OPNArrayFromStrings(entry.second);
    }
    return dict;
}

static std::map<std::string, std::vector<std::string>> OPNImageMapFromDictionary(id value) {
    std::map<std::string, std::vector<std::string>> result;
    NSDictionary *dict = [value isKindOfClass:[NSDictionary class]] ? (NSDictionary *)value : nil;
    if (!dict) return result;
    for (id key in dict) {
        NSString *stringKey = [key isKindOfClass:[NSString class]] ? (NSString *)key : @"";
        std::vector<std::string> urls = OPNStringsFromArray(dict[key]);
        if (stringKey.length > 0 && !urls.empty()) result[[stringKey UTF8String]] = urls;
    }
    return result;
}

static NSString *OPNSHA256String(NSString *value) {
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hash = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hash appendFormat:@"%02x", digest[i]];
    return hash;
}

static bool OPNCacheDictionaryIsFresh(NSDictionary *dict, NSTimeInterval maxAgeSeconds) {
    if (![dict isKindOfClass:[NSDictionary class]] || maxAgeSeconds <= 0.0) return false;
    NSNumber *timestamp = [dict[@"ts"] isKindOfClass:[NSNumber class]] ? dict[@"ts"] : nil;
    if (!timestamp) return false;
    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - timestamp.doubleValue;
    return age >= 0.0 && age <= maxAgeSeconds;
}

static void OPNCreateCacheDirectory(NSString *path) {
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error]) {
        OPN::LogError(@"[GameDataCache] Failed to create cache directory %@: %@", path, error.localizedDescription ?: @"unknown error");
    }
}

static NSDictionary *OPNReadCacheDictionary(NSString *path, bool requireFreshness, NSTimeInterval maxAgeSeconds) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSError *error = nil;
    id object = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:&error];
    NSDictionary *dict = [object isKindOfClass:[NSDictionary class]] ? (NSDictionary *)object : nil;
    if (!dict) {
        OPN::LogError(@"[GameDataCache] Failed to read cache plist %@: %@", path, error.localizedDescription ?: @"invalid plist dictionary");
        return nil;
    }
    if (requireFreshness && !OPNCacheDictionaryIsFresh(dict, maxAgeSeconds)) return nil;
    return dict;
}

static void OPNWriteCacheDictionary(NSString *path, NSDictionary *dict) {
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dict format:NSPropertyListBinaryFormat_v1_0 options:0 error:&serializationError];
    if (!data) {
        OPN::LogError(@"[GameDataCache] Failed to serialize cache plist %@: %@", path, serializationError.localizedDescription ?: @"unknown error");
        return;
    }
    NSError *writeError = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        OPN::LogError(@"[GameDataCache] Failed to write cache plist %@: %@", path, writeError.localizedDescription ?: @"unknown error");
    }
}

static void OPNWriteCacheData(NSString *path, NSData *data) {
    NSError *error = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        OPN::LogError(@"[GameDataCache] Failed to write cache data %@: %@", path, error.localizedDescription ?: @"unknown error");
    }
}

static NSDictionary *OPNVariantToDictionary(const GameVariant &variant) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (!variant.id.empty()) dict[@"i"] = OPNStringFromStd(variant.id);
    if (!variant.appStore.empty()) dict[@"s"] = OPNStringFromStd(variant.appStore);
    if (!variant.storeUrl.empty()) dict[@"u"] = OPNStringFromStd(variant.storeUrl);
    if (!variant.serviceStatus.empty()) dict[@"t"] = OPNStringFromStd(variant.serviceStatus);
    if (variant.librarySelected) dict[@"l"] = @YES;
    if (variant.inLibrary) dict[@"b"] = @YES;
    return dict;
}

static GameVariant OPNVariantFromDictionary(id value) {
    NSDictionary *dict = [value isKindOfClass:[NSDictionary class]] ? (NSDictionary *)value : @{};
    GameVariant variant;
    variant.id = OPNStdFromString(dict[@"i"]);
    variant.appStore = OPNStdFromString(dict[@"s"]);
    variant.storeUrl = OPNStdFromString(dict[@"u"]);
    variant.serviceStatus = OPNStdFromString(dict[@"t"]);
    variant.librarySelected = [dict[@"l"] boolValue];
    variant.inLibrary = [dict[@"b"] boolValue];
    return variant;
}

static NSDictionary *OPNGameToDictionary(const GameInfo &game) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (!game.id.empty()) dict[@"i"] = OPNStringFromStd(game.id);
    if (!game.uuid.empty()) dict[@"u"] = OPNStringFromStd(game.uuid);
    if (!game.launchAppId.empty()) dict[@"a"] = OPNStringFromStd(game.launchAppId);
    if (!game.title.empty()) dict[@"t"] = OPNStringFromStd(game.title);
    if (!game.shortName.empty()) dict[@"n"] = OPNStringFromStd(game.shortName);
    if (!game.description.empty()) dict[@"d"] = OPNStringFromStd(game.description);
    if (!game.developerName.empty()) dict[@"v"] = OPNStringFromStd(game.developerName);
    if (!game.publisherName.empty()) dict[@"p"] = OPNStringFromStd(game.publisherName);
    if (game.maxLocalPlayers > 0) dict[@"ml"] = @(game.maxLocalPlayers);
    if (game.maxOnlinePlayers > 0) dict[@"mo"] = @(game.maxOnlinePlayers);
    if (!game.playType.empty()) dict[@"pt"] = OPNStringFromStd(game.playType);
    if (!game.membershipTierLabel.empty()) dict[@"m"] = OPNStringFromStd(game.membershipTierLabel);
    if (!game.playabilityState.empty()) dict[@"ps"] = OPNStringFromStd(game.playabilityState);
    if (!game.imageUrl.empty()) dict[@"im"] = OPNStringFromStd(game.imageUrl);
    if (!game.heroImageUrl.empty()) dict[@"he"] = OPNStringFromStd(game.heroImageUrl);
    if (!game.screenshotUrls.empty()) dict[@"sc"] = OPNArrayFromStrings(game.screenshotUrls);
    if (!game.imageUrlsByType.empty()) dict[@"it"] = OPNImageMapToDictionary(game.imageUrlsByType);
    if (!game.genres.empty()) dict[@"g"] = OPNArrayFromStrings(game.genres);
    if (!game.featureLabels.empty()) dict[@"f"] = OPNArrayFromStrings(game.featureLabels);
    if (!game.supportedControls.empty()) dict[@"c"] = OPNArrayFromStrings(game.supportedControls);
    if (!game.contentRatings.empty()) dict[@"r"] = OPNArrayFromStrings(game.contentRatings);
    if (!game.nvidiaTech.empty()) dict[@"x"] = OPNArrayFromStrings(game.nvidiaTech);
    if (!game.availableStores.empty()) dict[@"as"] = OPNArrayFromStrings(game.availableStores);
    if (game.isInLibrary) dict[@"il"] = @YES;
    if (!game.variants.empty()) {
        NSMutableArray *variants = [NSMutableArray arrayWithCapacity:game.variants.size()];
        for (const GameVariant &variant : game.variants) [variants addObject:OPNVariantToDictionary(variant)];
        dict[@"z"] = variants;
    }
    return dict;
}

static GameInfo OPNGameFromDictionary(id value) {
    NSDictionary *dict = [value isKindOfClass:[NSDictionary class]] ? (NSDictionary *)value : @{};
    GameInfo game;
    game.id = OPNStdFromString(dict[@"i"]);
    game.uuid = OPNStdFromString(dict[@"u"]);
    game.launchAppId = OPNStdFromString(dict[@"a"]);
    game.title = OPNStdFromString(dict[@"t"]);
    game.shortName = OPNStdFromString(dict[@"n"]);
    game.description = OPNStdFromString(dict[@"d"]);
    game.developerName = OPNStdFromString(dict[@"v"]);
    game.publisherName = OPNStdFromString(dict[@"p"]);
    game.maxLocalPlayers = [dict[@"ml"] intValue];
    game.maxOnlinePlayers = [dict[@"mo"] intValue];
    game.playType = OPNStdFromString(dict[@"pt"]);
    game.membershipTierLabel = OPNStdFromString(dict[@"m"]);
    game.playabilityState = OPNStdFromString(dict[@"ps"]);
    game.imageUrl = OPNStdFromString(dict[@"im"]);
    game.heroImageUrl = OPNStdFromString(dict[@"he"]);
    game.screenshotUrls = OPNStringsFromArray(dict[@"sc"]);
    game.imageUrlsByType = OPNImageMapFromDictionary(dict[@"it"]);
    game.genres = OPNStringsFromArray(dict[@"g"]);
    game.featureLabels = OPNStringsFromArray(dict[@"f"]);
    game.supportedControls = OPNStringsFromArray(dict[@"c"]);
    game.contentRatings = OPNStringsFromArray(dict[@"r"]);
    game.nvidiaTech = OPNStringsFromArray(dict[@"x"]);
    game.availableStores = OPNStringsFromArray(dict[@"as"]);
    game.isInLibrary = [dict[@"il"] boolValue];
    NSArray *variants = [dict[@"z"] isKindOfClass:[NSArray class]] ? dict[@"z"] : nil;
    for (id entry in variants) game.variants.push_back(OPNVariantFromDictionary(entry));
    return game;
}

GameDataCache &GameDataCache::Shared() {
    static GameDataCache instance;
    return instance;
}

GameDataCache::GameDataCache() {
    NSArray<NSURL *> *urls = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask];
    NSURL *baseURL = urls.firstObject ?: [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    m_rootPath = [[baseURL URLByAppendingPathComponent:@"OpenNOW/GameData" isDirectory:YES].path copy];
    m_catalogPath = [[m_rootPath stringByAppendingPathComponent:@"catalog"] copy];
    m_catalogDefinitionsPath = [[m_rootPath stringByAppendingPathComponent:@"catalog-definitions"] copy];
    m_imagePath = [[m_rootPath stringByAppendingPathComponent:@"images"] copy];
    OPNCreateCacheDirectory(m_catalogPath);
    OPNCreateCacheDirectory(m_catalogDefinitionsPath);
    OPNCreateCacheDirectory(m_imagePath);
}

std::string GameDataCache::CatalogKey(const std::string &accountIdentifier,
                                      const std::string &searchQuery,
                                      const std::string &sortId,
                                      const std::vector<std::string> &filterIds,
                                      int fetchCount) const {
    std::vector<std::string> sortedFilters = filterIds;
    std::sort(sortedFilters.begin(), sortedFilters.end());
    NSMutableArray<NSString *> *filters = [NSMutableArray arrayWithCapacity:sortedFilters.size()];
    for (const std::string &filter : sortedFilters) [filters addObject:OPNStringFromStd(filter)];
    NSDictionary *key = @{
        @"a": OPNStringFromStd(accountIdentifier),
        @"q": OPNStringFromStd(searchQuery),
        @"s": OPNStringFromStd(sortId),
        @"f": filters,
        @"c": @(fetchCount),
        @"v": @4,
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:key options:0 error:nil];
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return [OPNSHA256String(string) UTF8String];
}

bool GameDataCache::LoadCatalog(const std::string &key, CatalogBrowseResult &result) const {
    NSString *path = [m_catalogPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.bplist", key.c_str()]];
    NSDictionary *dict = OPNReadCacheDictionary(path, false, 0.0);
    if (!dict) return false;
    result = CatalogBrowseResult{};
    result.numberReturned = [dict[@"nr"] intValue];
    result.numberSupported = [dict[@"ns"] intValue];
    result.totalCount = [dict[@"tc"] intValue];
    result.hasNextPage = [dict[@"hn"] boolValue];
    result.endCursor = OPNStdFromString(dict[@"ec"]);
    result.searchQuery = OPNStdFromString(dict[@"q"]);
    result.selectedSortId = OPNStdFromString(dict[@"so"]);
    result.selectedFilterIds = OPNStringsFromArray(dict[@"sf"]);
    NSArray *games = [dict[@"g"] isKindOfClass:[NSArray class]] ? dict[@"g"] : nil;
    for (id entry in games) result.games.push_back(OPNGameFromDictionary(entry));
    return !result.games.empty();
}

bool GameDataCache::LoadFreshCatalog(const std::string &key,
                                     NSTimeInterval maxAgeSeconds,
                                     CatalogBrowseResult &result) const {
    NSString *path = [m_catalogPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.bplist", key.c_str()]];
    NSDictionary *dict = OPNReadCacheDictionary(path, true, maxAgeSeconds);
    if (!dict) return false;
    result = CatalogBrowseResult{};
    result.numberReturned = [dict[@"nr"] intValue];
    result.numberSupported = [dict[@"ns"] intValue];
    result.totalCount = [dict[@"tc"] intValue];
    result.hasNextPage = [dict[@"hn"] boolValue];
    result.endCursor = OPNStdFromString(dict[@"ec"]);
    result.searchQuery = OPNStdFromString(dict[@"q"]);
    result.selectedSortId = OPNStdFromString(dict[@"so"]);
    result.selectedFilterIds = OPNStringsFromArray(dict[@"sf"]);
    NSArray *games = [dict[@"g"] isKindOfClass:[NSArray class]] ? dict[@"g"] : nil;
    for (id entry in games) result.games.push_back(OPNGameFromDictionary(entry));
    return !result.games.empty();
}

void GameDataCache::SaveCatalog(const std::string &key, const CatalogBrowseResult &result) const {
    NSMutableArray *games = [NSMutableArray arrayWithCapacity:result.games.size()];
    for (const GameInfo &game : result.games) [games addObject:OPNGameToDictionary(game)];
    NSDictionary *dict = @{
        @"ts": @([[NSDate date] timeIntervalSince1970]),
        @"nr": @(result.numberReturned),
        @"ns": @(result.numberSupported),
        @"tc": @(result.totalCount),
        @"hn": @(result.hasNextPage),
        @"ec": OPNStringFromStd(result.endCursor),
        @"q": OPNStringFromStd(result.searchQuery),
        @"so": OPNStringFromStd(result.selectedSortId),
        @"sf": OPNArrayFromStrings(result.selectedFilterIds),
        @"g": games,
    };
    NSString *path = [m_catalogPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.bplist", key.c_str()]];
    OPNWriteCacheDictionary(path, dict);
}

bool GameDataCache::LoadCatalogDefinitions(NSString *locale,
                                           NSTimeInterval maxAgeSeconds,
                                           NSDictionary **definitions) const {
    if (definitions) *definitions = nil;
    NSString *cacheKey = OPNSHA256String(locale.length > 0 ? locale : @"default");
    NSString *path = [m_catalogDefinitionsPath stringByAppendingPathComponent:[cacheKey stringByAppendingPathExtension:@"bplist"]];
    NSDictionary *dict = OPNReadCacheDictionary(path, true, maxAgeSeconds);
    if (!dict) return false;
    NSDictionary *payload = [dict[@"data"] isKindOfClass:[NSDictionary class]] ? dict[@"data"] : nil;
    if (!payload) return false;
    if (definitions) *definitions = payload;
    return true;
}

void GameDataCache::SaveCatalogDefinitions(NSString *locale, NSDictionary *definitions) const {
    if (![definitions isKindOfClass:[NSDictionary class]]) return;
    NSString *cacheKey = OPNSHA256String(locale.length > 0 ? locale : @"default");
    NSDictionary *dict = @{
        @"ts": @([[NSDate date] timeIntervalSince1970]),
        @"data": definitions,
    };
    NSString *path = [m_catalogDefinitionsPath stringByAppendingPathComponent:[cacheKey stringByAppendingPathExtension:@"bplist"]];
    OPNWriteCacheDictionary(path, dict);
}

NSData *GameDataCache::LoadImage(NSString *urlString) const {
    if (urlString.length == 0) return nil;
    NSString *path = [m_imagePath stringByAppendingPathComponent:[OPNSHA256String(urlString) stringByAppendingPathExtension:@"img"]];
    return [NSData dataWithContentsOfFile:path];
}

void GameDataCache::SaveImage(NSString *urlString, NSData *data) const {
    if (urlString.length == 0 || data.length == 0) return;
    NSString *path = [m_imagePath stringByAppendingPathComponent:[OPNSHA256String(urlString) stringByAppendingPathExtension:@"img"]];
    OPNWriteCacheData(path, data);
}

bool GameDataCache::ClearAllCaches() const {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSError *removeError = nil;
    BOOL removed = ![fileManager fileExistsAtPath:m_rootPath] || [fileManager removeItemAtPath:m_rootPath error:&removeError];
    if (!removed) {
        OPN::LogError(@"[GameDataCache] Failed to clear cache directory %@: %@", m_rootPath, removeError.localizedDescription ?: @"unknown error");
    }
    OPNCreateCacheDirectory(m_catalogPath);
    OPNCreateCacheDirectory(m_catalogDefinitionsPath);
    OPNCreateCacheDirectory(m_imagePath);
    return removed ? true : false;
}

}
