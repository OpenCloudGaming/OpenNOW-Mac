import CryptoKit
import Foundation

final class OPNGameDataCache: @unchecked Sendable {
    static let shared = OPNGameDataCache()

    private static let catalogCacheVersion = 13
    private static let catalogDefinitionsCacheVersion = "v2"

    // Catalog snapshots are ~60 MB each and keyed per query/filter/vpc, so
    // without pruning the directory grows unbounded (observed at 6.9 GB).
    private static let catalogPruneMaxAgeSeconds: TimeInterval = 7 * 24 * 60 * 60
    private static let catalogPruneMaxTotalBytes = 512 * 1024 * 1024

    private let rootPath: String
    private let catalogPath: String
    private let catalogDefinitionsPath: String
    private let imagePath: String
    private let ioQueue = DispatchQueue(label: "com.opennow.game-data-cache.io", qos: .utility)

    private init() {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        rootPath = baseURL.appendingPathComponent("OpenNOW/GameData", isDirectory: true).path
        catalogPath = (rootPath as NSString).appendingPathComponent("catalog")
        catalogDefinitionsPath = (rootPath as NSString).appendingPathComponent("catalog-definitions")
        imagePath = (rootPath as NSString).appendingPathComponent("images")
        createCacheDirectory(catalogPath)
        createCacheDirectory(catalogDefinitionsPath)
        createCacheDirectory(imagePath)
        ioQueue.async { [catalogPath] in
            Self.pruneCatalogCache(directory: catalogPath)
        }
    }

