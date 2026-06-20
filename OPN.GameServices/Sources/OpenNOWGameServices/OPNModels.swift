import Foundation

import Jarvis

@objc public enum OPNAuthScreen: Int {
    case emailEntry
    case authenticating
    case store
    case catalog
    case settings
    case error
    case oAuthBrowser
}

public typealias OPNAuthCredentials = JarvisCredentials
public typealias OPNAuthSession = JarvisSession

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
}

public struct OPNGameVariant: Codable, Equatable, Sendable {
    public var id = ""
    public var appStore = ""
    public var appStoreLabel = ""
    public var appStoreSmallImageUrl = ""
    public var storeUrl = ""
    public var serviceStatus = ""
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
    public var sortOrder = 0
    public var features: [OPNStoreFeatureInfo] = []
    public var accountLinkingMetadata = OPNStoreAccountLinkingMetadata()
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
    public var isInLibrary = false
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
    public var games: [OPNGameInfo] = []

    public init(id: String = "", title: String = "", typename: String = "", games: [OPNGameInfo] = []) {
        self.id = id
        self.title = title
        self.typename = typename
        self.games = games
    }
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
    public var appStore: String
    public var appStoreLabel: String
    public var appStoreSmallImageUrl: String
    public var storeUrl: String
    public var serviceStatus: String
    public var librarySelected: Bool
    public var inLibrary: Bool

    public override convenience init() {
        self.init(variant: OPNGameVariant())
    }

    public init(variant: OPNGameVariant) {
        id = variant.id
        appStore = variant.appStore
        appStoreLabel = variant.appStoreLabel
        appStoreSmallImageUrl = variant.appStoreSmallImageUrl
        storeUrl = variant.storeUrl
        serviceStatus = variant.serviceStatus
        librarySelected = variant.librarySelected
        inLibrary = variant.inLibrary
        super.init()
    }

    public var swiftValue: OPNGameVariant {
        OPNGameVariant(
            id: id,
            appStore: appStore,
            appStoreLabel: appStoreLabel,
            appStoreSmallImageUrl: appStoreSmallImageUrl,
            storeUrl: storeUrl,
            serviceStatus: serviceStatus,
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
    public var isInLibrary: Bool
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
        isInLibrary = game.isInLibrary
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
        game.isInLibrary = isInLibrary
        game.variants = variants.map(\.swiftValue)
        return game
    }
}

@objc(OPNCatalogPanelSectionObject)
@objcMembers
public final class OPNCatalogPanelSectionObject: NSObject {
    public var id: String
    public var title: String
    public var typeName: String
    public var games: [OPNCatalogGameObject]

    public override convenience init() {
        self.init(section: OPNPanelSection())
    }

    public init(section: OPNPanelSection) {
        id = section.id
        title = section.title
        typeName = section.typename
        games = section.games.map(OPNCatalogGameObject.init)
        super.init()
    }

