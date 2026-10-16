//  NVIDIA's DLSS games list: fetching it, caching it, and answering "what does the list say about
//  this title" without ever holding a catalog load or a launch hostage.

import Foundation

/// A cached copy of the list: the parsed rows and when they were last successfully checked.
public struct DlssCachedList: Codable, Equatable, Sendable {
    public let rows: [DlssGamesRow]
    public let checkedAt: Date

    public init(rows: [DlssGamesRow], checkedAt: Date) {
        self.rows = rows
        self.checkedAt = checkedAt
    }
}

public enum DlssCompatibilityFetchError: Error, Equatable, Sendable {
    case http(Int)
    case tooLarge
    case transport(String)
}

public protocol DlssCompatibilityTransport: Sendable {
    func fetchList(url: URL, timeout: TimeInterval) async throws -> Data
}

/// The live transport. It goes through the app's session-proxy plumbing, so a reader who routes the
/// catalog through a proxy routes this list the same way.
public struct DlssHTTPTransport: DlssCompatibilityTransport {
    public init() {}

    public func fetchList(url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await OPNSessionProxySessionProvider.shared.data(for: request, purpose: .catalog)
        guard let http = response as? HTTPURLResponse else {
            throw DlssCompatibilityFetchError.transport("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DlssCompatibilityFetchError.http(http.statusCode)
        }
        guard data.count <= DlssCompatibilityLimits.maximumListBytes else {
            throw DlssCompatibilityFetchError.tooLarge
        }
        return data
    }
}

public protocol DlssCompatibilityCacheStoring: Sendable {
    func load() -> DlssCachedList?
    func save(_ list: DlssCachedList)
}

/// The on-disk copy. It lives in the caches directory: losing it costs one fetch, never correctness.
public struct DlssCompatibilityDiskCache: DlssCompatibilityCacheStoring {
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = base.appending(path: "OpenNOW-DlssCompatibility.json")
    }

    public func load() -> DlssCachedList? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(DlssCachedList.self, from: data)
    }

    public func save(_ list: DlssCachedList) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Time and waiting, injected so the TTL, the retry backoff and the bounded first wait are testable
