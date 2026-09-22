import AppKit
import Foundation
import Testing
@testable import OpenNOW

/// The collection icon value: validation, legacy decoding, and the icon store's round trip.
@Suite struct CollectionIconModelTests {
    @Test func symbolIconsValidateTheirNames() {
        #expect(OPNCollectionIcon.symbol("gamecontroller.fill").validated == .symbol("gamecontroller.fill"))
        #expect(OPNCollectionIcon.symbol("  heart.fill  ").validated == .symbol("heart.fill"))
        #expect(OPNCollectionIcon.symbol("   ").validated == nil)
        #expect(OPNCollectionIcon.symbol(String(repeating: "a", count: OPNCollectionIcon.maximumSymbolNameLength + 1)).validated == nil)
    }

    @Test func imageIconsRequireALowercaseUuidShape() {
        let identifier = UUID().uuidString.lowercased()
        #expect(OPNCollectionIcon.image(assetIdentifier: identifier).validated == .image(assetIdentifier: identifier))
        #expect(OPNCollectionIcon.image(assetIdentifier: "../../etc/passwd").validated == nil)
        #expect(OPNCollectionIcon.image(assetIdentifier: "").validated == nil)
    }

    @Test func collectionsWithoutAnIconDecodeToTheDefault() throws {
        let json = Data(#"[{"id":"c","name":"Co-op","gameIds":["g1"]}]"#.utf8)
        let decoded = try JSONDecoder().decode([OPNUserCollection].self, from: json)
        #expect(decoded.first?.icon == nil)
        #expect(decoded.first?.resolvedIcon == .fallback)
    }

    @Test func anIconSurvivesACodableRoundTrip() throws {
        let collection = OPNUserCollection(id: "c", name: "Co-op", gameIds: ["g1"], icon: .symbol("gamecontroller.fill"))
        let data = try JSONEncoder().encode([collection])
        let decoded = try JSONDecoder().decode([OPNUserCollection].self, from: data)
        #expect(decoded == [collection])
    }

    @Test func anInvalidStoredIconFallsBackWithoutDroppingTheCollection() {
        let collection = OPNUserCollection(id: "c", name: "Co-op", icon: .symbol("   "))
        let validated = collection.validated
        #expect(validated != nil)
        #expect(validated?.icon == nil)
        #expect(validated?.resolvedIcon == .fallback)
    }

    @Test func customImagesRoundTripThroughTheStore() {
        let identifier = UUID().uuidString.lowercased()
        defer { OPNCollectionIconStore.remove(assetIdentifier: identifier) }

        let image = NSImage(size: NSSize(width: 40, height: 20))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 20).fill()
        image.unlockFocus()

        #expect(OPNCollectionIconStore.storeImage(image, assetIdentifier: identifier))
        #expect(OPNCollectionIconStore.image(for: identifier) != nil)

        OPNCollectionIconStore.remove(assetIdentifier: identifier)
        #expect(OPNCollectionIconStore.image(for: identifier) == nil)
    }

    @Test func theOrphanPruneKeepsOnlyNamedAssets() {
        let kept = UUID().uuidString.lowercased()
        let orphan = UUID().uuidString.lowercased()
        defer {
            OPNCollectionIconStore.remove(assetIdentifier: kept)
            OPNCollectionIconStore.remove(assetIdentifier: orphan)
        }
        let image = NSImage(size: NSSize(width: 8, height: 8))
        #expect(OPNCollectionIconStore.storeImage(image, assetIdentifier: kept))
        #expect(OPNCollectionIconStore.storeImage(image, assetIdentifier: orphan))

        OPNCollectionIconStore.removeOrphans(keeping: [kept])

        #expect(OPNCollectionIconStore.image(for: kept) != nil)
        #expect(OPNCollectionIconStore.image(for: orphan) == nil)
    }

    @Test func iconStoreWritesAndRemovalsAnnounceTheChange() {
        let identifier = UUID().uuidString.lowercased()
        defer { OPNCollectionIconStore.remove(assetIdentifier: identifier) }

        let recorder = IconStoreChangeRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: OPNCollectionIconStore.didChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            // Only this test's asset: the observer sees every store write in the process and the
            // suite's tests run in parallel, so an unfiltered recorder is a race.
            guard notification.userInfo?[OPNCollectionIconStore.assetIdentifierKey] as? String == identifier else { return }
            recorder.count += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let image = NSImage(size: NSSize(width: 8, height: 8))
        #expect(OPNCollectionIconStore.storeImage(image, assetIdentifier: identifier))
        #expect(recorder.count == 1)

        OPNCollectionIconStore.remove(assetIdentifier: identifier)
        #expect(recorder.count == 2)

        // Removing an icon that is already gone is not a change.
        OPNCollectionIconStore.remove(assetIdentifier: identifier)
        #expect(recorder.count == 2)
    }
}

