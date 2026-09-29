//  The maintenance watch store: add / remove / cap / persistence / corrupt-data tolerance / change
//  notification, and the pure edge detection the poll drives.

import Foundation
import Testing
@testable import OpenNOW

@Suite(.serialized) @MainActor struct CatalogMaintenanceWatchStoreTests {
    private func clearStore() {
        OPNAppPreferenceStorage.syncStore.removeObject(forKey: CatalogMaintenanceWatchStore.storageKey)
    }

    private func makeWatch(_ identity: String, title: String = "Game") -> CatalogMaintenanceWatch {
        CatalogMaintenanceWatch(
            identity: identity,
            appId: "app-\(identity)",
            title: title,
            startedAt: Date(timeIntervalSince1970: 0),
            observedAvailability: .maintenance,
            lastNotifiedEdge: nil
        )
    }

    @Test func addingAndRemovingRoundTripsThroughStorage() {
        clearStore()
        defer { clearStore() }

        let added = CatalogMaintenanceWatchStore.empty.adding(identity: "steam:1", appId: "app-1", title: "Hades", availability: .maintenance)
        #expect(added.added)
        #expect(added.store.isWatching("steam:1"))
        added.store.save()

        let loaded = CatalogMaintenanceWatchStore.load()
        #expect(loaded.isWatching("steam:1"))
        #expect(loaded.watch(for: "steam:1")?.title == "Hades")
        #expect(loaded.watch(for: "steam:1")?.appId == "app-1")
        #expect(loaded.watch(for: "steam:1")?.observedAvailability == .maintenance)

        let removed = loaded.removing(identity: "steam:1")
        removed.save()
        #expect(CatalogMaintenanceWatchStore.load().watches.isEmpty)
    }

    @Test func anEmptyStoreClearsTheStoredKey() {
        clearStore()
        defer { clearStore() }

        CatalogMaintenanceWatchStore.empty.adding(identity: "a", appId: "a", title: "A", availability: .maintenance).store.save()
        #expect(OPNAppPreferenceStorage.syncStore.object(forKey: CatalogMaintenanceWatchStore.storageKey) != nil)

        CatalogMaintenanceWatchStore.load().removingAll().save()
        #expect(OPNAppPreferenceStorage.syncStore.object(forKey: CatalogMaintenanceWatchStore.storageKey) == nil)
    }

    @Test func theCapIsEnforcedAndStated() {
        var store = CatalogMaintenanceWatchStore.empty
        for index in 0..<CatalogMaintenanceWatchStore.maximumCount {
            let result = store.adding(identity: "id-\(index)", appId: "app-\(index)", title: "Game \(index)", availability: .maintenance)
            #expect(result.added)
            store = result.store
        }
        #expect(store.isAtCapacity)
        #expect(store.watches.count == CatalogMaintenanceWatchStore.maximumCount)

        // The one past the cap is refused rather than silently dropping another watch the reader
        // chose. The count is what the UI states; this asserts the cap matches it.
        let refused = store.adding(identity: "one-more", appId: "app", title: "One More", availability: .maintenance)
        #expect(refused.added == false)
        #expect(refused.store.watches.count == CatalogMaintenanceWatchStore.maximumCount)
    }

    @Test func addingTheSameTitleTwiceIsRefused() {
        let first = CatalogMaintenanceWatchStore.empty.adding(identity: "same", appId: "a", title: "A", availability: .maintenance)
        let second = first.store.adding(identity: "same", appId: "a", title: "A", availability: .maintenance)
        #expect(second.added == false)
        #expect(second.store.watches.count == 1)
    }

    @Test func loadingCorruptDataYieldsAnEmptyStore() {
        clearStore()
        defer { clearStore() }

        OPNAppPreferenceStorage.syncStore.set(Data("not json".utf8), forKey: CatalogMaintenanceWatchStore.storageKey)
        #expect(CatalogMaintenanceWatchStore.load().watches.isEmpty)
    }

    @Test func oneMalformedRecordDoesNotDiscardTheRest() {
        clearStore()
        defer { clearStore() }

        let json = """
        [{"identity":"good","appId":"app","title":"Good","startedAt":0,"observedAvailability":"maintenance"},
         {"nope":true},
         {"identity":"good2","appId":"app2","title":"Good 2","startedAt":0,"observedAvailability":"maintenance","lastNotifiedEdge":"available"}]
        """
        OPNAppPreferenceStorage.syncStore.set(Data(json.utf8), forKey: CatalogMaintenanceWatchStore.storageKey)

        let loaded = CatalogMaintenanceWatchStore.load()
        #expect(loaded.watches.map(\.identity) == ["good", "good2"])
        #expect(loaded.watch(for: "good2")?.lastNotifiedEdge == .available)
    }

