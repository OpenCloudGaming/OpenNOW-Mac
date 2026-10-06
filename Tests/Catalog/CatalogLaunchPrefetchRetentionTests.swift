//  When the launch prefetch may drop the catalog graphs it retains for the home page. Releasing
//  too early strands a rail: a deferred attach finds nothing, or a fetch is dropped unseen.
//

import Testing
@testable import OpenNOW

@Suite struct CatalogLaunchPrefetchRetentionTests {
    @Test func theGraphsStayUntilTheCatalogHasAdoptedTheLaunchResults() {
        var retention = CatalogLaunchPrefetchRetention<String>()
        let keys = ["marquee", "main", "favorites", "library", "collection", "recent"]
        retention.recordDeliveriesStarted(keys)
        for key in keys { retention.recordDeliveryFinished(key) }
        #expect(retention.isReadyToReleaseRetainedGraphs == false)

        retention.recordLaunchResultsAdopted()
        #expect(retention.isReadyToReleaseRetainedGraphs)
    }

    @Test func theGraphsStayWhileADeliveryIsStillInFlight() {
        var retention = CatalogLaunchPrefetchRetention<String>()
        retention.recordDeliveriesStarted(["marquee", "main", "favorites", "library"])
        retention.recordLaunchResultsAdopted()
        for key in ["marquee", "main", "favorites"] { retention.recordDeliveryFinished(key) }
        #expect(retention.isReadyToReleaseRetainedGraphs == false)

        retention.recordDeliveryFinished("library")
        #expect(retention.isReadyToReleaseRetainedGraphs)
    }

    @Test func theGraphsGoAtTheLastDeliveryWhenAdoptionCameFirst() {
        var retention = CatalogLaunchPrefetchRetention<String>()
        retention.recordDeliveriesStarted(["marquee", "main"])
        retention.recordLaunchResultsAdopted()
        retention.recordDeliveryFinished("marquee")
        #expect(retention.isReadyToReleaseRetainedGraphs == false)

        retention.recordDeliveryFinished("main")
        #expect(retention.isReadyToReleaseRetainedGraphs)
    }

    @Test func theGraphsStayWhenADeliveryStartsAfterAdoption() {
        var retention = CatalogLaunchPrefetchRetention<String>()
        retention.recordLaunchResultsAdopted()
        #expect(retention.isReadyToReleaseRetainedGraphs)

        retention.recordDeliveriesStarted(["marquee", "main"])
        #expect(retention.isReadyToReleaseRetainedGraphs == false)

        retention.recordDeliveryFinished("marquee")
        retention.recordDeliveryFinished("main")
        #expect(retention.isReadyToReleaseRetainedGraphs)
    }

    @Test func aFinishedHandoverStaysFinished() {
        var retention = CatalogLaunchPrefetchRetention<String>()
        retention.recordHandoverFinished()
        #expect(retention.isReadyToReleaseRetainedGraphs == false)

        retention.recordDeliveriesStarted(["marquee", "main", "favorites", "library"])
        for key in ["marquee", "main", "favorites", "library"] { retention.recordDeliveryFinished(key) }
        retention.recordLaunchResultsAdopted()
        #expect(retention.isReadyToReleaseRetainedGraphs == false)
    }

    @Test func aDeliveryThatNeverStartedDoesNotKeepTheGraphs() {
        var retention = CatalogLaunchPrefetchRetention<String>()
        retention.recordDeliveryFinished("marquee")
        retention.recordLaunchResultsAdopted()
        #expect(retention.isReadyToReleaseRetainedGraphs)
    }

    @Test func aRedeliveredKindDoesNotSpendAnotherKindsBudget() {
        var retention = CatalogLaunchPrefetchRetention<String>()
        retention.recordDeliveriesStarted(["marquee", "main", "favorites", "library"])
        retention.recordLaunchResultsAdopted()
        // The panel pipeline redelivers each panel once metadata enrichment completes.
        for key in ["marquee", "main", "marquee", "main"] { retention.recordDeliveryFinished(key) }
        #expect(retention.isReadyToReleaseRetainedGraphs == false)

        retention.recordDeliveryFinished("favorites")
        #expect(retention.isReadyToReleaseRetainedGraphs == false)

        retention.recordDeliveryFinished("library")
        #expect(retention.isReadyToReleaseRetainedGraphs)
    }
}

/// The launch prefetch is a process-wide singleton, so the explicit-refresh path is exercised on
/// the shared instance: `CatalogViewModel.refresh()` invalidates it and then loads from the network.
@Suite(.serialized) @MainActor struct CatalogLaunchPrefetchHandoverTests {
    @Test func anInvalidatedPrefetchHandsNothingOver() {
        let prefetch = CatalogLaunchPrefetch.shared
        prefetch.invalidate()

        let attachment = prefetch.attach(accountIdentifier: "account") { _ in }

        #expect(attachment.isEmpty)
    }
}
