//  Everything the catalog derives from a game object: its identity, the best image for each slot,
//  the labels the cards and detail panel print, and the text advanced search matches against.
//
//  This lived in `CatalogMediaViews`, inside the view layer, even though none of it touches
//  SwiftUI or AppKit. Moving it here is what lets `GameDetailPresentation` and the view models use
//  it without importing a view file.
//

import CoreGraphics
import Foundation

/// The artwork shapes the catalog serves. MARQUEE_HERO_IMAGE is the only type authored wider than
/// 16:9 - TV_BANNER measures 3840x2160, the same frame HERO_IMAGE ships in.
enum CatalogArtworkType {
    static let wide = ["MARQUEE_HERO_IMAGE"]
    static let landscape = ["HERO_IMAGE", "FEATURE_IMAGE", "KEY_ART", "TV_BANNER"]
    /// Above this the band is wider than any 16:9 asset by more than a tenth of its height.
    static let wideBandAspectRatio: CGFloat = 2.0
}

/// One width for every logo request: the width is baked into the CDN URL and the URL is the image
/// cache key, so two widths for one asset decode it twice.
enum CatalogLogoArtwork {
    static let requestWidth = 620
}

extension OPNCatalogGameObject {
    var catalogIdentity: String { CatalogViewModel.identity(for: self) }

    var cardBadgeLabel: String? {
        if isLaunchPatching { return patchStatusPrimaryDisplayText }
        return CatalogCardBadgeMapper.label(promoTag: promoTag, campaignIds: campaignIds, skuTags: skuTags, genres: genres, featureLabels: featureLabels)
    }

    var isLaunchPatching: Bool {
        isPatching || variants.contains { $0.isPatching }
    }

    var patchStatusPrimaryDisplayText: String {
        if !patchStatusPrimaryText.isEmpty { return patchStatusPrimaryText }
        return variants.first { !$0.patchStatusPrimaryText.isEmpty }?.patchStatusPrimaryText ?? "Patching"
    }

    var patchStatusSecondaryDisplayText: String {
        if !patchStatusSecondaryText.isEmpty { return patchStatusSecondaryText }
        return variants.first { !$0.patchStatusSecondaryText.isEmpty }?.patchStatusSecondaryText ?? ""
    }

    var cardPrimaryActionIsLaunchable: Bool {
        isInLibrary || variants.contains { $0.inLibrary || $0.librarySelected } || variants.isEmpty
    }

    /// The server spells its keys SCREAMING_SNAKE; the lowercased probe covers the loose top-level
    /// fields the parser folds into the same map.
    func firstImageURL(ofTypes types: [String]) -> String? {
        for type in types {
            if let value = imageUrlsByType[type]?.first, !value.isEmpty { return value }
            if let value = imageUrlsByType[type.lowercased()]?.first, !value.isEmpty { return value }
        }
        return nil
    }

    var bestHeroImageURL: String {
        if let value = firstImageURL(ofTypes: CatalogArtworkType.wide + ["HERO_IMAGE"]) { return value }
        if !heroImageUrl.isEmpty { return heroImageUrl }
        return bestTileImageURL
    }

    var bestMarqueeHeroImageURL: String {
        firstImageURL(ofTypes: CatalogArtworkType.wide) ?? bestHeroImageURL
    }

    var bestLogoImageURL: String {
        firstImageURL(ofTypes: ["GAME_LOGO", "LOGO", "TITLE_LOGO"]) ?? ""
    }

    var bestTileImageURL: String {
        if !imageUrl.isEmpty { return imageUrl }
        if let value = firstImageURL(ofTypes: ["BOX_ART", "BOXART", "TILE", "GAME_BOX_ART", "HERO_IMAGE"]) { return value }
        if let value = screenshotUrls.first, !value.isEmpty { return value }
        return heroImageUrl
    }

    var bestStorePickerPosterURL: String {
        firstImageURL(ofTypes: ["GAME_BOX_ART", "BOX_ART", "BOXART", "KEY_ART", "KEY_IMAGE"]) ?? bestTileImageURL
    }

    var bestWideImageURL: String {
        firstImageURL(ofTypes: ["TV_BANNER"]) ?? bestTileImageURL
    }

    /// A hero band three to five times wider than it is tall shows less than half a 16:9 frame, so
    /// the wider marquee artwork is read first whenever the band is wide enough to need it.
    func detailImageURL(forAspectRatio aspectRatio: CGFloat) -> String {
        if let value = firstImageURL(ofTypes: Self.detailImageTypes(forAspectRatio: aspectRatio)) { return value }
        if !heroImageUrl.isEmpty { return heroImageUrl }
        if let value = screenshotUrls.first, !value.isEmpty { return value }
        return imageUrl
    }

    var bestDetailImageURL: String { detailImageURL(forAspectRatio: 16 / 9) }

    private static func detailImageTypes(forAspectRatio aspectRatio: CGFloat) -> [String] {
        if aspectRatio >= CatalogArtworkType.wideBandAspectRatio {
            return CatalogArtworkType.wide + CatalogArtworkType.landscape
        }
        return CatalogArtworkType.landscape + CatalogArtworkType.wide
    }

