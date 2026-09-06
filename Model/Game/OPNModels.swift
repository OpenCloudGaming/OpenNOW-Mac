import Foundation


@objc public enum OPNAuthScreen: Int {
    case emailEntry
    case authenticating
    case store
    case catalog
    case settings
    case error
    case oAuthBrowser
}

public struct OPNSubscriptionInfo: Equatable, Sendable {
    public var membershipTier = "Free"
    public var subscriptionType = ""
    public var subscriptionSubType = ""
    public var allottedHours = 0.0
    public var purchasedHours = 0.0
    public var rolledOverHours = 0.0
    public var usedHours = 0.0
    public var remainingHours = 0.0
    public var totalHours = 0.0
    public var isUnlimited = false
    public var isGamePlayAllowed = true
    /// Playback channels the membership streams: 2, 6 or 8 from `SUPPORTED_AUDIO_FORMATS`;
    /// 0 when the subscription payload named none.
    public var entitledAudioChannelCount = 0
}

public struct OPNGameVariant: Codable, Equatable, Sendable {
    public var id = ""
    public var shortName = ""
    public var appStore = ""
    public var appStoreLabel = ""
    public var appStoreSmallImageUrl = ""
    public var storeUrl = ""
    public var developerName = ""
    public var publisherName = ""
    public var releaseDate = ""
    public var supportedControls: [String] = []
    public var serviceStatus = ""
    public var libraryStatus = ""
    public var libraryPlayStatus = ""
    public var libraryInstalled = false
    public var librarySubscription = ""
    public var subscriptionIds: [String] = []
    public var paymentModelTypes: [String] = []
    public var minimumSizeInBytes = 0
    public var cloudSaveSupported = false
    public var installTimeInMinutes = 0
    public var supportedLanguages: [String] = []
    public var gfnFeatureLabels: [String] = []
    public var isPatching = false
    public var patchStatusPrimaryText = ""
    public var patchStatusSecondaryText = ""
    public var librarySelected = false
    public var inLibrary = false
}

public struct OPNStoreAccountSyncingInfo: Equatable, Sendable {
    public var totalNumberOfSyncedGfnGames = 0
    public var syncState = ""
    public var syncDate = ""
}

public struct OPNStoreAccountInfo: Equatable, Sendable {
    public var store = ""
    public var userDisplayName = ""
    public var expiresIn = ""
    public var userIdentifier = ""
    public var hasAccountLinkingData = false
    public var hasAccountSyncingData = false
    public var syncing = OPNStoreAccountSyncingInfo()
}

public struct OPNUserAccountInfo: Equatable, Sendable {
    public var subscriptions: [String] = []
    public var stores: [OPNStoreAccountInfo] = []
}

public struct OPNStoreFeatureInfo: Equatable, Sendable {
    public var type = ""
    public var displayProposition = ""
    public var supported = false
}

public struct OPNStoreAccountLinkingMetadata: Equatable, Sendable {
    public var supportedVariantIds: [String] = []
    public var isSupported = false
    public var isRequired = false
    public var label = ""
}

public struct OPNStoreDefinition: Equatable, Sendable {
    public var store = ""
    public var label = ""
    public var smallImageUrl = ""
    public var largeImageUrl = ""
    public var sortOrder = 0
    public var features: [OPNStoreFeatureInfo] = []
    public var accountLinkingMetadata = OPNStoreAccountLinkingMetadata()
}

public struct OPNSubscriptionDefinition: Equatable, Sendable {
    public var subscription = ""
    public var label = ""
    public var logoURL = ""
    public var primaryStore = ""
}

