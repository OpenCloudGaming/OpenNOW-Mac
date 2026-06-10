import Foundation

extension OPNGameCatalogView {
    static func catalogPanels(for sourceGames: [OPNCatalogGameObject]) -> [OPNCatalogPanelObject] {
        var seen = Set<String>()
        let panel = OPNCatalogPanelObject()
        panel.id = "catalog"
        panel.title = "Library"
        panel.typeName = "CatalogPanel"
        var sections: [OPNCatalogPanelSectionObject] = []
        var currentSection = catalogPanelSection(id: "catalog-section-1", title: "Library", games: [])
        var sectionIndex = 1
        for game in sourceGames {
            guard hasAccessibleVariants(game) else { continue }
            let catalogGame = gameWithAccessibleVariants(game)
            let identity = gameIdentity(catalogGame)
            if !identity.isEmpty {
                guard seen.insert(identity).inserted else { continue }
            }
            if currentSection.games.count >= 24 {
                sections.append(currentSection)
                sectionIndex += 1
                currentSection = catalogPanelSection(id: "catalog-section-\(sectionIndex)", title: "Library", games: [])
            }
            currentSection.games.append(catalogGame)
        }
        if !currentSection.games.isEmpty { sections.append(currentSection) }
        panel.sections = sections
        return sections.isEmpty ? [] : [panel]
    }

    static func visibleLibraryGames(from sourceGames: [OPNCatalogGameObject]) -> [OPNCatalogGameObject] {
        var seen = Set<String>()
        var games: [OPNCatalogGameObject] = []
        for game in sourceGames {
            guard hasAccessibleVariants(game) else { continue }
            let catalogGame = gameWithAccessibleVariants(game)
            let identity = gameIdentity(catalogGame)
            if !identity.isEmpty {
                guard seen.insert(identity).inserted else { continue }
            }
            games.append(catalogGame)
        }
        return games
    }

    static func panelsFingerprint(_ panels: [OPNCatalogPanelObject]) -> String {
        var fingerprint = ""
        for panel in panels {
            appendFingerprintField(&fingerprint, panel.id)
            appendFingerprintField(&fingerprint, panel.title)
            for section in panel.sections {
                appendFingerprintField(&fingerprint, section.id)
                appendFingerprintField(&fingerprint, section.title)
                for game in section.games {
                    appendFingerprintField(&fingerprint, game.id)
                    appendFingerprintField(&fingerprint, game.title)
                    appendFingerprintField(&fingerprint, game.imageUrl)
                    appendFingerprintField(&fingerprint, game.heroImageUrl)
                    fingerprint += game.isInLibrary ? "1|" : "0|"
                    for variant in game.variants {
                        appendFingerprintField(&fingerprint, variant.id)
                        appendFingerprintField(&fingerprint, variant.appStore)
                        appendFingerprintField(&fingerprint, variant.storeUrl)
                        appendFingerprintField(&fingerprint, variant.serviceStatus)
                        fingerprint += variant.inLibrary ? "1" : "0"
                        fingerprint += variant.librarySelected ? "1|" : "0|"
                    }
                }
            }
        }
        return fingerprint
    }

    static func clearOwnershipMetadata(_ game: OPNCatalogGameObject) -> Bool {
        var changed = false
        if game.isInLibrary {
            game.isInLibrary = false
            changed = true
        }
        for variant in game.variants {
            if variant.inLibrary { variant.inLibrary = false; changed = true }
            if variant.librarySelected { variant.librarySelected = false; changed = true }
            if OPNGameCatalogMetadataSupport.serviceStatusOwnedForLaunch(variant.serviceStatus) {
                variant.serviceStatus = ""
                changed = true
            }
        }
        return changed
    }

    static func mergeStoreMetadata(target: OPNCatalogGameObject, source: OPNCatalogGameObject) -> Bool {
        var changed = false
        if target.launchAppId.isEmpty, !source.launchAppId.isEmpty { target.launchAppId = source.launchAppId; changed = true }
        for store in source.availableStores where !store.isEmpty && !containsStoreName(target.availableStores, store) {
            target.availableStores.append(store)
            changed = true
        }
        for sourceVariant in source.variants where !sourceVariant.appStore.isEmpty {
            var merged = false
            for targetVariant in target.variants where variantsMatch(targetVariant, sourceVariant) {
                if targetVariant.id.isEmpty, !sourceVariant.id.isEmpty { targetVariant.id = sourceVariant.id; changed = true }
                if targetVariant.appStore.isEmpty { targetVariant.appStore = sourceVariant.appStore; changed = true }
                if targetVariant.storeUrl.isEmpty, !sourceVariant.storeUrl.isEmpty { targetVariant.storeUrl = sourceVariant.storeUrl; changed = true }
                if targetVariant.serviceStatus.isEmpty, !sourceVariant.serviceStatus.isEmpty { targetVariant.serviceStatus = sourceVariant.serviceStatus; changed = true }
                if !targetVariant.librarySelected, sourceVariant.librarySelected { targetVariant.librarySelected = true; changed = true }
                if !targetVariant.inLibrary, sourceVariant.inLibrary { targetVariant.inLibrary = true; changed = true }
                merged = true
                break
            }
            if !merged, !sourceVariant.storeUrl.isEmpty {
                target.variants.append(copyVariant(sourceVariant))
                if !containsStoreName(target.availableStores, sourceVariant.appStore) { target.availableStores.append(sourceVariant.appStore) }
                changed = true
            }
        }
        return changed
    }