    /// Screenshots only - the hero, logo and store art that `detailImageURLs` also carries are not
    /// screenshots, and listing them made the gallery open on a duplicate of the banner above it.
    var screenshotImageURLs: [String] {
        var values: [String] = []
        var seen = Set<String>()

        func append(_ value: String) {
            guard !value.isEmpty else { return }
            let key = String(value.prefix(while: { $0 != ";" }))
            guard !seen.contains(key) else { return }
            seen.insert(key)
            values.append(value)
        }

        for value in imageUrlsByType["SCREENSHOTS"] ?? [] { append(value) }
        for value in imageUrlsByType["screenshots"] ?? [] { append(value) }
        for value in screenshotUrls { append(value) }
        return values
    }

    var detailImageURLs: [String] {
        var values: [String] = []
        var seen = Set<String>()

        func append(_ value: String) {
            guard !value.isEmpty else { return }
            let key = String(value.prefix(while: { $0 != ";" }))
            guard !seen.contains(key) else { return }
            seen.insert(key)
            values.append(value)
        }

        func appendValues(forKey key: String) {
            for value in imageUrlsByType[key] ?? [] { append(value) }
            for value in imageUrlsByType[key.lowercased()] ?? [] { append(value) }
        }

        append(bestDetailImageURL)
        append(heroImageUrl)
        appendValues(forKey: "SCREENSHOTS")
        for value in screenshotUrls { append(value) }
        append(imageUrl)
        return values
    }

    var mallDisplayTitle: String {
        let displayTitle = shortName.isEmpty ? title : shortName
        return displayTitle.isEmpty ? "GEFORCE NOW" : displayTitle.uppercased()
    }

    var primaryStoreLabel: String {
        if let store = availableStores.first, !store.isEmpty { return store.capitalized }
        if let store = variants.first?.appStore, !store.isEmpty { return store.capitalized }
        return "GeForce NOW"
    }

    var ratingLabel: String {
        if !ratingCategoryTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ratingCategoryTitle }
        return contentRatings.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    var supportsKeyboard: Bool {
        supportedControls.contains { control in
            let value = control.lowercased()
            return value.contains("keyboard") || value.contains("mouse")
        }
    }

    var supportsGamepad: Bool {
        supportedControls.contains { control in
            let value = control.lowercased()
            return value.contains("gamepad") || value.contains("controller")
        }
    }

    var genreLine: String { genres.prefix(3).joined(separator: " / ") }

    var storeLine: String {
        let stores = availableStores.isEmpty ? variants.map(\.appStore) : availableStores
        return stores.filter { !$0.isEmpty }.map { $0.uppercased() }.joined(separator: ", ")
    }

    var advancedSearchText: String {
        var values = [
            id,
            uuid,
            launchAppId,
            title,
            shortName,
            gameDescription,
            shortDescription,
            longDescription,
            developerName,
            publisherName,
            releaseDate,
            playType,
            membershipTierLabel,
            playabilityState,
            ratingSystemName,
            ratingCategoryKey,
            ratingCategoryTitle,
            promoTag,
            primaryStoreLabel,
            genreLine,
            storeLine
        ]
        values.append(contentsOf: genres)
        values.append(contentsOf: featureLabels)
        values.append(contentsOf: supportedControls)
        values.append(contentsOf: contentRatings)
        values.append(contentsOf: ratingDescriptors)
        values.append(contentsOf: ratingInteractiveElements)
        values.append(contentsOf: nvidiaTech)
        values.append(contentsOf: availableStores)
        values.append(contentsOf: campaignIds)
        values.append(contentsOf: skuTags)
        for variant in variants {
            values.append(contentsOf: [variant.id, variant.shortName, variant.appStore, variant.appStoreLabel, variant.serviceStatus, variant.libraryStatus, variant.libraryPlayStatus, variant.librarySubscription, variant.developerName, variant.publisherName, variant.releaseDate])
            values.append(contentsOf: variant.supportedControls)
            values.append(contentsOf: variant.subscriptionIds)
            values.append(contentsOf: variant.paymentModelTypes)
            values.append(contentsOf: variant.supportedLanguages)
            values.append(contentsOf: variant.gfnFeatureLabels)
            if variant.inLibrary || variant.librarySelected { values.append("owned in library") }
            if variant.libraryInstalled { values.append("installed") }
            if variant.cloudSaveSupported { values.append("cloud saves") }
        }
        if isInLibrary { values.append("owned in library") }
        return values.joined(separator: " ").lowercased()
    }

    var detailChips: [String] {
        var chips: [String] = []
        if isInLibrary { chips.append("IN LIBRARY") }
        if !skuPlayabilityText.isEmpty { chips.append(skuPlayabilityText.uppercased()) }
        if !membershipTierLabel.isEmpty { chips.append(membershipTierLabel.uppercased()) }
        if !playabilityState.isEmpty { chips.append(playabilityState.replacingOccurrences(of: "_", with: " ").uppercased()) }
        chips.append(contentsOf: genres.prefix(3).map { $0.uppercased() })
        return chips.isEmpty ? ["CLOUD READY"] : chips
    }
}
