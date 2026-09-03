//  Second pass over a catalog page: app metadata, campaign promo tags and rating definitions
//  folded into the rows the browse query returned. Split out of OPNGameService+Catalog.swift.
//

import AppKit
import Foundation

extension OPNGameService {
    /// String fields the app-metadata pass fills in when the catalog row left them empty. Listed
    /// rather than written out one `if` per field, because the rule is the same for every one.
    // Computed, not stored: `WritableKeyPath` is non-Sendable by design, so a `static let` would
    // need a `nonisolated(unsafe)` the reader has to take on trust. These are read once per
    // merged record, well off any hot path.
    private static var enrichableStringFields: [WritableKeyPath<OPNGameInfo, String>] { [
        \.promoTag, \.skuPlayabilityText, \.skuUnplayableDialogHeader, \.skuUnplayableDialogBody,
        \.skuUnplayableDialogBodyEcommerceRestricted, \.shortDescription, \.longDescription,
        \.developerName, \.publisherName, \.releaseDate, \.imageUrl, \.heroImageUrl,
        \.ratingSystemName, \.ratingCategoryKey, \.ratingCategoryTitle, \.ratingImageUrl,
        \.patchStatusPrimaryText, \.patchStatusSecondaryText
    ] }

    private static var enrichableListFields: [WritableKeyPath<OPNGameInfo, [String]>] { [
        \.campaignIds, \.skuTags, \.genres, \.featureLabels, \.supportedControls,
        \.contentRatings, \.ratingDescriptors, \.ratingInteractiveElements, \.nvidiaTech
    ] }

    private static var enrichableFlagFields: [WritableKeyPath<OPNGameInfo, Bool>] { [
        \.isFreeToPlay, \.displaysOwnRatingDuringGameplay, \.isFavorited
    ] }

    private static var enrichableCountFields: [WritableKeyPath<OPNGameInfo, Int>] { [
        \.maxLocalPlayers, \.maxOnlinePlayers
    ] }

    /// Folds the app-metadata view of a title into the catalog row. The catalog row wins wherever
    /// it already has a value; description and screenshots are the exceptions, because the metadata
    /// endpoint is the authoritative source for both.
    func merging(_ game: OPNGameInfo, with metadataGame: OPNGameInfo) -> OPNGameInfo {
        var merged = game
        mergeMissingStoreMetadata(target: &merged, metadata: metadataGame)
        for field in Self.enrichableStringFields where merged[keyPath: field].isEmpty {
            merged[keyPath: field] = metadataGame[keyPath: field]
        }
        for field in Self.enrichableListFields where merged[keyPath: field].isEmpty {
            merged[keyPath: field] = metadataGame[keyPath: field]
        }
        for field in Self.enrichableFlagFields where !merged[keyPath: field] {
            merged[keyPath: field] = metadataGame[keyPath: field]
        }
        for field in Self.enrichableCountFields where merged[keyPath: field] <= 0 {
            merged[keyPath: field] = metadataGame[keyPath: field]
        }
        if !metadataGame.description.isEmpty { merged.description = metadataGame.description }
        if !metadataGame.screenshotUrls.isEmpty { merged.screenshotUrls = metadataGame.screenshotUrls }
        for (key, value) in metadataGame.imageUrlsByType where merged.imageUrlsByType[key] == nil {
            merged.imageUrlsByType[key] = value
        }
        return merged
    }