    public var swiftValue: OPNPanelSection {
        OPNPanelSection(id: id, title: title, typename: typeName, games: games.map(\.swiftValue))
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

public struct OPNIceServer: Equatable, Sendable {
    public var urls: [String] = []
    public var username = ""
    public var credential = ""
}

public struct OPNMediaConnectionInfo: Equatable, Sendable {
    public var ip = ""
    public var port = 0
}

public struct OPNNegotiatedStreamProfile: Equatable, Sendable {
    public var resolution = ""
    public var fps = 0
    public var codec = ""
    public var colorQuality = ""
    public var bitDepth = -1
    public var chromaFormat = -1
    public var prefilterMode = -1
    public var prefilterSharpness = -1
    public var prefilterDenoise = -1
    public var prefilterModel = -1
}

@objcMembers
public final class OPNParsedNegotiatedStreamProfile: NSObject {
    public let resolution: String
    public let fps: Int
    public let codec: String
    public let colorQuality: String
    public let bitDepth: Int
    public let chromaFormat: Int
    public let prefilterMode: Int
    public let prefilterSharpness: Int
    public let prefilterDenoise: Int
    public let prefilterModel: Int

    public init(profile: OPNNegotiatedStreamProfile) {
        resolution = profile.resolution
        fps = profile.fps
        codec = profile.codec
        colorQuality = profile.colorQuality
        bitDepth = profile.bitDepth
        chromaFormat = profile.chromaFormat
        prefilterMode = profile.prefilterMode
        prefilterSharpness = profile.prefilterSharpness
        prefilterDenoise = profile.prefilterDenoise
        prefilterModel = profile.prefilterModel
    }
}

@objcMembers
public final class OPNParsedSessionProgress: NSObject {
    public let queuePosition: Int
    public let seatSetupStep: Int
    public let progressState: Int
    public let remainingPlaytimeHours: Double
    public let remainingPlaytimeAvailable: Bool

    public init(queuePosition: Int, seatSetupStep: Int, progressState: OPNSessionProgressState, remainingPlaytimeHours: Double, remainingPlaytimeAvailable: Bool) {
        self.queuePosition = queuePosition
        self.seatSetupStep = seatSetupStep
        self.progressState = progressState.rawValue
        self.remainingPlaytimeHours = remainingPlaytimeHours
        self.remainingPlaytimeAvailable = remainingPlaytimeAvailable
    }
}

@objcMembers
public final class OPNParsedSessionAdMediaFile: NSObject {
    public let mediaFileUrl: String
    public let encodingProfile: String

    public init(mediaFileUrl: String, encodingProfile: String) {
        self.mediaFileUrl = mediaFileUrl
        self.encodingProfile = encodingProfile
    }
}

@objcMembers
public final class OPNParsedSessionAd: NSObject {
    public let adId: String
    public let adState: Int
    public let adUrl: String
    public let mediaUrl: String
    public let adMediaFiles: [OPNParsedSessionAdMediaFile]
    public let clickThroughUrl: String
    public let adLengthInSeconds: Int
    public let durationMs: Int
    public let title: String
    public let adDescription: String

    public init(ad: OPNSessionAdInfo) {
        adId = ad.adId
        adState = ad.adState
        adUrl = ad.adUrl
        mediaUrl = ad.mediaUrl
        adMediaFiles = ad.adMediaFiles.map { OPNParsedSessionAdMediaFile(mediaFileUrl: $0.mediaFileUrl, encodingProfile: $0.encodingProfile) }
        clickThroughUrl = ad.clickThroughUrl
        adLengthInSeconds = ad.adLengthInSeconds
        durationMs = ad.durationMs
        title = ad.title
        adDescription = ad.description
    }
}

@objcMembers
public final class OPNParsedSessionAdState: NSObject {
    public let isAdsRequired: Bool
    public let sessionAdsRequired: Bool
    public let isQueuePaused: Bool
    public let serverSentEmptyAds: Bool
    public let gracePeriodSeconds: Int
    public let message: String
    public let sessionAds: [OPNParsedSessionAd]

    public init(adState: OPNSessionAdState) {
        isAdsRequired = adState.isAdsRequired
        sessionAdsRequired = adState.sessionAdsRequired
        isQueuePaused = adState.isQueuePaused
        serverSentEmptyAds = adState.serverSentEmptyAds
        gracePeriodSeconds = adState.gracePeriodSeconds
        message = adState.message
        sessionAds = adState.sessionAds.map(OPNParsedSessionAd.init(ad:))
    }
}

@objc(OPNSessionJSONParser)
public final class OPNSessionJSONParser: NSObject {
    @objc(parseNegotiatedStreamProfileFromSession:)
    public static func parseNegotiatedStreamProfile(from session: NSDictionary?) -> OPNParsedNegotiatedStreamProfile {
        let session = session as? [String: Any] ?? [:]
        var profile = OPNNegotiatedStreamProfile()

        if let negotiated = session["negotiatedStreamProfile"] as? [String: Any] {
            if let resolution = nonEmptyString(negotiated["resolution"]) {
                profile.resolution = resolution
            }
            if let codec = nonEmptyString(negotiated["codec"]) {
                profile.codec = codec
            }
            if let fps = intValue(negotiated["fps"]) {
                profile.fps = fps
            }
        }

        if let features = session["finalizedStreamingFeatures"] as? [String: Any] {
            if let bitDepth = intValue(features["bitDepth"]) {
                profile.bitDepth = displayBitDepth(bitDepth)
            }
            if let chromaFormat = intValue(features["chromaFormat"]) {
                profile.chromaFormat = chromaFormat
            }
            if profile.bitDepth >= 0 || profile.chromaFormat >= 0 {
                profile.colorQuality = colorQuality(bitDepth: profile.bitDepth, chromaFormat: profile.chromaFormat)
            }
            if let prefilterMode = intValue(features["prefilterMode"]) {
                profile.prefilterMode = min(max(prefilterMode, 0), 2)
            }
            if let prefilterSharpness = intValue(features["prefilterSharpness"]) {
                profile.prefilterSharpness = min(max(prefilterSharpness, 0), 10)
            }
            if let prefilterDenoise = intValue(features["prefilterNoiseReduction"]) {
                profile.prefilterDenoise = min(max(prefilterDenoise, 0), 10)
            }
            if let prefilterModel = intValue(features["prefilterModel"]) {
                profile.prefilterModel = max(prefilterModel, 0)
            }
        }

        return OPNParsedNegotiatedStreamProfile(profile: profile)
    }

    @objc(parseSessionProgressFromSession:)
    public static func parseSessionProgress(from session: NSDictionary?) -> OPNParsedSessionProgress {
        let session = session as? [String: Any] ?? [:]
        let seatSetupInfo = dictionary(session["seatSetupInfo"])
        let sessionProgress = dictionary(session["sessionProgress"])
        let progressInfo = dictionary(session["progressInfo"])
        let controlInfo = dictionary(session["sessionControlInfo"])

        let queuePosition = positiveInt(session["queuePosition"])
            ?? positiveInt(seatSetupInfo?["queuePosition"])
            ?? positiveInt(sessionProgress?["queuePosition"])
            ?? positiveInt(progressInfo?["queuePosition"])
            ?? 0
        let seatSetupStep = intValue(seatSetupInfo?["seatSetupStep"])
            ?? intValue(sessionProgress?["seatSetupStep"])
            ?? intValue(progressInfo?["seatSetupStep"])
            ?? 0
        let remaining = remainingPlaytime(containers: [session, sessionProgress, progressInfo, controlInfo])

        return OPNParsedSessionProgress(
            queuePosition: queuePosition,
            seatSetupStep: seatSetupStep,
            progressState: progressState(seatSetupStep: seatSetupStep, queuePosition: queuePosition),
            remainingPlaytimeHours: remaining.hours,
            remainingPlaytimeAvailable: remaining.available
        )
    }

    @objc(parseSessionAdStateFromSession:)
    public static func parseSessionAdState(from session: NSDictionary?) -> OPNParsedSessionAdState {
        let session = session as? [String: Any] ?? [:]
        let progress = dictionary(session["sessionProgress"])
        let progressInfo = dictionary(session["progressInfo"])
        let required = boolValue(session["sessionAdsRequired"])
            || boolValue(session["isAdsRequired"])
            || boolValue(progress?["isAdsRequired"])
            || boolValue(progressInfo?["isAdsRequired"])

        var adState = OPNSessionAdState()
        adState.sessionAdsRequired = required
        adState.serverSentEmptyAds = session["sessionAds"] == nil || session["sessionAds"] is NSNull
        adState.sessionAds = array(session["sessionAds"]).enumerated().compactMap { index, value in
            guard let ad = dictionary(value) else { return nil }
            let parsed = parseSessionAd(ad, index: index)
            guard !isTerminalAdState(parsed.adState) else { return nil }
            guard !parsed.adId.isEmpty || !parsed.mediaUrl.isEmpty || !parsed.title.isEmpty || !parsed.description.isEmpty else { return nil }
            return parsed
        }

        if let opportunity = dictionary(session["opportunity"]) {
            adState.isQueuePaused = boolValue(opportunity["queuePaused"], fallback: adState.isQueuePaused)
            adState.gracePeriodSeconds = positiveInt(opportunity["gracePeriodSeconds"]) ?? 0
            adState.message = nonEmptyString(opportunity["message"]) ?? nonEmptyString(opportunity["description"]) ?? ""
            if nonEmptyString(opportunity["state"])?.lowercased() == "graceperiodstart" {
                adState.isQueuePaused = true
            }
        }

        adState.isAdsRequired = required || !adState.sessionAds.isEmpty || adState.isQueuePaused
        return OPNParsedSessionAdState(adState: adState)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String, let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return nil
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        guard let parsed = intValue(value), parsed > 0 else { return nil }
        return parsed
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func array(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    private static func boolValue(_ value: Any?, fallback: Bool = false) -> Bool {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return fallback
            }
        }
        return fallback
    }

    private static func adMediaProfileRank(_ profile: String) -> Int {
        switch profile {
        case "mp4deinterlaced720p": return 0
        case "hlsadaptive": return 1
        case "webm": return 2
        default: return 100
        }
    }

    private static func isTerminalAdState(_ adState: Int) -> Bool {
        adState == 5 || adState == 6
    }

    private static func parseSessionAd(_ ad: [String: Any], index: Int) -> OPNSessionAdInfo {
        var out = OPNSessionAdInfo()
        out.adId = nonEmptyString(ad["adId"]) ?? "ad-\(index + 1)"
        out.adState = intValue(ad["adState"]) ?? -1
        out.adUrl = nonEmptyString(ad["adUrl"]) ?? ""
        out.mediaUrl = nonEmptyString(ad["mediaUrl"]) ?? nonEmptyString(ad["videoUrl"]) ?? nonEmptyString(ad["url"]) ?? ""
        out.clickThroughUrl = nonEmptyString(ad["clickThroughUrl"]) ?? ""
        out.title = nonEmptyString(ad["title"]) ?? ""
        out.description = nonEmptyString(ad["description"]) ?? ""
        out.adLengthInSeconds = positiveInt(ad["adLengthInSeconds"]) ?? 0
        out.durationMs = out.adLengthInSeconds > 0 ? out.adLengthInSeconds * 1000 : positiveInt(ad["durationMs"]) ?? 0
        if out.durationMs == 0 {
            out.durationMs = positiveInt(ad["durationInMs"]) ?? 0
        }
        out.adMediaFiles = array(ad["adMediaFiles"]).compactMap { value in
            guard let file = dictionary(value) else { return nil }
            let mediaFileUrl = nonEmptyString(file["mediaFileUrl"]) ?? ""
            let encodingProfile = nonEmptyString(file["encodingProfile"]) ?? ""
            guard !mediaFileUrl.isEmpty || !encodingProfile.isEmpty else { return nil }
            return OPNSessionAdMediaFile(mediaFileUrl: mediaFileUrl, encodingProfile: encodingProfile)
        }.sorted { adMediaProfileRank($0.encodingProfile) < adMediaProfileRank($1.encodingProfile) }
        if out.mediaUrl.isEmpty {
            out.mediaUrl = out.adMediaFiles.first { !$0.mediaFileUrl.isEmpty }?.mediaFileUrl ?? ""
        }
        if out.mediaUrl.isEmpty && !out.adUrl.isEmpty {
            out.mediaUrl = out.adUrl
        }
        return out
    }

    private static func firstNumber(in container: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let number = valueAsDouble(container[key]) {
                return number
            }
        }
        return nil
    }

    private static func valueAsDouble(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let text = value as? String, let parsed = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return nil
    }

    private static func progressState(seatSetupStep: Int, queuePosition: Int) -> OPNSessionProgressState {
        switch seatSetupStep {
        case 0:
            return queuePosition > 0 ? .inQueue : .connecting
        case 1:
            return .inQueue
        case 5:
            return .previousSessionCleanup
        case 6:
            return .waitingForStorage
        default:
            return .settingUp
        }
    }

    private static func remainingPlaytime(containers: [[String: Any]?]) -> (hours: Double, available: Bool) {
        for container in containers.compactMap({ $0 }) {
            if let minutes = firstNumber(in: container, keys: ["remainingTimeInMinutes", "remainingSessionTimeInMinutes", "sessionTimeRemainingInMinutes", "timeRemainingInMinutes"]) {
                return (max(0.0, minutes / 60.0), true)
            }
            if let seconds = firstNumber(in: container, keys: ["remainingTimeInSeconds", "remainingSessionTimeInSeconds", "sessionTimeRemainingInSeconds", "timeRemainingInSeconds", "remainingTime", "timeRemaining"]) {
                return (max(0.0, seconds / 3600.0), true)
            }
            if let milliseconds = firstNumber(in: container, keys: ["remainingTimeInMs", "remainingTimeInMilliseconds", "remainingSessionTimeInMs", "sessionTimeRemainingInMs"]) {
                return (max(0.0, milliseconds / 3_600_000.0), true)
            }
        }
        return (0.0, false)
    }

    private static func colorQuality(bitDepth: Int, chromaFormat: Int) -> String {
        let tenBit = bitDepth >= 10
        let fourFourFour = chromaFormat == 2
        if tenBit && fourFourFour { return "10bit_444" }
        if tenBit { return "10bit_420" }
        if fourFourFour { return "8bit_444" }
        return "8bit_420"
    }

    private static func displayBitDepth(_ value: Int) -> Int {
        switch value {
        case 0: return 8
        case 1: return 10
        default: return value
        }
    }
}

public struct OPNSessionAdMediaFile: Equatable, Sendable {
    public var mediaFileUrl = ""
    public var encodingProfile = ""
}

public struct OPNSessionAdInfo: Equatable, Sendable {
    public var adId = ""
    public var adState = -1
    public var adUrl = ""
    public var mediaUrl = ""
    public var adMediaFiles: [OPNSessionAdMediaFile] = []
    public var clickThroughUrl = ""
    public var adLengthInSeconds = 0
    public var durationMs = 0
    public var title = ""
    public var description = ""
}

public struct OPNSessionAdState: Equatable, Sendable {
    public var isAdsRequired = false
    public var sessionAdsRequired = false
    public var isQueuePaused = false
    public var serverSentEmptyAds = false
    public var gracePeriodSeconds = 0
    public var message = ""
    public var sessionAds: [OPNSessionAdInfo] = []
}

public enum OPNSessionProgressState: Int, Sendable {
    case unknown = 0
    case connecting
    case inQueue
    case previousSessionCleanup
    case waitingForStorage
    case settingUp
}

public struct OPNSessionInfo: Equatable, Sendable {
    public var sessionId = ""
    public var status = 0
    public var queuePosition = 0
    public var seatSetupStep = 0
    public var progressState = OPNSessionProgressState.unknown
    public var zone = ""
    public var streamingBaseUrl = ""
    public var serverIp = ""
    public var signalingServer = ""
    public var signalingUrl = ""
    public var gpuType = ""
    public var iceServers: [OPNIceServer] = []
    public var mediaConnectionInfo = OPNMediaConnectionInfo()
    public var negotiatedStreamProfile = OPNNegotiatedStreamProfile()
    public var adState = OPNSessionAdState()
    public var remainingPlaytimeHours = 0.0
    public var remainingPlaytimeAvailable = false
    public var remainingPlaytimeUnlimited = false
    public var clientId = ""
    public var deviceId = ""
}

public struct OPNIceCandidatePayload: Equatable, Sendable {
    public var candidate = ""
    public var sdpMid = ""
    public var sdpMLineIndex = 0
    public var usernameFragment = ""
}

public struct OPNSendAnswerRequest: Equatable, Sendable {
    public var sdp = ""
    public var nvstSdp = ""
}
