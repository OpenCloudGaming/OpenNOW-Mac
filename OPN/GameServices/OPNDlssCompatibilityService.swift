//  NVIDIA's DLSS games list: fetching it, caching it, and answering "what does the list say about
//  this title" without ever holding a catalog load or a launch hostage.
//
//  The list is decoration. A missing, oversized or invalid document leaves every title unknown and
//  the next demand retries - it never fails the catalog or the launch that asked for it. The first
//  lookup in a process waits at most 1.5 seconds for the first attempt; after that the refresh runs
//  in the background and a later result replaces what is shown, once.

import Foundation

/// A cached copy of the list: the parsed rows and when they were last successfully checked.
public struct DlssCachedList: Codable, Equatable, Sendable {
    public var rows: [DlssGamesRow]
    public var checkedAt: Date

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
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (TimeInterval) async throws -> Void

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
        /// No usable data yet, and the first attempt is in flight.
        case loading
        /// Usable data, checked within the cache lifetime.
        case ready
        /// Saved data is past its lifetime and a refresh is in flight.
        case refreshing
        /// Saved data is past its lifetime and the last refresh failed. Another demand retries no
        /// sooner than the retry interval.
        case refreshFailed
        /// Saved data is past its lifetime and no refresh is in flight.
        case stale
        /// No usable data and the fetch failed.
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
        public var outcome: DlssMatchOutcome
        public var listState: ListState
        public var lastSuccessfulCheck: Date?
        /// The saved data came off disk this session rather than from a fetch this session, which is
        /// what the "Cached ·" prefix on the freshness footer reports.
        public var loadedFromCache: Bool

