//
//  OpenNOW
//

import AppKit
import Foundation

extension OPNGameService {
    func parseGameItem(_ app: NSDictionary?) -> OPNGameInfo {
        guard let app else { return OPNGameInfo() }
        var game = OPNGameInfo()
        applyIdentity(app, to: &game)
        applyItemMetadata(app, to: &game)
        applyGfnMetadata(app, to: &game)
        applyImages(app, to: &game)
        applyVariants(app, to: &game)
        applyVariantRollup(to: &game)
        applyGenresAndFeatures(app, to: &game)
        return game
    }

    /// Titles, descriptions and the flat scalar fields the catalog carries at the top level.
    private func applyIdentity(_ app: NSDictionary, to game: inout OPNGameInfo) {
        game.id = safeString(app["id"]) ?? ""
        game.uuid = game.id
        game.title = safeString(app["title"]) ?? ""
        game.shortName = safeString(app["shortName"]) ?? ""
        game.promoTag = safeString(app["promoTag"]) ?? ""
        game.shortDescription = firstSafeString(app, keys: ["shortDescription", "summary"]) ?? ""
        game.longDescription = firstSafeString(app, keys: ["longDescription", "description"]) ?? ""
        game.description = game.longDescription.isEmpty ? game.shortDescription : game.longDescription
        game.developerName = safeString(app["developerName"]) ?? ""
        game.publisherName = safeString(app["publisherName"]) ?? ""
        game.releaseDate = firstSafeString(app, keys: ["streetDate", "releaseDate", "releasedAt"]) ?? ""
        game.maxLocalPlayers = safeInt(app["maxLocalPlayers"])
        game.maxOnlinePlayers = safeInt(app["maxOnlinePlayers"])
        game.displaysOwnRatingDuringGameplay = safeBool(app["displaysOwnRatingDuringGameplay"])
        appendStringValues(&game.supportedControls, app["supportedControls"])
        assignContentRatings(app["contentRatings"], to: &game)
        game.nvidiaTech = parseFeatureFlags(app["nvidiaTech"])
    }

    /// `itemMetadata` only ever fills in what the top level left empty.
    private func applyItemMetadata(_ app: NSDictionary, to game: inout OPNGameInfo) {
        guard let itemMetadata = app["itemMetadata"] as? NSDictionary else { return }
        if game.shortDescription.isEmpty { game.shortDescription = firstSafeString(itemMetadata, keys: ["shortDescription", "summary"]) ?? "" }
        if game.longDescription.isEmpty { game.longDescription = firstSafeString(itemMetadata, keys: ["longDescription", "description"]) ?? "" }
        if game.description.isEmpty { game.description = game.longDescription.isEmpty ? game.shortDescription : game.longDescription }
        appendStringValues(&game.campaignIds, itemMetadata["campaignIds"])
        if game.promoTag.isEmpty { game.promoTag = safeString(itemMetadata["promoTag"]) ?? "" }
    }

    /// Playability, membership tier and the SKU-based copy the seat serves alongside them.
    private func applyGfnMetadata(_ app: NSDictionary, to game: inout OPNGameInfo) {
        if let library = app["library"] as? NSDictionary {
            game.isFavorited = safeBool(library["favorited"])
        }
        guard let gfn = app["gfn"] as? NSDictionary else { return }
        game.playabilityState = safeString(gfn["playabilityState"]) ?? ""
        game.membershipTierLabel = safeString(gfn["minimumMembershipTierLabel"]) ?? ""
        game.playType = safeString(gfn["playType"]) ?? ""
        game.isPatching = isAppPatchingStatus(gfn["playabilityState"])
        if game.promoTag.isEmpty { game.promoTag = safeString(gfn["promoTag"]) ?? "" }
        guard let catalogSkuStrings = gfn["catalogSkuStrings"] as? NSDictionary else { return }
        appendStringValues(&game.skuTags, catalogSkuStrings["SKU_BASED_TAG"])
        game.skuPlayabilityText = safeString(catalogSkuStrings["SKU_BASED_PLAYABILITY_TEXT"]) ?? ""
        game.skuUnplayableDialogHeader = safeString(catalogSkuStrings["SKU_BASED_UNPLAYABLE_DIALOG_HEADER"]) ?? ""
        game.skuUnplayableDialogBody = safeString(catalogSkuStrings["SKU_BASED_UNPLAYABLE_DIALOG_BODY_UPGRADE"]) ?? ""
        game.skuUnplayableDialogBodyEcommerceRestricted = safeString(catalogSkuStrings["SKU_BASED_UNPLAYABLE_DIALOG_BODY_UPGRADE_ECOMM_RESTRICTED"]) ?? ""
    }