private final class IconStoreChangeRecorder: @unchecked Sendable {
    var count = 0
}

/// The symbol catalog the picker searches: categories and the two query shapes. The assertions hold
/// whether the bundled resource loads or the inline fallback stands in.
@Suite struct CollectionSymbolCatalogTests {
    @Test func categoriesAndSymbolsArePresent() {
        #expect(!OPNCollectionSymbolCatalog.categories.isEmpty)
        #expect(!OPNCollectionSymbolCatalog.symbols.isEmpty)
        #expect(!OPNCollectionSymbolCatalog.symbols(in: OPNCollectionSymbolCatalog.allCategoryID).isEmpty)
    }

    @Test func popularIsACuratedNonEmptySpread() {
        #expect(!OPNCollectionSymbolCatalog.popular.isEmpty)
        #expect(OPNCollectionSymbolCatalog.symbols(in: OPNCollectionSymbolCatalog.popularCategoryID) == OPNCollectionSymbolCatalog.popular)
    }

    @Test func searchingByANameTokenFindsTheSymbol() {
        let matches = OPNCollectionSymbolCatalog.search("gamecontroller", categoryID: OPNCollectionSymbolCatalog.allCategoryID)
        #expect(matches.contains { $0.name == "gamecontroller.fill" })
    }

    @Test func searchingIsScopedToTheCategory() {
        let gaming = OPNCollectionSymbolCatalog.search("heart", categoryID: "gaming")
        let all = OPNCollectionSymbolCatalog.search("heart", categoryID: OPNCollectionSymbolCatalog.allCategoryID)
        #expect(all.contains { $0.name == "heart.fill" })
        #expect(!gaming.contains { $0.name == "heart.fill" })
    }

    @Test func aQueryWithNoMatchesIsEmpty() {
        #expect(OPNCollectionSymbolCatalog.search("zzzznotasymbol", categoryID: OPNCollectionSymbolCatalog.allCategoryID).isEmpty)
    }
}

/// The collections view model's icon plumbing: create, rename and explicit set all persist.
@Suite @MainActor struct CollectionIconViewModelTests {
    private func makeModel() -> CatalogViewModel {
        let model = makeCatalogViewModelForTesting()
        model.session.userId = "icons-\(UUID().uuidString)"
        return model
    }

    private func clear(_ model: CatalogViewModel) {
        CatalogCollectionsStore(collections: []).save(accountIdentifier: model.collectionsAccountIdentifier)
    }

    @Test func creatingARenameAndExplicitIconAllPersist() {
        let model = makeModel()
        defer { clear(model) }

        guard let created = model.createCollection(name: "Co-op", icon: .symbol("gamecontroller.fill")) else {
            Issue.record("collection should be created")
            return
        }
        #expect(created.icon == .symbol("gamecontroller.fill"))

        #expect(model.renameCollection(id: created.id, name: "Co-op nights"))
        #expect(model.collection(id: created.id)?.icon == .symbol("gamecontroller.fill"))

        #expect(model.setCollectionIcon(.symbol("car.fill"), collectionId: created.id))
        let reloaded = CatalogCollectionsStore.load(accountIdentifier: model.collectionsAccountIdentifier)
        #expect(reloaded.collections.first?.icon == .symbol("car.fill"))
    }

    @Test func renamingWithoutAnIconArgumentRetainsTheExistingOne() {
        let model = makeModel()
        defer { clear(model) }
        guard let created = model.createCollection(name: "Co-op", icon: .symbol("bolt.fill")) else { return }

        #expect(model.renameCollection(id: created.id, name: "Renamed"))
        #expect(model.collection(id: created.id)?.icon == .symbol("bolt.fill"))
    }

    @Test func clearingAnIconStoresTheDefault() {
        let model = makeModel()
        defer { clear(model) }
        guard let created = model.createCollection(name: "Co-op", icon: .symbol("bolt.fill")) else { return }

        #expect(model.setCollectionIcon(nil, collectionId: created.id))
        #expect(model.collection(id: created.id)?.icon == nil)
        #expect(model.collection(id: created.id)?.resolvedIcon == .fallback)
    }
}
