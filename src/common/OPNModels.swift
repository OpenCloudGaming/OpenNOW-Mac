import Foundation

import Jarvis

@objc enum OPNAuthScreen: Int {
    case emailEntry
    case authenticating
    case store
    case catalog
    case settings
    case error
    case oAuthBrowser
}

typealias OPNAuthCredentials = JarvisCredentials
typealias OPNAuthSession = JarvisSession

struct OPNSubscriptionInfo: Equatable, Sendable {
    var membershipTier = "Free"
    var subscriptionType = ""
    var subscriptionSubType = ""
    var allottedHours = 0.0
    var purchasedHours = 0.0
    var rolledOverHours = 0.0
    var usedHours = 0.0
    var remainingHours = 0.0
    var totalHours = 0.0
    var isUnlimited = false
    var isGamePlayAllowed = true
}

struct OPNGameVariant: Codable, Equatable, Sendable {
    var id = ""
    var appStore = ""
    var storeUrl = ""
    var serviceStatus = ""
    var librarySelected = false
    var inLibrary = false
}

struct OPNStoreAccountSyncingInfo: Equatable, Sendable {
    var totalNumberOfSyncedGfnGames = 0
    var syncState = ""
    var syncDate = ""
}

struct OPNStoreAccountInfo: Equatable, Sendable {
    var store = ""
    var userDisplayName = ""
    var expiresIn = ""
    var userIdentifier = ""
    var hasAccountLinkingData = false
    var hasAccountSyncingData = false
    var syncing = OPNStoreAccountSyncingInfo()
}

struct OPNUserAccountInfo: Equatable, Sendable {
    var subscriptions: [String] = []
    var stores: [OPNStoreAccountInfo] = []
}

struct OPNStoreFeatureInfo: Equatable, Sendable {
    var type = ""
    var displayProposition = ""
    var supported = false
}

struct OPNStoreAccountLinkingMetadata: Equatable, Sendable {
    var supportedVariantIds: [String] = []
    var isSupported = false
    var isRequired = false
    var label = ""
}

struct OPNStoreDefinition: Equatable, Sendable {
    var store = ""
    var label = ""
    var smallImageUrl = ""
    var sortOrder = 0
    var features: [OPNStoreFeatureInfo] = []
    var accountLinkingMetadata = OPNStoreAccountLinkingMetadata()
}

struct OPNGameInfo: Codable, Equatable, Sendable {
    var id = ""
    var uuid = ""
    var launchAppId = ""
    var title = ""
    var shortName = ""
    var description = ""
    var developerName = ""
    var publisherName = ""
    var maxLocalPlayers = 0
    var maxOnlinePlayers = 0
    var playType = ""
    var membershipTierLabel = ""
    var playabilityState = ""
    var imageUrl = ""
    var heroImageUrl = ""
    var screenshotUrls: [String] = []
    var imageUrlsByType: [String: [String]] = [:]
    var genres: [String] = []
    var featureLabels: [String] = []
    var supportedControls: [String] = []
    var contentRatings: [String] = []
    var nvidiaTech: [String] = []
    var availableStores: [String] = []
    var isInLibrary = false
    var variants: [OPNGameVariant] = []
}

struct OPNActiveSessionEntry: Equatable, Sendable {
    var sessionId = ""
    var appId = 0
    var status = 0
    var serverIp = ""
    var gpuType = ""
    var streamingBaseUrl = ""
    var signalingUrl = ""
}

struct OPNPanelSection: Equatable, Sendable {
    var id = ""
    var title = ""
    var typename = ""
    var games: [OPNGameInfo] = []
}

struct OPNPanelResult: Equatable, Sendable {
    var id = ""
    var title = ""
    var typename = ""
    var sections: [OPNPanelSection] = []
}

struct OPNCatalogFilterOption: Equatable, Sendable {
    var id = ""
    var rawId = ""
    var label = ""
    var groupId = ""
    var groupLabel = ""
}

struct OPNCatalogFilterGroup: Equatable, Sendable {
    var id = ""
    var label = ""
    var options: [OPNCatalogFilterOption] = []
}

struct OPNCatalogSortOption: Equatable, Sendable {
    var id = ""
    var label = ""
    var orderBy = ""
}