    /// The `images` map plus the loose top-level image keys, then the hero/tile fallbacks.
    private func applyImages(_ app: NSDictionary, to game: inout OPNGameInfo) {
        if let images = app["images"] as? NSDictionary {
            for case let key as String in images.allKeys {
                let urls = imageStrings(from: images[key]).map { Self.optimizeImageURL($0, width: 1200) }.uniqueValues()
                if !urls.isEmpty { game.imageUrlsByType[key] = urls }
            }
            let landscape = firstLandscapeImageString(images)
            let primary = landscape ?? firstPosterImageString(images)
            if let landscape { game.heroImageUrl = Self.optimizeImageURL(landscape, width: 1200) }
            if let primary { game.imageUrl = Self.optimizeImageURL(primary, width: 900) }
            game.screenshotUrls = imageStrings(from: images["SCREENSHOTS"]).map { Self.optimizeImageURL($0, width: 720) }.uniqueValues()
        }
        appendDirectImage(firstSafeString(app, keys: ["marqueeHeroImage", "marqueeHeroImageUrl", "marqueeImage", "marqueeImageUrl"]), type: "MARQUEE_HERO_IMAGE", width: 1920, game: &game)
        appendDirectImage(firstSafeString(app, keys: ["heroImage", "heroImageUrl"]), type: "HERO_IMAGE", width: 1920, game: &game)
        appendDirectImage(firstSafeString(app, keys: ["logoImage", "logoImageUrl", "gameLogo", "gameLogoUrl"]), type: "GAME_LOGO", width: 620, game: &game)
        appendDirectImage(firstSafeString(app, keys: ["imageUrl", "tileImage", "tileImageUrl"]), type: "KEY_IMAGE", width: 900, game: &game)
        if let marqueeHeroImage = game.imageUrlsByType["MARQUEE_HERO_IMAGE"]?.first, !marqueeHeroImage.isEmpty {
            game.heroImageUrl = marqueeHeroImage
        } else if let heroImage = game.imageUrlsByType["HERO_IMAGE"]?.first, !heroImage.isEmpty {
            game.heroImageUrl = heroImage
        }
        if game.imageUrl.isEmpty {
            game.imageUrl = game.imageUrlsByType["TV_BANNER"]?.first ?? game.imageUrlsByType["KEY_IMAGE"]?.first ?? game.imageUrlsByType["GAME_BOX_ART"]?.first ?? ""
        }
    }

    /// One entry per store the title is sold through. Variants from the same store merge rather
    /// than stack, so a title listed twice does not appear twice in the detail panel.
    private func applyVariants(_ app: NSDictionary, to game: inout OPNGameInfo) {
        guard let variants = app["variants"] as? [NSDictionary] else { return }
        for item in variants {
            let variant = parseVariant(item)
            if game.contentRatings.isEmpty { assignContentRatings(item["contentRatings"], to: &game) }
            guard Self.variantIsRelevant(variant) else { continue }
            if let index = game.variants.firstIndex(where: { variantMatchesStoreMetadata(target: $0, metadata: variant) }) {
                _ = mergeVariantFromSameStore(target: &game.variants[index], source: variant)
            } else {
                if !variant.appStore.isEmpty { game.availableStores.append(variant.appStore) }
                game.variants.append(variant)
            }
        }
    }

