//  NVIDIA's DLSS games list: parsing limits, title matching, and the cache/refresh state machine
//  that keeps a missing or slow list from failing anything.

import Foundation
import Testing
@testable import OpenNOW

@Suite struct DlssCompatibilityTests {
    // MARK: - Parsing

    @Test func parsesStringAndNumericNamesAndSkipsApps() throws {
        let rows = try DlssGamesListParser.parse(document([
            row("007 First Light", ["NV, T", "NV, U", "NV, 6X", "NV, T", "NV, T"]),
            row(83, ["NV, T", "", "", "", ""]),
            row("Broadcast", ["Yes", "", "", "", ""], type: "App"),
            ["name": NSNull(), "type": "Game"],
        ]))
        #expect(rows.map(\.title) == ["007 First Light", "83"])
        #expect(rows[0].support?.multiFrameGeneration?.maxMultiplier == 6)
    }

    @Test func mapsCellsToNativeOverrideAndMultiplier() throws {
        let index = DlssGamesIndex(rows: try DlssGamesListParser.parse(document([
            row("Cyberpunk 2077", ["Yes", "Yes", "NV, 6X", "NV, T", "Yes"]),
            row("Black Myth: Wukong", ["NV, T", "Yes", "NV, 4X", "", ""]),
            row("Ray Traced Only", ["", "", "", "", ""]),
        ])))
        let cyberpunk = try #require(index.lookup("Cyberpunk 2077").support)
        #expect(cyberpunk.superResolution == .native)
        #expect(cyberpunk.frameGeneration == .native)
        #expect(cyberpunk.multiFrameGeneration?.maxMultiplier == 6)
        #expect(cyberpunk.rayReconstruction == .override)
        #expect(cyberpunk.dlaa == .native)

        let wukong = try #require(index.lookup("Black Myth: Wukong").support)
        #expect(wukong.superResolution == .override)
        #expect(wukong.multiFrameGeneration?.maxMultiplier == 4)
        #expect(wukong.rayReconstruction == nil)

        // A row that only lists ray tracing is not DLSS information.
        #expect(index.lookup("Ray Traced Only") == .listedWithoutSupport)
        #expect(DlssMultiFrameGeneration.fromCell("Yes") == nil)
        #expect(DlssSupport.fromCell("Maybe") == nil)
    }