struct OPNCatalogBrowseResult: Equatable, Sendable {
    var games: [OPNGameInfo] = []
    var numberReturned = 0
    var numberSupported = 0
    var totalCount = 0
    var hasNextPage = false
    var endCursor = ""
    var searchQuery = ""
    var selectedSortId = ""
    var selectedFilterIds: [String] = []
    var filterGroups: [OPNCatalogFilterGroup] = []
    var sortOptions: [OPNCatalogSortOption] = []
}

struct OPNGameProviderEndpoint: Equatable, Sendable {
    var loginProvider = ""
    var loginProviderCode = ""
    var loginProviderDisplayName = ""
    var streamingServiceUrl = ""
    var idpId = ""
    var redeemRedirectUrl = ""
    var priority = 0
}

struct OPNGameProviderInfo: Equatable, Sendable {
    var defaultProvider = ""
    var loggedInProvider = ""
    var loginRequired = false
    var loginPreferredProviders: [String] = []
    var endpoints: [OPNGameProviderEndpoint] = []
}

struct OPNFeaturedGamesResult: Equatable, Sendable {
    var games: [OPNGameInfo] = []
    var usedExplicitFeaturedSection = false
}

@objc(OPNCatalogGameVariantObject)
@objcMembers
final class OPNCatalogGameVariantObject: NSObject {
    var id: String
    var appStore: String
    var storeUrl: String
    var serviceStatus: String
    var librarySelected: Bool
    var inLibrary: Bool

    override convenience init() {
        self.init(variant: OPNGameVariant())
    }

    init(variant: OPNGameVariant) {
        id = variant.id
        appStore = variant.appStore
        storeUrl = variant.storeUrl
        serviceStatus = variant.serviceStatus
        librarySelected = variant.librarySelected
        inLibrary = variant.inLibrary
        super.init()
    }

    var swiftValue: OPNGameVariant {
        OPNGameVariant(
            id: id,
            appStore: appStore,
            storeUrl: storeUrl,
            serviceStatus: serviceStatus,
            librarySelected: librarySelected,
            inLibrary: inLibrary
        )
    }
}

@objc(OPNCatalogGameObject)
@objcMembers
final class OPNCatalogGameObject: NSObject {
    var id: String
    var uuid: String
    var launchAppId: String
    var title: String
    var shortName: String
    var gameDescription: String
    var developerName: String
    var publisherName: String
    var maxLocalPlayers: Int
    var maxOnlinePlayers: Int
    var playType: String
    var membershipTierLabel: String
    var playabilityState: String
    var imageUrl: String
    var heroImageUrl: String
    var screenshotUrls: [String]
    var imageUrlsByType: [String: [String]]
    var genres: [String]
    var featureLabels: [String]
    var supportedControls: [String]
    var contentRatings: [String]
    var nvidiaTech: [String]
    var availableStores: [String]
    var isInLibrary: Bool
    var variants: [OPNCatalogGameVariantObject]

    override convenience init() {
        self.init(game: OPNGameInfo())
    }

    init(game: OPNGameInfo) {
        id = game.id
        uuid = game.uuid
        launchAppId = game.launchAppId
        title = game.title
        shortName = game.shortName
        gameDescription = game.description
        developerName = game.developerName
        publisherName = game.publisherName
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
        nvidiaTech = game.nvidiaTech
        availableStores = game.availableStores
        isInLibrary = game.isInLibrary
        variants = game.variants.map(OPNCatalogGameVariantObject.init)
        super.init()
    }

    var swiftValue: OPNGameInfo {
        var game = OPNGameInfo()
        game.id = id
        game.uuid = uuid
        game.launchAppId = launchAppId
        game.title = title
        game.shortName = shortName
        game.description = gameDescription
        game.developerName = developerName
        game.publisherName = publisherName
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
        game.nvidiaTech = nvidiaTech
        game.availableStores = availableStores
        game.isInLibrary = isInLibrary
        game.variants = variants.map(\.swiftValue)
        return game
    }
}

@objc(OPNCatalogPanelSectionObject)
@objcMembers
final class OPNCatalogPanelSectionObject: NSObject {
    var id: String
    var title: String
    var typeName: String
    var games: [OPNCatalogGameObject]

    override convenience init() {
        self.init(section: OPNPanelSection())
    }

