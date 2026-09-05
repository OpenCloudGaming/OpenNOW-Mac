//  The `@objc` reference-type mirrors of the catalog value types, for the call sites that need
//  identity or Objective-C bridging.
//

import Foundation

@objc(OPNCatalogFilterOptionObject)
@objcMembers
public final class OPNCatalogFilterOptionObject: NSObject {
    public var id: String
    public var rawId: String
    public var label: String
    public var groupId: String
    public var groupLabel: String

    public override convenience init() {
        self.init(option: OPNCatalogFilterOption())
    }

    public init(option: OPNCatalogFilterOption) {
        id = option.id
        rawId = option.rawId
        label = option.label
        groupId = option.groupId
        groupLabel = option.groupLabel
        super.init()
    }

    public var swiftValue: OPNCatalogFilterOption {
        OPNCatalogFilterOption(id: id, rawId: rawId, label: label, groupId: groupId, groupLabel: groupLabel)
    }
}

@objc(OPNCatalogFilterGroupObject)
@objcMembers
public final class OPNCatalogFilterGroupObject: NSObject {
    public var id: String
    public var label: String
    public var options: [OPNCatalogFilterOptionObject]

    public override convenience init() {
        self.init(group: OPNCatalogFilterGroup())
    }

    public init(group: OPNCatalogFilterGroup) {
        id = group.id
        label = group.label
        options = group.options.map(OPNCatalogFilterOptionObject.init)
        super.init()
    }

    public var swiftValue: OPNCatalogFilterGroup {
        OPNCatalogFilterGroup(id: id, label: label, options: options.map(\.swiftValue))
    }
}

@objc(OPNCatalogSortOptionObject)
@objcMembers
public final class OPNCatalogSortOptionObject: NSObject {
    public var id: String
    public var label: String
    public var orderBy: String

    public override convenience init() {
        self.init(option: OPNCatalogSortOption())
    }

    public init(option: OPNCatalogSortOption) {
        id = option.id
        label = option.label
        orderBy = option.orderBy
        super.init()
    }

    public var swiftValue: OPNCatalogSortOption {
        OPNCatalogSortOption(id: id, label: label, orderBy: orderBy)
    }
}

public struct OPNGameProviderEndpoint: Equatable, Sendable {
    public var loginProvider = ""
    public var loginProviderCode = ""
    public var loginProviderDisplayName = ""
    public var streamingServiceUrl = ""
    public var idpId = ""
    public var redeemRedirectUrl = ""
    public var priority = 0
}

public struct OPNGameProviderInfo: Equatable, Sendable {
    public var defaultProvider = ""
    public var loggedInProvider = ""
    public var loginRequired = false
    public var loginPreferredProviders: [String] = []
    public var endpoints: [OPNGameProviderEndpoint] = []
}

public struct OPNFeaturedGamesResult: Equatable, Sendable {
    public var games: [OPNGameInfo] = []
    public var usedExplicitFeaturedSection = false
}

@objc(OPNCatalogGameVariantObject)
@objcMembers
public final class OPNCatalogGameVariantObject: NSObject {
    public var id: String
    public var shortName: String
    public var appStore: String
    public var appStoreLabel: String
    public var appStoreSmallImageUrl: String
    public var storeUrl: String
    public var developerName: String
    public var publisherName: String
    public var releaseDate: String
    public var supportedControls: [String]
    public var serviceStatus: String
    public var libraryStatus: String
    public var libraryPlayStatus: String
    public var libraryInstalled: Bool
    public var librarySubscription: String
    public var subscriptionIds: [String]
    public var paymentModelTypes: [String]
    public var minimumSizeInBytes: Int
    public var cloudSaveSupported: Bool
    public var installTimeInMinutes: Int
    public var supportedLanguages: [String]
    public var gfnFeatureLabels: [String]
    public var isPatching: Bool
    public var patchStatusPrimaryText: String
    public var patchStatusSecondaryText: String
    public var librarySelected: Bool
    public var inLibrary: Bool

    public override convenience init() {
        self.init(variant: OPNGameVariant())
    }

