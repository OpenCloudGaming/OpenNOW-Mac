//  Which store a game plays from and whether the account owns it there: the store picker,
//  favourites, shortcuts, ownership marking and account linking.
//

import Foundation
import Observation

extension CatalogViewModel {
    func openStoreForSelectedVariant() {
        guard let selectedGame else { return }
        let variantIndex = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: selectedGame)
        guard variantIndex >= 0, variantIndex < selectedGame.variants.count else { return }
        let variant = selectedGame.variants[variantIndex]
        if let url = URL(string: variant.storeUrl), !variant.storeUrl.isEmpty {
            systemIntegration.open(url)
            return
        }
        gameService.resolveStoreURL(game: selectedGame.swiftValue, variantIndex: variantIndex) { [weak self] success, storeURL, error in
            guard let self else { return }
            guard success, let url = URL(string: storeURL), !storeURL.isEmpty else {
                self.errorMessage = error.isEmpty ? "No store URL is available for this game." : error
                return
            }
            systemIntegration.open(url)
        }
    }

    func shareSelectedGame() {
        guard let selectedGame else { return }
        let title = selectedGame.title.isEmpty ? "GeForce NOW game" : selectedGame.title
        let url = selectedGame.primaryStoreURL ?? URL(string: "https://play.geforcenow.com/")
        systemIntegration.copyToPasteboard([title, url?.absoluteString].compactMap { $0 }.joined(separator: "\n"))
        actionMessage = "Copied share details."
    }

    func isFavorite(_ game: OPNCatalogGameObject) -> Bool {
        game.isFavorited || favoriteGameIdentities.contains(Self.identity(for: game))
    }

    func toggleFavoriteSelectedGame() {
        guard let selectedGame else { return }
        let appId = Self.favoriteAppId(for: selectedGame)
        let identity = Self.identity(for: selectedGame)
        guard !appId.isEmpty, !identity.isEmpty else { return }
        let previousGames = favoriteGames
        let previousIdentities = favoriteGameIdentities
        if isFavorite(selectedGame) {
            favoriteGameIdentities.remove(identity)
            favoriteGames.removeAll { Self.identity(for: $0) == identity }
            updateGameFavoriteState(identity: identity, isFavorited: false)
            actionMessage = "Removing from favorites..."
            gameService.removeFavoriteApp(appId) { [weak self] success, error in
                guard let self else { return }
                if success {
                    self.actionMessage = "Removed from favorites."
                    self.reloadFavoritesAfterChange()
                    self.refreshShowAllIfFavoritesFiltered()
                } else {
                    self.favoriteGames = previousGames
                    self.favoriteGameIdentities = previousIdentities
                    self.updateGameFavoriteState(identity: identity, isFavorited: true)
                    if self.refreshAuthIfNeeded(error: error) { return }
                    self.errorMessage = error.isEmpty ? "Unable to remove this game from favorites." : error
                }
            }
        } else {
            favoriteGameIdentities.insert(identity)
            updateGameFavoriteState(identity: identity, isFavorited: true)
            let favoriteSnapshot = Self.snapshotObject(for: selectedGame)
            favoriteSnapshot.isFavorited = true
            favoriteGames.insert(favoriteSnapshot, at: 0)
            actionMessage = "Adding to favorites..."
            gameService.addFavoriteApp(appId) { [weak self] success, error in
                guard let self else { return }
                if success {
                    self.actionMessage = "Added to favorites."
                    self.reloadFavoritesAfterChange()
                    self.refreshShowAllIfFavoritesFiltered()
                } else {
                    self.favoriteGames = previousGames
                    self.favoriteGameIdentities = previousIdentities
                    self.updateGameFavoriteState(identity: identity, isFavorited: false)
                    if self.refreshAuthIfNeeded(error: error) { return }
                    self.errorMessage = error.isEmpty ? "Unable to add this game to favorites." : error
                }
            }
        }
    }

    /// The Show All grid is a server browse, so a favorite that was just added/removed only leaves
    /// the grid after a fresh browse. Cached pages would otherwise keep showing the stale set.
    func refreshShowAllIfFavoritesFiltered() {
        guard selectedShowAllSection != nil,
              selectedFilterIds.contains(OPNGameService.favoritesCatalogFilterId) else { return }
        browseCatalog(forceRefresh: true)
    }

    func changeSelectedGameStore() {
        guard let selectedGame, selectedGame.variants.count > 1 else {
            actionMessage = "No alternate store is available."
            return
        }
        presentedModal = .storePicker(stage: .storeSelection)
        ownershipFlowMessage = ""
    }

    func closeStorePicker() {
        guard isStorePickerVisible else { return }
        presentedModal = nil
        ownershipFlowMessage = ""
    }

    /// Moves the store picker to its next stage. A stage only exists while the picker is the
    /// presented modal, so this cannot reopen a picker the user has dismissed - which is what the
    /// old `if stage != .hidden` guards at every call site were trying to say.
    func advanceOwnershipFlow(to stage: CatalogOwnershipFlowStage) {
        guard isStorePickerVisible else { return }
        presentedModal = .storePicker(stage: stage)
    }

    func selectGameStoreVariant(at index: Int) {
        guard let selectedGame, index >= 0, index < selectedGame.variants.count else { return }
        focusGameStoreVariant(at: index)
        guard let option = platformOptions(for: selectedGame).first(where: { $0.variantIndex == index }) else { return }
        if option.isOwned {
            let variant = selectedGame.variants[index]
            selectOwnedVariant(variant)
            advanceOwnershipFlow(to: .success)
            ownershipFlowMessage = ""
        } else if option.hasAccess {
            advanceOwnershipFlow(to: .success)
            ownershipFlowMessage = ""
        } else if isStorePickerVisible {
            advanceOwnershipFlow(to: .manualMark)
            ownershipFlowMessage = ""
        }
        actionMessage = "Changed store to \(option.title)."
    }

    func focusGameStoreVariant(at index: Int) {
        guard let selectedGame, index >= 0, index < selectedGame.variants.count else { return }
        selectedVariantIndex = index
    }

    func cycleSelectedGameStore() {
        guard let selectedGame, selectedGame.variants.count > 1 else {
            actionMessage = "No alternate store is available."
            return
        }
        let currentIndex = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: selectedGame)
        let nextIndex = (max(currentIndex, 0) + 1) % selectedGame.variants.count
        selectGameStoreVariant(at: nextIndex)
    }

    func addShortcutForSelectedGame() {
        guard let selectedGame else { return }
        let title = selectedGame.title.isEmpty ? "Cloud Game" : selectedGame.title
        do {
            let desktopURL = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let shortcutURL = desktopURL.appendingPathComponent(Self.safeShortcutFilename(title))
            let variantIndex = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: selectedGame)
            let variant = variantIndex >= 0 && variantIndex < selectedGame.variants.count ? selectedGame.variants[variantIndex] : nil
            let cmsId = Self.shortcutCMSId(for: selectedGame, variant: variant)
            let shortName = !selectedGame.shortName.isEmpty ? selectedGame.shortName : (!selectedGame.uuid.isEmpty ? selectedGame.uuid : selectedGame.id)
            guard !cmsId.isEmpty || !shortName.isEmpty else {
                errorMessage = "No GeForce NOW identifier is available for this game."
                return
            }
            let shortcut = GFNGameShortcut(sourceURL: nil, displayName: title, cmsId: cmsId, shortName: shortName, parentGameId: shortName)
            try shortcut.write(to: shortcutURL)
            systemIntegration.applyAppIcon(toFileAt: shortcutURL)
            actionMessage = "Added OpenNOW shortcut to Desktop."
        } catch {
            errorMessage = "Unable to add shortcut: \(error.localizedDescription)"
        }
    }

    func markSelectedVariantOwned() {
        beginMarkSelectedVariantOwnedFlow()
    }

    func handleUnownedSelectedVariantPrimaryAction() {
        guard let selectedGame else { return }
        if selectedGame.isFreeToPlay {
            autoMarkFreeToPlaySelectedVariantThenLaunch()
        } else {
            markSelectedVariantOwned()
        }
    }

    func autoMarkFreeToPlaySelectedVariantThenLaunch() {
        guard let selectedGame, let variant = selectedVariant(in: selectedGame), !variant.id.isEmpty else { return }
        let gameIdentity = Self.identity(for: selectedGame)
        let variantId = variant.id
        let variantIndex = selectedVariantIndex
        let title = selectedGame.title.isEmpty ? "game" : selectedGame.title
        setActionMessage("Adding free-to-play \(title) to library...")
        gameService.addOwnedVariant(variantId) { [weak self] success, error in
            guard let self else { return }
            if success {
                self.updateSelectedGameOwnership(gameIdentity: gameIdentity, variantId: variantId, inLibrary: true)
                self.actionMessage = "Added to library. Launching \(title)..."
                self.refreshCatalogAfterOwnershipChange()
                if let game = self.selectedGame {
                    self.launch(game: game, variantIndex: variantIndex)
                }
            } else {
                if self.refreshAuthIfNeeded(error: error) { return }
                self.errorMessage = error.isEmpty ? "Unable to add this free-to-play game to your library." : error
                self.markSelectedVariantOwned()
            }
        }
    }

    func beginMarkSelectedVariantOwnedFlow() {
        guard let selectedGame, selectedVariant(in: selectedGame) != nil else { return }
        presentedModal = .storePicker(stage: .resyncing)
        ownershipFlowMessage = syncingOwnershipMessage(for: selectedGame)
        let stores = CatalogAccountParsing.uniqueNonEmpty(selectedGame.variants.map(\.appStore))
        let syncableStores = stores.filter { accountStatus(forStore: $0)?.hasAccountSyncingData == true }
        guard let store = syncableStores.first else {
            advanceOwnershipFlow(to: .storeSelection)
            ownershipFlowMessage = ""
            return
        }
        gameService.syncAccountProvider(store: store) { [weak self] _, _ in
            guard let self, self.ownershipFlowStage == .resyncing else { return }
            self.loadAccountAndStores()
            self.loadLibrary()
            self.browseCatalog()
            self.advanceOwnershipFlow(to: .storeSelection)
            self.ownershipFlowMessage = ""
        }
    }

    func stopOwnershipResync() {
        advanceOwnershipFlow(to: .storeSelection)
        ownershipFlowMessage = ""
    }

    func confirmSelectedVariantOwned() {
        guard let selectedGame, let variant = selectedVariant(in: selectedGame), !variant.id.isEmpty else { return }
        let gameIdentity = Self.identity(for: selectedGame)
        let variantId = variant.id
        let title = selectedGame.title.isEmpty ? "game" : selectedGame.title
        setActionMessage("Adding \(title) to library...")
        gameService.addOwnedVariant(variantId) { [weak self] success, error in
            guard let self else { return }
            if success {
                self.updateSelectedGameOwnership(gameIdentity: gameIdentity, variantId: variantId, inLibrary: true)
                self.advanceOwnershipFlow(to: .success)
                self.ownershipFlowMessage = ""
                self.actionMessage = "Added to library."
                self.refreshCatalogAfterOwnershipChange()
            } else {
                self.errorMessage = error.isEmpty ? "Unable to add this game to your library." : error
            }
        }
    }

    func finishOwnershipFlow() {
        closeStorePicker()
    }

    func removeSelectedVariantOwned() {
        guard let selectedGame, let variant = selectedVariant(in: selectedGame), !variant.id.isEmpty else { return }
        let gameIdentity = Self.identity(for: selectedGame)
        let variantId = variant.id
        let title = selectedGame.title.isEmpty ? "game" : selectedGame.title
        setActionMessage("Removing \(title) from library...")
        gameService.removeOwnedVariant(variantId) { [weak self] success, error in
            guard let self else { return }
            if success {
                self.updateSelectedGameOwnership(gameIdentity: gameIdentity, variantId: variantId, inLibrary: false)
                self.actionMessage = "Removed from library."
                self.refreshCatalogAfterOwnershipChange()
            } else {
                self.errorMessage = error.isEmpty ? "Unable to remove this game from your library." : error
            }
        }
    }

    func selectOwnedVariant(_ variant: OPNCatalogGameVariantObject) {
        guard !variant.id.isEmpty else { return }
        let variantId = variant.id
        gameService.selectOwnedVariant(variantId) { [weak self] success, error in
            guard let self else { return }
            if success {
                self.selectedGame?.variants.forEach { $0.librarySelected = $0.id == variantId }
                self.actionMessage = "Store selection updated."
                self.refreshCatalogAfterOwnershipChange()
            } else {
                self.errorMessage = error.isEmpty ? "Unable to update store selection." : error
            }
        }
    }

    func syncSelectedStoreAccount() {
        guard let store = selectedPlatformOption(in: selectedGame)?.accountStore, !store.isEmpty else { return }
        syncStoreAccount(store)
    }

    func syncStoreAccount(_ store: String) {
        guard !store.isEmpty else { return }
        setActionMessage("Syncing \(displayName(forStore: store)) account...")
        gameService.syncAccountProvider(store: store) { [weak self] success, error in
            guard let self else { return }
            if success {
                self.actionMessage = "Store sync started."
                self.loadAccountAndStores()
                self.loadLibrary()
                self.browseCatalog()
            } else {
                self.errorMessage = error.isEmpty ? "Unable to sync this store account." : error
            }
        }
    }

    func linkSelectedStoreAccount() {
        guard let store = selectedPlatformOption(in: selectedGame)?.accountStore, !store.isEmpty else { return }
        linkStoreAccount(store)
    }

    func linkStoreAccount(_ store: String) {
        guard !store.isEmpty else { return }
        setActionMessage("Opening \(displayName(forStore: store)) account linking...")
        gameService.startAccountLinking(store: store) { [weak self] success, error in
            guard let self else { return }
            if success {
                self.actionMessage = "Account linked."
                self.loadAccountAndStores()
                self.loadLibrary()
                self.browseCatalog()
            } else {
                self.errorMessage = error.isEmpty ? "Unable to link this store account." : error
            }
        }
    }

    func selectedVariant(in game: OPNCatalogGameObject?) -> OPNCatalogGameVariantObject? {
        guard let game else { return nil }
        let index = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: game)
        guard index >= 0, index < game.variants.count else { return nil }
        return game.variants[index]
    }

    func selectedPlatformOption(in game: OPNCatalogGameObject?) -> CatalogPlatformOption? {
        let options = platformOptions(for: game)
        return options.first(where: { $0.isSelected }) ?? options.first
    }

    func selectedPlatformHasAccess(in game: OPNCatalogGameObject?) -> Bool {
        selectedPlatformOption(in: game)?.hasAccess == true
    }

    func platformOptions(for game: OPNCatalogGameObject?) -> [CatalogPlatformOption] {
        guard let game else { return [] }
        let selectedIndex = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: game)
        return game.variants.enumerated().map { index, variant in
            let subscriptionIds = Self.visibleSubscriptionIds(for: variant)
            let subscriptionDefinition = subscriptionDefinition(for: subscriptionIds)
            let accountStore = subscriptionDefinition?.primaryStore.isEmpty == false ? subscriptionDefinition?.primaryStore ?? "" : variant.appStore
            let account = accountStatus(forStore: accountStore)
            let storeDefinition = storeDefinition(forStore: accountStore)
            let isOwned = Self.variantIsOwned(variant, in: game)
            let hasSubscriptionEntitlement = subscriptionIds.contains { accountHasSubscription($0) }
            let isUnavailable = Self.variantIsUnavailable(variant)
            let isSubscription = !subscriptionIds.isEmpty
            let title = displayName(forVariant: variant)
            let iconURL = iconURL(forVariant: variant)
            let canLink = account == nil && storeDefinition?.isAccountLinkingSupported == true
            let canSync = account?.hasAccountSyncingData == true
            return CatalogPlatformOption(
                id: variant.id.isEmpty ? "\(index)-\(variant.appStore)-\(title)" : variant.id,
                variantIndex: index,
                variant: variant,
                title: title,
                iconURL: iconURL,
                store: variant.appStore,
                subscriptionIds: subscriptionIds,
                primaryStore: accountStore,
                isSubscription: isSubscription,
                isOwned: isOwned,
                hasSubscriptionEntitlement: hasSubscriptionEntitlement,
                hasAccess: isOwned || hasSubscriptionEntitlement,
                isSelected: selectedIndex == index,
                isUnavailable: isUnavailable,
                canLink: canLink,
                canSync: canSync,
                accountDisplayName: account?.userDisplayName ?? "",
                status: platformStatusLabel(isOwned: isOwned, hasSubscriptionEntitlement: hasSubscriptionEntitlement, isUnavailable: isUnavailable, isSubscription: isSubscription, account: account, canLink: canLink, canSync: canSync)
            )
        }
    }

    func displayName(forStore store: String) -> String {
        if let definition = storeDefinitions.first(where: { $0.store.caseInsensitiveCompare(store) == .orderedSame }), !definition.label.isEmpty {
            return definition.label
        }
        return store.isEmpty ? "Store" : store.uppercased()
    }

    func displayName(forSubscription subscription: String) -> String {
        if let definition = subscriptionDefinitions.first(where: { $0.subscription.caseInsensitiveCompare(subscription) == .orderedSame }), !definition.label.isEmpty {
            return definition.label
        }
        return subscription.isEmpty ? "Subscription" : subscription.replacingOccurrences(of: "_", with: " ").capitalized
    }

    func iconURL(forSubscription subscription: String) -> String {
        subscriptionDefinitions.first { $0.subscription.caseInsensitiveCompare(subscription) == .orderedSame }?.logoURL ?? ""
    }

    func displayName(forVariant variant: OPNCatalogGameVariantObject) -> String {
        let subscriptionNames = Self.visibleSubscriptionIds(for: variant).map { displayName(forSubscription: $0) }
        if !subscriptionNames.isEmpty { return subscriptionNames.joined(separator: " / ") }
        if !variant.appStoreLabel.isEmpty { return variant.appStoreLabel }
        return variant.appStore.isEmpty ? "GeForce NOW" : displayName(forStore: variant.appStore)
    }

    func iconURL(forVariant variant: OPNCatalogGameVariantObject) -> String {
        let subscription = Self.visibleSubscriptionIds(for: variant).first ?? ""
        let subscriptionIconURL = iconURL(forSubscription: subscription)
        if !subscriptionIconURL.isEmpty { return subscriptionIconURL }
        return variant.appStoreSmallImageUrl
    }

    func accountStatus(forStore store: String) -> CatalogStoreAccount? {
        accountStores.first { $0.store.caseInsensitiveCompare(store) == .orderedSame }
    }

    func accountHasSubscription(_ subscription: String) -> Bool {
        accountSubscriptions.contains { $0.caseInsensitiveCompare(subscription) == .orderedSame }
    }

    func storeDefinition(forStore store: String) -> CatalogStoreDefinition? {
        storeDefinitions.first { $0.store.caseInsensitiveCompare(store) == .orderedSame }
    }

    func subscriptionDefinition(for subscriptionIds: [String]) -> CatalogSubscriptionDefinition? {
        for subscription in subscriptionIds {
            if let definition = subscriptionDefinitions.first(where: { $0.subscription.caseInsensitiveCompare(subscription) == .orderedSame }) {
                return definition
            }
        }
        return nil
    }

    func platformStatusLabel(isOwned: Bool, hasSubscriptionEntitlement: Bool, isUnavailable: Bool, isSubscription: Bool, account: CatalogStoreAccount?, canLink: Bool, canSync: Bool) -> String {
        if isOwned { return "Owned" }
        if hasSubscriptionEntitlement { return "Subscribed" }
        if isUnavailable { return "Game not found" }
        if canSync { return "Sync available" }
        if account?.hasAccountLinkingData == true { return "Connected" }
        if canLink { return "Connect" }
        if isSubscription { return "Subscription required" }
        return ""
    }
}
