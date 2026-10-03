//  When the launch prefetch may drop the catalog graphs it retains for the home page. Releasing
//  too early strands a rail: a deferred attach finds nothing, or a fetch is dropped unseen.
//

import Testing
@testable import OpenNOW

@Suite struct CatalogLaunchPrefetchRetentionTests {
    @Test func theGraphsStayUntilTheCatalogHasAdoptedTheLaunchResults() {
        var retention = CatalogLaunchPrefetchRetention()
        retention.recordDeliveriesStarted(6)
        for _ in 0..<6 { retention.recordDeliveryFinished() }
        #expect(retention.isReadyToReleaseRetainedGraphs == false)

        retention.recordLaunchResultsAdopted()
        #expect(retention.isReadyToReleaseRetainedGraphs)
    }

    @Test func theGraphsStayWhileADeliveryIsStillInFlight() {
        var retention = CatalogLaunchPrefetchRetention()
        retention.recordDeliveriesStarted(4)
        retention.recordLaunchResultsAdopted()
        for _ in 0..<3 { retention.recordDeliveryFinished() }
        #expect(retention.isReadyToReleaseRetainedGraphs == false)

        retention.recordDeliveryFinished()
        #expect(retention.isReadyToReleaseRetainedGraphs)
    }

    @Test func theGraphsGoAtTheLastDeliveryWhenAdoptionCameFirst() {
        var retention = CatalogLaunchPrefetchRetention()
        retention.recordDeliveriesStarted(2)
        retention.recordLaunchResultsAdopted()
        retention.recordDeliveryFinished()
        #expect(retention.isReadyToReleaseRetainedGraphs == false)

        retention.recordDeliveryFinished()
        #expect(retention.isReadyToReleaseRetainedGraphs)
    }

    @Test func theGraphsStayWhenADeliveryStartsAfterAdoption() {
        var retention = CatalogLaunchPrefetchRetention()
        retention.recordLaunchResultsAdopted()
        #expect(retention.isReadyToReleaseRetainedGraphs)

        retention.recordDeliveriesStarted(2)
        #expect(retention.isReadyToReleaseRetainedGraphs == false)

        retention.recordDeliveryFinished()
        retention.recordDeliveryFinished()
        #expect(retention.isReadyToReleaseRetainedGraphs)
    }

    @Test func aFinishedHandoverStaysFinished() {
        var retention = CatalogLaunchPrefetchRetention()
        retention.recordHandoverFinished()
        #expect(retention.isReadyToReleaseRetainedGraphs == false)

        retention.recordDeliveriesStarted(4)
        for _ in 0..<4 { retention.recordDeliveryFinished() }
        retention.recordLaunchResultsAdopted()
        #expect(retention.isReadyToReleaseRetainedGraphs == false)
    }

    @Test func aDeliveryThatNeverStartedDoesNotKeepTheGraphs() {
        var retention = CatalogLaunchPrefetchRetention()
        retention.recordDeliveryFinished()
        retention.recordLaunchResultsAdopted()
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
