//  The catalog's own DLSS plumbing: which game a presentation belongs to, what a late result does
//  when the reader has already moved on, and the compact chip's presence rules.

import Foundation
import Testing
@testable import OpenNOW

@Suite struct DlssCompatibilityLookupTests {
    @MainActor @Test func aLateResultForAReplacedGameDoesNotLand() async {
        let transport = DlssGatedTransport(rows: [
            makeDlssListRow("Fortnite", ["NV, T", "", "", "", "NV, T"]),
            makeDlssListRow("Cyberpunk 2077", ["Yes", "Yes", "NV, 6X", "NV, T", "Yes"]),
        ])
        let model = makeModel(transport: transport)
        let first = makeDlssGame(id: "1", title: "Fortnite")
        let second = makeDlssGame(id: "2", title: "Cyberpunk 2077")

        model.beginDlssCompatibilityLookup(for: first)
        await transport.waitUntilRequested()
        #expect(model.dlssCompatibilityGameKey == first.catalogIdentity)

        // The reader moves to another game while the first lookup is still in flight.
        model.beginDlssCompatibilityLookup(for: second)
        transport.release()
        await model.dlssLookupTask?.value

        #expect(model.dlssCompatibilityGameKey == second.catalogIdentity)
        #expect(model.dlssCompatibility.gameSupport != nil, "the second game's own result must land")
        #expect(model.dlssCompactChip(for: first) == nil, "a presentation must not leak onto another game")
        #expect(model.dlssCompactChip(for: second)?.label == "DLSS")
    }

    @MainActor @Test func anInitialUnknownAnswerIsAnnouncedOnce() async {
        let transport = DlssGatedTransport(
            rows: [makeDlssListRow("Fortnite", ["NV, T", "", "", "", "NV, T"])],
            isReleasedImmediately: true
        )
        let scheduler = DlssVirtualScheduler()
        var posted: [String] = []
        let announcer = OPNDlssCompatibilityAnnouncer(scheduler: scheduler) { posted.append($0) }
        let model = makeModel(transport: transport, announcer: announcer)

        model.beginDlssCompatibilityLookup(for: makeDlssGame(id: "9", title: "Some Unlisted Game"))
        await model.dlssLookupTask?.value
        scheduler.advance(by: 0.2)

        // The start is cancelled by the answer arriving first; the outcome is still the answer, even
        // when that answer is "unknown".
        #expect(posted == ["DLSS compatibility unknown."])
    }

    @MainActor @Test func closingTheSurfaceLeavesTheAnnouncerSilent() async {
        let transport = DlssGatedTransport(rows: [makeDlssListRow("Fortnite", ["NV, T", "", "", "", "NV, T"])])
        let scheduler = DlssVirtualScheduler()
        var posted: [String] = []
        let announcer = OPNDlssCompatibilityAnnouncer(scheduler: scheduler) { posted.append($0) }
        let model = makeModel(transport: transport, announcer: announcer)

        model.beginDlssCompatibilityLookup(for: makeDlssGame(id: "1", title: "Fortnite"))
        await transport.waitUntilRequested()
        let lookupTask = model.dlssLookupTask
        model.endDlssCompatibilityLookup()
        transport.release()
        await lookupTask?.value
        scheduler.advance(by: 5)

        #expect(posted.isEmpty, "a queued start is cancelled, and the late result is not replayed")
    }

    @MainActor @Test func aLookupThatNeverMatchesReportsUnknownAndWearsNoChip() async {
        let transport = DlssGatedTransport(
            rows: [makeDlssListRow("Fortnite", ["NV, T", "", "", "", "NV, T"])],
            isReleasedImmediately: true
        )
        let model = makeModel(transport: transport)
        let game = makeDlssGame(id: "9", title: "Some Unlisted Game")
        model.beginDlssCompatibilityLookup(for: game)
        await model.dlssLookupTask?.value

        #expect(model.dlssCompatibility.statusText == DlssCompatibilityPresentation.unknownTitle)
        #expect(model.dlssCompactChip(for: game) == nil)
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
}

/// A catalog game with the two fields the compatibility lookup reads.
@MainActor
func makeDlssGame(id: String, title: String) -> OPNCatalogGameObject {
    var info = OPNGameInfo()
    info.id = id
    info.title = title
    return OPNCatalogGameObject(game: info)
}