        public var hasSavedData: Bool { listState.hasSavedData }
        public var isStale: Bool { listState.isStale }
    }

    private let transport: DlssCompatibilityTransport
    private let cache: DlssCompatibilityCacheStoring
    private let clock: DlssCompatibilityClock
    private let listURL: URL
    private let cacheLifetime: TimeInterval
    private let retryInterval: TimeInterval

    private var index: DlssGamesIndex?
    private var expiresAt = Date.distantPast
    private var retryAt = Date.distantPast
    private var isLoading = false
    private var firstAttemptDone = false
    private var firstWaitClaimed = false
    private var lastSuccessfulCheck: Date?
    private var lastRefreshFailed = false
    private var loadedFromCache = false
    private var didPrepare = false
    private var loadTask: Task<Void, Never>?
    private var firstWaitContinuation: CheckedContinuation<Void, Never>?
    private var firstWaitEnded = false

    public init(
        transport: DlssCompatibilityTransport = DlssHTTPTransport(),
        cache: DlssCompatibilityCacheStoring = DlssCompatibilityDiskCache(),
        clock: DlssCompatibilityClock = .live,
        listURL: URL = DlssCompatibilityLimits.listURL,
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

    /// The index, waiting at most `seconds` for the process's first attempt and never longer.
    ///
    /// Only one caller ever waits: the rest get whatever is in hand, so a slow download cannot make
    /// a burst of catalog lookups all block behind it. The wait is ended either by the attempt
    /// finishing or by its own timeout, whichever happens first - the download itself keeps going.
    public func index(waitingUpTo seconds: TimeInterval = DlssCompatibilityLimits.firstLookupWait) async -> DlssGamesIndex? {
        prepare()
        startRefreshIfNeeded()
        if let index { return index }
        guard !firstAttemptDone, !firstWaitClaimed, isLoading else { return nil }
        firstWaitClaimed = true
        firstWaitEnded = false
        let clock = self.clock
        let timeout = Task { [weak self] in
            try? await clock.sleep(seconds)
            await self?.endFirstWait()
        }
        await withCheckedContinuation { continuation in
            if firstWaitEnded {
                continuation.resume()
            } else {
                firstWaitContinuation = continuation
            }
        }
        timeout.cancel()
        return index
    }

    private func endFirstWait() {
        firstWaitEnded = true
        firstWaitContinuation?.resume()
        firstWaitContinuation = nil
    }

    /// What the compatibility section should show for this title. Reading a snapshot is a demand:
    /// it is what starts a refresh when the saved copy is past its lifetime.
    public func snapshot(forTitle title: String) async -> Snapshot {
        prepare()
        startRefreshIfNeeded()
        let outcome = index?.lookup(title) ?? .unknown
        return Snapshot(
            outcome: outcome,
            listState: listState(),
            lastSuccessfulCheck: lastSuccessfulCheck,
            loadedFromCache: loadedFromCache
        )
    }

    /// The snapshot without starting anything. For re-renders that must not add demand.
    public func currentSnapshot(forTitle title: String) -> Snapshot {
        prepare()
        return Snapshot(
            outcome: index?.lookup(title) ?? .unknown,
            listState: listState(),
            lastSuccessfulCheck: lastSuccessfulCheck,
            loadedFromCache: loadedFromCache
        )
    }

    /// Waits for the in-flight refresh to finish, however long it takes. Used for the single
    /// background update that may follow the UI's bounded wait; it never blocks a catalog load.
    public func awaitPendingRefresh() async {
        while let task = loadTask {
            await task.value
        }
    }

    private func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        guard let cached = cache.load(), !cached.rows.isEmpty else { return }
        index = DlssGamesIndex(rows: cached.rows)
        lastSuccessfulCheck = cached.checkedAt
        expiresAt = cached.checkedAt.addingTimeInterval(cacheLifetime)
        loadedFromCache = true
    }

    private func startRefreshIfNeeded() {
        let now = clock.now()
        guard !isLoading, now >= retryAt else { return }
        guard index == nil || now >= expiresAt else { return }
        isLoading = true
        loadTask = Task { await self.performLoad() }
    }

    private func performLoad() async {
        do {
            let data = try await transport.fetchList(url: listURL, timeout: DlssCompatibilityLimits.fetchTimeout)
            let rows = try DlssGamesListParser.parse(data)
            let completedAt = clock.now()
            index = DlssGamesIndex(rows: rows)
            expiresAt = completedAt.addingTimeInterval(cacheLifetime)
            // A successful revalidation advances the last successful check even when the content is
            // unchanged; a stale read never does.
            lastSuccessfulCheck = completedAt
            loadedFromCache = false
            lastRefreshFailed = false
            retryAt = .distantPast
            cache.save(DlssCachedList(rows: rows, checkedAt: completedAt))
        } catch {
            lastRefreshFailed = true
            // Back off on the next demand rather than polling. Saved data stays in place.
            retryAt = clock.now().addingTimeInterval(retryInterval)
            OPNDiagnostics.logWarningMessage(OPNDiagnostics.formattedLogMessage(level: "warning", area: "DLSS", message: "DLSS games list unavailable: \(Self.describe(error))"))
        }
        isLoading = false
        firstAttemptDone = true
        loadTask = nil
        endFirstWait()
    }

    private func listState() -> ListState {
        guard index != nil else {
            return firstAttemptDone && !isLoading ? .unavailable : .loading
        }
        if isLoading { return .refreshing }
        if lastRefreshFailed { return .refreshFailed }
        return clock.now() >= expiresAt ? .stale : .ready
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let DlssCompatibilityFetchError.http(status): "HTTP \(status)"
        case DlssCompatibilityFetchError.tooLarge: "document larger than 4 MiB"
        case let DlssCompatibilityFetchError.transport(reason): reason
        case DlssGamesListError.tooLarge: "document larger than 4 MiB"
        case let DlssGamesListError.malformed(reason): reason
        default: String(describing: error)
        }
    }
}

/// The compatibility section's exact copy, built from a snapshot. Pure, so every state combination
/// can be asserted without rendering.
public struct DlssCompatibilityPresentation: Equatable, Sendable {
    public var statusText: String
    public var statusSupportingText: String
    public var statusShowsProgress: Bool
    public var statusShowsWarning: Bool
    /// The feature table's source. Nil when the table is replaced by an unknown or unavailable
    /// message.
    public var support: DlssGameSupport?
    public var unknownTitle: String
    public var unknownBody: String
    public var freshnessText: String
    public var freshnessSupportingText: String
    public var freshnessShowsProgress: Bool
    public var freshnessShowsWarning: Bool
    public var freshnessHelpText: String
    public var sourceFooter: String
    public var compactChip: CompactChip?

    public struct CompactChip: Equatable, Sendable {
        public var label: String
        public var accessibilityLabel: String
        public var isStale: Bool
    }

