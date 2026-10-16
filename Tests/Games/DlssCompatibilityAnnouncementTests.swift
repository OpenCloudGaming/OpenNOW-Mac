//  The DLSS compatibility announcement queue: what is said, what is held back, and what a result
//  arriving at an awkward moment does to a start that is already queued.

import Foundation
import Testing
@testable import OpenNOW

@Suite struct DlssCompatibilityAnnouncementTests {
    @MainActor
    private func makeAnnouncer() -> (OPNDlssCompatibilityAnnouncer, DlssVirtualScheduler, () -> [String]) {
        let scheduler = DlssVirtualScheduler()
        var posted: [String] = []
        let announcer = OPNDlssCompatibilityAnnouncer(scheduler: scheduler) { posted.append($0) }
        return (announcer, scheduler, { posted })
    }

    @Test @MainActor func aResultBeforeTheStartDelayCancelsTheStartAndSaysOnlyTheOutcome() {
        let (announcer, scheduler, posted) = makeAnnouncer()
        announcer.beginCycle()
        announcer.handle(.initialLookupStarted)
        scheduler.advance(by: 0.3)
        #expect(posted().isEmpty)

        announcer.handle(.initialLookupSucceeded)
        scheduler.advance(by: 0.2)
        #expect(posted() == ["DLSS compatibility available."])

        scheduler.advance(by: 1)
        #expect(posted() == ["DLSS compatibility available."], "the cancelled start must never surface")
    }

    @Test @MainActor func aStartThatWasAlreadySubmittedIsFollowedByTheOutcome() {
        let (announcer, scheduler, posted) = makeAnnouncer()
        announcer.beginCycle()
        announcer.handle(.initialLookupStarted)
        scheduler.advance(by: 0.5)
        #expect(posted() == ["Checking DLSS compatibility."])

        announcer.handle(.initialLookupSucceeded)
        scheduler.advance(by: 0.2)
        #expect(posted() == ["Checking DLSS compatibility.", "DLSS compatibility available."])
    }

    @Test @MainActor func outcomesCoalesceSoABurstReadsAsOneUpdate() {
        let (announcer, scheduler, posted) = makeAnnouncer()
        announcer.beginCycle()
        announcer.handle(.initialLookupStarted)
        scheduler.advance(by: 0.5)

        announcer.handle(.refreshSucceeded)
        scheduler.advance(by: 0.1)
        announcer.handle(.refreshSucceededUnknown)
        scheduler.advance(by: 0.2)
        #expect(posted() == ["Checking DLSS compatibility.", "DLSS compatibility updated. Compatibility is unknown."])
    }

    @Test @MainActor func anIdenticalOutcomeIsNotRepeated() {
        let (announcer, scheduler, posted) = makeAnnouncer()
        announcer.beginCycle()
        announcer.handle(.initialLookupSucceeded)
        scheduler.advance(by: 0.2)
        #expect(posted().count == 1)

        // A re-render or a timestamp-only refresh resolving the same way is not a new outcome.
        announcer.handle(.initialLookupSucceeded)
        scheduler.advance(by: 1)
        #expect(posted().count == 1)
    }

    @Test @MainActor func oneStartPerCycleEvenWhenBothStartsAreOffered() {
        let (announcer, scheduler, posted) = makeAnnouncer()
        announcer.beginCycle()
        announcer.handle(.initialLookupStarted)
        announcer.handle(.refreshStarted)
        scheduler.advance(by: 1)
        #expect(posted() == ["Checking DLSS compatibility."])
    }

    @Test @MainActor func automaticRetriesStaySilentUntilTheyRecover() {
        let (announcer, scheduler, posted) = makeAnnouncer()
        announcer.beginCycle()
        announcer.handle(.initialLookupStarted, isAutomaticRetry: true)
        scheduler.advance(by: 1)
        #expect(posted().isEmpty)

        announcer.handle(.refreshFailedWithSavedData, isAutomaticRetry: true)
        scheduler.advance(by: 1)
        #expect(posted().isEmpty)

        announcer.handle(.refreshSucceeded, isAutomaticRetry: true)
        scheduler.advance(by: 0.2)
        #expect(posted() == ["DLSS compatibility updated."])

        // Recovery is announced once, not on every subsequent silent retry.
        announcer.handle(.refreshSucceeded, isAutomaticRetry: true)
        scheduler.advance(by: 1)
        #expect(posted().count == 1)
    }

    @Test @MainActor func aSilentAutomaticRetryIsNotARecoveryOnItsOwn() {
        let (announcer, scheduler, posted) = makeAnnouncer()
        announcer.beginCycle()
        announcer.handle(.refreshSucceeded, isAutomaticRetry: true)
        scheduler.advance(by: 1)
        #expect(posted().isEmpty, "nothing was ever said for this cycle, so there is no recovery to describe")
    }

    @Test @MainActor func anExplicitRetryStartsANewSequence() {
        let (announcer, scheduler, posted) = makeAnnouncer()
        announcer.beginCycle()
        announcer.handle(.initialLookupStarted)
        scheduler.advance(by: 0.5)
        announcer.handle(.lookupFailedWithoutSavedData)
        scheduler.advance(by: 0.2)
        #expect(posted() == ["Checking DLSS compatibility.", "DLSS compatibility information unavailable."])

        announcer.beginCycle()
        announcer.handle(.initialLookupStarted)
        scheduler.advance(by: 0.5)
        announcer.handle(.initialLookupSucceeded)
        scheduler.advance(by: 0.2)
        #expect(posted().suffix(2) == ["Checking DLSS compatibility.", "DLSS compatibility available."])
    }

    @Test @MainActor func leavingTheSurfaceCancelsEverythingAndNothingIsReplayed() {
        let (announcer, scheduler, posted) = makeAnnouncer()
        announcer.beginCycle()
        announcer.handle(.initialLookupStarted)
        announcer.handle(.refreshStarted)
        announcer.endCycle()
        scheduler.advance(by: 5)
        #expect(posted().isEmpty)

        // A result that arrives after the cycle ended is ignored rather than spoken on return.
        announcer.handle(.refreshSucceeded)
        scheduler.advance(by: 1)
        #expect(posted().isEmpty)
    }

    @Test @MainActor func theRefreshFailureAnnouncementUsesTheExactCopy() {
        let (announcer, scheduler, posted) = makeAnnouncer()
        announcer.beginCycle()
        announcer.handle(.refreshStarted)
        scheduler.advance(by: 0.5)
        announcer.handle(.refreshFailedWithSavedData)
        scheduler.advance(by: 0.2)
        #expect(posted() == [
            "Updating DLSS compatibility. Showing saved information.",
            "Couldn't update DLSS compatibility. Showing saved information.",
        ])
    }
}

/// A scheduler the test drives by hand: nothing fires until `advance(by:)` passes its due time.
@MainActor
final class DlssVirtualScheduler: DlssAnnouncementScheduling {
    private struct Item {
        let id: Int
        let due: TimeInterval
        let action: @MainActor () -> Void
    }

    private var now: TimeInterval = 0
    private var items: [Item] = []
    private var cancelled: Set<Int> = []
    private var nextID = 0

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> DlssAnnouncementTicket {
        let id = nextID
        nextID += 1
        items.append(Item(id: id, due: now + delay, action: action))
        return DlssAnnouncementTicket { [weak self] in
            self?.cancelled.insert(id)
        }
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
        while true {
            let due = items.filter { !cancelled.contains($0.id) && $0.due <= now }.min { $0.due < $1.due }
            guard let due else { return }
            items.removeAll { $0.id == due.id }
            due.action()
        }
    }
}