/// without a live network or a real clock.
public struct DlssCompatibilityClock: Sendable {
    public let now: @Sendable () -> Date
    public let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public static let live = DlssCompatibilityClock(
        now: { Date() },
        sleep: { seconds in
            guard seconds > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    )
}

/// Owns the in-memory index and its background refresh.
public actor OPNDlssCompatibilityService {
    public static let shared = OPNDlssCompatibilityService()

    /// What the app knows about the list right now.
    public enum ListState: Equatable, Sendable {
        case loading
        case ready
        case refreshing
        case refreshFailed
        case stale
        case unavailable

        public var hasSavedData: Bool {
            switch self {
            case .ready, .refreshing, .refreshFailed, .stale: true
            case .loading, .unavailable: false
            }
        }

        public var isStale: Bool {
            switch self {
            case .refreshing, .refreshFailed, .stale: true
            case .loading, .ready, .unavailable: false
            }
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let outcome: DlssMatchOutcome
        public let listState: ListState
        public let lastSuccessfulCheck: Date?
        /// Whether the saved data came off disk this session, which is what the "Cached ·" prefix on
        /// the freshness footer reports.
        public let isLoadedFromCache: Bool

        public var hasSavedData: Bool { listState.hasSavedData }
        public var isStale: Bool { listState.isStale }
    }

    private let transport: DlssCompatibilityTransport
    private let cache: DlssCompatibilityCacheStoring
    private let clock: DlssCompatibilityClock
    private let listURL: URL?
    private let cacheLifetime: TimeInterval
    private let retryInterval: TimeInterval

    private var gamesIndex: DlssGamesIndex?
    private var expiresAt = Date.distantPast
    private var retryAt = Date.distantPast
    private var isLoading = false
    private var isFirstAttemptDone = false
    private var isFirstWaitClaimed = false
    private var isFirstWaitEnded = false
    private var isLastRefreshFailed = false
    private var isLoadedFromCache = false
    private var isCachedListRestored = false
    private var lastSuccessfulCheck: Date?
    private var loadTask: Task<Void, Never>?
    private var firstWaitContinuation: CheckedContinuation<Void, Never>?

    public init(
        transport: DlssCompatibilityTransport = DlssHTTPTransport(),
        cache: DlssCompatibilityCacheStoring = DlssCompatibilityDiskCache(),
        clock: DlssCompatibilityClock = .live,
        listURL: URL? = URL(string: DlssCompatibilityLimits.listURLString),
        cacheLifetime: TimeInterval = DlssCompatibilityLimits.cacheLifetime,
        retryInterval: TimeInterval = DlssCompatibilityLimits.retryInterval
    ) {
        self.transport = transport
        self.cache = cache
        self.clock = clock
        self.listURL = listURL
        self.cacheLifetime = cacheLifetime
        self.retryInterval = retryInterval
    }

    /// The index, waiting at most `seconds` for the process's first attempt and never longer. Only
    /// one caller waits: a slow download cannot make a burst of lookups all block behind it.
    public func index(waitingUpTo seconds: TimeInterval = DlssCompatibilityLimits.firstLookupWait) async -> DlssGamesIndex? {
        restoreCachedList()
        startRefreshWhenNeeded()
        if let gamesIndex { return gamesIndex }
        guard !isFirstAttemptDone, !isFirstWaitClaimed, isLoading else { return nil }
        isFirstWaitClaimed = true
        isFirstWaitEnded = false
        let clock = self.clock
        let timeout = Task { [weak self] in
            try? await clock.sleep(seconds)
            await self?.endFirstWait()
        }
        await withCheckedContinuation { continuation in
            if isFirstWaitEnded {
                continuation.resume()
                return
            }
            firstWaitContinuation = continuation
        }
        timeout.cancel()
        return gamesIndex
    }

    /// What the compatibility section should show for this title. Reading a snapshot is a demand: it
    /// is what starts a refresh when the saved copy is past its lifetime.
    public func snapshot(forTitle title: String) async -> Snapshot {
        restoreCachedList()
        startRefreshWhenNeeded()
        return buildSnapshot(forTitle: title)
    }

    /// The snapshot without starting anything. For re-renders that must not add demand.
    public func currentSnapshot(forTitle title: String) -> Snapshot {
        restoreCachedList()
        return buildSnapshot(forTitle: title)
    }

    /// Waits for the in-flight refresh to finish, however long it takes. Used for the single
    /// background update that may follow the UI's bounded wait.
    public func awaitPendingRefresh() async {
        while let task = loadTask {
            await task.value
        }
    }

    private func buildSnapshot(forTitle title: String) -> Snapshot {
        Snapshot(
            outcome: gamesIndex?.lookup(title) ?? .unknown,
            listState: currentListState(),
            lastSuccessfulCheck: lastSuccessfulCheck,
            isLoadedFromCache: isLoadedFromCache
        )
    }

    private func restoreCachedList() {
        guard !isCachedListRestored else { return }
        isCachedListRestored = true
        guard let cached = cache.load(), !cached.rows.isEmpty else { return }
        gamesIndex = DlssGamesIndex(rows: cached.rows)
        lastSuccessfulCheck = cached.checkedAt
        expiresAt = cached.checkedAt.addingTimeInterval(cacheLifetime)
        isLoadedFromCache = true
    }

    private func startRefreshWhenNeeded() {
        let now = clock.now()
        guard !isLoading, now >= retryAt else { return }
        guard gamesIndex == nil || now >= expiresAt else { return }
        isLoading = true
        loadTask = Task { await self.performLoad() }
    }

    private func performLoad() async {
        guard let listURL else {
            finishLoad(outcome: .failure(DlssCompatibilityFetchError.transport("invalid list URL")))
            return
        }
        do {
            let data = try await transport.fetchList(url: listURL, timeout: DlssCompatibilityLimits.fetchTimeout)
            let rows = try DlssGamesListParser.parse(data)
            finishLoad(outcome: .success(rows))
        } catch {
            finishLoad(outcome: .failure(error))
        }
    }

    private func finishLoad(outcome: Result<[DlssGamesRow], any Error>) {
        switch outcome {
        case let .success(rows):
            acceptFetchedRows(rows)
        case let .failure(error):
            acceptFetchFailure(error)
        }
        isLoading = false
        isFirstAttemptDone = true
        loadTask = nil
        endFirstWait()
    }

    private func acceptFetchedRows(_ rows: [DlssGamesRow]) {
        let completedAt = clock.now()
        gamesIndex = DlssGamesIndex(rows: rows)
        expiresAt = completedAt.addingTimeInterval(cacheLifetime)
        // A successful revalidation advances the last successful check even when nothing changed; a
        // stale read never does.
        lastSuccessfulCheck = completedAt
        isLoadedFromCache = false
        isLastRefreshFailed = false
        retryAt = .distantPast
        cache.save(DlssCachedList(rows: rows, checkedAt: completedAt))
    }

    private func acceptFetchFailure(_ error: any Error) {
        isLastRefreshFailed = true
        // Back off on the next demand rather than polling. Saved data stays in place.
        retryAt = clock.now().addingTimeInterval(retryInterval)
        OPNDiagnostics.logWarningMessage(
            OPNDiagnostics.formattedLogMessage(level: "warning", area: "DLSS", message: "DLSS games list unavailable: \(Self.diagnosticMessage(for: error))")
        )
    }

    private func currentListState() -> ListState {
        guard gamesIndex != nil else {
            guard isFirstAttemptDone, !isLoading else { return .loading }
            return .unavailable
        }
        guard !isLoading else { return .refreshing }
        guard !isLastRefreshFailed else { return .refreshFailed }
        return clock.now() >= expiresAt ? .stale : .ready
    }

    private func endFirstWait() {
        isFirstWaitEnded = true
        firstWaitContinuation?.resume()
        firstWaitContinuation = nil
    }

    private static func diagnosticMessage(for error: any Error) -> String {
        switch error {
        case let DlssCompatibilityFetchError.http(status): "HTTP \(status)"
        case DlssCompatibilityFetchError.tooLarge: "document larger than 4 MiB"
        case let DlssCompatibilityFetchError.transport(reason): reason
        case let DlssGamesListError.malformed(reason): reason
        case DlssGamesListError.tooLarge: "document larger than 4 MiB"
        default: String(describing: error)
        }
    }
}

/// The glyph a compatibility state carries. Text plus an icon, never colour alone.
public enum DlssCompatibilityGlyph: Equatable, Sendable {
    case none
    /// An animated indicator, drawn only while the app is inside its bounded wait.
    case progress
    case clock
    case warning
    case question
    case info
}

/// The compatibility section's exact copy, built from a snapshot. Pure, so every state combination
/// can be asserted without rendering.
public struct DlssCompatibilityPresentation: Equatable, Sendable {
    public struct CompactChip: Equatable, Sendable {
        public let label: String
        public let accessibilityLabel: String
        public let isStale: Bool
    }

    public let statusText: String
    public let statusSupportingText: String
    public let statusGlyph: DlssCompatibilityGlyph
    /// The feature table's source. Nil when the table is replaced by an unknown or unavailable
    /// message.
    public let gameSupport: DlssGameSupport?
    public let freshnessText: String
    public let freshnessSupportingText: String
    public let freshnessGlyph: DlssCompatibilityGlyph
    public let freshnessHelpText: String
    public let sourceFooter: String
    public let compactChip: CompactChip?

    public static let unknownTitle = "DLSS compatibility unknown"
    public static let unknownBody = "We couldn't confirm this game's DLSS compatibility from NVIDIA's list. This does not mean DLSS is unsupported."
    public static let unavailableText = "Compatibility information unavailable."
    public static let loadingText = "Checking DLSS compatibility…"
    public static let loadingSupportingText = "Looking up this game in NVIDIA's DLSS games list."
    public static let sourceFooter = "Source: NVIDIA's DLSS games list"
    public static let cachedHelpText = "Compatibility information is saved for up to 24 hours before a refresh is attempted."
    public static let staleChipAccessibilityLabel = "DLSS compatibility information may be outdated."
    public static let freshChipAccessibilityLabel = "DLSS compatibility information available."

    /// What the section shows before anything is known. The view model replaces it with a real
    /// snapshot as soon as the bounded lookup answers.
    public static let checking = DlssCompatibilityPresentation(
        statusText: loadingText,
        statusSupportingText: loadingSupportingText,
        statusGlyph: .progress,
        gameSupport: nil,
        freshnessText: "",
        freshnessSupportingText: "",
        freshnessGlyph: .none,
        freshnessHelpText: "",
        sourceFooter: sourceFooter,
        compactChip: nil
    )

    public static func make(_ snapshot: OPNDlssCompatibilityService.Snapshot, locale: Locale = .current) -> DlssCompatibilityPresentation {
        let checkedTimestamp = snapshot.lastSuccessfulCheck.map { timestamp($0, locale: locale) }
        return DlssCompatibilityPresentation(
            statusText: statusText(for: snapshot),
            statusSupportingText: statusSupportingText(for: snapshot),
            statusGlyph: statusGlyph(for: snapshot),
            gameSupport: snapshot.outcome.gameSupport,
            freshnessText: freshnessText(for: snapshot, checkedTimestamp: checkedTimestamp),
            freshnessSupportingText: freshnessSupportingText(for: snapshot, checkedTimestamp: checkedTimestamp),
            freshnessGlyph: freshnessGlyph(for: snapshot),
            freshnessHelpText: snapshot.isLoadedFromCache ? cachedHelpText : "",
            sourceFooter: sourceFooter,
            compactChip: compactChip(for: snapshot)
        )
    }

    private static func statusText(for snapshot: OPNDlssCompatibilityService.Snapshot) -> String {
        switch snapshot.listState {
        case .loading: loadingText
        case .unavailable: unavailableText
        case .ready, .refreshing, .refreshFailed, .stale: snapshot.outcome.isMatched ? "" : unknownTitle
        }
    }

    private static func statusSupportingText(for snapshot: OPNDlssCompatibilityService.Snapshot) -> String {
        switch snapshot.listState {
        case .loading: loadingSupportingText
        case .unavailable: ""
        case .ready, .refreshing, .refreshFailed, .stale: snapshot.outcome.isMatched ? "" : unknownBody
        }
    }

    private static func statusGlyph(for snapshot: OPNDlssCompatibilityService.Snapshot) -> DlssCompatibilityGlyph {
        switch snapshot.listState {
        case .loading: .progress
        case .unavailable: .info
        case .ready, .refreshing, .refreshFailed, .stale: snapshot.outcome.isMatched ? .none : .question
        }
    }

    private static func freshnessText(for snapshot: OPNDlssCompatibilityService.Snapshot, checkedTimestamp: String?) -> String {
        switch snapshot.listState {
        case .loading, .unavailable: ""
        case .ready: checkedText(checkedTimestamp, isCached: snapshot.isLoadedFromCache)
        case .stale: checkedText(checkedTimestamp, isCached: true)
        case .refreshing: "Saved information · Updating…"
        case .refreshFailed: "Saved information · Update unavailable"
        }
    }

    private static func freshnessSupportingText(for snapshot: OPNDlssCompatibilityService.Snapshot, checkedTimestamp: String?) -> String {
        switch snapshot.listState {
        case .loading, .unavailable, .ready: ""
        case .refreshing, .refreshFailed, .stale: staleSupportingText(checkedTimestamp)
        }
    }

    private static func freshnessGlyph(for snapshot: OPNDlssCompatibilityService.Snapshot) -> DlssCompatibilityGlyph {
        switch snapshot.listState {
        case .loading, .unavailable: .none
        case .ready: .clock
        case .stale: .clock
        case .refreshing: .progress
        case .refreshFailed: .warning
        }
    }

    private static func compactChip(for snapshot: OPNDlssCompatibilityService.Snapshot) -> CompactChip? {
        guard snapshot.outcome.isMatched else { return nil }
        return CompactChip(
            label: "DLSS",
            accessibilityLabel: snapshot.isStale ? staleChipAccessibilityLabel : freshChipAccessibilityLabel,
            isStale: snapshot.isStale
        )
    }

    private static func checkedText(_ checkedTimestamp: String?, isCached: Bool) -> String {
        let checked = "Checked \(checkedTimestamp ?? "")"
        guard isCached else { return checked }
        return "Cached · \(checked)"
    }

    private static func staleSupportingText(_ checkedTimestamp: String?) -> String {
        "Last checked \(checkedTimestamp ?? ""). Compatibility information may have changed."
    }

    private static func timestamp(_ date: Date, locale: Locale) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute().locale(locale))
    }
}