    private func parseVariant(_ item: NSDictionary) -> OPNGameVariant {
        var variant = OPNGameVariant()
        variant.id = safeString(item["id"]) ?? ""
        variant.shortName = safeString(item["shortName"]) ?? ""
        variant.appStore = Self.normalizedVariantAppStore(safeString(item["appStore"]) ?? "")
        variant.storeUrl = safeString(item["storeUrl"]) ?? ""
        variant.developerName = safeString(item["developerName"]) ?? ""
        variant.publisherName = safeString(item["publisherName"]) ?? ""
        variant.releaseDate = firstSafeString(item, keys: ["streetDate", "releaseDate", "releasedAt"]) ?? ""
        appendStringValues(&variant.supportedControls, item["supportedControls"])
        appendStringValues(&variant.subscriptionIds, item["subscriptions"])
        variant.paymentModelTypes = parsePaymentModelTypes(item["paymentModels"])
        variant.minimumSizeInBytes = safeInt(item["minimumSizeInBytes"])
        variant.cloudSaveSupported = safeBool(item["cloudSaveSupported"])
        if let appStoreInfo = item["appStoreInfo"] as? NSDictionary {
            variant.appStoreLabel = safeString(appStoreInfo["label"]) ?? ""
            variant.appStoreSmallImageUrl = safeString(appStoreInfo["smallImageUrl"]) ?? ""
        }
        if let gfn = item["gfn"] as? NSDictionary {
            applyVariantGfn(gfn, to: &variant)
        }
        return variant
    }

    /// Service status and patch state for one variant.
    private func applyVariantGfn(_ gfn: NSDictionary, to variant: inout OPNGameVariant) {
        variant.serviceStatus = safeString(gfn["status"]) ?? ""
        variant.isPatching = currentStatusIsPatching(status: gfn["status"], playabilityState: gfn["playabilityState"], libraryStatus: nil, stateDetails: gfn["stateDetails"])
        let patchText = patchStatusText(status: gfn["status"], stateDetails: gfn["stateDetails"], isPatching: variant.isPatching)
        variant.patchStatusPrimaryText = patchText.primary
        variant.patchStatusSecondaryText = patchText.secondary
        variant.installTimeInMinutes = safeInt(gfn["installTimeInMinutes"])
        variant.supportedLanguages = parseSupportedLanguages(gfn["supportedLanguages"])
        variant.gfnFeatureLabels = parseGfnFeatureLabels(gfn["features"])
        guard let library = gfn["library"] as? NSDictionary else { return }
        applyVariantLibrary(library, gfn: gfn, to: &variant)
    }

    /// The account's own view of a variant: owned, installed, and which store it plays from. The
    /// library's status wins over the catalog's when it has one.
    private func applyVariantLibrary(_ library: NSDictionary, gfn: NSDictionary, to variant: inout OPNGameVariant) {
        let libraryStatus = firstSafeString(library, keys: ["status"]) ?? ""
        variant.libraryStatus = libraryStatus
        variant.libraryPlayStatus = safeString(library["playStatus"]) ?? ""
        variant.libraryInstalled = safeBool(library["installed"])
        variant.librarySubscription = safeString(library["subscription"]) ?? ""
        variant.serviceStatus = libraryStatus.isEmpty ? variant.serviceStatus : libraryStatus
        variant.isPatching = currentStatusIsPatching(status: gfn["status"], playabilityState: gfn["playabilityState"], libraryStatus: library["status"], stateDetails: gfn["stateDetails"])
        if variant.patchStatusPrimaryText.isEmpty {
            let patchText = patchStatusText(status: library["status"], stateDetails: gfn["stateDetails"], isPatching: variant.isPatching)
            variant.patchStatusPrimaryText = patchText.primary
            variant.patchStatusSecondaryText = patchText.secondary
        }
        variant.librarySelected = safeBool(library["selected"])
        if variant.librarySelected || Self.libraryStatusIsOwned(libraryStatus) { variant.inLibrary = true }
    }

