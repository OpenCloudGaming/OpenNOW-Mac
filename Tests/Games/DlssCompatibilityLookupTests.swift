//  The catalog's own DLSS plumbing: which game a presentation belongs to, what a late result does
//  when the reader has already moved on, and the compact chip's presence rules.

import Foundation
import Testing
@testable import OpenNOW

@Suite struct DlssCompatibilityLookupTests {
    @MainActor @Test func aLateResultForAReplacedGameDoesNotLand() async {
        let transport = DlssGatedTransport(rows: [
            row("Fortnite", ["NV, T", "", "", "", "NV, T"]),
            row("Cyberpunk 2077", ["Yes", "Yes", "NV, 6X", "NV, T", "Yes"]),
        ])
        let model = makeModel(transport: transport)
        let first = makeGameForTesting(id: "1", title: "Fortnite")
        let second = makeGameForTesting(id: "2", title: "Cyberpunk 2077")

        model.beginDlssCompatibilityLookup(for: first)
        await transport.waitUntilRequested()
        #expect(model.dlssCompatibilityGameKey == first.catalogIdentity)

        // The reader moves to another game while the first lookup is still in flight.
        model.beginDlssCompatibilityLookup(for: second)
        transport.release()
        await model.dlssLookupTask?.value

        #expect(model.dlssCompatibilityGameKey == second.catalogIdentity)
        #expect(model.dlssCompatibility.support != nil, "the second game's own result must land")
        #expect(model.dlssCompactChip(for: first) == nil, "a presentation must not leak onto another game")
        #expect(model.dlssCompactChip(for: second)?.label == "DLSS")
    }

    @MainActor @Test func closingTheSurfaceLeavesTheAnnouncerSilent() async {
        let transport = DlssGatedTransport(rows: [row("Fortnite", ["NV, T", "", "", "", "NV, T"])])
        let scheduler = DlssVirtualScheduler()
        var posted: [String] = []
        let announcer = OPNDlssCompatibilityAnnouncer(scheduler: scheduler) { posted.append($0) }
        let model = makeModel(transport: transport, announcer: announcer)

        model.beginDlssCompatibilityLookup(for: makeGameForTesting(id: "1", title: "Fortnite"))
        await transport.waitUntilRequested()
        let task = model.dlssLookupTask
        model.endDlssCompatibilityLookup()
        transport.release()
        await task?.value
        scheduler.advance(by: 5)

        #expect(posted.isEmpty, "a queued start is cancelled, and the late result is not replayed")
    }

    @MainActor @Test func aLookupThatNeverMatchesStillReportsUnknownRatherThanFailing() async {
        let transport = DlssGatedTransport(rows: [row("Fortnite", ["NV, T", "", "", "", "NV, T"])], releaseImmediately: true)
        let model = makeModel(transport: transport)
        let game = makeGameForTesting(id: "9", title: "Some Unlisted Game")
        model.beginDlssCompatibilityLookup(for: game)
        await model.dlssLookupTask?.value

        #expect(model.dlssCompatibility.statusText == DlssCompatibilityPresentation.unknownTitle)
        #expect(model.dlssCompactChip(for: game) == nil, "unknown compatibility gets no chip at all")
    }

    @MainActor @Test func anInitialUnknownAnswerIsAnnouncedOnce() async {
        let transport = DlssGatedTransport(rows: [row("Fortnite", ["NV, T", "", "", "", "NV, T"])], releaseImmediately: true)
        let scheduler = DlssVirtualScheduler()
        var posted: [String] = []
        let announcer = OPNDlssCompatibilityAnnouncer(scheduler: scheduler) { posted.append($0) }
        let model = makeModel(transport: transport, announcer: announcer)

        model.beginDlssCompatibilityLookup(for: makeGameForTesting(id: "9", title: "Some Unlisted Game"))
        await model.dlssLookupTask?.value
        scheduler.advance(by: 0.2)

        // The start is cancelled by the answer arriving first; the outcome is still the answer,
        // even when that answer is "unknown".
        #expect(posted == ["DLSS compatibility unknown."])
    }

    @MainActor private func makeModel(
        transport: DlssCompatibilityTransport,
        announcer: OPNDlssCompatibilityAnnouncer = OPNDlssCompatibilityAnnouncer(scheduler: DlssVirtualScheduler()) { _ in }
    ) -> CatalogViewModel {
        let service = OPNDlssCompatibilityService(
            transport: transport,
            cache: DlssMemoryCache(),
            clock: DlssTestClock().compatibilityClock
        )
        return makeCatalogViewModelForTesting(dlssCompatibilityService: service, dlssAnnouncer: announcer)
    }

    @MainActor private func makeGameForTesting(id: String, title: String) -> OPNCatalogGameObject {
        var info = OPNGameInfo()
        info.id = id
        info.title = title
        return OPNCatalogGameObject(game: info)
    }

    private func row(_ name: String, _ cells: [String]) -> DlssGamesRow {
        let support = DlssGamesListParser.support(from: cells)
        return DlssGamesRow(title: name, support: support)
    }
}

/// A transport whose single fetch can be held open until the test releases it, so a "late result"
/// can be produced on demand rather than by racing a real delay.
final class DlssGatedTransport: DlssCompatibilityTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let rows: [DlssGamesRow]
    private let releaseImmediately: Bool
    private var requested = false
    private var released = false
    private var gate: CheckedContinuation<Void, Never>?

    init(rows: [DlssGamesRow], releaseImmediately: Bool = false) {
        self.rows = rows
        self.releaseImmediately = releaseImmediately
    }

    var requestCount: Int {
        lock.withLock { requested ? 1 : 0 }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            let continuation = gate
            gate = nil
            return continuation
        }
        continuation?.resume()
    }

    func waitUntilRequested() async {
        while lock.withLock({ !requested }) {
            await Task.yield()
        }
    }

    func fetchList(url: URL, timeout: TimeInterval) async throws -> Data {
        if !releaseImmediately {
            await withCheckedContinuation { continuation in
                let alreadyReleased = lock.withLock { () -> Bool in
                    requested = true
                    if released { return true }
                    gate = continuation
                    return false
                }
                if alreadyReleased { continuation.resume() }
            }
        } else {
            lock.withLock { requested = true }
        }
        let document: [String: Any] = [
            "columns": [],
            "footer": "",
            "data": rows.map { row -> [String: Any] in
                var value: [String: Any] = ["sno": 1, "name": row.title, "type": "Game"]
                let cells = [
                    row.support?.superResolution?.rawValue,
                    row.support?.frameGeneration?.rawValue,
                    row.support?.multiFrameGeneration.map { "NV, \($0.maxMultiplier)X" },
                    row.support?.rayReconstruction?.rawValue,
                    row.support?.dlaa?.rawValue,
                ]
                for (index, column) in DlssCompatibilityLimits.columns.enumerated() {
                    value[column] = cells[index].map { $0 == "native" ? "Yes" : "NV, T" } ?? ""
                }
                return value
            },
        ]
        return (try? JSONSerialization.data(withJSONObject: document)) ?? Data()
    }
}