    init(section: OPNPanelSection) {
        id = section.id
        title = section.title
        typeName = section.typename
        games = section.games.map(OPNCatalogGameObject.init)
        super.init()
    }

    var swiftValue: OPNPanelSection {
        OPNPanelSection(id: id, title: title, typename: typeName, games: games.map(\.swiftValue))
    }
}

@objc(OPNCatalogPanelObject)
@objcMembers
final class OPNCatalogPanelObject: NSObject {
    var id: String
    var title: String
    var typeName: String
    var sections: [OPNCatalogPanelSectionObject]

    override convenience init() {
        self.init(panel: OPNPanelResult())
    }

    init(panel: OPNPanelResult) {
        id = panel.id
        title = panel.title
        typeName = panel.typename
        sections = panel.sections.map(OPNCatalogPanelSectionObject.init)
        super.init()
    }

    var swiftValue: OPNPanelResult {
        OPNPanelResult(id: id, title: title, typename: typeName, sections: sections.map(\.swiftValue))
    }
}

@objc(OPNCatalogBrowseResultObject)
@objcMembers
final class OPNCatalogBrowseResultObject: NSObject {
    var games: [OPNCatalogGameObject]
    var numberReturned: Int
    var numberSupported: Int
    var totalCount: Int
    var hasNextPage: Bool
    var endCursor: String
    var searchQuery: String
    var selectedSortId: String
    var selectedFilterIds: [String]

    override convenience init() {
        self.init(result: OPNCatalogBrowseResult())
    }

    init(result: OPNCatalogBrowseResult) {
        games = result.games.map(OPNCatalogGameObject.init)
        numberReturned = result.numberReturned
        numberSupported = result.numberSupported
        totalCount = result.totalCount
        hasNextPage = result.hasNextPage
        endCursor = result.endCursor
        searchQuery = result.searchQuery
        selectedSortId = result.selectedSortId
        selectedFilterIds = result.selectedFilterIds
        super.init()
    }

    var swiftValue: OPNCatalogBrowseResult {
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
        return result
    }
}

struct OPNStreamSettings: Equatable, Sendable {
    var resolution = "1920x1080"
    var fps = 60
    var codec = "H264"
    var colorQuality = "8bit_420"
    var maxBitrateMbps = 50
    var prefilterMode = 0
    var prefilterSharpness = 0
    var prefilterDenoise = 0
    var prefilterModel = 0
    var enableCloudGsync = false
    var enableL4S = false
    var enableReflex = true
    var lowLatencyMode = false
    var enableHdr = false
    var microphoneMode = "disabled"
    var microphoneDeviceId = ""
    var microphonePushToTalkKeyCode = 9
    var microphonePushToTalkModifierMask = 0
    var gameVolume = 1.0
    var microphoneVolume = 1.0
    var keyboardLayout = "us"
    var gameLanguage = "en_US"
    var accountLinked = true
    var selectedStore = ""
    var networkTestSessionId = ""
    var networkType = "Unknown"
    var networkLatencyMs = -1
    var remoteControllersBitmap: UInt32 = 0
    var supportedHidDevices: UInt32 = 0
    var availableSupportedControllers: [String] = []
}

struct OPNIceServer: Equatable, Sendable {
    var urls: [String] = []
    var username = ""
    var credential = ""
}

struct OPNMediaConnectionInfo: Equatable, Sendable {
    var ip = ""
    var port = 0
}

struct OPNNegotiatedStreamProfile: Equatable, Sendable {
    var resolution = ""
    var fps = 0
    var codec = ""
    var colorQuality = ""
    var bitDepth = -1
    var chromaFormat = -1
    var prefilterMode = -1
    var prefilterSharpness = -1
    var prefilterDenoise = -1
    var prefilterModel = -1
}

@objcMembers
final class OPNParsedNegotiatedStreamProfile: NSObject {
    let resolution: String
    let fps: Int
    let codec: String
    let colorQuality: String
    let bitDepth: Int
    let chromaFormat: Int
    let prefilterMode: Int
    let prefilterSharpness: Int
    let prefilterDenoise: Int
    let prefilterModel: Int