    public static let unknownTitle = "DLSS compatibility unknown"
    public static let unknownBody = "We couldn't confirm this game's DLSS compatibility from NVIDIA's list. This does not mean DLSS is unsupported."
    public static let unavailableText = "Compatibility information unavailable."
    public static let loadingText = "Checking DLSS compatibility…"
    public static let loadingSupportingText = "Looking up this game in NVIDIA's DLSS games list."
    public static let sourceFooter = "Source: NVIDIA's DLSS games list"
    public static let cachedHelpText = "Compatibility information is saved for up to 24 hours before a refresh is attempted."
    public static let staleChipAccessibilityLabel = "DLSS compatibility information may be outdated."
    public static let freshChipAccessibilityLabel = "DLSS compatibility information available."

    public static func make(_ snapshot: OPNDlssCompatibilityService.Snapshot, locale: Locale = .current) -> DlssCompatibilityPresentation {
        let support = snapshot.outcome.support
        let staleSupportingText = snapshot.lastSuccessfulCheck.map { "Last checked \(Self.timestamp($0, locale: locale)). Compatibility information may have changed." } ?? ""

        var presentation = DlssCompatibilityPresentation(
            statusText: "",
            statusSupportingText: "",
            statusShowsProgress: false,
            statusShowsWarning: false,
            support: support,
            unknownTitle: "",
            unknownBody: "",
            freshnessText: "",
            freshnessSupportingText: "",
            freshnessShowsProgress: false,
            freshnessShowsWarning: false,
            freshnessHelpText: "",
            sourceFooter: sourceFooter,
            compactChip: nil
        )

        switch snapshot.listState {
        case .loading:
            presentation.statusText = loadingText
            presentation.statusSupportingText = loadingSupportingText
            presentation.statusShowsProgress = true
        case .unavailable:
            presentation.statusText = unavailableText
        case .ready, .refreshing, .refreshFailed, .stale:
            if support == nil {
                presentation.statusText = unknownTitle
                presentation.statusSupportingText = unknownBody
            }
        }

        switch snapshot.listState {
        case .ready:
            let checked = snapshot.lastSuccessfulCheck.map { Self.timestamp($0, locale: locale) } ?? ""
            presentation.freshnessText = snapshot.loadedFromCache ? "Cached · Checked \(checked)" : "Checked \(checked)"
            presentation.freshnessHelpText = snapshot.loadedFromCache ? cachedHelpText : ""
        case .refreshing:
            presentation.freshnessText = "Saved information · Updating…"
            presentation.freshnessSupportingText = staleSupportingText
            presentation.freshnessShowsProgress = true
            presentation.freshnessShowsWarning = true
        case .refreshFailed:
            presentation.freshnessText = "Saved information · Update unavailable"
            presentation.freshnessSupportingText = staleSupportingText
            presentation.freshnessShowsWarning = true
        case .stale:
            let checked = snapshot.lastSuccessfulCheck.map { Self.timestamp($0, locale: locale) } ?? ""
            presentation.freshnessText = "Cached · Checked \(checked)"
            presentation.freshnessSupportingText = staleSupportingText
        case .loading, .unavailable:
            break
        }

        if support != nil {
            presentation.compactChip = CompactChip(
                label: "DLSS",
                accessibilityLabel: snapshot.isStale ? staleChipAccessibilityLabel : freshChipAccessibilityLabel,
                isStale: snapshot.isStale
            )
        }
        return presentation
    }

    private static func timestamp(_ date: Date, locale: Locale) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute().locale(locale))
    }

    /// What the section shows before anything is known. The view model replaces it with a real
    /// snapshot as soon as the bounded lookup answers.
    public static let checking = DlssCompatibilityPresentation(
        statusText: loadingText,
        statusSupportingText: loadingSupportingText,
        statusShowsProgress: true,
        statusShowsWarning: false,
        support: nil,
        unknownTitle: "",
        unknownBody: "",
        freshnessText: "",
        freshnessSupportingText: "",
        freshnessShowsProgress: false,
        freshnessShowsWarning: false,
        freshnessHelpText: "",
        sourceFooter: sourceFooter,
        compactChip: nil
    )
}