    public init(variant: OPNGameVariant) {
        id = variant.id
        shortName = variant.shortName
        appStore = variant.appStore
        appStoreLabel = variant.appStoreLabel
        appStoreSmallImageUrl = variant.appStoreSmallImageUrl
        storeUrl = variant.storeUrl
        developerName = variant.developerName
        publisherName = variant.publisherName
        releaseDate = variant.releaseDate
        supportedControls = variant.supportedControls
        serviceStatus = variant.serviceStatus
        libraryStatus = variant.libraryStatus
        libraryPlayStatus = variant.libraryPlayStatus
        libraryInstalled = variant.libraryInstalled
        librarySubscription = variant.librarySubscription
        subscriptionIds = variant.subscriptionIds
        paymentModelTypes = variant.paymentModelTypes
        minimumSizeInBytes = variant.minimumSizeInBytes
        cloudSaveSupported = variant.cloudSaveSupported
        installTimeInMinutes = variant.installTimeInMinutes
        supportedLanguages = variant.supportedLanguages
        gfnFeatureLabels = variant.gfnFeatureLabels
        isPatching = variant.isPatching
        patchStatusPrimaryText = variant.patchStatusPrimaryText
        patchStatusSecondaryText = variant.patchStatusSecondaryText
        librarySelected = variant.librarySelected
        inLibrary = variant.inLibrary
        super.init()
    }

    public var swiftValue: OPNGameVariant {
        OPNGameVariant(
            id: id,
            shortName: shortName,
            appStore: appStore,
            appStoreLabel: appStoreLabel,
            appStoreSmallImageUrl: appStoreSmallImageUrl,
            storeUrl: storeUrl,
            developerName: developerName,
            publisherName: publisherName,
            releaseDate: releaseDate,
            supportedControls: supportedControls,
            serviceStatus: serviceStatus,
            libraryStatus: libraryStatus,
            libraryPlayStatus: libraryPlayStatus,
            libraryInstalled: libraryInstalled,
            librarySubscription: librarySubscription,
            subscriptionIds: subscriptionIds,
            paymentModelTypes: paymentModelTypes,
            minimumSizeInBytes: minimumSizeInBytes,
            cloudSaveSupported: cloudSaveSupported,
            installTimeInMinutes: installTimeInMinutes,
            supportedLanguages: supportedLanguages,
            gfnFeatureLabels: gfnFeatureLabels,
            isPatching: isPatching,
            patchStatusPrimaryText: patchStatusPrimaryText,
            patchStatusSecondaryText: patchStatusSecondaryText,
            librarySelected: librarySelected,
            inLibrary: inLibrary
        )
    }
}

@objc(OPNCatalogGameObject)
@objcMembers
public final class OPNCatalogGameObject: NSObject {
    public var id: String
    public var uuid: String
    public var launchAppId: String
    public var title: String
    public var shortName: String
    public var gameDescription: String
    public var shortDescription: String
    public var longDescription: String
    public var developerName: String
    public var publisherName: String
    public var releaseDate: String
    public var maxLocalPlayers: Int
    public var maxOnlinePlayers: Int
    public var playType: String
    public var membershipTierLabel: String
    public var playabilityState: String
    public var imageUrl: String
    public var heroImageUrl: String
    public var screenshotUrls: [String]
    public var imageUrlsByType: [String: [String]]
    public var genres: [String]
    public var featureLabels: [String]
    public var supportedControls: [String]
    public var contentRatings: [String]
    public var ratingSystemName: String
    public var ratingCategoryKey: String
    public var ratingCategoryTitle: String
    public var ratingDescriptors: [String]
    public var ratingInteractiveElements: [String]
    public var ratingImageUrl: String
    public var nvidiaTech: [String]
    public var availableStores: [String]
    public var promoTag: String
    public var campaignIds: [String]
    public var skuTags: [String]
    public var skuPlayabilityText: String
    public var skuUnplayableDialogHeader: String
    public var skuUnplayableDialogBody: String
    public var skuUnplayableDialogBodyEcommerceRestricted: String
    public var displaysOwnRatingDuringGameplay: Bool
    public var isFavorited: Bool
    public var isInLibrary: Bool
    public var isPatching: Bool
    public var isFreeToPlay: Bool
    public var patchStatusPrimaryText: String
    public var patchStatusSecondaryText: String
    public var variants: [OPNCatalogGameVariantObject]

    public override convenience init() {
        self.init(game: OPNGameInfo())
    }