    @Test func rejectsOversizedOrInvalidLists() {
        #expect(throws: DlssGamesListError.tooLarge) {
            try DlssGamesListParser.parse(Data(repeating: 0x20, count: DlssCompatibilityLimits.maximumListBytes + 1))
        }
        #expect(throws: (any Error).self) { try DlssGamesListParser.parse(Data("not json".utf8)) }
        #expect(throws: (any Error).self) { try DlssGamesListParser.parse(Data(#"{"data":{}}"#.utf8)) }
        #expect(throws: (any Error).self) { try DlssGamesListParser.parse(Data("[]".utf8)) }
        let tooMany = (0...(DlssCompatibilityLimits.maximumRows)).map { row("x\($0)", ["", "", "", "", ""], type: "App") }
        #expect(throws: (any Error).self) { try DlssGamesListParser.parse(document(tooMany)) }
    }

    @Test func aMalformedDocumentLeavesEveryTitleUnknown() async {
        let service = makeService(transport: DlssStubTransport([.success(Data("not json".utf8))]), clock: DlssTestClock().compatibilityClock)
        _ = await service.index(waitingUpTo: 1)
        await service.awaitPendingRefresh()
        let snapshot = await service.currentSnapshot(forTitle: "Fortnite")
        #expect(snapshot.outcome == .unknown)
        #expect(snapshot.listState == .unavailable)
    }

    // MARK: - Matching

    @Test func normalizesMarksAccentsAndPunctuation() {
        #expect(DlssTitleMatcher.normalize("Cyberpunk 2077®") == "cyberpunk 2077")
        #expect(DlssTitleMatcher.normalize("Fortnite™") == "fortnite")
        #expect(DlssTitleMatcher.normalize("Shadow of the Tomb Raider\u{200B}™ Definitive Edition") == "shadow of the tomb raider definitive edition")
        #expect(DlssTitleMatcher.normalize("Pokémon & Friends©") == "pokemon and friends")
        #expect(DlssTitleMatcher.normalize("  S.T.A.L.K.E.R. 2:  Heart of Chornobyl ") == "s t a l k e r 2 heart of chornobyl")
    }

    @Test func matchesExactThenLooseEditionsButNotRemasters() throws {
        let index = DlssGamesIndex(rows: try DlssGamesListParser.parse(document([
            row("Cyberpunk 2077", ["Yes", "Yes", "NV, 6X", "NV, T", "Yes"]),
            row("Fortnite", ["NV, T", "", "", "", "NV, T"]),
            row("Control", ["Yes", "", "", "", ""]),
            row("Alan Wake Remastered", ["Yes", "", "", "", ""]),
            row("Goat Simulator: Remastered", ["Yes", "", "", "", ""]),
            row("Battlefield V", ["Yes", "", "", "", ""]),
            row("The Witcher 3: Wild Hunt", ["Yes", "", "", "", ""]),
        ])))
        #expect(index.lookup("Cyberpunk 2077®").isMatched)
        #expect(index.lookup("Fortnite®").support?.superResolution == .override)
        #expect(index.lookup("Fortnite®").support?.frameGeneration == nil)
        #expect(index.lookup("Control Ultimate Edition").isMatched)
        #expect(index.lookup("Battlefield™ V: Definitive").isMatched)
        #expect(index.lookup("The Witcher 3: Wild Hunt - Game of the Year Edition").isMatched)
        #expect(index.lookup("Witcher 3: Wild Hunt Complete Edition").isMatched)
        // Remastered is a different release and is never stripped as an edition suffix.
        #expect(index.lookup("Alan Wake") == .unknown)
        #expect(index.lookup("Goat Simulator") == .unknown)
        #expect(index.lookup("Control 2") == .unknown)
        #expect(index.lookup("Ultimate") == .unknown)
        #expect(index.lookup("™") == .unknown)
    }

    @Test func exactRowsWithoutDlssDoNotFallBackToEditions() throws {
        let index = DlssGamesIndex(rows: try DlssGamesListParser.parse(document([
            row("Puzzle Quest", ["", "", "", "", ""]),
            row("Puzzle Quest Deluxe", ["Yes", "", "", "", ""]),
        ])))
        #expect(index.lookup("Puzzle Quest") == .listedWithoutSupport)
        #expect(index.lookup("Puzzle Quest™ Deluxe").isMatched)
    }

    // MARK: - Cache and refresh

    @Test func aFreshCacheServesWithoutAFetch() async {
        let clock = DlssTestClock()
        let transport = DlssStubTransport([])
        let cache = DlssMemoryCache(DlssCachedList(rows: fortniteRows, checkedAt: clock.now.addingTimeInterval(-3600)))
        let service = makeService(transport: transport, cache: cache, clock: clock.compatibilityClock)
        let snapshot = await service.snapshot(forTitle: "Fortnite®")
        #expect(snapshot.listState == .ready)
        #expect(snapshot.loadedFromCache)
        #expect(snapshot.outcome.isMatched)
        #expect(transport.requestCount == 0)
    }

    @Test func aStaleCacheIsKeptWhileRefreshingAndAfterAFailure() async {
        let clock = DlssTestClock()
        let transport = DlssStubTransport([.failure(DlssCompatibilityFetchError.http(503))])
        let cachedAt = clock.now.addingTimeInterval(-25 * 3600)
        let cache = DlssMemoryCache(DlssCachedList(rows: fortniteRows, checkedAt: cachedAt))
        let service = makeService(transport: transport, cache: cache, clock: clock.compatibilityClock)

        let refreshing = await service.snapshot(forTitle: "Fortnite®")
        #expect(refreshing.listState == .refreshing)
        #expect(refreshing.hasSavedData)
        #expect(refreshing.outcome.isMatched)
        #expect(refreshing.lastSuccessfulCheck == cachedAt)

        await service.awaitPendingRefresh()
        let failed = await service.snapshot(forTitle: "Fortnite®")
        #expect(failed.listState == .refreshFailed)
        #expect(failed.hasSavedData)
        #expect(failed.outcome.isMatched)
        // A stale read never resets the last successful check.
        #expect(failed.lastSuccessfulCheck == cachedAt)
        #expect(transport.requestCount == 1)

        // The next demand inside the backoff window does not hammer the list.
        _ = await service.snapshot(forTitle: "Fortnite®")
        #expect(transport.requestCount == 1)

        clock.advance(DlssCompatibilityLimits.retryInterval + 1)
        _ = await service.snapshot(forTitle: "Fortnite®")
        await service.awaitPendingRefresh()
        #expect(transport.requestCount == 2)
    }

    @Test func aFailedFirstFetchLeavesTheListUnknownAndBacksOff() async {
        let clock = DlssTestClock()
        let transport = DlssStubTransport([.failure(DlssCompatibilityFetchError.transport("offline"))])
        let service = makeService(transport: transport, clock: clock.compatibilityClock)
        _ = await service.index(waitingUpTo: 1)
        await service.awaitPendingRefresh()
        let snapshot = await service.snapshot(forTitle: "Fortnite")
        #expect(snapshot.listState == .unavailable)
        #expect(snapshot.outcome == .unknown)
        #expect(snapshot.lastSuccessfulCheck == nil)
        #expect(transport.requestCount == 1)

        clock.advance(DlssCompatibilityLimits.retryInterval - 1)
        _ = await service.snapshot(forTitle: "Fortnite")
        #expect(transport.requestCount == 1)
    }

    @Test func aSuccessfulRevalidationAdvancesTheLastCheckEvenWhenUnchanged() async {
        let clock = DlssTestClock()
        let cachedAt = clock.now.addingTimeInterval(-25 * 3600)
        let cache = DlssMemoryCache(DlssCachedList(rows: fortniteRows, checkedAt: cachedAt))
        let service = makeService(transport: DlssStubTransport([.success(document([row("Fortnite", ["NV, T", "", "", "", "NV, T"])]))]), cache: cache, clock: clock.compatibilityClock)

        _ = await service.snapshot(forTitle: "Fortnite")
        await service.awaitPendingRefresh()
        let snapshot = await service.snapshot(forTitle: "Fortnite")
        #expect(snapshot.listState == .ready)
        #expect(!snapshot.loadedFromCache)
        #expect(snapshot.lastSuccessfulCheck == clock.now)
        #expect(snapshot.outcome.isMatched)
    }

    @Test func aFailedRefreshRetriesOnTheNextDemandAfterTheBackoff() async {
        let clock = DlssTestClock()
        let transport = DlssStubTransport([
            .failure(DlssCompatibilityFetchError.transport("offline")),
            .success(document([row("Fortnite", ["NV, T", "", "", "", "NV, T"])])),
        ])
        let service = makeService(transport: transport, clock: clock.compatibilityClock)
        _ = await service.index(waitingUpTo: 1)
        await service.awaitPendingRefresh()
        #expect(await service.currentSnapshot(forTitle: "Fortnite").listState == .unavailable)

        clock.advance(DlssCompatibilityLimits.retryInterval + 1)
        _ = await service.snapshot(forTitle: "Fortnite")
        await service.awaitPendingRefresh()
        let recovered = await service.currentSnapshot(forTitle: "Fortnite")
        #expect(recovered.listState == .ready)
        #expect(recovered.outcome.isMatched)
        #expect(transport.requestCount == 2)
    }

    @Test func theFirstLookupWaitsAtMostTheBoundedTimeAndOnlyOnce() async {
        let transport = DlssStubTransport([.success(document([row("Fortnite", ["NV, T", "", "", "", "NV, T"])]))], delay: 2)
        let service = makeService(transport: transport, clock: .live)

        let start = Date()
        let first = await service.index(waitingUpTo: 0.3)
        let elapsed = Date().timeIntervalSince(start)
        #expect(first == nil)
        #expect(elapsed < 1.2, "the bounded wait must not hold the caller for the whole download")

        // A second caller does not wait at all while the first attempt is still in flight.
        let secondStart = Date()
        let second = await service.index(waitingUpTo: 0.3)
        #expect(second == nil)
        #expect(Date().timeIntervalSince(secondStart) < 0.2)
        #expect(transport.requestCount == 1)

        await service.awaitPendingRefresh()
        let snapshot = await service.currentSnapshot(forTitle: "Fortnite")
        #expect(snapshot.outcome.isMatched)
        #expect(transport.requestCount == 1)
    }

    @Test func anEmptyDocumentLeavesEveryTitleUnknownWithoutFailing() async {
        let clock = DlssTestClock()
        let service = makeService(
            transport: DlssStubTransport([.success(document([]))]),
            cache: DlssMemoryCache(DlssCachedList(rows: [], checkedAt: clock.now)),
            clock: clock.compatibilityClock
        )
        _ = await service.index(waitingUpTo: 1)
        await service.awaitPendingRefresh()
        let snapshot = await service.currentSnapshot(forTitle: "Fortnite")
        #expect(snapshot.outcome == .unknown)
        #expect(snapshot.listState == .ready)
    }

    @Test func theSnapshotReportsTheMatchOutcomeAndItsFreshness() async {
        let clock = DlssTestClock()
        let service = makeService(
            transport: DlssStubTransport([.success(document([
                row("Fortnite", ["NV, T", "", "", "", "NV, T"]),
                row("Ray Traced Only", ["", "", "", "", ""]),
            ]))]),
            clock: clock.compatibilityClock
        )
        _ = await service.index(waitingUpTo: 1)
        await service.awaitPendingRefresh()
        let matched = await service.currentSnapshot(forTitle: "Fortnite®")
        #expect(matched.outcome.isMatched)
        #expect(matched.listState == .ready)
        #expect(!matched.loadedFromCache)

        let unlisted = await service.currentSnapshot(forTitle: "Some Unlisted Game")
        #expect(unlisted.outcome == .unknown)
        #expect(unlisted.listState == .ready)

        let listedWithoutSupport = await service.currentSnapshot(forTitle: "Ray Traced Only")
        #expect(listedWithoutSupport.outcome == .listedWithoutSupport)
        #expect(!listedWithoutSupport.outcome.isMatched)
    }

    // MARK: - Fixtures

    private var fortniteRows: [DlssGamesRow] {
        [DlssGamesRow(title: "Fortnite", support: DlssGameSupport(superResolution: .override, dlaa: .override))]
    }

    private func makeService(
        transport: DlssCompatibilityTransport,
        cache: DlssCompatibilityCacheStoring = DlssMemoryCache(),
        clock: DlssCompatibilityClock
    ) -> OPNDlssCompatibilityService {
        OPNDlssCompatibilityService(transport: transport, cache: cache, clock: clock)
    }

    private func row(_ name: Any, _ cells: [String], type: String = "Game") -> [String: Any] {
        var value: [String: Any] = ["sno": 1, "name": name, "type": type, "ray tracing": "", "ai": ""]
        for (index, column) in DlssCompatibilityLimits.columns.enumerated() where cells.indices.contains(index) {
            value[column] = cells[index]
        }
        return value
    }

    private func document(_ rows: [[String: Any]]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["columns": [], "footer": "", "data": rows])) ?? Data()
    }
}