    init(profile: OPNNegotiatedStreamProfile) {
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
final class OPNParsedSessionProgress: NSObject {
    let queuePosition: Int
    let seatSetupStep: Int
    let progressState: Int
    let remainingPlaytimeHours: Double
    let remainingPlaytimeAvailable: Bool

    init(queuePosition: Int, seatSetupStep: Int, progressState: OPNSessionProgressState, remainingPlaytimeHours: Double, remainingPlaytimeAvailable: Bool) {
        self.queuePosition = queuePosition
        self.seatSetupStep = seatSetupStep
        self.progressState = progressState.rawValue
        self.remainingPlaytimeHours = remainingPlaytimeHours
        self.remainingPlaytimeAvailable = remainingPlaytimeAvailable
    }
}

@objcMembers
final class OPNParsedSessionAdMediaFile: NSObject {
    let mediaFileUrl: String
    let encodingProfile: String

    init(mediaFileUrl: String, encodingProfile: String) {
        self.mediaFileUrl = mediaFileUrl
        self.encodingProfile = encodingProfile
    }
}

@objcMembers
final class OPNParsedSessionAd: NSObject {
    let adId: String
    let adState: Int
    let adUrl: String
    let mediaUrl: String
    let adMediaFiles: [OPNParsedSessionAdMediaFile]
    let clickThroughUrl: String
    let adLengthInSeconds: Int
    let durationMs: Int
    let title: String
    let adDescription: String

    init(ad: OPNSessionAdInfo) {
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
final class OPNParsedSessionAdState: NSObject {
    let isAdsRequired: Bool
    let sessionAdsRequired: Bool
    let isQueuePaused: Bool
    let serverSentEmptyAds: Bool
    let gracePeriodSeconds: Int
    let message: String
    let sessionAds: [OPNParsedSessionAd]

    init(adState: OPNSessionAdState) {
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
final class OPNSessionJSONParser: NSObject {
    @objc(parseNegotiatedStreamProfileFromSession:)
    static func parseNegotiatedStreamProfile(from session: NSDictionary?) -> OPNParsedNegotiatedStreamProfile {
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
                profile.bitDepth = bitDepth
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
    static func parseSessionProgress(from session: NSDictionary?) -> OPNParsedSessionProgress {
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
    static func parseSessionAdState(from session: NSDictionary?) -> OPNParsedSessionAdState {
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
}

struct OPNSessionAdMediaFile: Equatable, Sendable {
    var mediaFileUrl = ""
    var encodingProfile = ""
}

struct OPNSessionAdInfo: Equatable, Sendable {
    var adId = ""
    var adState = -1
    var adUrl = ""
    var mediaUrl = ""
    var adMediaFiles: [OPNSessionAdMediaFile] = []
    var clickThroughUrl = ""
    var adLengthInSeconds = 0
    var durationMs = 0
    var title = ""
    var description = ""
}

struct OPNSessionAdState: Equatable, Sendable {
    var isAdsRequired = false
    var sessionAdsRequired = false
    var isQueuePaused = false
    var serverSentEmptyAds = false
    var gracePeriodSeconds = 0
    var message = ""
    var sessionAds: [OPNSessionAdInfo] = []
}

enum OPNSessionProgressState: Int, Sendable {
    case unknown = 0
    case connecting
    case inQueue
    case previousSessionCleanup
    case waitingForStorage
    case settingUp
}

struct OPNSessionInfo: Equatable, Sendable {
    var sessionId = ""
    var status = 0
    var queuePosition = 0
    var seatSetupStep = 0
    var progressState = OPNSessionProgressState.unknown
    var zone = ""
    var streamingBaseUrl = ""
    var serverIp = ""
    var signalingServer = ""
    var signalingUrl = ""
    var gpuType = ""
    var iceServers: [OPNIceServer] = []
    var mediaConnectionInfo = OPNMediaConnectionInfo()
    var negotiatedStreamProfile = OPNNegotiatedStreamProfile()
    var adState = OPNSessionAdState()
    var remainingPlaytimeHours = 0.0
    var remainingPlaytimeAvailable = false
    var remainingPlaytimeUnlimited = false
    var clientId = ""
    var deviceId = ""
}

struct OPNIceCandidatePayload: Equatable, Sendable {
    var candidate = ""
    var sdpMid = ""
    var sdpMLineIndex = 0
    var usernameFragment = ""
}

struct OPNSendAnswerRequest: Equatable, Sendable {
    var sdp = ""
    var nvstSdp = ""
}
