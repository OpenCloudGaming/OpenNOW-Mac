//  CatalogModels.swift
//  OpenNOW
//

import Foundation

struct CatalogSectionModel: Identifiable, Equatable {
    enum Kind: Equatable {
        case catalog
        case library
        case favorites
        case panel
    }

    let id: String
    let title: String
    let games: [OPNCatalogGameObject]
    let kind: Kind
    /// A rail whose data is still loading: render a skeleton, no games yet.
    var isPlaceholder = false
    var tiles: [OPNCatalogPanelTileObject] = []
    var seeMoreFilterIds: [String] = []
    var seeMoreSortId = ""
    var seeMoreTitle = ""

    init(
        id: String,
        title: String,
        games: [OPNCatalogGameObject],
        kind: Kind,
        isPlaceholder: Bool = false,
        tiles: [OPNCatalogPanelTileObject] = [],
        seeMoreFilterIds: [String] = [],
        seeMoreSortId: String = "",
        seeMoreTitle: String = ""
    ) {
        self.id = id
        self.title = title
        self.games = CatalogViewModel.dedupedByTitleGrouping(games)
        self.kind = kind
        self.isPlaceholder = isPlaceholder
        self.tiles = tiles
        self.seeMoreFilterIds = seeMoreFilterIds
        self.seeMoreSortId = seeMoreSortId
        self.seeMoreTitle = seeMoreTitle
    }

    var canLoadFullList: Bool {
        if kind == .library || kind == .favorites { return true }
        return !seeMoreFilterIds.isEmpty || !seeMoreSortId.isEmpty
    }

    func visibleGames(expanded: Bool) -> [OPNCatalogGameObject] {
        expanded ? games : Array(games.prefix(18))
    }
}

struct CatalogGameRevealRequest: Equatable {
    let sectionId: String
    let gameIdentity: String
    let sequence: Int
}

struct CatalogStoreAccount: Identifiable, Equatable {
    var id: String { store }
    let store: String
    let userDisplayName: String
    let expiresIn: String
    let userIdentifier: String
    let hasAccountLinkingData: Bool
    let hasAccountSyncingData: Bool
    let totalSyncedGames: Int
    let syncState: String
    let syncDate: String
}

struct CatalogStoreDefinition: Identifiable, Equatable {
    var id: String { store }
    let store: String
    let label: String
    let smallImageUrl: String
    let isAccountLinkingSupported: Bool
    let isAccountLinkingRequired: Bool
    let accountLinkingLabel: String
}

struct CatalogSubscriptionDefinition: Identifiable, Equatable {
    var id: String { subscription }
    let subscription: String
    let label: String
    let logoURL: String
    let primaryStore: String
}

struct CatalogPlatformOption: Identifiable {
    let id: String
    let variantIndex: Int
    let variant: OPNCatalogGameVariantObject
    let title: String
    let iconURL: String
    let store: String
    let subscriptionIds: [String]
    let primaryStore: String
    let isSubscription: Bool
    let isOwned: Bool
    let hasSubscriptionEntitlement: Bool
    let hasAccess: Bool
    let isSelected: Bool
    let isUnavailable: Bool
    let canLink: Bool
    let canSync: Bool
    let accountDisplayName: String
    let status: String

    var accountStore: String { primaryStore.isEmpty ? store : primaryStore }
}

struct CatalogPlaytimeStatistics: Codable, Equatable {
    private static let storagePrefix = "OpenNOW.Catalog.PlaytimeStatistics"

    static let empty = CatalogPlaytimeStatistics(totalSeconds: 0, sessionCount: 0, lastSessionSeconds: 0, longestSessionSeconds: 0, lastPlayedTitle: "", lastPlayedAt: nil)

    private(set) var totalSeconds: Double
    private(set) var sessionCount: Int
    private(set) var lastSessionSeconds: Double
    private(set) var longestSessionSeconds: Double
    private(set) var lastPlayedTitle: String
    private(set) var lastPlayedAt: Date?

    var averageSessionSeconds: Double {
        sessionCount > 0 ? totalSeconds / Double(sessionCount) : 0
    }