    @Test func theWatchListNeverTravelsThroughICloud() {
        // A watch is a promise only a running app can keep, so it stays on the Mac that made it.
        #expect(OPNCloudSyncSettingsRegistry.isSyncable(CatalogMaintenanceWatchStore.storageKey) == false)
    }

    @Test func savingPostsTheChangeNotification() {
        clearStore()
        defer { clearStore() }

        let fired = NotificationFlag()
        let observer = NotificationCenter.default.addObserver(forName: CatalogMaintenanceWatchStore.didChangeNotification, object: nil, queue: nil) { _ in fired.value = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        CatalogMaintenanceWatchStore.empty.adding(identity: "notify", appId: "a", title: "A", availability: .maintenance).store.save()
        #expect(fired.value)
    }

    // MARK: - Edge detection

    @Test func maintenanceEndingIntoPatchingIsOneEdge() {
        let store = CatalogMaintenanceWatchStore(watches: [makeWatch("g")])
        let result = store.advancing(availabilityByIdentity: ["g": .patching])
        #expect(result.events.map(\.edge) == [.patching])
        #expect(result.store.watch(for: "g")?.lastNotifiedEdge == .patching)
        #expect(result.store.watch(for: "g")?.observedAvailability == .patching)
    }

    @Test func patchingFinishingIsASecondDistinctEdgeAndEndsTheWatch() {
        let first = CatalogMaintenanceWatchStore(watches: [makeWatch("g")]).advancing(availabilityByIdentity: ["g": .patching])
        let second = first.store.advancing(availabilityByIdentity: ["g": .available])
        #expect(second.events.map(\.edge) == [.available])
        // The promise is kept, so the watch is done: it stops counting toward the badge.
        #expect(second.store.watches.isEmpty)
    }

    @Test func maintenanceGoingStraightToAvailableFiresTheReadyEdgeAndClearsTheWatch() {
        let result = CatalogMaintenanceWatchStore(watches: [makeWatch("g")]).advancing(availabilityByIdentity: ["g": .available])
        #expect(result.events.map(\.edge) == [.available])
        #expect(result.store.watches.isEmpty)
    }

    @Test func aFlappingStatusDoesNotDuplicateThePatchingEdge() {
        let first = CatalogMaintenanceWatchStore(watches: [makeWatch("g")]).advancing(availabilityByIdentity: ["g": .patching])
        #expect(first.events.count == 1)
        let back = first.store.advancing(availabilityByIdentity: ["g": .maintenance])
        #expect(back.events.isEmpty)
        let again = back.store.advancing(availabilityByIdentity: ["g": .patching])
        #expect(again.events.isEmpty, "the same edge is announced once per watch")
        #expect(again.store.isWatching("g"))
    }

    @Test func aFreshWatchCanFireAgain() {
        let first = CatalogMaintenanceWatchStore(watches: [makeWatch("g")]).advancing(availabilityByIdentity: ["g": .available])
        #expect(first.events.count == 1)
        #expect(first.store.watches.isEmpty)
        // Re-watching after the title went down again is a new watch with no notified edge.
        let rewatched = CatalogMaintenanceWatchStore.empty.adding(identity: "g", appId: "app-g", title: "Game", availability: .maintenance).store
        let second = rewatched.advancing(availabilityByIdentity: ["g": .available])
        #expect(second.events.count == 1)
    }

    @Test func aTitleWithNoNewObservationIsLeftAlone() {
        let result = CatalogMaintenanceWatchStore(watches: [makeWatch("g")]).advancing(availabilityByIdentity: [:])
        #expect(result.events.isEmpty)
        #expect(result.store.watch(for: "g")?.observedAvailability == .maintenance)
    }

    @Test func threeReturningTitlesProduceOneEventEach() {
        let watches = ["a", "b", "c"].map { makeWatch($0) }
        let result = CatalogMaintenanceWatchStore(watches: watches).advancing(availabilityByIdentity: ["a": .available, "b": .available, "c": .available])
        #expect(result.events.count == 3)
        // All three are ready events: the announcer collapses them into one attention request.
        #expect(Set(result.events.map(\.edge)) == [.available])
        #expect(result.store.watches.isEmpty)
    }
}

/// A notification flag the observer's `@Sendable` closure can set without tripping the concurrency
/// checker on a captured local.
private final class NotificationFlag: @unchecked Sendable {
    var value = false
}