    /// What the parsed variants say about the title as a whole, including which app id a launch
    /// should use.
    private func applyVariantRollup(to game: inout OPNGameInfo) {
        var firstNumericVariant = ""
        for variant in game.variants {
            if variant.inLibrary { game.isInLibrary = true }
            if variant.isPatching { game.isPatching = true }
            if game.patchStatusPrimaryText.isEmpty { game.patchStatusPrimaryText = variant.patchStatusPrimaryText }
            if game.patchStatusSecondaryText.isEmpty { game.patchStatusSecondaryText = variant.patchStatusSecondaryText }
            if variant.paymentModelTypes.contains(where: Self.paymentModelIsFreeToPlay) { game.isFreeToPlay = true }
            let numeric = !variant.id.isEmpty && variant.id.allSatisfy(\.isNumber)
            if numeric, variant.librarySelected { game.launchAppId = variant.id }
            if numeric, firstNumericVariant.isEmpty { firstNumericVariant = variant.id }
        }
        if game.launchAppId.isEmpty { game.launchAppId = firstNumericVariant }
    }

    /// Genres arrive as either bare strings or `{name:}` objects depending on the endpoint.
    private func applyGenresAndFeatures(_ app: NSDictionary, to game: inout OPNGameInfo) {
        if let genres = app["genres"] as? [Any] {
            for item in genres {
                if let text = item as? String { appendUnique(&game.genres, text) }
                if let dictionary = item as? NSDictionary { appendUnique(&game.genres, safeString(dictionary["name"]) ?? "") }
            }
        }
        if let features = (app["featureLabels"] ?? app["features"]) as? [String] {
            for feature in features { appendUnique(&game.featureLabels, feature) }
        }
    }

    func firstSafeString(_ dictionary: NSDictionary, keys: [String]) -> String? {
        for key in keys {
            if let value = safeString(dictionary[key]), !value.isEmpty { return value }
        }
        return nil
    }

    func appendDirectImage(_ value: String?, type: String, width: Int, game: inout OPNGameInfo) {
        guard let value, !value.isEmpty else { return }
        var urls = game.imageUrlsByType[type] ?? []
        appendUnique(&urls, Self.optimizeImageURL(value, width: width))
        if !urls.isEmpty { game.imageUrlsByType[type] = urls }
    }

    func imageStrings(from rawValue: Any?) -> [String] {
        guard let rawValue, !(rawValue is NSNull) else { return [] }
        if let text = rawValue as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let array = rawValue as? [Any] { return array.flatMap { imageStrings(from: $0) }.uniqueValues() }
        guard let dictionary = rawValue as? NSDictionary else { return [] }
        if let directURL = firstSafeString(dictionary, keys: ["url", "URL", "src", "href", "imageUrl", "imageURL", "thumbnailUrl", "thumbnailURL", "contentUrl", "contentURL"]) {
            return imageStrings(from: directURL)
        }
        return dictionary.allValues.flatMap { imageStrings(from: $0) }.uniqueValues()
    }

    func firstImageString(_ images: NSDictionary, keys: [String]) -> String? {
        for key in keys {
            if let url = imageStrings(from: images[key]).first, !url.isEmpty { return url }
        }
        return nil
    }

    func firstLandscapeImageString(_ images: NSDictionary) -> String? {
        firstImageString(images, keys: ["MARQUEE_HERO_IMAGE", "HERO_IMAGE", "TV_BANNER", "FEATURE_IMAGE", "KEY_IMAGE", "KEY_ART"])
    }

    func firstPosterImageString(_ images: NSDictionary) -> String? {
        firstImageString(images, keys: ["GAME_BOX_ART", "KEY_IMAGE", "KEY_ART"])
    }

    func appendStringValues(_ values: inout [String], _ rawValue: Any?) {
        if let text = rawValue as? String {
            appendUnique(&values, text)
            return
        }
        for item in rawValue as? [Any] ?? [] {
            if let text = item as? String { appendUnique(&values, text) }
            if let dictionary = item as? NSDictionary { appendUnique(&values, firstSafeString(dictionary, keys: ["name", "label", "value", "rating", "control", "type"]) ?? "") }
        }
    }

