import Testing
import Foundation
@testable import OpenNOW

/// User-defined collections: local persistence, membership, the local Show All path, and the home
/// rails they contribute.
@Suite @MainActor struct CatalogCollectionsTests {
    private func makeModel() -> CatalogViewModel {
        let model = makeCatalogViewModelForTesting()
        model.session.userId = "collections-\(UUID().uuidString)"
        return model
    }

    private func clear(_ model: CatalogViewModel) {
        CatalogCollectionsStore(collections: []).save(accountIdentifier: model.collectionsAccountIdentifier)
    }

    private func gameInfo(id: String, title: String, launchAppId: String = "") -> OPNGameInfo {
        var info = OPNGameInfo()
        info.id = id
        info.title = title
        info.launchAppId = launchAppId.isEmpty ? id : launchAppId
        info.variants = [OPNGameVariant(id: info.launchAppId, appStore: "STEAM", serviceStatus: "AVAILABLE", isPatching: false)]
        return info
    }

    private func game(id: String = "id-1", title: String = "Hades") -> OPNCatalogGameObject {
        OPNCatalogGameObject(game: gameInfo(id: id, title: title))
    }

    @Test func editsToACollectionSurviveReload() {
        let model = makeModel()
        defer { clear(model) }

        guard let created = model.createCollection(name: "Co-op with Sam") else {
            Issue.record("collection should be created")
            return
        }
        #expect(model.userCollections.map(\.name) == ["Co-op with Sam"])
        #expect(model.renameCollection(id: created.id, name: "Finished this year"))
        #expect(CatalogCollectionsStore.load(accountIdentifier: model.collectionsAccountIdentifier).collections.map(\.name) == ["Finished this year"])

        model.deleteCollection(id: created.id)
        #expect(model.userCollections.isEmpty)
        #expect(CatalogCollectionsStore.load(accountIdentifier: model.collectionsAccountIdentifier).collections.isEmpty)
    }

    @Test func blankNamesAreRefused() {
        let model = makeModel()
        defer { clear(model) }

        #expect(model.createCollection(name: "   ") == nil)
        #expect(model.userCollections.isEmpty)
        #expect(!model.collectionsDialogError.isEmpty)
    }

    @Test func collectionsAreScopedToTheirAccount() {
        let owner = makeModel()
        let other = makeModel()
        defer {
            clear(owner)
            clear(other)
        }

        owner.createCollection(name: "Owner only")

        #expect(owner.collectionsAccountIdentifier != other.collectionsAccountIdentifier)
        #expect(owner.userCollections.count == 1)
        #expect(other.userCollections.isEmpty)
    }

    @Test func togglingMembershipFlipsWithoutDuplicates() {
        let model = makeModel()
        defer { clear(model) }
        let hades = game()
        guard let collection = model.createCollection(name: "Co-op") else { return }

        model.toggleMembership(collectionId: collection.id, game: hades)
        #expect(model.isInCollection(hades, id: collection.id))
        #expect(model.collections(containing: hades).count == 1)
        #expect(model.collection(id: collection.id)?.gameIds == ["id-1"])

        model.toggleMembership(collectionId: collection.id, game: hades)
        #expect(!model.isInCollection(hades, id: collection.id))
        #expect(model.collection(id: collection.id)?.gameIds.isEmpty == true)
    }

    @Test func deletingACollectionLeavesOtherGameListsAlone() {
        let model = makeModel()
        defer { clear(model) }
        let hades = game()
        model.catalogGames = [hades]
        model.libraryGames = [hades]
        model.favoriteGames = [hades]
        model.recentlyPlayed.record(title: "Hades", appId: "id-1", store: "steam", playedAt: Date())
        guard let collection = model.createCollection(name: "Co-op") else { return }
        model.toggleMembership(collectionId: collection.id, game: hades)

        model.deleteCollection(id: collection.id)

        #expect(model.libraryGames.map(\.title) == ["Hades"])
        #expect(model.favoriteGames.map(\.title) == ["Hades"])
        #expect(model.recentlyPlayed.games.map(\.title) == ["Hades"])
    }

    @Test func aCollectionRailAppearsAfterTheFixedRails() {
        let model = makeModel()
        defer { clear(model) }
        let hades = game()
        model.catalogGames = [hades]
        model.favoriteGames = [hades]
        model.libraryGames = [hades]
        guard let collection = model.createCollection(name: "Co-op") else { return }
        model.toggleMembership(collectionId: collection.id, game: hades)

        let sections = model.catalogSections
        let railID = OPNHomeCustomization.userCollectionRailID(collection.id)
        guard let collectionIndex = sections.firstIndex(where: { $0.id == railID }),
              let libraryIndex = sections.firstIndex(where: { $0.id == OPNHomeCustomization.libraryRailID }) else {
            Issue.record("collection and library rails should both be present")
            return
        }

        #expect(sections[collectionIndex].kind == .userCollection(id: collection.id))
        #expect(sections[collectionIndex].games.map(\.title) == ["Hades"])
        #expect(collectionIndex > libraryIndex)
    }