public struct OPNGameInfo: Codable, Equatable, Sendable {
    public var id = ""
    public var uuid = ""
    public var launchAppId = ""
    public var title = ""
    public var shortName = ""
    public var description = ""
    public var shortDescription = ""
    public var longDescription = ""
    public var developerName = ""
    public var publisherName = ""
    public var releaseDate = ""
    public var maxLocalPlayers = 0
    public var maxOnlinePlayers = 0
    public var playType = ""
    public var membershipTierLabel = ""
    public var playabilityState = ""
    public var imageUrl = ""
    public var heroImageUrl = ""
    public var screenshotUrls: [String] = []
    public var imageUrlsByType: [String: [String]] = [:]
    public var genres: [String] = []
    public var featureLabels: [String] = []
    public var supportedControls: [String] = []
    public var contentRatings: [String] = []
    public var ratingSystemName = ""
    public var ratingCategoryKey = ""
    public var ratingCategoryTitle = ""
    public var ratingDescriptors: [String] = []
    public var ratingInteractiveElements: [String] = []
    public var ratingImageUrl = ""
    public var nvidiaTech: [String] = []
    public var availableStores: [String] = []
    public var promoTag = ""
    public var campaignIds: [String] = []
    public var skuTags: [String] = []
    public var skuPlayabilityText = ""
    public var skuUnplayableDialogHeader = ""
    public var skuUnplayableDialogBody = ""
    public var skuUnplayableDialogBodyEcommerceRestricted = ""
    public var displaysOwnRatingDuringGameplay = false
    public var isFavorited = false
    public var isInLibrary = false
    public var isPatching = false
    public var isFreeToPlay = false
    public var patchStatusPrimaryText = ""
    public var patchStatusSecondaryText = ""
    public var variants: [OPNGameVariant] = []
}

public struct OPNActiveSessionEntry: Equatable, Sendable {
    public var sessionId = ""
    public var appId = 0
    public var status = 0
    public var serverIp = ""
    public var gpuType = ""
    public var streamingBaseUrl = ""
    public var signalingUrl = ""
}

public struct OPNPanelSection: Equatable, Sendable {
    public var id = ""
    public var title = ""
    public var typename = ""
    public var seeMoreFilterIds: [String] = []
    public var seeMoreSortId = ""
    public var seeMoreTitle = ""
    public var games: [OPNGameInfo] = []
    public var tiles: [OPNPanelTile] = []

    public init(id: String = "", title: String = "", typename: String = "", seeMoreFilterIds: [String] = [], seeMoreSortId: String = "", seeMoreTitle: String = "", games: [OPNGameInfo] = [], tiles: [OPNPanelTile] = []) {
        self.id = id
        self.title = title
        self.typename = typename
        self.seeMoreFilterIds = seeMoreFilterIds
        self.seeMoreSortId = seeMoreSortId
        self.seeMoreTitle = seeMoreTitle
        self.games = games
        self.tiles = tiles
    }
}

public struct OPNPanelTile: Equatable, Sendable {
    public var id = ""
    public var kind = ""
    public var title = ""
    public var subtitle = ""
    public var body = ""
    public var imageUrl = ""
    public var actionUrl = ""
    public var actionLabel = ""
    public var filterIds: [String] = []
    public var sortId = ""
}

public struct OPNPanelResult: Equatable, Sendable {
    public var id = ""
    public var title = ""
    public var typename = ""
    public var sections: [OPNPanelSection] = []

    public init(id: String = "", title: String = "", typename: String = "", sections: [OPNPanelSection] = []) {
        self.id = id
        self.title = title
        self.typename = typename
        self.sections = sections
    }
}

public struct OPNCatalogFilterOption: Equatable, Sendable {
    public var id = ""
    public var rawId = ""
    public var label = ""
    public var groupId = ""
    public var groupLabel = ""
}

public struct OPNCatalogFilterGroup: Equatable, Sendable {
    public var id = ""
    public var label = ""
    public var options: [OPNCatalogFilterOption] = []
}

public struct OPNCatalogSortOption: Equatable, Sendable {
    public var id = ""
    public var label = ""
    public var orderBy = ""
}

public struct OPNCatalogBrowseResult: Equatable, Sendable {
    public var games: [OPNGameInfo] = []
    public var numberReturned = 0
    public var numberSupported = 0
    public var totalCount = 0
    public var hasNextPage = false
    public var endCursor = ""
    public var searchQuery = ""
    public var selectedSortId = ""
    public var selectedFilterIds: [String] = []
    public var filterGroups: [OPNCatalogFilterGroup] = []
    public var sortOptions: [OPNCatalogSortOption] = []
}