    public init(game: OPNGameInfo) {
        id = game.id
        uuid = game.uuid
        launchAppId = game.launchAppId
        title = game.title
        shortName = game.shortName
        gameDescription = game.description
        shortDescription = game.shortDescription
        longDescription = game.longDescription
        developerName = game.developerName
        publisherName = game.publisherName
        releaseDate = game.releaseDate
        maxLocalPlayers = game.maxLocalPlayers
        maxOnlinePlayers = game.maxOnlinePlayers
        playType = game.playType
        membershipTierLabel = game.membershipTierLabel
        playabilityState = game.playabilityState
        imageUrl = game.imageUrl
        heroImageUrl = game.heroImageUrl
        screenshotUrls = game.screenshotUrls
        imageUrlsByType = game.imageUrlsByType
        genres = game.genres
        featureLabels = game.featureLabels
        supportedControls = game.supportedControls
        contentRatings = game.contentRatings
        ratingSystemName = game.ratingSystemName
        ratingCategoryKey = game.ratingCategoryKey
        ratingCategoryTitle = game.ratingCategoryTitle
        ratingDescriptors = game.ratingDescriptors
        ratingInteractiveElements = game.ratingInteractiveElements
        ratingImageUrl = game.ratingImageUrl
        nvidiaTech = game.nvidiaTech
        availableStores = game.availableStores
        promoTag = game.promoTag
        campaignIds = game.campaignIds
        skuTags = game.skuTags
        skuPlayabilityText = game.skuPlayabilityText
        skuUnplayableDialogHeader = game.skuUnplayableDialogHeader
        skuUnplayableDialogBody = game.skuUnplayableDialogBody
        skuUnplayableDialogBodyEcommerceRestricted = game.skuUnplayableDialogBodyEcommerceRestricted
        displaysOwnRatingDuringGameplay = game.displaysOwnRatingDuringGameplay
        isFavorited = game.isFavorited
        isInLibrary = game.isInLibrary
        isPatching = game.isPatching
        isFreeToPlay = game.isFreeToPlay
        patchStatusPrimaryText = game.patchStatusPrimaryText
        patchStatusSecondaryText = game.patchStatusSecondaryText
        variants = game.variants.map(OPNCatalogGameVariantObject.init)
        super.init()
    }

    public var swiftValue: OPNGameInfo {
        var game = OPNGameInfo()
        game.id = id
        game.uuid = uuid
        game.launchAppId = launchAppId
        game.title = title
        game.shortName = shortName
        game.description = gameDescription
        game.shortDescription = shortDescription
        game.longDescription = longDescription
        game.developerName = developerName
        game.publisherName = publisherName
        game.releaseDate = releaseDate
        game.maxLocalPlayers = maxLocalPlayers
        game.maxOnlinePlayers = maxOnlinePlayers
        game.playType = playType
        game.membershipTierLabel = membershipTierLabel
        game.playabilityState = playabilityState
        game.imageUrl = imageUrl
        game.heroImageUrl = heroImageUrl
        game.screenshotUrls = screenshotUrls
        game.imageUrlsByType = imageUrlsByType
        game.genres = genres
        game.featureLabels = featureLabels
        game.supportedControls = supportedControls
        game.contentRatings = contentRatings
        game.ratingSystemName = ratingSystemName
        game.ratingCategoryKey = ratingCategoryKey
        game.ratingCategoryTitle = ratingCategoryTitle
        game.ratingDescriptors = ratingDescriptors
        game.ratingInteractiveElements = ratingInteractiveElements
        game.ratingImageUrl = ratingImageUrl
        game.nvidiaTech = nvidiaTech
        game.availableStores = availableStores
        game.promoTag = promoTag
        game.campaignIds = campaignIds
        game.skuTags = skuTags
        game.skuPlayabilityText = skuPlayabilityText
        game.skuUnplayableDialogHeader = skuUnplayableDialogHeader
        game.skuUnplayableDialogBody = skuUnplayableDialogBody
        game.skuUnplayableDialogBodyEcommerceRestricted = skuUnplayableDialogBodyEcommerceRestricted
        game.displaysOwnRatingDuringGameplay = displaysOwnRatingDuringGameplay
        game.isFavorited = isFavorited
        game.isInLibrary = isInLibrary
        game.isPatching = isPatching
        game.isFreeToPlay = isFreeToPlay
        game.patchStatusPrimaryText = patchStatusPrimaryText
        game.patchStatusSecondaryText = patchStatusSecondaryText
        game.variants = variants.map(\.swiftValue)
        return game
    }

    public static func isFreeMembershipTier(_ membershipTier: String) -> Bool {
        let normalized = membershipTier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "free" || normalized == "free tier" || normalized == "free-tier"
    }

    public func freeAccountAccessBadgeLabel(isFreeTierAccount: Bool) -> String? {
        guard isFreeTierAccount else { return nil }
        let tier = membershipTierLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tier.isEmpty, !Self.isFreeMembershipTier(tier) else { return nil }
        return "Membership Required"
    }
}

@objc(OPNCatalogPanelSectionObject)
@objcMembers
public final class OPNCatalogPanelSectionObject: NSObject {
    public var id: String
    public var title: String
    public var typeName: String
    public var seeMoreFilterIds: [String]
    public var seeMoreSortId: String
    public var seeMoreTitle: String
    public var games: [OPNCatalogGameObject]
    public var tiles: [OPNCatalogPanelTileObject]