    @Test func anEmptyCollectionDoesNotDrawABrokenRail() {
        let model = makeModel()
        defer { clear(model) }
        model.catalogGames = [game()]
        guard let collection = model.createCollection(name: "Empty") else { return }

        #expect(!model.catalogSections.contains { $0.id == OPNHomeCustomization.userCollectionRailID(collection.id) })
    }

    @Test func openingACollectionFiltersLocallyWithoutBrowsingTheServer() {
        let model = makeModel()
        defer { clear(model) }
        let hades = game()
        model.catalogGames = [hades]
        guard let collection = model.createCollection(name: "Co-op") else { return }
        model.toggleMembership(collectionId: collection.id, game: hades)
        let generation = model.browseGeneration

        model.openUserCollection(id: collection.id)

        #expect(model.isShowingLocalCollection)
        #expect(model.displayedShowAllGames.map(\.title) == ["Hades"])
        #expect(model.selectedShowAllSection?.kind == .userCollection(id: collection.id))
        #expect(model.browseGeneration == generation, "a local collection must never seed a server browse")
        #expect(model.isLoading == false)
    }

    @Test func showAllOnACollectionSectionDoesNotBrowse() {
        let model = makeModel()
        defer { clear(model) }
        let hades = game()
        model.catalogGames = [hades]
        guard let collection = model.createCollection(name: "Co-op") else { return }
        model.toggleMembership(collectionId: collection.id, game: hades)
        let section = CatalogSectionModel(
            id: OPNHomeCustomization.userCollectionRailID(collection.id),
            title: collection.name,
            games: [hades],
            kind: .userCollection(id: collection.id)
        )
        let generation = model.browseGeneration

        model.openShowAll(section)

        #expect(model.isShowingLocalCollection)
        #expect(model.displayedShowAllGames.map(\.title) == ["Hades"])
        #expect(model.browseGeneration == generation)
    }

    @Test func membersTheCatalogDoesNotCarryAreCountedNotDropped() {
        let model = makeModel()
        defer { clear(model) }
        let known = game(id: "id-1", title: "Known")
        model.catalogGames = [known]
        guard let collection = model.createCollection(name: "Mixed") else { return }
        model.toggleMembership(collectionId: collection.id, game: known)
        model.addGame(game(id: "id-ghost", title: "Ghost"), toCollectionId: collection.id)

        let resolved = model.resolvedMembers(of: model.collection(id: collection.id) ?? collection)
        #expect(resolved.games.map(\.title) == ["Known"])
        #expect(resolved.missingIdentities == ["id-ghost"])

        model.openUserCollection(id: collection.id)
        #expect(model.localShowAllUnavailableCount == 1)
    }

    @Test func aNewEmptyCollectionAppearsInTheHomeCategoryListAndLeavesOnDelete() {
        let model = makeModel()
        defer { clear(model) }
        guard let collection = model.createCollection(name: "Empty") else { return }
        let railID = OPNHomeCustomization.userCollectionRailID(collection.id)

        #expect(model.homeRailRows.contains { $0.id == railID && $0.title == "Empty" && $0.isVisible })

        model.deleteCollection(id: collection.id)
        #expect(!model.homeRailRows.contains { $0.id == railID })
    }

    @Test func emptyCollectionRailsStayInNameOrderAsCollectionsChange() {
        OPNHomeCustomization.arrangement = .default
        defer { OPNHomeCustomization.arrangement = .default }
        let model = makeModel()
        defer { clear(model) }
        for name in ["Tree", "Bar", "Second Bla", "Bla Update"] {
            model.createCollection(name: name)
        }
        let railTitles = {
            model.homeRailRows
                .filter { $0.id.hasPrefix("user-collection-") }
                .map(\.title)
        }
        #expect(railTitles() == ["Bar", "Bla Update", "Second Bla", "Tree"])

        model.createCollection(name: "Apple")
        #expect(railTitles() == ["Apple", "Bar", "Bla Update", "Second Bla", "Tree"])

        model.setHomeRailVisible(OPNHomeCustomization.userCollectionRailID(model.sortedUserCollections[0].id), isVisible: false)
        #expect(railTitles() == ["Apple", "Bar", "Bla Update", "Second Bla", "Tree"])
    }
}