    mutating func record(title: String, durationSeconds: Double, endedAt: Date) {
        let duration = max(0, durationSeconds.isFinite ? durationSeconds : 0)
        guard duration > 0 else { return }
        totalSeconds += duration
        sessionCount += 1
        lastSessionSeconds = duration
        longestSessionSeconds = max(longestSessionSeconds, duration)
        lastPlayedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        lastPlayedAt = endedAt
    }

    static func load(accountIdentifier: String) -> CatalogPlaytimeStatistics {
        guard let data = OPNAppPreferenceStorage.standard.data(forKey: storageKey(accountIdentifier: accountIdentifier)),
              let statistics = try? JSONDecoder().decode(CatalogPlaytimeStatistics.self, from: data) else {
            return .empty
        }
        return statistics
    }

    func save(accountIdentifier: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        OPNAppPreferenceStorage.standard.set(data, forKey: Self.storageKey(accountIdentifier: accountIdentifier))
    }

    private static func storageKey(accountIdentifier: String) -> String {
        "\(storagePrefix).\(accountIdentifier)"
    }
}

struct CatalogSubscriptionStatus: Equatable {
    static let unavailable = CatalogSubscriptionStatus(membershipTier: "Performance", remainingPlaytimeText: "Unavailable", usageText: "Playtime refresh pending", isAvailable: false)

    let membershipTier: String
    let remainingPlaytimeText: String
    let usageText: String
    let isAvailable: Bool

    var isFreeTierAccount: Bool {
        OPNCatalogGameObject.isFreeMembershipTier(membershipTier)
    }

    init(membershipTier: String, remainingPlaytimeText: String, usageText: String, isAvailable: Bool) {
        self.membershipTier = membershipTier.isEmpty ? "Performance" : membershipTier
        self.remainingPlaytimeText = remainingPlaytimeText
        self.usageText = usageText
        self.isAvailable = isAvailable
    }

    init(subscription: OPNSubscriptionInfo) {
        let tier = subscription.membershipTier.isEmpty ? "Performance" : subscription.membershipTier.capitalized
        if subscription.isUnlimited {
            self.init(membershipTier: tier, remainingPlaytimeText: "Unlimited", usageText: "No monthly playtime cap", isAvailable: true)
            return
        }
        let remaining = Self.hoursText(subscription.remainingHours)
        let used = Self.hoursText(subscription.usedHours)
        let total = Self.hoursText(subscription.totalHours)
        let usage = subscription.totalHours > 0 ? "\(used) used of \(total)" : "\(used) used"
        self.init(membershipTier: tier, remainingPlaytimeText: "\(remaining) left", usageText: usage, isAvailable: true)
    }

    private static func hoursText(_ hours: Double) -> String {
        let totalMinutes = max(0, Int((hours * 60).rounded()))
        let wholeHours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if wholeHours > 0, minutes > 0 { return "\(wholeHours)h \(minutes)m" }
        if wholeHours > 0 { return "\(wholeHours)h" }
        return "\(minutes)m"
    }
}

struct CatalogPreviousGameSession: Codable, Equatable {
    private static let storageKey = "OpenNOW.Catalog.PreviousGameSession"

    let title: String
    let appId: String
    let store: String
    let result: String
    let endedAt: Date
    let launchTime: String
    let averageLatency: String
    let averageBitrate: String
    let droppedFrames: String

    init(configuration: StreamLaunchConfiguration, success: Bool, message: String, report: StreamReport?) {
        let reportTitle = report?.title ?? ""
        title = reportTitle.isEmpty ? (configuration.title.isEmpty ? "GeForce NOW" : configuration.title) : reportTitle
        appId = configuration.applicationID
        store = configuration.selectedStore
        if success {
            result = report?.success == false ? "Ended with warnings" : "Ended normally"
        } else {
            result = message.isEmpty ? "Ended with error" : message
        }
        endedAt = Date()
        launchTime = report.map { Self.durationText(seconds: $0.durationSeconds) } ?? "Unknown"
        averageLatency = report?.metadata["averageLatency"] ?? "Unknown"
        averageBitrate = report?.metadata["averageBitrate"] ?? "Unknown"
        droppedFrames = report?.metadata["droppedFrames"] ?? "Unknown"
    }

    private static func durationText(seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    static func load() -> CatalogPreviousGameSession? {
        guard let data = OPNAppPreferenceStorage.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(CatalogPreviousGameSession.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        OPNAppPreferenceStorage.standard.set(data, forKey: Self.storageKey)
    }
}