    public override convenience init() {
        self.init(section: OPNPanelSection())
    }

    public init(section: OPNPanelSection) {
        id = section.id
        title = section.title
        typeName = section.typename
        seeMoreFilterIds = section.seeMoreFilterIds
        seeMoreSortId = section.seeMoreSortId
        seeMoreTitle = section.seeMoreTitle
        games = section.games.map(OPNCatalogGameObject.init)
        tiles = section.tiles.map(OPNCatalogPanelTileObject.init)
        super.init()
    }

    public var swiftValue: OPNPanelSection {
        OPNPanelSection(id: id, title: title, typename: typeName, seeMoreFilterIds: seeMoreFilterIds, seeMoreSortId: seeMoreSortId, seeMoreTitle: seeMoreTitle, games: games.map(\.swiftValue), tiles: tiles.map(\.swiftValue))
    }
}

@objc(OPNCatalogPanelTileObject)
@objcMembers
public final class OPNCatalogPanelTileObject: NSObject {
    public var id: String
    public var kind: String
    public var title: String
    public var subtitle: String
    public var body: String
    public var imageUrl: String
    public var actionUrl: String
    public var actionLabel: String
    public var filterIds: [String]
    public var sortId: String

    public override convenience init() {
        self.init(tile: OPNPanelTile())
    }

    public init(tile: OPNPanelTile) {
        id = tile.id
        kind = tile.kind
        title = tile.title
        subtitle = tile.subtitle
        body = tile.body
        imageUrl = tile.imageUrl
        actionUrl = tile.actionUrl
        actionLabel = tile.actionLabel
        filterIds = tile.filterIds
        sortId = tile.sortId
        super.init()
    }

    public var swiftValue: OPNPanelTile {
        OPNPanelTile(id: id, kind: kind, title: title, subtitle: subtitle, body: body, imageUrl: imageUrl, actionUrl: actionUrl, actionLabel: actionLabel, filterIds: filterIds, sortId: sortId)
    }
}

@objc(OPNCatalogPanelObject)
@objcMembers
public final class OPNCatalogPanelObject: NSObject {
    public var id: String
    public var title: String
    public var typeName: String
    public var sections: [OPNCatalogPanelSectionObject]

    public override convenience init() {
        self.init(panel: OPNPanelResult())
    }

    public init(panel: OPNPanelResult) {
        id = panel.id
        title = panel.title
        typeName = panel.typename
        sections = panel.sections.map(OPNCatalogPanelSectionObject.init)
        super.init()
    }

    public var swiftValue: OPNPanelResult {
        OPNPanelResult(id: id, title: title, typename: typeName, sections: sections.map(\.swiftValue))
    }
}

@objc(OPNCatalogBrowseResultObject)
@objcMembers
public final class OPNCatalogBrowseResultObject: NSObject {
    public var games: [OPNCatalogGameObject]
    public var numberReturned: Int
    public var numberSupported: Int
    public var totalCount: Int
    public var hasNextPage: Bool
    public var endCursor: String
    public var searchQuery: String
    public var selectedSortId: String
    public var selectedFilterIds: [String]
    public var filterGroups: [OPNCatalogFilterGroupObject]
    public var sortOptions: [OPNCatalogSortOptionObject]

    public override convenience init() {
        self.init(result: OPNCatalogBrowseResult())
    }

    public init(result: OPNCatalogBrowseResult) {
        games = result.games.map(OPNCatalogGameObject.init)
        numberReturned = result.numberReturned
        numberSupported = result.numberSupported
        totalCount = result.totalCount
        hasNextPage = result.hasNextPage
        endCursor = result.endCursor
        searchQuery = result.searchQuery
        selectedSortId = result.selectedSortId
        selectedFilterIds = result.selectedFilterIds
        filterGroups = result.filterGroups.map(OPNCatalogFilterGroupObject.init)
        sortOptions = result.sortOptions.map(OPNCatalogSortOptionObject.init)
        super.init()
    }

    public var swiftValue: OPNCatalogBrowseResult {
        var result = OPNCatalogBrowseResult()
        result.games = games.map(\.swiftValue)
        result.numberReturned = numberReturned
        result.numberSupported = numberSupported
        result.totalCount = totalCount
        result.hasNextPage = hasNextPage
        result.endCursor = endCursor
        result.searchQuery = searchQuery
        result.selectedSortId = selectedSortId
        result.selectedFilterIds = selectedFilterIds
        result.filterGroups = filterGroups.map(\.swiftValue)
        result.sortOptions = sortOptions.map(\.swiftValue)
        return result
    }
}