    static func findKnownGame(_ storeGame: OPNCatalogGameObject, in libraryGames: [OPNCatalogGameObject]) -> OPNCatalogGameObject? {
        libraryGames.first { gamesMatch(storeGame, $0) }
    }

    static func gamesMatch(_ storeGame: OPNCatalogGameObject, _ libraryGame: OPNCatalogGameObject) -> Bool {
        if !storeGame.uuid.isEmpty, storeGame.uuid == libraryGame.uuid { return true }
        if !storeGame.id.isEmpty, storeGame.id == libraryGame.id { return true }
        if !storeGame.launchAppId.isEmpty, storeGame.launchAppId == libraryGame.launchAppId { return true }
        return !storeGame.title.isEmpty && OPNGameCatalogMetadataSupport.stringEqualsCaseInsensitive(storeGame.title, rhs: libraryGame.title)
    }

    static func selectedLibraryVariantIndex(_ libraryGame: OPNCatalogGameObject) -> Int {
        if let index = libraryGame.variants.firstIndex(where: { $0.librarySelected }) { return index }
        if let index = libraryGame.variants.firstIndex(where: variantIsLibrarySelected) { return index }
        return libraryGame.variants.isEmpty ? -1 : 0
    }

    static func gameIdentity(_ game: OPNCatalogGameObject) -> String {
        if !game.id.isEmpty { return game.id }
        if !game.uuid.isEmpty { return game.uuid }
        if !game.launchAppId.isEmpty { return game.launchAppId }
        return game.title
    }

    static func hasAccessibleVariants(_ game: OPNCatalogGameObject) -> Bool {
        if game.isInLibrary { return true }
        if game.variants.contains(where: variantIsLibrarySelected) { return true }
        return game.variants.isEmpty
    }

    static func gameWithAccessibleVariants(_ game: OPNCatalogGameObject) -> OPNCatalogGameObject {
        let catalogGame = copyGame(game)
        catalogGame.isInLibrary = true
        let variants = game.variants.filter(variantIsLibrarySelected).map { variant -> OPNCatalogGameVariantObject in
            let copy = copyVariant(variant)
            copy.inLibrary = true
            return copy
        }
        if !variants.isEmpty { catalogGame.variants = variants }
        return catalogGame
    }

    static func variantIsLibrarySelected(_ variant: OPNCatalogGameVariantObject) -> Bool {
        OPNGameCatalogMetadataSupport.variantIsLibrarySelected(librarySelected: variant.librarySelected, inLibrary: variant.inLibrary, serviceStatus: variant.serviceStatus)
    }

    static func copyGame(_ game: OPNCatalogGameObject) -> OPNCatalogGameObject {
        let copy = OPNCatalogGameObject()
        copy.id = game.id
        copy.uuid = game.uuid
        copy.launchAppId = game.launchAppId
        copy.title = game.title
        copy.shortName = game.shortName
        copy.gameDescription = game.gameDescription
        copy.developerName = game.developerName
        copy.publisherName = game.publisherName
        copy.maxLocalPlayers = game.maxLocalPlayers
        copy.maxOnlinePlayers = game.maxOnlinePlayers
        copy.playType = game.playType
        copy.membershipTierLabel = game.membershipTierLabel
        copy.playabilityState = game.playabilityState
        copy.imageUrl = game.imageUrl
        copy.heroImageUrl = game.heroImageUrl
        copy.screenshotUrls = game.screenshotUrls
        copy.imageUrlsByType = game.imageUrlsByType
        copy.genres = game.genres
        copy.featureLabels = game.featureLabels
        copy.supportedControls = game.supportedControls
        copy.contentRatings = game.contentRatings
        copy.nvidiaTech = game.nvidiaTech
        copy.availableStores = game.availableStores
        copy.isInLibrary = game.isInLibrary
        copy.variants = game.variants.map(copyVariant)
        return copy
    }

    static func copyVariant(_ variant: OPNCatalogGameVariantObject) -> OPNCatalogGameVariantObject {
        let copy = OPNCatalogGameVariantObject()
        copy.id = variant.id
        copy.appStore = variant.appStore
        copy.storeUrl = variant.storeUrl
        copy.serviceStatus = variant.serviceStatus
        copy.librarySelected = variant.librarySelected
        copy.inLibrary = variant.inLibrary
        return copy
    }

    private static func catalogPanelSection(id: String, title: String, games: [OPNCatalogGameObject]) -> OPNCatalogPanelSectionObject {
        let section = OPNCatalogPanelSectionObject()
        section.id = id
        section.title = title
        section.typeName = "CatalogSection"
        section.games = games
        return section
    }

    private static func appendFingerprintField(_ fingerprint: inout String, _ value: String) {
        fingerprint += "\(value.count):\(value)|"
    }

    private static func containsStoreName(_ stores: [String], _ store: String) -> Bool {
        stores.contains { OPNGameCatalogMetadataSupport.stringEqualsCaseInsensitive($0, rhs: store) }
    }

    private static func variantsMatch(_ target: OPNCatalogGameVariantObject, _ source: OPNCatalogGameVariantObject) -> Bool {
        if !target.id.isEmpty, !source.id.isEmpty, target.id == source.id { return true }
        return !target.appStore.isEmpty && !source.appStore.isEmpty && OPNGameCatalogMetadataSupport.stringEqualsCaseInsensitive(target.appStore, rhs: source.appStore)
    }
}
