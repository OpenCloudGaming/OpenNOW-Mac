//  The launch path's account-scoped disk work: `start()` defers the icon-directory scan and the
//  state reads behind collections, playtime and recently-played, and the surfaces wait on it.

import AppKit
import Foundation
import Testing
@testable import OpenNOW

/// `.serialized` because the prune lists and deletes the whole icon directory: a parallel test
/// writing its own icon file would have it deleted mid-test.
@Suite(.serialized) @MainActor struct CatalogLaunchDiskWorkTests {
    private func makeModel() -> CatalogViewModel {
        let model = makeCatalogViewModelForTesting()
        model.session.userId = "launch-disk-\(UUID().uuidString)"
        return model
    }

    private func clear(_ model: CatalogViewModel) {
        CatalogCollectionsStore(collections: []).save(accountIdentifier: model.collectionsAccountIdentifier)
    }

    private func game(id: String = "id-1", title: String = "Hades") -> OPNCatalogGameObject {
        var info = OPNGameInfo()
        info.id = id
        info.title = title
        info.variants = [OPNGameVariant(id: id, appStore: "STEAM", serviceStatus: "AVAILABLE")]
        return OPNCatalogGameObject(game: info)
    }

    @Test func startDefersTheAccountScopedStateUntilItIsAwaited() async {
        let model = makeModel()
        defer { clear(model) }
        CatalogCollectionsStore(collections: [OPNUserCollection(id: "c-1", name: "Co-op", gameIds: ["id-1"])])
            .save(accountIdentifier: model.collectionsAccountIdentifier)

        model.start()

        // `start()` has to return with the disk work still queued: an inline load would already have
        // put the stored collection in the model here, which is the main-actor scan this defers.
        #expect(!model.isAccountScopedStateLoaded)
        #expect(model.userCollections.isEmpty)

        await model.awaitAccountScopedState()

        #expect(model.isAccountScopedStateLoaded)
        #expect(model.userCollections.map(\.name) == ["Co-op"])
    }

    @Test func theDeferredWorkStillPrunesOrphanedIcons() async {
        let model = makeModel()
        let kept = UUID().uuidString.lowercased()
        let orphan = UUID().uuidString.lowercased()
        defer {
            clear(model)
            OPNCollectionIconStore.remove(assetIdentifier: kept)
            OPNCollectionIconStore.remove(assetIdentifier: orphan)
        }
        let image = NSImage(size: NSSize(width: 8, height: 8))
        #expect(OPNCollectionIconStore.storeImage(image, assetIdentifier: kept))
        #expect(OPNCollectionIconStore.storeImage(image, assetIdentifier: orphan))
        CatalogCollectionsStore(collections: [
            OPNUserCollection(id: "c-1", name: "Co-op", gameIds: ["id-1"], icon: .image(assetIdentifier: kept))
        ]).save(accountIdentifier: model.collectionsAccountIdentifier)

        model.start()
        await model.awaitAccountScopedState()

        #expect(OPNCollectionIconStore.image(for: kept) != nil)
        #expect(OPNCollectionIconStore.image(for: orphan) == nil)
    }

    /// The splash must not uncover a page whose rails are about to arrive with the deferred state.
    @Test func theSplashGateWaitsForTheDeferredAccountScopedState() async {
        let model = makeModel()
        defer { clear(model) }
        model.favoriteGames = [game()]

        model.start()

        #expect(!model.catalogSections.isEmpty)
        #expect(model.startupContentGate == nil)

        await model.awaitAccountScopedState()

        #expect(model.startupContentGate == .rails)
    }
}