/// A transport that hands back queued results in order, optionally after a delay.
final class DlssStubTransport: DlssCompatibilityTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Result<Data, any Error>]
    private var count = 0
    private let delay: TimeInterval

    init(_ queued: [Result<Data, any Error>], delay: TimeInterval = 0) {
        self.queued = queued
        self.delay = delay
    }

    var requestCount: Int {
        lock.withLock { count }
    }

    func fetchList(url: URL, timeout: TimeInterval) async throws -> Data {
        let response = lock.withLock { () -> Result<Data, any Error>? in
            count += 1
            return queued.isEmpty ? nil : queued.removeFirst()
        }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        guard let response else { throw DlssCompatibilityFetchError.transport("no queued response") }
        return try response.get()
    }
}

final class DlssMemoryCache: DlssCompatibilityCacheStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DlssCachedList?

    init(_ stored: DlssCachedList? = nil) {
        self.stored = stored
    }

    func load() -> DlssCachedList? {
        lock.withLock { stored }
    }

    func save(_ list: DlssCachedList) {
        lock.withLock { stored = list }
    }
}

/// A clock the test moves by hand. Its sleep returns immediately, so a bounded wait that is not
/// under test costs nothing.
final class DlssTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.date = date
    }

    var now: Date {
        lock.withLock { date }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(seconds) }
    }

    var compatibilityClock: DlssCompatibilityClock {
        DlssCompatibilityClock(now: { [self] in now }, sleep: { _ in })
    }
}