    func assignContentRatings(_ rawValue: Any?, to game: inout OPNGameInfo) {
        guard let rawValue, !(rawValue is NSNull) else { return }
        var values: [String] = []
        let entries = rawValue as? [Any] ?? [rawValue]
        for entry in entries {
            if let text = entry as? String {
                appendUnique(&values, readableMetadataLabel(text))
                continue
            }
            guard let dictionary = entry as? NSDictionary else { continue }
            let categoryKey = firstSafeString(dictionary, keys: ["categoryKey", "ratingCategoryKey", "rating", "category", "label", "name"]) ?? ""
            let type = firstSafeString(dictionary, keys: ["type", "ratingSystem", "system"]) ?? ""
            let categoryLabel = ratingCategoryLabel(categoryKey: categoryKey, type: type) ?? ""
            if game.ratingSystemName.isEmpty { game.ratingSystemName = readableRatingSystem(type) }
            if game.ratingCategoryKey.isEmpty { game.ratingCategoryKey = categoryKey }
            if game.ratingCategoryTitle.isEmpty { game.ratingCategoryTitle = categoryLabel }
            if game.ratingImageUrl.isEmpty { game.ratingImageUrl = ratingImageString(dictionary["rating"] ?? dictionary["image"] ?? dictionary["images"] ?? dictionary["largeImageUrl"]) }
            if !categoryLabel.isEmpty { appendUnique(&values, categoryLabel) }
            appendUnique(&values, readableRatingSystem(type))
            appendMetadataLabels(&game.ratingDescriptors, dictionary["contentDescriptorKeys"])
            appendMetadataLabels(&game.ratingInteractiveElements, dictionary["interactiveElementKeys"])
            for descriptor in game.ratingDescriptors { appendUnique(&values, descriptor) }
            for element in game.ratingInteractiveElements { appendUnique(&values, element) }
        }
        game.contentRatings = values.filter { !$0.isEmpty }
    }

    func parseFeatureFlags(_ rawValue: Any?) -> [String] {
        guard let rawValue, !(rawValue is NSNull) else { return [] }
        if let dictionary = rawValue as? NSDictionary {
            var values: [String] = []
            for case let key as String in dictionary.allKeys where safeBool(dictionary[key]) {
                appendUnique(&values, readableMetadataLabel(key))
            }
            return values
        }
        var values: [String] = []
        appendStringValues(&values, rawValue)
        return values.map(readableMetadataLabel)
    }

    func parsePaymentModelTypes(_ rawValue: Any?) -> [String] {
        var values: [String] = []
        for item in rawValue as? [Any] ?? [] {
            if let text = item as? String { appendUnique(&values, text) }
            if let dictionary = item as? NSDictionary { appendUnique(&values, safeString(dictionary["__typename"]) ?? "") }
        }
        return values
    }

    func parseSupportedLanguages(_ rawValue: Any?) -> [String] {
        var values: [String] = []
        for item in rawValue as? [Any] ?? [] {
            if let text = item as? String { appendUnique(&values, text) }
            if let dictionary = item as? NSDictionary { appendUnique(&values, safeString(dictionary["language"]) ?? "") }
        }
        return values
    }

    func parseGfnFeatureLabels(_ rawValue: Any?) -> [String] {
        var values: [String] = []
        for item in rawValue as? [Any] ?? [] {
            if let text = item as? String { appendUnique(&values, readableMetadataLabel(text)) }
            guard let dictionary = item as? NSDictionary else { continue }
            let key = safeString(dictionary["key"]) ?? safeString(dictionary["__typename"]) ?? ""
            if !key.isEmpty { appendUnique(&values, readableMetadataLabel(key)) }
            appendStringValues(&values, dictionary["values"])
            appendStringValues(&values, dictionary["value"])
        }
        return values
    }