    func enrichGames(_ games: [OPNGameInfo], vpcId: String, completion: @escaping @Sendable ([OPNGameInfo]) -> Void) {
        let appIds = Array(Set(games.map(\.uuid).filter { !$0.isEmpty }))
        if appIds.isEmpty {
            completion(games)
            return
        }
        let metadataState = MetadataState()
        let chunks = stride(from: 0, to: appIds.count, by: 40).map { Array(appIds[$0..<min($0 + 40, appIds.count)]) }
        let group = DispatchGroup()
        // A 20-section home panel enriches in ~15 chunks of ~300KB; firing them all at
        // once starves the artwork downloads the first frame is waiting on.
        for chunk in chunks {
            group.enter()
            Self.appMetadataLimiter.submit { [weak self] finished in
                guard let self else {
                    group.leave()
                    finished()
                    return
                }
                self.fetchAppMetadata(appIds: chunk, vpcId: vpcId) { data, _ in
                    if let items = (data?["apps"] as? NSDictionary)?["items"] as? [NSDictionary] {
                        let itemsBox = NSDictionaryArrayBox(items)
                        Self.workQueue.async { [itemsBox] in
                            for item in itemsBox.values {
                                if let appId = self.safeString(item["id"]) { metadataState[appId] = item }
                            }
                            group.leave()
                            finished()
                        }
                    } else {
                        group.leave()
                        finished()
                    }
                }
            }
        }
        group.notify(queue: Self.workQueue) {
            let enriched = games.map { game in
                guard let metadata = metadataState[game.uuid] else { return game }
                return self.merging(game, with: self.parseGameItem(metadata))
            }
            self.fetchCampaignPromoTags(vpcId: vpcId, locale: Self.currentGFNCatalogLocale()) { tagsByCampaignId in
                let campaignEnriched = enriched.map { game in
                    guard game.promoTag.isEmpty else { return game }
                    var merged = game
                    merged.promoTag = game.campaignIds.compactMap { tagsByCampaignId[$0] }.first ?? ""
                    return merged
                }
                self.enrichRatingMetadata(campaignEnriched, locale: Self.currentGFNCatalogLocale(), completion: completion)
            }
        }
    }

    func enrichRatingMetadata(_ games: [OPNGameInfo], locale: String, completion: @escaping @Sendable ([OPNGameInfo]) -> Void) {
        guard games.contains(where: { !$0.ratingSystemName.isEmpty }) else {
            completion(games)
            return
        }
        fetchRatingDefinitions(locale: locale) { metadataByType in
            let enriched = games.map { game in
                guard let metadata = metadataByType[game.ratingSystemName.uppercased()] else { return game }
                var output = game
                metadata.apply(to: &output)
                return output
            }
            completion(enriched)
        }
    }

    func fetchRatingDefinitions(locale: String, completion: @escaping @Sendable ([String: RatingMetadata]) -> Void) {
        Self.referenceDataLock.lock()
        if let entry = Self.ratingDefinitionCache[locale], Date().timeIntervalSince(entry.timestamp) <= Self.referenceDataFreshSeconds {
            Self.referenceDataLock.unlock()
            completion(entry.value)
            return
        }
        if Self.pendingRatingDefinitionCallbacks[locale] != nil {
            Self.pendingRatingDefinitionCallbacks[locale]?.append(completion)
            Self.referenceDataLock.unlock()
            return
        }
        Self.pendingRatingDefinitionCallbacks[locale] = [completion]
        Self.referenceDataLock.unlock()

        fetchRatingDefinitionsUncached(locale: locale) { metadataByType in
            Self.referenceDataLock.lock()
            Self.ratingDefinitionCache[locale] = ReferenceDataEntry(value: metadataByType, timestamp: Date())
            let callbacks = Self.pendingRatingDefinitionCallbacks.removeValue(forKey: locale) ?? []
            Self.referenceDataLock.unlock()
            for callback in callbacks { callback(metadataByType) }
        }
    }

    func fetchRatingDefinitionsUncached(locale: String, completion: @escaping @Sendable ([String: RatingMetadata]) -> Void) {
        let query = """
        query GetRatingDefinitions($locale: String!) {
          ratingDefinitions(language: $locale) {
            ratingSystem
            label
            displayInterval
            contentDescriptors { key label sortOrder }
            interactiveElements { key label sortOrder }
            ratings { categoryKey description label minimumAge largeImageUrl smallImageUrl }
          }
        }
        """
        let variables: NSDictionary = ["locale": locale]
        postGraphQlJson(query: query, variables: variables) { [weak self] data, _ in
            guard let self else {
                completion([:])
                return
            }
            var metadataByType: [String: RatingMetadata] = [:]
            for item in data?["ratingDefinitions"] as? [NSDictionary] ?? [] {
                guard let type = self.safeString(item["ratingSystem"]), !type.isEmpty else { continue }
                metadataByType[type.uppercased()] = self.parseRatingMetadata(item)
            }
            completion(metadataByType)
        }
    }
}

private final class MetadataState: @unchecked Sendable {
    let lock = NSLock()
    var metadataById: [String: NSDictionary] = [:]

    subscript(appId: String) -> NSDictionary? {
        get { lock.withLock { metadataById[appId] } }
        set { lock.withLock { metadataById[appId] = newValue } }
    }
}
