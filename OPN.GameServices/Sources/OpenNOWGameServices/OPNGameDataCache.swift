import CryptoKit
import Foundation

@objc(OPNGameDataCache)
final class OPNGameDataCache: NSObject {
    @objc(shared)
    nonisolated(unsafe) static let shared = OPNGameDataCache()

    private let rootPath: String
    private let catalogPath: String
    private let catalogDefinitionsPath: String
    private let imagePath: String

    private override init() {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        rootPath = baseURL.appendingPathComponent("OpenNOW/GameData", isDirectory: true).path
        catalogPath = (rootPath as NSString).appendingPathComponent("catalog")
        catalogDefinitionsPath = (rootPath as NSString).appendingPathComponent("catalog-definitions")
        imagePath = (rootPath as NSString).appendingPathComponent("images")
        super.init()
        createCacheDirectory(catalogPath)
        createCacheDirectory(catalogDefinitionsPath)
        createCacheDirectory(imagePath)
    }

    func catalogKey(
        accountIdentifier: String,
        searchQuery: String,
        sortId: String,
        filterIds: [String],
        fetchCount: Int,
        locale: String = "",
        providerStreamingBaseUrl: String = "",
        vpcId: String = ""
    ) -> String {
        let key: [String: Any] = [
            "a": accountIdentifier,
            "q": searchQuery,
            "s": sortId,
            "f": filterIds.sorted(),
            "c": fetchCount,
            "l": locale,
            "p": providerStreamingBaseUrl,
            "vp": vpcId,
            "v": 5,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: key, options: [])) ?? Data()
        let string = String(data: data, encoding: .utf8) ?? ""
        return sha256String(string)
    }

    @objc(catalogKeyWithAccountIdentifier:searchQuery:sortId:filterIds:fetchCount:locale:providerStreamingBaseUrl:vpcId:)
    func catalogKeyObjC(
        accountIdentifier: String,
        searchQuery: String,
        sortId: String,
        filterIds: [String],
        fetchCount: Int,
        locale: String,
        providerStreamingBaseUrl: String,
        vpcId: String
    ) -> String {
        catalogKey(
            accountIdentifier: accountIdentifier,
            searchQuery: searchQuery,
            sortId: sortId,
            filterIds: filterIds,
            fetchCount: fetchCount,
            locale: locale,
            providerStreamingBaseUrl: providerStreamingBaseUrl,
            vpcId: vpcId
        )
    }

    func loadCatalog(key: String) -> OPNCatalogBrowseResult? {
        loadCatalog(key: key, requireFreshness: false, maxAgeSeconds: 0)
    }

    func loadFreshCatalog(key: String, maxAgeSeconds: TimeInterval) -> OPNCatalogBrowseResult? {
        loadCatalog(key: key, requireFreshness: true, maxAgeSeconds: maxAgeSeconds)
    }

    func saveCatalog(key: String, result: OPNCatalogBrowseResult) {
        let dictionary: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "nr": result.numberReturned,
            "ns": result.numberSupported,
            "tc": result.totalCount,
            "hn": result.hasNextPage,
            "ec": result.endCursor,
            "q": result.searchQuery,
            "so": result.selectedSortId,
            "sf": result.selectedFilterIds,
            "g": result.games.map(gameDictionary),
        ]
        writeCacheDictionary(path: catalogFilePath(key: key), dictionary: dictionary)
    }

    @objc(loadCatalogDictionaryWithKey:)
    func loadCatalogDictionary(key: String) -> NSDictionary? {
        readCacheDictionary(path: catalogFilePath(key: key), requireFreshness: false, maxAgeSeconds: 0)
    }

    @objc(loadFreshCatalogDictionaryWithKey:maxAgeSeconds:)
    func loadFreshCatalogDictionary(key: String, maxAgeSeconds: TimeInterval) -> NSDictionary? {
        readCacheDictionary(path: catalogFilePath(key: key), requireFreshness: true, maxAgeSeconds: maxAgeSeconds)
    }

    @objc(saveCatalogDictionaryWithKey:dictionary:)
    func saveCatalogDictionary(key: String, dictionary: NSDictionary) {
        guard var payload = dictionary as? [String: Any] else { return }
        payload["ts"] = Date().timeIntervalSince1970
        writeCacheDictionary(path: catalogFilePath(key: key), dictionary: payload)
    }

    func loadCatalogDefinitions(locale: String, maxAgeSeconds: TimeInterval) -> NSDictionary? {
        let cacheKey = sha256String(locale.isEmpty ? "default" : locale)
        let path = (catalogDefinitionsPath as NSString).appendingPathComponent("\(cacheKey).bplist")
        guard let dictionary = readCacheDictionary(path: path, requireFreshness: true, maxAgeSeconds: maxAgeSeconds) else {
            return nil
        }
        return dictionary["data"] as? NSDictionary
    }

    func saveCatalogDefinitions(locale: String, definitions: NSDictionary) {
        let cacheKey = sha256String(locale.isEmpty ? "default" : locale)
        let path = (catalogDefinitionsPath as NSString).appendingPathComponent("\(cacheKey).bplist")
        writeCacheDictionary(path: path, dictionary: [
            "ts": Date().timeIntervalSince1970,
            "data": definitions,
        ])
    }

    @objc(loadCatalogDefinitionsWithLocale:maxAgeSeconds:)
    func loadCatalogDefinitionsObjC(locale: String, maxAgeSeconds: TimeInterval) -> NSDictionary? {
        loadCatalogDefinitions(locale: locale, maxAgeSeconds: maxAgeSeconds)
    }

    @objc(saveCatalogDefinitionsWithLocale:definitions:)
    func saveCatalogDefinitionsObjC(locale: String, definitions: NSDictionary) {
        saveCatalogDefinitions(locale: locale, definitions: definitions)
    }

    @objc(loadImageWithURLString:)
    func loadImage(urlString: String) -> Data? {
        guard !urlString.isEmpty else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: imageFilePath(urlString: urlString)))
    }

    @objc(saveImageWithURLString:data:)
    func saveImage(urlString: String, data: Data) {
        guard !urlString.isEmpty, !data.isEmpty else { return }
        try? data.write(to: URL(fileURLWithPath: imageFilePath(urlString: urlString)), options: .atomic)
    }

    @objc(clearAllCaches)
    func clearAllCaches() -> Bool {
        let existed = FileManager.default.fileExists(atPath: rootPath)
        let removed: Bool
        if existed {
            do {
                try FileManager.default.removeItem(atPath: rootPath)
                removed = true
            } catch {
                removed = false
            }
        } else {
            removed = true
        }
        createCacheDirectory(catalogPath)
        createCacheDirectory(catalogDefinitionsPath)
        createCacheDirectory(imagePath)
        return removed
    }

    private func loadCatalog(key: String, requireFreshness: Bool, maxAgeSeconds: TimeInterval) -> OPNCatalogBrowseResult? {
        guard let dictionary = readCacheDictionary(path: catalogFilePath(key: key), requireFreshness: requireFreshness, maxAgeSeconds: maxAgeSeconds) else {
            return nil
        }

        var result = OPNCatalogBrowseResult()
        result.numberReturned = (dictionary["nr"] as? NSNumber)?.intValue ?? 0
        result.numberSupported = (dictionary["ns"] as? NSNumber)?.intValue ?? 0
        result.totalCount = (dictionary["tc"] as? NSNumber)?.intValue ?? 0
        result.hasNextPage = (dictionary["hn"] as? NSNumber)?.boolValue ?? false
        result.endCursor = dictionary["ec"] as? String ?? ""
        result.searchQuery = dictionary["q"] as? String ?? ""
        result.selectedSortId = dictionary["so"] as? String ?? ""
        result.selectedFilterIds = dictionary["sf"] as? [String] ?? []
        result.games = (dictionary["g"] as? [Any] ?? []).map(gameInfo).filter { !$0.id.isEmpty || !$0.title.isEmpty }
        return result
    }

    private func catalogFilePath(key: String) -> String {
        (catalogPath as NSString).appendingPathComponent("\(key).bplist")
    }

    private func imageFilePath(urlString: String) -> String {
        (imagePath as NSString).appendingPathComponent("\(sha256String(urlString)).img")
    }

    private func createCacheDirectory(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func readCacheDictionary(path: String, requireFreshness: Bool, maxAgeSeconds: TimeInterval) -> NSDictionary? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard let dictionary = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? NSDictionary else {
            return nil
        }
        if requireFreshness && !cacheDictionaryIsFresh(dictionary, maxAgeSeconds: maxAgeSeconds) {
            return nil
        }
        return dictionary
    }

    private func writeCacheDictionary(path: String, dictionary: [String: Any]) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func cacheDictionaryIsFresh(_ dictionary: NSDictionary, maxAgeSeconds: TimeInterval) -> Bool {
        guard maxAgeSeconds > 0, let timestamp = dictionary["ts"] as? NSNumber else { return false }
        let age = Date().timeIntervalSince1970 - timestamp.doubleValue
        return age >= 0 && age <= maxAgeSeconds
    }

    private func gameDictionary(_ game: OPNGameInfo) -> [String: Any] {
        var dictionary: [String: Any] = [:]
        putString(game.id, key: "i", into: &dictionary)
        putString(game.uuid, key: "u", into: &dictionary)
        putString(game.launchAppId, key: "a", into: &dictionary)
        putString(game.title, key: "t", into: &dictionary)
        putString(game.shortName, key: "n", into: &dictionary)
        putString(game.description, key: "d", into: &dictionary)
        putString(game.developerName, key: "v", into: &dictionary)
        putString(game.publisherName, key: "p", into: &dictionary)
        if game.maxLocalPlayers > 0 { dictionary["ml"] = game.maxLocalPlayers }
        if game.maxOnlinePlayers > 0 { dictionary["mo"] = game.maxOnlinePlayers }
        putString(game.playType, key: "pt", into: &dictionary)
        putString(game.membershipTierLabel, key: "m", into: &dictionary)
        putString(game.playabilityState, key: "ps", into: &dictionary)
        putString(game.imageUrl, key: "im", into: &dictionary)
        putString(game.heroImageUrl, key: "he", into: &dictionary)
        putArray(game.screenshotUrls, key: "sc", into: &dictionary)
        if !game.imageUrlsByType.isEmpty { dictionary["it"] = game.imageUrlsByType }
        putArray(game.genres, key: "g", into: &dictionary)
        putArray(game.featureLabels, key: "f", into: &dictionary)
        putArray(game.supportedControls, key: "c", into: &dictionary)
        putArray(game.contentRatings, key: "r", into: &dictionary)
        putArray(game.nvidiaTech, key: "x", into: &dictionary)
        putArray(game.availableStores, key: "as", into: &dictionary)
        if game.isInLibrary { dictionary["il"] = true }
        if !game.variants.isEmpty { dictionary["z"] = game.variants.map(variantDictionary) }
        return dictionary
    }

    private func gameInfo(_ value: Any) -> OPNGameInfo {
        let dictionary = value as? [String: Any] ?? [:]
        var game = OPNGameInfo()
        game.id = dictionary["i"] as? String ?? ""
        game.uuid = dictionary["u"] as? String ?? ""
        game.launchAppId = dictionary["a"] as? String ?? ""
        game.title = dictionary["t"] as? String ?? ""
        game.shortName = dictionary["n"] as? String ?? ""
        game.description = dictionary["d"] as? String ?? ""
        game.developerName = dictionary["v"] as? String ?? ""
        game.publisherName = dictionary["p"] as? String ?? ""
        game.maxLocalPlayers = (dictionary["ml"] as? NSNumber)?.intValue ?? 0
        game.maxOnlinePlayers = (dictionary["mo"] as? NSNumber)?.intValue ?? 0
        game.playType = dictionary["pt"] as? String ?? ""
        game.membershipTierLabel = dictionary["m"] as? String ?? ""
        game.playabilityState = dictionary["ps"] as? String ?? ""
        game.imageUrl = dictionary["im"] as? String ?? ""
        game.heroImageUrl = dictionary["he"] as? String ?? ""
        game.screenshotUrls = dictionary["sc"] as? [String] ?? []
        game.imageUrlsByType = dictionary["it"] as? [String: [String]] ?? [:]
        game.genres = dictionary["g"] as? [String] ?? []
        game.featureLabels = dictionary["f"] as? [String] ?? []
        game.supportedControls = dictionary["c"] as? [String] ?? []
        game.contentRatings = dictionary["r"] as? [String] ?? []
        game.nvidiaTech = dictionary["x"] as? [String] ?? []
        game.availableStores = dictionary["as"] as? [String] ?? []
        game.isInLibrary = (dictionary["il"] as? NSNumber)?.boolValue ?? false
        game.variants = (dictionary["z"] as? [Any] ?? []).map(gameVariant)
        return game
    }

    private func variantDictionary(_ variant: OPNGameVariant) -> [String: Any] {
        var dictionary: [String: Any] = [:]
        putString(variant.id, key: "i", into: &dictionary)
        putString(variant.appStore, key: "s", into: &dictionary)
        putString(variant.storeUrl, key: "u", into: &dictionary)
        putString(variant.serviceStatus, key: "t", into: &dictionary)
        if variant.librarySelected { dictionary["l"] = true }
        if variant.inLibrary { dictionary["b"] = true }
        return dictionary
    }

    private func gameVariant(_ value: Any) -> OPNGameVariant {
        let dictionary = value as? [String: Any] ?? [:]
        return OPNGameVariant(
            id: dictionary["i"] as? String ?? "",
            appStore: dictionary["s"] as? String ?? "",
            storeUrl: dictionary["u"] as? String ?? "",
            serviceStatus: dictionary["t"] as? String ?? "",
            librarySelected: (dictionary["l"] as? NSNumber)?.boolValue ?? false,
            inLibrary: (dictionary["b"] as? NSNumber)?.boolValue ?? false
        )
    }

    private func putString(_ value: String, key: String, into dictionary: inout [String: Any]) {
        if !value.isEmpty { dictionary[key] = value }
    }

    private func putArray(_ value: [String], key: String, into dictionary: inout [String: Any]) {
        let filtered = value.filter { !$0.isEmpty }
        if !filtered.isEmpty { dictionary[key] = filtered }
    }

    private func sha256String(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