    func parseRatingMetadata(_ dictionary: NSDictionary?) -> RatingMetadata {
        var metadata = RatingMetadata()
        for entry in dictionary?["ratings"] as? [NSDictionary] ?? [] {
            let key = (safeString(entry["categoryKey"]) ?? "").uppercased()
            guard !key.isEmpty else { continue }
            metadata.ratingsByCategoryKey[key] = RatingCategoryMetadata(
                label: safeString(entry["label"]) ?? "",
                largeImageUrl: safeString(entry["largeImageUrl"]) ?? "",
                smallImageUrl: safeString(entry["smallImageUrl"]) ?? ""
            )
        }
        for entry in dictionary?["contentDescriptors"] as? [NSDictionary] ?? [] {
            let key = (safeString(entry["key"]) ?? "").uppercased()
            let label = safeString(entry["label"]) ?? ""
            if !key.isEmpty, !label.isEmpty { metadata.contentDescriptorsByKey[key] = label }
        }
        for entry in dictionary?["interactiveElements"] as? [NSDictionary] ?? [] {
            let key = (safeString(entry["key"]) ?? "").uppercased()
            let label = safeString(entry["label"]) ?? ""
            if !key.isEmpty, !label.isEmpty { metadata.interactiveElementsByKey[key] = label }
        }
        return metadata
    }

    func appendMetadataLabels(_ values: inout [String], _ rawValue: Any?) {
        for value in safeStringArray(rawValue) {
            appendUnique(&values, readableMetadataLabel(value))
        }
    }

    func ratingCategoryLabel(categoryKey: String, type: String) -> String? {
        let key = categoryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let normalized = key.uppercased().replacingOccurrences(of: "-", with: "_")
        let esrbLabels: [String: String] = [
            "EARLY_CHILDHOOD": "Early Childhood",
            "EVERYONE": "Everyone",
            "EVERYONE_10": "Everyone 10+",
            "EVERYONE_10_PLUS": "Everyone 10+",
            "TEEN": "Teen",
            "MATURE": "Mature 17+",
            "MATURE_17": "Mature 17+",
            "MATURE_17_PLUS": "Mature 17+",
            "ADULTS_ONLY": "Adults Only 18+",
            "ADULTS_ONLY_18": "Adults Only 18+",
            "ADULTS_ONLY_18_PLUS": "Adults Only 18+",
            "RATING_PENDING": "Rating Pending"
        ]
        if type.uppercased() == "ESRB", let label = esrbLabels[normalized] { return label }
        return readableMetadataLabel(key)
    }

    func readableRatingSystem(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 8 ? trimmed.uppercased() : readableMetadataLabel(trimmed)
    }

    func ratingImageString(_ rawValue: Any?) -> String {
        if let text = safeString(rawValue) { return text }
        guard let dictionary = rawValue as? NSDictionary else { return "" }
        return firstSafeString(dictionary, keys: ["largeImageUrl", "smallImageUrl", "imageUrl", "url", "src"]) ?? ""
    }

