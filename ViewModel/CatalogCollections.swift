//  The reader's locally-owned collections: create, rename, delete and membership, and resolving a
//  collection's stored game identities against the catalog the app has loaded.

import Foundation

/// The collection dialog the UI is showing. Deleting asks first; create and rename ask for a name.
enum CatalogCollectionsDialog: Equatable {
    case create
    case rename(id: String)
    case delete(id: String)
}

extension CatalogViewModel {
    /// The account a collection belongs to, following favorites' catalog account and falling back
    /// to the playtime identity so an account without a user id still gets an isolated store.
    var collectionsAccountIdentifier: String {
        let identifier = catalogAccountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? Self.playtimeAccountIdentifier(account: account, session: session) : identifier
    }

    /// The collections in the order the UI lists them, case-insensitively by name.
    var sortedUserCollections: [OPNUserCollection] {
        _ = userCollections
        if let cachedSortedUserCollections { return cachedSortedUserCollections }
        let sorted = userCollections.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cachedSortedUserCollections = sorted
        return sorted
    }

    func collection(id: String) -> OPNUserCollection? {
        userCollections.first { $0.id == id }
    }

    func isInCollection(_ game: OPNCatalogGameObject, id: String) -> Bool {
        let identity = Self.identity(for: game)
        guard !identity.isEmpty else { return false }
        return collection(id: id)?.contains(identity) ?? false
    }

    func collections(containing game: OPNCatalogGameObject) -> [OPNUserCollection] {
        let identity = Self.identity(for: game)
        guard !identity.isEmpty else { return [] }
        return sortedUserCollections.filter { $0.contains(identity) }
    }

    func collectionMemberCount(_ collection: OPNUserCollection) -> Int {
        collection.gameIds.count
    }

    // MARK: - Create / rename / delete

    @discardableResult
    func createCollection(name: String) -> OPNUserCollection? {
        guard userCollections.count < OPNUserCollection.maximumCount else {
            collectionsDialogError = "You can keep at most \(OPNUserCollection.maximumCount) collections."
            return nil
        }
        let candidate = OPNUserCollection(id: UUID().uuidString.lowercased(), name: name)
        guard let validated = candidate.validated else {
            collectionsDialogError = Self.collectionNameError(name)
            return nil
        }
        userCollections.append(validated)
        persistUserCollections()
        return validated
    }

    @discardableResult
    func renameCollection(id: String, name: String) -> Bool {
        guard let index = userCollections.firstIndex(where: { $0.id == id }) else { return false }
        guard let validated = userCollections[index].renamed(name).validated else {
            collectionsDialogError = Self.collectionNameError(name)
            return false
        }
        userCollections[index] = validated
        persistUserCollections()
        return true
    }

    func deleteCollection(id: String) {
        guard userCollections.contains(where: { $0.id == id }) else { return }
        // Removing a collection removes only the collection. A game stays in My Library, My
        // Favorites and Recently Played: those are separate lists the vendor or the app owns.
        userCollections.removeAll { $0.id == id }
        persistUserCollections()
    }

    // MARK: - Membership

    func toggleMembership(collectionId: String, game: OPNCatalogGameObject) {
        let identity = Self.identity(for: game)
        guard !identity.isEmpty, let index = userCollections.firstIndex(where: { $0.id == collectionId }) else { return }
        let current = userCollections[index]
        if !current.contains(identity), current.gameIds.count >= OPNUserCollection.maximumGameCount {
            actionMessage = "That collection is full."
            return
        }
        userCollections[index] = current.toggling(identity)
        persistUserCollections()
    }

    func addGame(_ game: OPNCatalogGameObject, toCollectionId id: String) {
        let identity = Self.identity(for: game)
        guard !identity.isEmpty, let index = userCollections.firstIndex(where: { $0.id == id }), !userCollections[index].contains(identity) else { return }
        guard userCollections[index].gameIds.count < OPNUserCollection.maximumGameCount else {
            actionMessage = "That collection is full."
            return
        }
        userCollections[index] = userCollections[index].toggling(identity)
        persistUserCollections()
    }

    // MARK: - Resolution

    /// A collection's members resolved against everything the catalog knows, in stored order, plus
    /// the identities it cannot resolve so the caller can report them rather than drop them.
    func resolvedMembers(of collection: OPNUserCollection) -> (games: [OPNCatalogGameObject], missingIdentities: [String]) {
        let byIdentity = catalogGamesByIdentity
        var games: [OPNCatalogGameObject] = []
        var missing: [String] = []
        for identity in collection.gameIds {
            guard let game = byIdentity[identity] else {
                missing.append(identity)
                continue
            }
            games.append(game)
        }
        return (games, missing)
    }

    // MARK: - Presentation

    func presentCollectionsPicker() {
        guard selectedGame != nil else { return }
        isCollectionsPickerPresented = true
        revealCollectionsLocalOnlyNotice()
    }

    func dismissCollectionsPicker() {
        isCollectionsPickerPresented = false
    }

    func presentCollectionsManager() {
        isCollectionsManagerPresented = true
        revealCollectionsLocalOnlyNotice()
    }

    func dismissCollectionsManager() {
        isCollectionsManagerPresented = false
    }

    func presentCollectionsDialog(_ dialog: CatalogCollectionsDialog) {
        collectionsDialog = dialog
        collectionsDialogError = ""
        switch dialog {
        case .create:
            collectionsDraftName = ""
        case .rename(let id):
            collectionsDraftName = collection(id: id)?.name ?? ""
        case .delete:
            collectionsDraftName = ""
        }
    }

    func cancelCollectionsDialog() {
        collectionsDialog = nil
        collectionsDialogError = ""
        collectionsDraftName = ""
    }

    /// Runs whichever dialog is up against the current draft. Returns true when it closed.
    @discardableResult
    func confirmCollectionsDialog() -> Bool {
        guard let dialog = collectionsDialog else { return false }
        switch dialog {
        case .create:
            guard createCollection(name: collectionsDraftName) != nil else { return false }
        case .rename(let id):
            guard renameCollection(id: id, name: collectionsDraftName) else { return false }
        case .delete(let id):
            deleteCollection(id: id)
        }
        cancelCollectionsDialog()
        return true
    }

    /// Shows the one-time explainer the first time the reader meets collections. Only when iCloud is
    /// not carrying the catalog: a reader whose collections are already backed up has nothing to warn.
    func revealCollectionsLocalOnlyNotice() {
        guard !CatalogCollectionsStore.isLocalOnlyNoticeSeen else { return }
        guard !isCatalogBackedUpByICloud else { return }
        CatalogCollectionsStore.isLocalOnlyNoticeSeen = true
        isCollectionsNoticePresented = true
    }

    private var isCatalogBackedUpByICloud: Bool {
        OPNCloudSyncPreferences.isEnabled && OPNCloudSyncPreferences.isCategoryEnabled(.catalog)
    }

    func dismissCollectionsLocalOnlyNotice() {
        isCollectionsNoticePresented = false
    }

    // MARK: - Persistence

    func persistUserCollections() {
        CatalogCollectionsStore(collections: userCollections).save(accountIdentifier: collectionsAccountIdentifier)
    }

    static func collectionNameError(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a name for the collection." }
        if trimmed.count > OPNUserCollection.maximumNameLength { return "Names can be at most \(OPNUserCollection.maximumNameLength) characters." }
        return "That name cannot be used."
    }
}
