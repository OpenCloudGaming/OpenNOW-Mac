//
//  MacForceNow
//

import AppKit
import Foundation

extension OPNGameService {
    func parseGameItem(_ app: NSDictionary?) -> OPNGameInfo {
        guard let app else { return OPNGameInfo() }
        var game = OPNGameInfo()
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
        if let itemMetadata = app["itemMetadata"] as? NSDictionary {
            if game.shortDescription.isEmpty { game.shortDescription = firstSafeString(itemMetadata, keys: ["shortDescription", "summary"]) ?? "" }
            if game.longDescription.isEmpty { game.longDescription = firstSafeString(itemMetadata, keys: ["longDescription", "description"]) ?? "" }
            if game.description.isEmpty { game.description = game.longDescription.isEmpty ? game.shortDescription : game.longDescription }
        }
        if let itemMetadata = app["itemMetadata"] as? NSDictionary {
            appendStringValues(&game.campaignIds, itemMetadata["campaignIds"])
            if game.promoTag.isEmpty { game.promoTag = safeString(itemMetadata["promoTag"]) ?? "" }
        }
        if let gfn = app["gfn"] as? NSDictionary {
            game.playabilityState = safeString(gfn["playabilityState"]) ?? ""
            game.membershipTierLabel = safeString(gfn["minimumMembershipTierLabel"]) ?? ""
            game.playType = safeString(gfn["playType"]) ?? ""
            game.isPatching = isAppPatchingStatus(gfn["playabilityState"])
            if game.promoTag.isEmpty { game.promoTag = safeString(gfn["promoTag"]) ?? "" }
            if let catalogSkuStrings = gfn["catalogSkuStrings"] as? NSDictionary {
                appendStringValues(&game.skuTags, catalogSkuStrings["SKU_BASED_TAG"])
                game.skuPlayabilityText = safeString(catalogSkuStrings["SKU_BASED_PLAYABILITY_TEXT"]) ?? ""
                game.skuUnplayableDialogHeader = safeString(catalogSkuStrings["SKU_BASED_UNPLAYABLE_DIALOG_HEADER"]) ?? ""
                game.skuUnplayableDialogBody = safeString(catalogSkuStrings["SKU_BASED_UNPLAYABLE_DIALOG_BODY_UPGRADE"]) ?? ""
                game.skuUnplayableDialogBodyEcommerceRestricted = safeString(catalogSkuStrings["SKU_BASED_UNPLAYABLE_DIALOG_BODY_UPGRADE_ECOMM_RESTRICTED"]) ?? ""
            }
        }
        if let library = app["library"] as? NSDictionary {
            game.isFavorited = safeBool(library["favorited"])
        }
        if let images = app["images"] as? NSDictionary {
            for case let key as String in images.allKeys {
                let urls = imageStrings(from: images[key]).map { Self.optimizeImageURL($0, width: 1200) }.uniqueValues()
                if !urls.isEmpty { game.imageUrlsByType[key] = urls }
            }
            let landscape = firstLandscapeImageString(images)
            let poster = firstPosterImageString(images)
            let primary = landscape ?? poster
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
        if let variants = app["variants"] as? [NSDictionary] {
            for item in variants {
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
                    variant.serviceStatus = safeString(gfn["status"]) ?? ""
                    variant.isPatching = currentStatusIsPatching(status: gfn["status"], playabilityState: gfn["playabilityState"], libraryStatus: nil, stateDetails: gfn["stateDetails"])
                    let patchText = patchStatusText(status: gfn["status"], stateDetails: gfn["stateDetails"], isPatching: variant.isPatching)
                    variant.patchStatusPrimaryText = patchText.primary
                    variant.patchStatusSecondaryText = patchText.secondary
                    variant.installTimeInMinutes = safeInt(gfn["installTimeInMinutes"])
                    variant.supportedLanguages = parseSupportedLanguages(gfn["supportedLanguages"])
                    variant.gfnFeatureLabels = parseGfnFeatureLabels(gfn["features"])
                    if let library = gfn["library"] as? NSDictionary {
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
                }
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
        if let genres = app["genres"] as? [Any] {
            for item in genres {
                if let text = item as? String { appendUnique(&game.genres, text) }
                if let dictionary = item as? NSDictionary { appendUnique(&game.genres, safeString(dictionary["name"]) ?? "") }
            }
        }
        if let features = (app["featureLabels"] ?? app["features"]) as? [String] {
            for feature in features { appendUnique(&game.featureLabels, feature) }
        }
        return game
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

    func mergeVariantFromSameStore(target: inout OPNGameVariant, source: OPNGameVariant) -> Bool {
        var changed = false
        if !source.id.isEmpty, target.id.isEmpty || (!target.librarySelected && source.librarySelected) { target.id = source.id; changed = true }
        if target.shortName.isEmpty, !source.shortName.isEmpty { target.shortName = source.shortName; changed = true }
        if target.appStoreLabel.isEmpty, !source.appStoreLabel.isEmpty { target.appStoreLabel = source.appStoreLabel; changed = true }
        if target.appStoreSmallImageUrl.isEmpty, !source.appStoreSmallImageUrl.isEmpty { target.appStoreSmallImageUrl = source.appStoreSmallImageUrl; changed = true }
        if target.storeUrl.isEmpty, !source.storeUrl.isEmpty { target.storeUrl = source.storeUrl; changed = true }
        if target.developerName.isEmpty, !source.developerName.isEmpty { target.developerName = source.developerName; changed = true }
        if target.publisherName.isEmpty, !source.publisherName.isEmpty { target.publisherName = source.publisherName; changed = true }
        if target.releaseDate.isEmpty, !source.releaseDate.isEmpty { target.releaseDate = source.releaseDate; changed = true }
        if target.supportedControls.isEmpty, !source.supportedControls.isEmpty { target.supportedControls = source.supportedControls; changed = true }
        if !source.serviceStatus.isEmpty, target.serviceStatus.isEmpty || (!target.librarySelected && source.librarySelected) { target.serviceStatus = source.serviceStatus; changed = true }
        if target.libraryStatus.isEmpty, !source.libraryStatus.isEmpty { target.libraryStatus = source.libraryStatus; changed = true }
        if target.libraryPlayStatus.isEmpty, !source.libraryPlayStatus.isEmpty { target.libraryPlayStatus = source.libraryPlayStatus; changed = true }
        if !target.libraryInstalled, source.libraryInstalled { target.libraryInstalled = true; changed = true }
        if target.librarySubscription.isEmpty, !source.librarySubscription.isEmpty { target.librarySubscription = source.librarySubscription; changed = true }
        if target.subscriptionIds.isEmpty, !source.subscriptionIds.isEmpty { target.subscriptionIds = source.subscriptionIds; changed = true }
        if target.paymentModelTypes.isEmpty, !source.paymentModelTypes.isEmpty { target.paymentModelTypes = source.paymentModelTypes; changed = true }
        if target.minimumSizeInBytes <= 0, source.minimumSizeInBytes > 0 { target.minimumSizeInBytes = source.minimumSizeInBytes; changed = true }
        if !target.cloudSaveSupported, source.cloudSaveSupported { target.cloudSaveSupported = true; changed = true }
        if target.installTimeInMinutes <= 0, source.installTimeInMinutes > 0 { target.installTimeInMinutes = source.installTimeInMinutes; changed = true }
        if target.supportedLanguages.isEmpty, !source.supportedLanguages.isEmpty { target.supportedLanguages = source.supportedLanguages; changed = true }
        if target.gfnFeatureLabels.isEmpty, !source.gfnFeatureLabels.isEmpty { target.gfnFeatureLabels = source.gfnFeatureLabels; changed = true }
        if !target.librarySelected, source.librarySelected { target.librarySelected = true; changed = true }
        if !target.inLibrary, source.inLibrary { target.inLibrary = true; changed = true }
        return changed
    }

    func mergeMissingStoreMetadata(target: inout OPNGameInfo, metadata: OPNGameInfo) {
        if target.launchAppId.isEmpty { target.launchAppId = metadata.launchAppId }
        if !target.displaysOwnRatingDuringGameplay { target.displaysOwnRatingDuringGameplay = metadata.displaysOwnRatingDuringGameplay }
        for store in metadata.availableStores where !target.availableStores.contains(where: { $0.caseInsensitiveCompare(store) == .orderedSame }) { target.availableStores.append(store) }
        for metadataVariant in metadata.variants {
            if let index = target.variants.firstIndex(where: { variantMatchesStoreMetadata(target: $0, metadata: metadataVariant) }) {
                if target.variants[index].id.isEmpty { target.variants[index].id = metadataVariant.id }
                if target.variants[index].shortName.isEmpty { target.variants[index].shortName = metadataVariant.shortName }
                if target.variants[index].appStore.isEmpty { target.variants[index].appStore = metadataVariant.appStore }
                if target.variants[index].appStoreLabel.isEmpty { target.variants[index].appStoreLabel = metadataVariant.appStoreLabel }
                if target.variants[index].appStoreSmallImageUrl.isEmpty { target.variants[index].appStoreSmallImageUrl = metadataVariant.appStoreSmallImageUrl }
                if target.variants[index].storeUrl.isEmpty { target.variants[index].storeUrl = metadataVariant.storeUrl }
                if target.variants[index].developerName.isEmpty { target.variants[index].developerName = metadataVariant.developerName }
                if target.variants[index].publisherName.isEmpty { target.variants[index].publisherName = metadataVariant.publisherName }
                if target.variants[index].releaseDate.isEmpty { target.variants[index].releaseDate = metadataVariant.releaseDate }
                if target.variants[index].supportedControls.isEmpty { target.variants[index].supportedControls = metadataVariant.supportedControls }
                if target.variants[index].serviceStatus.isEmpty { target.variants[index].serviceStatus = metadataVariant.serviceStatus }
                if target.variants[index].libraryStatus.isEmpty { target.variants[index].libraryStatus = metadataVariant.libraryStatus }
                if target.variants[index].libraryPlayStatus.isEmpty { target.variants[index].libraryPlayStatus = metadataVariant.libraryPlayStatus }
                if !target.variants[index].libraryInstalled { target.variants[index].libraryInstalled = metadataVariant.libraryInstalled }
                if target.variants[index].librarySubscription.isEmpty { target.variants[index].librarySubscription = metadataVariant.librarySubscription }
                if target.variants[index].subscriptionIds.isEmpty { target.variants[index].subscriptionIds = metadataVariant.subscriptionIds }
                if target.variants[index].paymentModelTypes.isEmpty { target.variants[index].paymentModelTypes = metadataVariant.paymentModelTypes }
                if target.variants[index].minimumSizeInBytes <= 0 { target.variants[index].minimumSizeInBytes = metadataVariant.minimumSizeInBytes }
                if !target.variants[index].cloudSaveSupported { target.variants[index].cloudSaveSupported = metadataVariant.cloudSaveSupported }
                if target.variants[index].installTimeInMinutes <= 0 { target.variants[index].installTimeInMinutes = metadataVariant.installTimeInMinutes }
                if target.variants[index].supportedLanguages.isEmpty { target.variants[index].supportedLanguages = metadataVariant.supportedLanguages }
                if target.variants[index].gfnFeatureLabels.isEmpty { target.variants[index].gfnFeatureLabels = metadataVariant.gfnFeatureLabels }
                if target.variants[index].patchStatusPrimaryText.isEmpty { target.variants[index].patchStatusPrimaryText = metadataVariant.patchStatusPrimaryText }
                if target.variants[index].patchStatusSecondaryText.isEmpty { target.variants[index].patchStatusSecondaryText = metadataVariant.patchStatusSecondaryText }
                if !target.variants[index].librarySelected { target.variants[index].librarySelected = metadataVariant.librarySelected }
                if !target.variants[index].inLibrary { target.variants[index].inLibrary = metadataVariant.inLibrary }
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