    func readableMetadataLabel(_ value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return normalized
            .split(separator: " ")
            .map { word in word.prefix(1).uppercased() + word.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    func appendUnique(_ values: inout [String], _ value: String) {
        if !value.isEmpty, !values.contains(value) { values.append(value) }
    }

    func deepMergeDictionary(into target: inout [String: Any], source: [String: Any]) {
        for (key, value) in source {
            if var targetDictionary = target[key] as? [String: Any], let sourceDictionary = value as? [String: Any] {
                deepMergeDictionary(into: &targetDictionary, source: sourceDictionary)
                target[key] = targetDictionary
            } else {
                target[key] = value
            }
        }
    }

    /// Fields a merge fills in when the destination is still empty. Listed rather than written out
    /// one `if` per field, because the rule is the same for every one of them.
    // Computed, not stored: `WritableKeyPath` is non-Sendable by design, so a `static let` would
    // need a `nonisolated(unsafe)` the reader has to take on trust. These are read once per
    // merged record, well off any hot path.
    private static var sameStoreStringFields: [WritableKeyPath<OPNGameVariant, String>] { [
        \.shortName, \.appStoreLabel, \.appStoreSmallImageUrl, \.storeUrl,
        \.developerName, \.publisherName, \.releaseDate,
        \.libraryStatus, \.libraryPlayStatus, \.librarySubscription
    ] }

    /// A store-metadata merge fills in the identity fields too — the catalog row it merges into may
    /// have come from a source that never carried them.
    private static var storeMetadataStringFields: [WritableKeyPath<OPNGameVariant, String>] {
        sameStoreStringFields + [\.id, \.appStore, \.serviceStatus, \.patchStatusPrimaryText, \.patchStatusSecondaryText]
    }

    private static var mergeableListFields: [WritableKeyPath<OPNGameVariant, [String]>] { [
        \.supportedControls, \.subscriptionIds, \.paymentModelTypes, \.supportedLanguages, \.gfnFeatureLabels
    ] }

    private static var mergeableFlagFields: [WritableKeyPath<OPNGameVariant, Bool>] { [
        \.libraryInstalled, \.cloudSaveSupported, \.librarySelected, \.inLibrary
    ] }

    private static var mergeableCountFields: [WritableKeyPath<OPNGameVariant, Int>] { [
        \.minimumSizeInBytes, \.installTimeInMinutes
    ] }

    /// Copies every listed field that `target` still lacks. Returns whether anything changed.
    @discardableResult
    private func fillEmptyFields(_ target: inout OPNGameVariant,
                                 from source: OPNGameVariant,
                                 stringFields: [WritableKeyPath<OPNGameVariant, String>]) -> Bool {
        var changed = false
        for field in stringFields where target[keyPath: field].isEmpty && !source[keyPath: field].isEmpty {
            target[keyPath: field] = source[keyPath: field]
            changed = true
        }
        for field in Self.mergeableListFields where target[keyPath: field].isEmpty && !source[keyPath: field].isEmpty {
            target[keyPath: field] = source[keyPath: field]
            changed = true
        }
        for field in Self.mergeableFlagFields where !target[keyPath: field] && source[keyPath: field] {
            target[keyPath: field] = true
            changed = true
        }
        for field in Self.mergeableCountFields where target[keyPath: field] <= 0 && source[keyPath: field] > 0 {
            target[keyPath: field] = source[keyPath: field]
            changed = true
        }
        return changed
    }

    /// Two listings of the same title on the same store. The library-selected one is authoritative
    /// about the launch id and the service status; everything else is filled in where missing.
    func mergeVariantFromSameStore(target: inout OPNGameVariant, source: OPNGameVariant) -> Bool {
        var changed = false
        // Both overrides run before `fillEmptyFields`, which itself sets `librarySelected`: read
        // after it, `!target.librarySelected` is never true and the authoritative branch is dead.
        if !source.id.isEmpty, target.id.isEmpty || (!target.librarySelected && source.librarySelected) {
            target.id = source.id
            changed = true
        }
        if !source.serviceStatus.isEmpty, target.serviceStatus.isEmpty || (!target.librarySelected && source.librarySelected) {
            target.serviceStatus = source.serviceStatus
            changed = true
        }
        let filled = fillEmptyFields(&target, from: source, stringFields: Self.sameStoreStringFields)
        return filled || changed
    }

    func mergeMissingStoreMetadata(target: inout OPNGameInfo, metadata: OPNGameInfo) {
        if target.launchAppId.isEmpty { target.launchAppId = metadata.launchAppId }
        if !target.displaysOwnRatingDuringGameplay { target.displaysOwnRatingDuringGameplay = metadata.displaysOwnRatingDuringGameplay }
        for store in metadata.availableStores where !target.availableStores.contains(where: { $0.caseInsensitiveCompare(store) == .orderedSame }) { target.availableStores.append(store) }
        for metadataVariant in metadata.variants {
            if let index = target.variants.firstIndex(where: { variantMatchesStoreMetadata(target: $0, metadata: metadataVariant) }) {
                fillEmptyFields(&target.variants[index], from: metadataVariant, stringFields: Self.storeMetadataStringFields)
            } else if !metadataVariant.appStore.isEmpty {
                target.variants.append(metadataVariant)
                if !target.availableStores.contains(where: { $0.caseInsensitiveCompare(metadataVariant.appStore) == .orderedSame }) { target.availableStores.append(metadataVariant.appStore) }
            }
        }
    }

    func variantMatchesStoreMetadata(target: OPNGameVariant, metadata: OPNGameVariant) -> Bool {
        if !target.id.isEmpty, !metadata.id.isEmpty, target.id == metadata.id { return true }
        if !target.appStore.isEmpty, !metadata.appStore.isEmpty, target.appStore.caseInsensitiveCompare(metadata.appStore) == .orderedSame { return true }
        return false
    }

    static var libraryCatalogFilter: NSDictionary {
        libraryCatalogFilterPayload as NSDictionary
    }

    /// Payloads for the server-defined `collections` filter group. The catalog normally delivers
    /// these through `filterGroupDefinitions`; we keep copies so a locale/account that returns no
    /// definitions still scopes My Library / My Favorites instead of silently browsing everything.
    static var libraryCatalogFilterPayload: [String: Any] {
        ["variants": ["gfn": ["library": ["status": ["notEquals": "NOT_OWNED"]]]]]
    }

    static var favoritesCatalogFilterPayload: [String: Any] {
        ["library": ["favorited": ["equals": true]]]
    }

    static func libraryStatusIsOwned(_ status: String) -> Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && normalized.caseInsensitiveCompare("NOT_OWNED") != .orderedSame
    }

    static func normalizedVariantAppStore(_ appStore: String) -> String {
        let normalized = appStore.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.caseInsensitiveCompare("UNKNOWN") == .orderedSame { return "" }
        if normalized.caseInsensitiveCompare("NONE") == .orderedSame { return "" }
        return normalized
    }

    static func variantIsRelevant(_ variant: OPNGameVariant) -> Bool {
        !variant.appStore.isEmpty || variant.inLibrary || variant.librarySelected || OPNLaunchAppId.resolve(variant.id) != nil
    }

    static func paymentModelIsFreeToPlay(_ value: String) -> Bool {
        let normalized = value.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        return normalized.contains("freetoplay") || normalized.contains("freegame") || normalized == "free"
    }
}

struct RatingCategoryMetadata: Sendable {
    var label = ""
    var largeImageUrl = ""
    var smallImageUrl = ""
}

struct RatingMetadata: Sendable {
    var ratingsByCategoryKey: [String: RatingCategoryMetadata] = [:]
    var contentDescriptorsByKey: [String: String] = [:]
    var interactiveElementsByKey: [String: String] = [:]

