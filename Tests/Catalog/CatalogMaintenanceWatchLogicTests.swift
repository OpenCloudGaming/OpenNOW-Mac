//  The maintenance watch's announcement surface: the copy each edge carries, the one-request
//  arbitration, and the view model's opt-in wiring.

import AppKit
import Foundation
import Testing
@testable import OpenNOW

private func watch(_ identity: String, title: String) -> CatalogMaintenanceWatch {
    CatalogMaintenanceWatch(
        identity: identity,
        appId: "app-\(identity)",
        title: title,
        startedAt: Date(timeIntervalSince1970: 0),
        observedAvailability: .maintenance,
        lastNotifiedEdge: nil
    )
}

private func maintenanceGame(id: String, title: String) -> OPNCatalogGameObject {
    var variant = OPNGameVariant(id: "\(id)-v", appStore: "STEAM")
    variant.catalogStatus = "SERVER_MAINTENANCE"
    variant.catalogStateDetailsSubType = "GFN_DEVELOPER_MAINTENANCE"
    var info = OPNGameInfo()
    info.id = id
    info.title = title
    info.variants = [variant]
    return OPNCatalogGameObject(game: info)
}

@Test @MainActor func theTwoEdgesCarryDistinctCopy() {
    let patching = CatalogMaintenanceWatchEvent(watch: watch("g", title: "Hades"), edge: .patching)
    let available = CatalogMaintenanceWatchEvent(watch: watch("g", title: "Hades"), edge: .available)

    #expect(OPNMaintenanceWatchAction.notificationTitle(patching) == "Hades is now patching")
    #expect(OPNMaintenanceWatchAction.notificationTitle(available) == "Hades is ready to play")
    #expect(OPNMaintenanceWatchAction.notificationBody(patching) != OPNMaintenanceWatchAction.notificationBody(available))
    #expect(OPNMaintenanceWatchAction.inAppMessage(patching).contains("patching"))
    #expect(OPNMaintenanceWatchAction.inAppMessage(available).contains("ready to play"))
    // The vendor publishes no maintenance ETA, so no copy may imply a schedule.
    for message in [OPNMaintenanceWatchAction.inAppMessage(patching), OPNMaintenanceWatchAction.inAppMessage(available)] {
        #expect(!message.localizedCaseInsensitiveContains("schedule"))
        #expect(!message.localizedCaseInsensitiveContains("at "))
    }
}

@Test @MainActor func attentionIsOnlyRequestedWhenTheAppIsNotFrontmost() {
    #expect(OPNMaintenanceWatchAction.shouldRequestAttention(isActive: false))
    #expect(OPNMaintenanceWatchAction.shouldRequestAttention(isActive: true) == false)
}

@Test func theAttentionArbiterHoldsOneRequestAtATime() {
    var arbiter = OPNMaintenanceWatchAttentionArbiter()
    #expect(arbiter.replace(with: 1) == nil, "the first request supersedes nothing")
    #expect(arbiter.heldRequestId == 1)
    // Three titles returning together request three times, and each supersedes the last, so only one
    // request is ever live — the other two are handed back to be cancelled.
    #expect(arbiter.replace(with: 2) == 1)
    #expect(arbiter.replace(with: 3) == 2)
    #expect(arbiter.heldRequestId == 3)
    #expect(arbiter.clear() == 3)
    #expect(arbiter.heldRequestId == nil)
    #expect(arbiter.clear() == nil, "clearing twice cancels nothing the second time")
}

@Suite(.serialized) @MainActor struct CatalogMaintenanceWatchViewModelTests {
    private func clearStore() {
        OPNAppPreferenceStorage.syncStore.removeObject(forKey: CatalogMaintenanceWatchStore.storageKey)
    }

    /// The poll task is the only part of the wiring that reaches the network, and this test does not
    /// exercise it: cancelling it in the same main-actor turn stops it ever running.
    private func stopPoll(_ model: CatalogViewModel) {
        model.deinitHandle.patchingPollTask?.cancel()
        model.deinitHandle.patchingPollTask = nil
    }

    @Test func optingInPersistsAndOptingOutStopsImmediately() {
        clearStore()
        defer { clearStore() }

        let model = makeCatalogViewModelForTesting()
        let game = maintenanceGame(id: "hades", title: "Hades")
        model.catalogGames = [game]

        model.toggleMaintenanceWatch(for: game)
        stopPoll(model)

        #expect(model.isWatching(game))
        #expect(model.watchedTitleCount == 1)
        #expect(CatalogMaintenanceWatchStore.load().isWatching("hades"))

        model.removeMaintenanceWatch(identity: "hades")
        stopPoll(model)

        #expect(model.isWatching(game) == false)
        #expect(model.watchedTitleCount == 0)
        #expect(model.maintenanceWatches.isEmpty)
        #expect(CatalogMaintenanceWatchStore.load().watches.isEmpty)
    }

    @Test func watchedTitlesJoinOneMergedPollWithoutDuplicates() {
        clearStore()
        defer { clearStore() }

        var store = CatalogMaintenanceWatchStore.empty
        store = store.adding(identity: "a", appId: "app-1", title: "A", availability: .maintenance).store
        store = store.adding(identity: "b", appId: "app-2", title: "B", availability: .maintenance).store
        store.save()

        let model = makeCatalogViewModelForTesting()
        model.loadMaintenanceWatches()
        stopPoll(model)

        // Two watched titles widen the one poll set; they do not add a second fetch path.
        #expect(model.patchingPollAppIds() == ["app-1", "app-2"])
        #expect(Set(model.patchingPollAppIds()).count == model.patchingPollAppIds().count)
    }

    @Test func anUnrecoverableSessionStopsTheWatchAndSaysSo() {
        clearStore()
        defer { clearStore() }

        let model = makeCatalogViewModelForTesting()
        let game = maintenanceGame(id: "hades", title: "Hades")
        model.catalogGames = [game]
        model.toggleMaintenanceWatch(for: game)
        stopPoll(model)
        #expect(model.watchedTitleCount == 1)

        model.stopMaintenanceWatchesForUnrecoverableAuth()
        stopPoll(model)

        #expect(model.watchedTitleCount == 0)
        #expect(model.maintenanceWatches.isEmpty)
        #expect(model.errorMessage.localizedCaseInsensitiveContains("stopped watching"))
    }

    @Test func theControlIsOfferedForMaintenanceOnly() {
        let model = makeCatalogViewModelForTesting()
        var available = OPNGameVariant(id: "v", appStore: "STEAM")
        available.catalogStatus = "AVAILABLE"
        var info = OPNGameInfo()
        info.id = "free"
        info.variants = [available]
        let playable = OPNCatalogGameObject(game: info)

        model.toggleMaintenanceWatch(for: playable)
        stopPoll(model)

        #expect(model.isWatching(playable) == false, "a playable title carries no promise to watch")
    }
}
