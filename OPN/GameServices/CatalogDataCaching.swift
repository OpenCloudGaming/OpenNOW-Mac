//
//  CatalogDataCaching.swift
//  MacForceNow
//

import Foundation

protocol CatalogDataCaching {
    func catalogKey(accountIdentifier: String, searchQuery: String, sortId: String, filterIds: [String], fetchCount: Int, locale: String, providerStreamingBaseUrl: String, vpcId: String) -> String
    func loadFreshCatalogAndDefinitions(key: String, locale: String, catalogMaxAgeSeconds: TimeInterval, definitionsMaxAgeSeconds: TimeInterval, completion: @escaping @Sendable (OPNCatalogBrowseResult?, NSDictionary?) -> Void)
    func loadCatalogAsync(key: String, completion: @escaping @Sendable (OPNCatalogBrowseResult?) -> Void)
    func saveCatalogAsync(key: String, result: OPNCatalogBrowseResult)
    func loadCatalogDefinitionsAsync(locale: String, maxAgeSeconds: TimeInterval, completion: @escaping @Sendable (NSDictionary?) -> Void)
    func saveCatalogDefinitionsAsync(locale: String, definitions: NSDictionary)
}

extension OPNGameDataCache: CatalogDataCaching {}
