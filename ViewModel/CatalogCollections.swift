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

    /// Whether the account already holds the most collections it may keep, so every "new collection"
    /// affordance can disable itself instead of failing after the name is typed.
    var isAtCollectionLimit: Bool {
        userCollections.count >= OPNUserCollection.maximumCount
    }

    @discardableResult
    func createCollection(name: String, icon: OPNCollectionIcon? = nil) -> OPNUserCollection? {
        guard userCollections.count < OPNUserCollection.maximumCount else {
            collectionsDialogError = "You can keep at most \(OPNUserCollection.maximumCount) collections."
            return nil
        }
        let candidate = OPNUserCollection(id: UUID().uuidString.lowercased(), name: name, icon: icon, updatedAt: Date())
        guard let validated = candidate.validated else {
            collectionsDialogError = Self.collectionNameError(name)
            return nil
        }
        userCollections.append(validated)
        persistUserCollections()
        return validated
    }

    @discardableResult
    func renameCollection(id: String, name: String, icon: OPNCollectionIcon? = nil) -> Bool {
        guard let index = userCollections.firstIndex(where: { $0.id == id }) else { return false }
        let retainedIcon = icon ?? userCollections[index].icon
        guard let validated = userCollections[index].renamed(name).withIcon(retainedIcon).stamped(at: Date()).validated else {
            collectionsDialogError = Self.collectionNameError(name)
            return false
        }
        userCollections[index] = validated
        persistUserCollections()
        return true
    }

    /// Sets or clears one collection's icon. Clearing stores nil, which draws the catalog default.
    @discardableResult
    func setCollectionIcon(_ icon: OPNCollectionIcon?, collectionId: String) -> Bool {
        guard let index = userCollections.firstIndex(where: { $0.id == collectionId }) else { return false }
        guard let validated = userCollections[index].withIcon(icon).stamped(at: Date()).validated else { return false }
        userCollections[index] = validated
        persistUserCollections()
        return true
    }

    /// The glyph a collection draws, resolved to the catalog default when it has none.
    func icon(for collection: OPNUserCollection) -> OPNCollectionIcon {
        collection.resolvedIcon
    }

    func deleteCollection(id: String) {
        guard let index = userCollections.firstIndex(where: { $0.id == id }) else { return }
        // Removing a collection removes only the collection; a game stays in My Library, My
        // Favorites and Recently Played. The tombstone stops another Mac re-adding the collection.
        let removed = userCollections.remove(at: index)
        persistUserCollections(addingTombstone: removed.deleting(at: Date()))
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
        userCollections[index] = current.toggling(identity).stamped(at: Date())
        persistUserCollections()
    }

    func addGame(_ game: OPNCatalogGameObject, toCollectionId id: String) {
        let identity = Self.identity(for: game)
        guard !identity.isEmpty, let index = userCollections.firstIndex(where: { $0.id == id }), !userCollections[index].contains(identity) else { return }
        guard userCollections[index].gameIds.count < OPNUserCollection.maximumGameCount else {
            actionMessage = "That collection is full."
            return
        }
        userCollections[index] = userCollections[index].toggling(identity).stamped(at: Date())
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

    func presentCollectionsIconPicker() {
        collectionsIconPickerBaseline = collectionsDraftIcon
        isCollectionsIconPickerPresented = true
    }

    /// Closes the picker keeping the chosen glyph. The dialog's own SAVE still decides whether it is
    /// stored, so DONE is a preview confirmation, not a write.
    func dismissCollectionsIconPicker() {
        isCollectionsIconPickerPresented = false
    }

    /// Closes the picker and restores the dialog's icon to what it was when the picker opened.
    func cancelCollectionsIconPicker() {
        collectionsDraftIcon = collectionsIconPickerBaseline
        isCollectionsIconPickerPresented = false
    }

    /// Sets the open dialog's icon draft from a built-in symbol or a cleared choice.
    func setCollectionsDraftIcon(_ icon: OPNCollectionIcon?) {
        collectionsDraftIcon = icon?.validated
        collectionsDialogError = ""
    }

    /// Imports a reader-chosen image into the icon store and returns the icon that points at it, or
    /// nil when the file cannot be decoded or is kept out by the size limits. The image is stored
    /// immediately; a cancelled dialog leaves an orphan the next prune removes.
    func storeCollectionIconImage(from url: URL) -> OPNCollectionIcon? {
        let identifier = UUID().uuidString.lowercased()
        guard OPNCollectionIconStore.storeImage(from: url, assetIdentifier: identifier) else { return nil }
        return .image(assetIdentifier: identifier)
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
            collectionsDraftIcon = nil
        case .rename(let id):
            collectionsDraftName = collection(id: id)?.name ?? ""
            collectionsDraftIcon = collection(id: id)?.icon
        case .delete:
            collectionsDraftName = ""
            collectionsDraftIcon = nil
        }
    }

    func cancelCollectionsDialog() {
        collectionsDialog = nil
        collectionsDialogError = ""
        collectionsDraftName = ""
        collectionsDraftIcon = nil
    }

    /// Runs whichever dialog is up against the current draft. Returns true when it closed.
    @discardableResult
    func confirmCollectionsDialog() -> Bool {
        guard let dialog = collectionsDialog else { return false }
        switch dialog {
        case .create:
            guard createCollection(name: collectionsDraftName, icon: collectionsDraftIcon) != nil else { return false }
        case .rename(let id):
            guard renameCollection(id: id, name: collectionsDraftName, icon: collectionsDraftIcon) else { return false }
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

    /// Whether any collections surface is up. These panels never take keyboard focus, so the view
    /// installs an Escape monitor only while one of them is on screen.
    var hasPresentedCollectionsOverlay: Bool {
        isCollectionsIconPickerPresented
            || isCollectionsNoticePresented
            || collectionsDialog != nil
            || isCollectionsManagerPresented
            || isCollectionsPickerPresented
    }

    /// Closes the topmost collections surface, in the z-order the catalog draws them, and reports
    /// whether one was up. Escape routes here: `onExitCommand` fires only for the focused view, and
    /// none of these panels ever takes focus, so the manager sat unresponsive to the key.
    @discardableResult
    func dismissTopmostCollectionsOverlay() -> Bool {
        if isCollectionsIconPickerPresented {
            cancelCollectionsIconPicker()
            return true
        }
        if isCollectionsNoticePresented {
            dismissCollectionsLocalOnlyNotice()
            return true
        }
        if collectionsDialog != nil {
            cancelCollectionsDialog()
            return true
        }
        if isCollectionsManagerPresented {
            dismissCollectionsManager()
            return true
        }
        if isCollectionsPickerPresented {
            dismissCollectionsPicker()
            return true
        }
        return false
    }

    // MARK: - Persistence

    func persistUserCollections() {
        persistUserCollections(addingTombstone: nil)
    }

    /// Writes the live collections and the account's tombstones together, so a live edit never drops
    /// a pending deletion. `addingTombstone` records a deletion in the same write.
    func persistUserCollections(addingTombstone tombstone: OPNUserCollection?) {
        let account = collectionsAccountIdentifier
        var tombstones = CatalogCollectionsStore.load(accountIdentifier: account).tombstones
        if let tombstone {
            tombstones.removeAll { $0.id == tombstone.id }
            tombstones.append(tombstone)
        }
        CatalogCollectionsStore(collections: userCollections, tombstones: tombstones).save(accountIdentifier: account)
        pruneOrphanedCollectionIcons()
    }

    /// Drops custom icon files no collection names any more, so deleting a collection also deletes
    /// the image behind its icon instead of leaving it on disk forever.
    func pruneOrphanedCollectionIcons() {
        let liveAssets = Set(userCollections.compactMap { collection -> String? in
            guard let icon = collection.icon?.validated, icon.kind == .image else { return nil }
            return icon.value
        })
        OPNCollectionIconStore.removeOrphans(keeping: liveAssets)
    }

    /// iCloud sync writes the collections store directly from a background actor, so without a nudge
    /// this model keeps showing the collections it read at launch. Reload only the account on screen,
    /// and only when the store actually differs: a local edit posts the same notification, and the
    /// equality guard keeps its own write from re-entering and invalidating the derived caches twice.
    func observeCollectionsStoreChanges() {
        guard deinitHandle.collectionsStoreObserver == nil else { return }
        deinitHandle.collectionsStoreObserver = NotificationCenter.default.addObserver(
            forName: CatalogCollectionsStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let changedAccount = notification.userInfo?[CatalogCollectionsStore.accountIdentifierKey] as? String
            MainActor.assumeIsolated {
                self?.reloadCollectionsAfterExternalWrite(accountIdentifier: changedAccount)
            }
        }
    }

    private func reloadCollectionsAfterExternalWrite(accountIdentifier: String?) {
        guard let accountIdentifier,
              accountIdentifier.caseInsensitiveCompare(collectionsAccountIdentifier) == .orderedSame else { return }
        let stored = CatalogCollectionsStore.load(accountIdentifier: accountIdentifier).collections
        guard stored != userCollections else { return }
        userCollections = stored
    }

    static func collectionNameError(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a name for the collection." }
        if trimmed.count > OPNUserCollection.maximumNameLength { return "Names can be at most \(OPNUserCollection.maximumNameLength) characters." }
        return "That name cannot be used."
    }
}