    func apply(to game: inout OPNGameInfo) {
        let normalizedCategory = game.ratingCategoryKey.uppercased().replacingOccurrences(of: "-", with: "_")
        let rating = ratingsByCategoryKey[normalizedCategory] ?? ratingsByCategoryKey.first { $0.value.label.caseInsensitiveCompare(game.ratingCategoryTitle) == .orderedSame }?.value
        if let rating {
            if !rating.label.isEmpty { game.ratingCategoryTitle = rating.label }
            if game.ratingImageUrl.isEmpty { game.ratingImageUrl = rating.largeImageUrl.isEmpty ? rating.smallImageUrl : rating.largeImageUrl }
        }
        game.ratingDescriptors = game.ratingDescriptors.map { contentDescriptorsByKey[$0.uppercased().replacingOccurrences(of: " ", with: "_")] ?? $0 }
        game.ratingInteractiveElements = game.ratingInteractiveElements.map { interactiveElementsByKey[$0.uppercased().replacingOccurrences(of: " ", with: "_")] ?? $0 }
        var contentRatings: [String] = []
        if !game.ratingCategoryTitle.isEmpty { contentRatings.append(game.ratingCategoryTitle) }
        if !game.ratingSystemName.isEmpty { contentRatings.append(game.ratingSystemName) }
        contentRatings.append(contentsOf: game.ratingDescriptors)
        contentRatings.append(contentsOf: game.ratingInteractiveElements)
        if !contentRatings.isEmpty { game.contentRatings = contentRatings }
    }
}

private extension Array where Element: Hashable {
    func uniqueValues() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