    private static func pruneCatalogCache(directory: String) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return }
        var entries: [(path: String, modified: Date, size: Int)] = []
        for name in names {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { continue }
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            entries.append((path, modified, size))
        }
        let cutoff = Date().addingTimeInterval(-catalogPruneMaxAgeSeconds)
        var kept: [(path: String, modified: Date, size: Int)] = []
        for entry in entries {
            if entry.modified < cutoff {
                try? fileManager.removeItem(atPath: entry.path)
            } else {
                kept.append(entry)
            }
        }
        var totalBytes = kept.reduce(0) { $0 + $1.size }
        guard totalBytes > catalogPruneMaxTotalBytes else { return }
        for entry in kept.sorted(by: { $0.modified < $1.modified }) {
            try? fileManager.removeItem(atPath: entry.path)
            totalBytes -= entry.size
            if totalBytes <= catalogPruneMaxTotalBytes { break }
        }
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
            "v": Self.catalogCacheVersion,
        ]
        // .sortedKeys is required, not cosmetic: Swift dictionary iteration order is
        // randomized per instance, so serializing without it produces a different byte
        // order (and therefore a different key) for identical inputs — every cache read
        // missed, and each write landed in its own file.
        let data = (try? JSONSerialization.data(withJSONObject: key, options: [.sortedKeys])) ?? Data()
        let string = String(data: data, encoding: .utf8) ?? ""
        return sha256String(string)
    }


    func loadCatalog(key: String) -> OPNCatalogBrowseResult? {
        loadCatalog(key: key, requireFreshness: false, maxAgeSeconds: 0)
    }

    func loadFreshCatalog(key: String, maxAgeSeconds: TimeInterval) -> OPNCatalogBrowseResult? {
        loadCatalog(key: key, requireFreshness: true, maxAgeSeconds: maxAgeSeconds)
    }

    func loadFreshCatalogAndDefinitions(
        key: String,
        locale: String,
        catalogMaxAgeSeconds: TimeInterval,
        definitionsMaxAgeSeconds: TimeInterval,
        completion: @escaping @Sendable (OPNCatalogBrowseResult?, NSDictionary?) -> Void
    ) {
        ioQueue.async { [self] in
            completion(
                loadFreshCatalog(key: key, maxAgeSeconds: catalogMaxAgeSeconds),
                loadCatalogDefinitions(locale: locale, maxAgeSeconds: definitionsMaxAgeSeconds)
            )
        }
    }

    func loadCatalogAsync(key: String, completion: @escaping @Sendable (OPNCatalogBrowseResult?) -> Void) {
        ioQueue.async { [self] in
            completion(loadCatalog(key: key))
        }
    }

    func saveCatalogAsync(key: String, result: OPNCatalogBrowseResult) {
        ioQueue.async { [self] in
            saveCatalog(key: key, result: result)
        }
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




    func loadCatalogDefinitions(locale: String, maxAgeSeconds: TimeInterval) -> NSDictionary? {
        let cacheKey = catalogDefinitionsCacheKey(locale: locale)
        let path = (catalogDefinitionsPath as NSString).appendingPathComponent("\(cacheKey).bplist")
        guard let dictionary = readCacheDictionary(path: path, requireFreshness: true, maxAgeSeconds: maxAgeSeconds) else {
            return nil
        }
        return dictionary["data"] as? NSDictionary
    }

    func saveCatalogDefinitions(locale: String, definitions: NSDictionary) {
        let cacheKey = catalogDefinitionsCacheKey(locale: locale)
        let path = (catalogDefinitionsPath as NSString).appendingPathComponent("\(cacheKey).bplist")
        writeCacheDictionary(path: path, dictionary: [
            "ts": Date().timeIntervalSince1970,
            "data": definitions,
        ])
    }

    func loadCatalogDefinitionsAsync(locale: String, maxAgeSeconds: TimeInterval, completion: @escaping @Sendable (NSDictionary?) -> Void) {
        ioQueue.async { [self] in
            completion(loadCatalogDefinitions(locale: locale, maxAgeSeconds: maxAgeSeconds))
        }
    }

    func saveCatalogDefinitionsAsync(locale: String, definitions: NSDictionary) {
        nonisolated(unsafe) let unsafeDefinitions = definitions.copy() as? NSDictionary ?? definitions
        ioQueue.async { [self] in
            saveCatalogDefinitions(locale: locale, definitions: unsafeDefinitions)
        }
    }

    func loadCatalogDefinitionsObjC(locale: String, maxAgeSeconds: TimeInterval) -> NSDictionary? {
        loadCatalogDefinitions(locale: locale, maxAgeSeconds: maxAgeSeconds)
    }

    func saveCatalogDefinitionsObjC(locale: String, definitions: NSDictionary) {
        saveCatalogDefinitions(locale: locale, definitions: definitions)
    }

    func loadPanelsAsync(
        kind: String,
        accountIdentifier: String,
        vpcId: String,
        locale: String,
        maxAgeSeconds: TimeInterval,
        completion: @escaping @Sendable ([OPNPanelResult]?) -> Void
    ) {
        let key = panelsKey(kind: kind, accountIdentifier: accountIdentifier, vpcId: vpcId, locale: locale)
        let path = (catalogPath as NSString).appendingPathComponent("\(key).panels.bplist")
        ioQueue.async { [self] in
            guard let dictionary = readCacheDictionary(path: path, requireFreshness: true, maxAgeSeconds: maxAgeSeconds),
                  let rawPanels = dictionary["p"] as? [Any] else {
                completion(nil)
                return
            }
            completion(rawPanels.map(panelInfo))
        }
    }

    func savePanelsAsync(kind: String, accountIdentifier: String, vpcId: String, locale: String, panels: [OPNPanelResult]) {
        let key = panelsKey(kind: kind, accountIdentifier: accountIdentifier, vpcId: vpcId, locale: locale)
        let path = (catalogPath as NSString).appendingPathComponent("\(key).panels.bplist")
        ioQueue.async { [self] in
            let dictionary: [String: Any] = [
                "ts": Date().timeIntervalSince1970,
                "p": panels.map(panelDictionary)
            ]
            writeCacheDictionary(path: path, dictionary: dictionary)
        }
    }

    private func panelsKey(kind: String, accountIdentifier: String, vpcId: String, locale: String) -> String {
        let key: [String: Any] = [
            "k": kind,
            "a": accountIdentifier,
            "vp": vpcId,
            "l": locale,
            "c": Self.catalogCacheVersion
        ]
        // .sortedKeys is required, not cosmetic: Swift dictionary iteration order is
        // randomized per instance, so serializing without it produces a different byte
        // order (and therefore a different key) for identical inputs — every cache read
        // missed, and each write landed in its own file.
        let data = (try? JSONSerialization.data(withJSONObject: key, options: [.sortedKeys])) ?? Data()
        let string = String(data: data, encoding: .utf8) ?? ""
        return sha256String(string)
    }

    private func panelDictionary(_ panel: OPNPanelResult) -> [String: Any] {
        var dictionary: [String: Any] = [:]
        putString(panel.id, key: "i", into: &dictionary)
        putString(panel.title, key: "t", into: &dictionary)
        putString(panel.typename, key: "y", into: &dictionary)
        if !panel.sections.isEmpty { dictionary["s"] = panel.sections.map(sectionDictionary) }
        return dictionary
    }

    private func panelInfo(_ value: Any) -> OPNPanelResult {
        let dictionary = value as? [String: Any] ?? [:]
        var panel = OPNPanelResult()
        panel.id = dictionary["i"] as? String ?? ""
        panel.title = dictionary["t"] as? String ?? ""
        panel.typename = dictionary["y"] as? String ?? ""
        panel.sections = (dictionary["s"] as? [Any] ?? []).map(sectionInfo)
        return panel
    }

    private func sectionDictionary(_ section: OPNPanelSection) -> [String: Any] {
        var dictionary: [String: Any] = [:]
        putString(section.id, key: "i", into: &dictionary)
        putString(section.title, key: "t", into: &dictionary)
        putString(section.typename, key: "y", into: &dictionary)
        putArray(section.seeMoreFilterIds, key: "smf", into: &dictionary)
        putString(section.seeMoreSortId, key: "sms", into: &dictionary)
        putString(section.seeMoreTitle, key: "smt", into: &dictionary)
        if !section.games.isEmpty { dictionary["g"] = section.games.map(gameDictionary) }
        if !section.tiles.isEmpty { dictionary["tl"] = section.tiles.map(tileDictionary) }
        return dictionary
    }

    private func sectionInfo(_ value: Any) -> OPNPanelSection {
        let dictionary = value as? [String: Any] ?? [:]
        var section = OPNPanelSection()
        section.id = dictionary["i"] as? String ?? ""
        section.title = dictionary["t"] as? String ?? ""
        section.typename = dictionary["y"] as? String ?? ""
        section.seeMoreFilterIds = dictionary["smf"] as? [String] ?? []
        section.seeMoreSortId = dictionary["sms"] as? String ?? ""
        section.seeMoreTitle = dictionary["smt"] as? String ?? ""
        section.games = (dictionary["g"] as? [Any] ?? []).map(gameInfo)
        section.tiles = (dictionary["tl"] as? [Any] ?? []).map(tileInfo)
        return section
    }

    private func tileDictionary(_ tile: OPNPanelTile) -> [String: Any] {
        var dictionary: [String: Any] = [:]
        putString(tile.id, key: "i", into: &dictionary)
        putString(tile.kind, key: "k", into: &dictionary)
        putString(tile.title, key: "t", into: &dictionary)
        putString(tile.subtitle, key: "st", into: &dictionary)
        putString(tile.body, key: "b", into: &dictionary)
        putString(tile.imageUrl, key: "im", into: &dictionary)
        putString(tile.actionUrl, key: "au", into: &dictionary)
        putString(tile.actionLabel, key: "al", into: &dictionary)
        putArray(tile.filterIds, key: "f", into: &dictionary)
        putString(tile.sortId, key: "so", into: &dictionary)
        return dictionary
    }

    private func tileInfo(_ value: Any) -> OPNPanelTile {
        let dictionary = value as? [String: Any] ?? [:]
        var tile = OPNPanelTile()
        tile.id = dictionary["i"] as? String ?? ""
        tile.kind = dictionary["k"] as? String ?? ""
        tile.title = dictionary["t"] as? String ?? ""
        tile.subtitle = dictionary["st"] as? String ?? ""
        tile.body = dictionary["b"] as? String ?? ""
        tile.imageUrl = dictionary["im"] as? String ?? ""
        tile.actionUrl = dictionary["au"] as? String ?? ""
        tile.actionLabel = dictionary["al"] as? String ?? ""
        tile.filterIds = dictionary["f"] as? [String] ?? []
        tile.sortId = dictionary["so"] as? String ?? ""
        return tile
    }

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

    private func catalogDefinitionsCacheKey(locale: String) -> String {
        let normalizedLocale = locale.isEmpty ? "default" : locale
        return sha256String("\(Self.catalogDefinitionsCacheVersion):\(normalizedLocale)")
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
}
