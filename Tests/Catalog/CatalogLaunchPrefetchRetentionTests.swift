//  When the launch prefetch may drop the catalog graphs it retains for the home page. The
//  sequencing is the whole risk: release too early and a deferred `loadLibrary()` /
//  `loadFavorites()` attach finds nothing and re-requests what is already in flight, or a fetch
//  that has not landed yet is dropped before the view model ever sees it.
//

import Testing
@testable import OpenNOW

@Suite struct CatalogLaunchPrefetchRetentionTests {
    @Test func aSettledHandoverIsOnlyReleasableOnceTheCatalogHasAdoptedIt() {
        var retention = CatalogLaunchPrefetchRetention()
        retention.noteDeliveriesStarted(6)
        for _ in 0..<6 { retention.noteDeliveryFinished() }
        #expect(retention.canReleaseRetainedGraphs == false)

        retention.noteCatalogAdoptedLaunchResults()
        #expect(retention.canReleaseRetainedGraphs)
    }

    @Test func aDeliveryStillInFlightBlocksTheRelease() {
        var retention = CatalogLaunchPrefetchRetention()
        retention.noteDeliveriesStarted(4)
        retention.noteCatalogAdoptedLaunchResults()
        for _ in 0..<3 { retention.noteDeliveryFinished() }
        #expect(retention.canReleaseRetainedGraphs == false)

        retention.noteDeliveryFinished()
        #expect(retention.canReleaseRetainedGraphs)
    }

    @Test func adoptionBeforeTheLastDeliveryStillReleasesAtThatDelivery() {
        var retention = CatalogLaunchPrefetchRetention()
        retention.noteDeliveriesStarted(2)
        retention.noteCatalogAdoptedLaunchResults()
        retention.noteDeliveryFinished()
        #expect(retention.canReleaseRetainedGraphs == false)

        retention.noteDeliveryFinished()
        #expect(retention.canReleaseRetainedGraphs)
    }

    @Test func deliveriesStartedAfterAdoptionStillHoldTheRelease() {
        var retention = CatalogLaunchPrefetchRetention()
        retention.noteCatalogAdoptedLaunchResults()
        #expect(retention.canReleaseRetainedGraphs)

        retention.noteDeliveriesStarted(2)
        #expect(retention.canReleaseRetainedGraphs == false)

        retention.noteDeliveryFinished()
        retention.noteDeliveryFinished()
        #expect(retention.canReleaseRetainedGraphs)
    }

    @Test func aFinishedHandoverStopsThePrefetchHandingAnythingOver() {
        var retention = CatalogLaunchPrefetchRetention()
        retention.noteCatalogAdoptedLaunchResults()
        retention.noteHandoverFinished()

        #expect(retention.didFinishHandover)
        #expect(retention.canReleaseRetainedGraphs == false)
    }

    @Test func aFinishedHandoverCannotBeReopenedByALateDeliveryOrAdoption() {
        var retention = CatalogLaunchPrefetchRetention()
        retention.noteHandoverFinished()
        retention.noteDeliveriesStarted(4)
        for _ in 0..<4 { retention.noteDeliveryFinished() }
        retention.noteCatalogAdoptedLaunchResults()

        #expect(retention.didFinishHandover)
        #expect(retention.canReleaseRetainedGraphs == false)
    }

    @Test func aDeliveryCountedWithoutAStartCannotUnsettleTheHandover() {
        var retention = CatalogLaunchPrefetchRetention()
        retention.noteDeliveryFinished()
        retention.noteCatalogAdoptedLaunchResults()

        #expect(retention.canReleaseRetainedGraphs)
    }
}

/// The launch prefetch is a process-wide singleton, so the explicit-refresh path is exercised on
/// the shared instance: `CatalogViewModel.refresh()` invalidates it and then expects every load to
/// go to the network.
@Suite(.serialized) @MainActor struct CatalogLaunchPrefetchHandoverTests {
    @Test func anInvalidatedPrefetchHandsNothingOver() {
        let prefetch = CatalogLaunchPrefetch.shared
        prefetch.invalidate()

        let attachment = prefetch.attach(accountIdentifier: "account") { _ in }

        #expect(attachment.isEmpty)
    }
}
