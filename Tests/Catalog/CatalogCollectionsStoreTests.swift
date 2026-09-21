import Foundation
import Testing
@testable import OpenNOW

/// The locally-owned collections: their storage keying, validation bounds, and the lenient load
/// that keeps a corrupt payload from taking the rest of the account's collections with it.
struct CatalogCollectionsStoreTests {
    private func account(_ label: String) -> String {
        "collections-\(label)-\(UUID().uuidString)"
    }

    private func clear(_ identifiers: String...) {
        for identifier in identifiers {
            CatalogCollectionsStore(collections: []).save(accountIdentifier: identifier)
        }
    }

    @Test func collectionsRoundTripPerAccount() {
        let owner = account("owner")
        let other = account("other")
        defer { clear(owner, other) }

        let collections = [
            OPNUserCollection(id: "coop", name: "Co-op with Sam", gameIds: ["game-1", "game-2"]),
            OPNUserCollection(id: "finished", name: "Finished this year", gameIds: ["game-3"]),
        ]
        CatalogCollectionsStore(collections: collections).save(accountIdentifier: owner)

        #expect(CatalogCollectionsStore.load(accountIdentifier: owner).collections == collections)
        #expect(CatalogCollectionsStore.load(accountIdentifier: other).collections.isEmpty)
        #expect(CatalogCollectionsStore.load(accountIdentifier: "").collections.isEmpty)
    }

    @Test func anEmptyListClearsTheStoredCollections() {
        let owner = account("empty")
        defer { clear(owner) }

        CatalogCollectionsStore(collections: [OPNUserCollection(id: "x", name: "X")]).save(accountIdentifier: owner)
        #expect(!CatalogCollectionsStore.load(accountIdentifier: owner).collections.isEmpty)

        CatalogCollectionsStore(collections: []).save(accountIdentifier: owner)
        #expect(CatalogCollectionsStore.load(accountIdentifier: owner).collections.isEmpty)
    }

    @Test func namesAreTrimmedWhileBlankNamesAreDropped() {
        let store = CatalogCollectionsStore(collections: [
            OPNUserCollection(id: "keep", name: "  Co-op  "),
            OPNUserCollection(id: "blank", name: "   "),
        ])

        #expect(store.collections == [OPNUserCollection(id: "keep", name: "Co-op")])
    }

    @Test func malformedPersistedEntriesAreDroppedWithoutLosingTheRest() {
        let owner = account("malformed")
        defer { clear(owner) }
        let json = """
        [
          {"id": "good", "name": "Good", "gameIds": ["g1"]},
          {"id": "bad-missing-name", "gameIds": ["g2"]},
          {"id": "also-good", "name": "Also Good", "gameIds": ["g3", "g3"]}
        ]
        """
        OPNAppPreferenceStorage.standard.set(Data(json.utf8), forKey: CatalogCollectionsStore.storageKey(accountIdentifier: owner))

        let loaded = CatalogCollectionsStore.load(accountIdentifier: owner).collections
        #expect(loaded.map(\.id) == ["good", "also-good"])
        #expect(loaded.last?.gameIds == ["g3"])
    }

    @Test func aNonArrayPayloadLoadsAsEmpty() {
        let owner = account("corrupt")
        defer { clear(owner) }
        OPNAppPreferenceStorage.standard.set(Data("{\"not\":\"a list\"}".utf8), forKey: CatalogCollectionsStore.storageKey(accountIdentifier: owner))

        #expect(CatalogCollectionsStore.load(accountIdentifier: owner).collections.isEmpty)
    }

    @Test func countsAreCappedAtTheirLimits() {
        let members = (0..<(OPNUserCollection.maximumGameCount + 5)).map { "game-\($0)" }
        let capped = CatalogCollectionsStore(collections: [OPNUserCollection(id: "big", name: "Big", gameIds: members)])
        #expect(capped.collections.first?.gameIds.count == OPNUserCollection.maximumGameCount)

        let many = (0..<(OPNUserCollection.maximumCount + 5)).map { OPNUserCollection(id: "c\($0)", name: "C\($0)") }
        #expect(CatalogCollectionsStore(collections: many).collections.count == OPNUserCollection.maximumCount)
    }

    @Test func duplicateIdentifiersKeepTheFirstCollection() {
        let store = CatalogCollectionsStore(collections: [
            OPNUserCollection(id: "same", name: "First", gameIds: ["a"]),
            OPNUserCollection(id: "same", name: "Second", gameIds: ["b"]),
        ])

        #expect(store.collections == [OPNUserCollection(id: "same", name: "First", gameIds: ["a"])])
    }

    @Test func togglingMembershipFlipsMembershipOnce() {
        let collection = OPNUserCollection(id: "c", name: "C")

        let added = collection.toggling("game-1")
        #expect(added.gameIds == ["game-1"])
        #expect(added.toggling("game-1").gameIds.isEmpty)
    }
}
