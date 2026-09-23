import Foundation

/// One home rail as the customization card sees it. Unlike `CatalogSectionModel` it exists even for
/// a rail the catalog has nothing for yet, so a reader can still hide My Favorites while empty.
struct CatalogHomeRail: Identifiable, Equatable {
    let id: String
    let title: String
    let isVisible: Bool
}

struct CatalogSectionModel: Identifiable, Equatable {
    enum Kind: Equatable {
        case catalog
        case library
        case favorites
        case panel
        case jumpBackIn
        /// A locally-owned collection. Its games come from the reader's own store, never from the
        /// vendor, so opening its Show All page must filter locally rather than seed a server filter.
        case userCollection(id: String)
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
        if case .userCollection = kind { return true }
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

/// Account and definition state the option builder resolves store/subscription rows against.
/// A snapshot of the view model's catalog-account state, so the builder stays a pure static.
struct CatalogOptionContext {
    var accountSubscriptions: [String] = []
    var accountStores: [CatalogStoreAccount] = []
    var storeDefinitions: [CatalogStoreDefinition] = []
    var subscriptionDefinitions: [CatalogSubscriptionDefinition] = []
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

struct CatalogRecentlyPlayedGame: Codable, Equatable {
    let title: String
    let appId: String
    let store: String
    let playedAt: Date
    /// The catalog's box art, carried so the windowless menu bar can show a thumbnail without the
    /// catalog loaded. Optional: older records and vendor-history rows may not have one.
    var artworkURL: String?

    init(title: String, appId: String, store: String, playedAt: Date, artworkURL: String? = nil) {
        self.title = title
        self.appId = appId
        self.store = store
        self.playedAt = playedAt
        self.artworkURL = artworkURL
    }
}

/// The games this account played most recently, newest first, for the home page's Jump Back In
/// rail: the vendor's server-side last-played history folded together with local session ends.
struct CatalogRecentlyPlayed: Codable, Equatable {
    private static let storagePrefix = "OpenNOW.Catalog.RecentlyPlayed"

    static let empty = CatalogRecentlyPlayed()

    /// The rail never grows past this; older games fall off the end.
    static let maximumGameCount = 12

    private(set) var games: [CatalogRecentlyPlayedGame] = []

    mutating func record(title: String, appId: String, store: String, playedAt: Date, artworkURL: String? = nil) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAppId = appId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedAppId.isEmpty else { return }
        merge([CatalogRecentlyPlayedGame(
            title: trimmedTitle,
            appId: trimmedAppId,
            store: store.trimmingCharacters(in: .whitespacesAndNewlines),
            playedAt: playedAt,
            artworkURL: Self.trimmedArtwork(artworkURL)
        )])
    }

    /// Folds new entries in; a game already present keeps whichever timestamp is newer, so a
    /// session that just ended locally beats the vendor's last sync. Box art is backfilled in
    /// either direction: a row that already has art keeps it, and a row without picks up what the
    /// other side has, so whichever source knows the artwork wins. Newest first, capped.
    mutating func merge(_ entries: [CatalogRecentlyPlayedGame]) {
        for entry in entries {
            if let index = games.firstIndex(where: { Self.matches($0, entry) }) {
                if games[index].playedAt < entry.playedAt {
                    var updated = entry
                    if updated.artworkURL == nil { updated.artworkURL = games[index].artworkURL }
                    games[index] = updated
                } else if games[index].artworkURL == nil, let artworkURL = entry.artworkURL {
                    games[index].artworkURL = artworkURL
                }
            } else {
                games.append(entry)
            }
        }
        games.sort { $0.playedAt > $1.playedAt }
        if games.count > Self.maximumGameCount {
            games.removeLast(games.count - Self.maximumGameCount)
        }
    }

    private static func trimmedArtwork(_ artworkURL: String?) -> String? {
        let trimmed = artworkURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A replayed game moves to the front rather than appearing twice. The app id wins when both
    /// sides have one, because titles can outlive the ids the store assigned them.
    private static func matches(_ existing: CatalogRecentlyPlayedGame, _ entry: CatalogRecentlyPlayedGame) -> Bool {
        if !existing.appId.isEmpty, !entry.appId.isEmpty { return existing.appId == entry.appId }
        return !existing.title.isEmpty && existing.title.caseInsensitiveCompare(entry.title) == .orderedSame
    }

    /// The vendor sends last-played as a full ISO timestamp with or without an offset, or as a bare
    /// date. Parse all three, or nothing.
    static func playedDate(from raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = Self.offsetTimestampFormatter.date(from: trimmed) { return date }
        if let date = Self.bareTimestampFormatter.date(from: trimmed) { return date }
        return Self.dayFormatter.date(from: trimmed)
    }

    // ISO8601DateFormatter is not Sendable, but this instance only ever parses; formatter parsing
    // is documented thread-safe since macOS 10.9, so a shared read-only instance cannot race.
    private nonisolated(unsafe) static let offsetTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let bareTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func load(accountIdentifier: String) -> CatalogRecentlyPlayed {
        guard let data = OPNAppPreferenceStorage.standard.data(forKey: storageKey(accountIdentifier: accountIdentifier)),
              let recentlyPlayed = try? JSONDecoder().decode(CatalogRecentlyPlayed.self, from: data) else {
            return .empty
        }
        return recentlyPlayed
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
    /// The tier stays empty until the request resolves. A placeholder here made the chrome show
    /// "Performance" and then change once the account's own saved tier was known.
    static let unavailable = CatalogSubscriptionStatus(membershipTier: "", remainingPlaytimeText: "Unavailable", usageText: "Playtime refresh pending", isAvailable: false)

    /// Brand tier used only when a live subscription returned no tier name at all.
    static let fallbackMembershipTier = "Performance"

    let membershipTier: String
    let remainingPlaytimeText: String
    let usageText: String
    let isAvailable: Bool

    var isFreeTierAccount: Bool {
        OPNCatalogGameObject.isFreeMembershipTier(membershipTier)
    }

    init(membershipTier: String, remainingPlaytimeText: String, usageText: String, isAvailable: Bool) {
        self.membershipTier = membershipTier
        self.remainingPlaytimeText = remainingPlaytimeText
        self.usageText = usageText
        self.isAvailable = isAvailable
    }

    init(subscription: OPNSubscriptionInfo) {
        let tier = subscription.membershipTier.isEmpty ? Self.fallbackMembershipTier : subscription.membershipTier.capitalized
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
