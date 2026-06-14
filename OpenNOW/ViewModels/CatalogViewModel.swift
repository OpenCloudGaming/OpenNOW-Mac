//  CatalogViewModel.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import Backend
import Combine
import Foundation

private final class CatalogWeakObject<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}

private final class CatalogSendableValue<T>: @unchecked Sendable {
    nonisolated(unsafe) let value: T

    nonisolated init(_ value: T) {
        self.value = value
    }
}

@MainActor
final class CatalogViewModel: ObservableObject {
    @Published var searchQuery = ""
    @Published var selectedSortId = "last_played"
    @Published var selectedFilterIds: [String] = []
    @Published var isLoading = false
    @Published var isLoadingPanels = false
    @Published var errorMessage = ""
    @Published var launchMessage = ""
    @Published var actionMessage = ""
    @Published var marqueePanels: [OPNCatalogPanelObject] = []
    @Published var mainPanels: [OPNCatalogPanelObject] = []
    @Published var catalogGames: [OPNCatalogGameObject] = []
    @Published var libraryGames: [OPNCatalogGameObject] = []
    @Published var filterGroups: [OPNCatalogFilterGroupObject] = []
    @Published var sortOptions: [OPNCatalogSortOptionObject] = []
    @Published var totalCatalogCount = 0
    @Published var supportedCatalogCount = 0
    @Published var hasMoreCatalogResults = false
    @Published var expandedSectionIds: Set<String> = []
    @Published var accountStores: [CatalogStoreAccount] = []
    @Published var storeDefinitions: [CatalogStoreDefinition] = []
    @Published var selectedGame: OPNCatalogGameObject?
    @Published var selectedVariantIndex = -1

    let account: LoginAccount
    let session: LoginSession
    let onRefreshAuth: () -> Void

    private var hasLoaded = false
    private var browseGeneration = 0
    private var authRefreshInFlight = false
    private var cancellables = Set<AnyCancellable>()

    init(account: LoginAccount, session: LoginSession, onRefreshAuth: @escaping () -> Void) {
        self.account = account
        self.session = session
        self.onRefreshAuth = onRefreshAuth
        $searchQuery
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.browseCatalog() }
            .store(in: &cancellables)
    }

    var featuredGames: [OPNCatalogGameObject] {
        var games: [OPNCatalogGameObject] = []
        var seen = Set<String>()
        for panel in marqueePanels + mainPanels {
            for section in panel.sections {
                for game in section.games {
                    let key = Self.identity(for: game)
                    guard !key.isEmpty, !seen.contains(key) else { continue }
                    seen.insert(key)
                    games.append(game)
                }
            }
        }
        return Array(games.prefix(8))
    }

    var catalogSections: [CatalogSectionModel] {
        var sections: [CatalogSectionModel] = []
        var seenTitles = Set<String>()
        for panel in mainPanels {
            for section in panel.sections where !section.games.isEmpty {
                let title = section.title.isEmpty ? panel.title : section.title
                let resolvedTitle = title.isEmpty ? "Featured Games" : title
                guard !seenTitles.contains(resolvedTitle) else { continue }
                seenTitles.insert(resolvedTitle)
                sections.append(CatalogSectionModel(id: section.sectionIdentity(fallbackPanelId: panel.id), title: resolvedTitle, games: section.games, kind: .panel))
            }
        }
        if !catalogGames.isEmpty {
            sections.insert(CatalogSectionModel(id: "catalog-results", title: searchQuery.trimmed.isEmpty ? "My Favorites" : "Search Results", games: catalogGames, kind: .catalog), at: 0)
        }
        if searchQuery.trimmed.isEmpty, !libraryGames.isEmpty {
            let insertionIndex = min(sections.count, catalogGames.isEmpty ? 0 : 1)
            sections.insert(CatalogSectionModel(id: "my-library", title: "My Library", games: libraryGames, kind: .library), at: insertionIndex)
        }
        return Array(sections.prefix(10))
    }

    var selectedSortLabel: String {
        sortOptions.first { $0.id == selectedSortId }?.label ?? "Recently Played"
    }

    var visibleFilterGroups: [OPNCatalogFilterGroupObject] {
        filterGroups.filter { !$0.options.isEmpty }
    }

    var selectedFilterCount: Int { selectedFilterIds.count }

    var resultSummary: String {
        let total = totalCatalogCount > 0 ? totalCatalogCount : catalogGames.count
        if searchQuery.trimmed.isEmpty, selectedFilterIds.isEmpty { return "" }
        if total == 1 { return "1 result" }
        return "\(total) results"
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        configureCatalogService()
        loadPanels()
        loadLibrary()
        loadAccountAndStores()
        browseCatalog()
    }

    func refresh() {
        configureCatalogService()
        loadPanels()
        loadLibrary()
        loadAccountAndStores()
        browseCatalog()
    }

    func browseCatalog() {
        browseGeneration += 1
        let generation = browseGeneration
        isLoading = true
        errorMessage = ""
        configureCatalogService()
        let query = searchQuery.trimmed
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.browseCatalogObject(
            searchQuery: query,
            sortId: selectedSortId.isEmpty ? "last_played" : selectedSortId,
            filterIds: selectedFilterIds,
            fetchCount: 96
        ) { success, result, error in
            let resultBox = CatalogSendableValue(result)
            Task { @MainActor in
                guard let self = selfBox.value, generation == self.browseGeneration else { return }
                self.isLoading = false
                guard success else {
                    if self.refreshAuthIfNeeded(error: error) { return }
                    self.errorMessage = error.isEmpty ? "Unable to browse the GeForce NOW catalog." : error
                    return
                }
                let browseResult = resultBox.value
                self.catalogGames = browseResult.games
                self.totalCatalogCount = browseResult.totalCount
                self.supportedCatalogCount = browseResult.numberSupported
                self.hasMoreCatalogResults = browseResult.hasNextPage
                self.filterGroups = browseResult.filterGroups
                self.sortOptions = browseResult.sortOptions
                if !browseResult.selectedSortId.isEmpty { self.selectedSortId = browseResult.selectedSortId }
                self.selectedFilterIds = browseResult.selectedFilterIds
            }
        }
    }

    func setSort(_ sortId: String) {
        guard selectedSortId != sortId else { return }
        selectedSortId = sortId
        browseCatalog()
    }

    func toggleFilter(_ filterId: String) {
        if selectedFilterIds.contains(filterId) {
            selectedFilterIds.removeAll { $0 == filterId }
        } else {
            selectedFilterIds.append(filterId)
        }
        browseCatalog()
    }

    func clearFilters() {
        guard !selectedFilterIds.isEmpty else { return }
        selectedFilterIds = []
        browseCatalog()
    }

    func clearSearchAndFilters() {
        searchQuery = ""
        selectedFilterIds = []
        browseCatalog()
    }

    func toggleSectionExpansion(_ sectionId: String) {
        if expandedSectionIds.contains(sectionId) {
            expandedSectionIds.remove(sectionId)
        } else {
            expandedSectionIds.insert(sectionId)
        }
    }

    func selectGame(_ game: OPNCatalogGameObject?) {
        selectedGame = game
        selectedVariantIndex = game.map { Self.preferredVariantIndex(for: $0) } ?? -1
        launchMessage = ""
        actionMessage = ""
    }

    func launchSelectedGame() {
        guard let selectedGame else { return }
        launch(game: selectedGame, variantIndex: selectedVariantIndex)
    }

    func launch(game: OPNCatalogGameObject, variantIndex: Int? = nil) {
        launchMessage = "Launching \(game.title.isEmpty ? "game" : game.title)..."
        let userId = session.userId.isEmpty ? account.userId : session.userId
        OPNGameLaunchBridge.shared.launch(
            game: game,
            accessToken: session.accessToken,
            idToken: session.idToken,
            userId: userId,
            variantIndex: variantIndex ?? Self.preferredVariantIndex(for: game)
        ) { [weak self] success, message in
            guard let self else { return }
            self.launchMessage = success ? message : ""
            if !success { self.errorMessage = message }
        }
    }

    func openStoreForSelectedVariant() {
        guard let selectedGame else { return }
        let variantIndex = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: selectedGame)
        guard variantIndex >= 0, variantIndex < selectedGame.variants.count else { return }
        let variant = selectedGame.variants[variantIndex]
        if let url = URL(string: variant.storeUrl), !variant.storeUrl.isEmpty {
            NSWorkspace.shared.open(url)
            return
        }
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.resolveStoreURL(game: selectedGame, variantIndex: variantIndex) { success, storeURL, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                guard success, let url = URL(string: storeURL), !storeURL.isEmpty else {
                    self.errorMessage = error.isEmpty ? "No store URL is available for this game." : error
                    return
                }
                NSWorkspace.shared.open(url)
            }
        }
    }

    func shareSelectedGame() {
        guard let selectedGame else { return }
        let title = selectedGame.title.isEmpty ? "GeForce NOW game" : selectedGame.title
        let url = selectedGame.primaryStoreURL ?? URL(string: "https://play.geforcenow.com/")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString([title, url?.absoluteString].compactMap { $0 }.joined(separator: "\n"), forType: .string)
        actionMessage = "Copied share details."
    }

    func markSelectedVariantOwned() {
        guard let selectedGame, let variant = selectedVariant(in: selectedGame), !variant.id.isEmpty else { return }
        let gameIdentity = Self.identity(for: selectedGame)
        let variantId = variant.id
        let title = selectedGame.title.isEmpty ? "game" : selectedGame.title
        let selfBox = CatalogWeakObject(self)
        setActionMessage("Adding \(title) to library...")
        OPNGameServiceSwiftAdapter.addOwnedVariant(variantId) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.updateSelectedGameOwnership(gameIdentity: gameIdentity, variantId: variantId, inLibrary: true)
                    self.actionMessage = "Added to library."
                    self.refreshCatalogAfterOwnershipChange()
                } else {
                    self.errorMessage = error.isEmpty ? "Unable to add this game to your library." : error
                }
            }
        }
    }

    func removeSelectedVariantOwned() {
        guard let selectedGame, let variant = selectedVariant(in: selectedGame), !variant.id.isEmpty else { return }
        let gameIdentity = Self.identity(for: selectedGame)
        let variantId = variant.id
        let title = selectedGame.title.isEmpty ? "game" : selectedGame.title
        let selfBox = CatalogWeakObject(self)
        setActionMessage("Removing \(title) from library...")
        OPNGameServiceSwiftAdapter.removeOwnedVariant(variantId) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.updateSelectedGameOwnership(gameIdentity: gameIdentity, variantId: variantId, inLibrary: false)
                    self.actionMessage = "Removed from library."
                    self.refreshCatalogAfterOwnershipChange()
                } else {
                    self.errorMessage = error.isEmpty ? "Unable to remove this game from your library." : error
                }
            }
        }
    }

    func selectOwnedVariant(_ variant: OPNCatalogGameVariantObject) {
        guard !variant.id.isEmpty else { return }
        let variantId = variant.id
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.selectOwnedVariant(variantId) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.selectedGame?.variants.forEach { $0.librarySelected = $0.id == variantId }
                    self.actionMessage = "Store selection updated."
                    self.refreshCatalogAfterOwnershipChange()
                } else {
                    self.errorMessage = error.isEmpty ? "Unable to update store selection." : error
                }
            }
        }
    }

    func syncSelectedStoreAccount() {
        guard let store = selectedVariant(in: selectedGame)?.appStore, !store.isEmpty else { return }
        let selfBox = CatalogWeakObject(self)
        setActionMessage("Syncing \(displayName(forStore: store)) account...")
        OPNGameServiceSwiftAdapter.syncAccountProvider(store: store) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
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
    }

    func linkSelectedStoreAccount() {
        guard let store = selectedVariant(in: selectedGame)?.appStore, !store.isEmpty else { return }
        let selfBox = CatalogWeakObject(self)
        setActionMessage("Opening \(displayName(forStore: store)) account linking...")
        OPNGameServiceSwiftAdapter.startAccountLinking(store: store) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
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
    }

    func selectedVariant(in game: OPNCatalogGameObject?) -> OPNCatalogGameVariantObject? {
        guard let game else { return nil }
        let index = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: game)
        guard index >= 0, index < game.variants.count else { return nil }
        return game.variants[index]
    }

    func displayName(forStore store: String) -> String {
        if let definition = storeDefinitions.first(where: { $0.store.caseInsensitiveCompare(store) == .orderedSame }), !definition.label.isEmpty {
            return definition.label
        }
        return store.isEmpty ? "Store" : store.uppercased()
    }

    func accountStatus(forStore store: String) -> CatalogStoreAccount? {
        accountStores.first { $0.store.caseInsensitiveCompare(store) == .orderedSame }
    }

    func optimizedImageURL(_ rawValue: String, width: Int) -> URL? {
        guard !rawValue.isEmpty else { return nil }
        let optimized = OPNGameServiceSwiftAdapter.optimizeImageURL(rawValue, width: width)
        return URL(string: optimized.isEmpty ? rawValue : optimized)
    }

    private func loadPanels() {
        isLoadingPanels = true
        errorMessage = ""
        configureCatalogService()
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.fetchMarqueePanelObjects { success, panels, error in
            let panelBox = CatalogSendableValue(panels)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.marqueePanels = panelBox.value
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.isLoadingPanels = false
                } else if self.errorMessage.isEmpty {
                    self.errorMessage = error
                }
            }
        }
        OPNGameServiceSwiftAdapter.fetchMainPanelObjects { success, panels, error in
            let panelBox = CatalogSendableValue(panels)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                self.isLoadingPanels = false
                if success {
                    self.mainPanels = panelBox.value
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.isLoadingPanels = false
                } else if self.errorMessage.isEmpty {
                    self.errorMessage = error.isEmpty ? "Unable to load GeForce NOW home panels." : error
                }
            }
        }
    }

    private func loadLibrary() {
        configureCatalogService()
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.fetchLibraryGameObjects { success, games, error in
            let gamesBox = CatalogSendableValue(games)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.libraryGames = gamesBox.value
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.libraryGames = []
                }
            }
        }
    }

    private func loadAccountAndStores() {
        configureCatalogService()
        let selfBox = CatalogWeakObject(self)
        OPNGameServiceSwiftAdapter.fetchUserAccountDictionary { success, account, error in
            let accountBox = CatalogSendableValue(account)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.accountStores = Self.parseStoreAccounts(accountBox.value)
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.accountStores = []
                }
            }
        }
        OPNGameServiceSwiftAdapter.fetchStoreDefinitionDictionaries { success, definitions, _ in
            let definitionsBox = CatalogSendableValue(definitions)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success { self.storeDefinitions = definitionsBox.value.map(Self.parseStoreDefinition) }
            }
        }
    }

    private func refreshCatalogAfterOwnershipChange() {
        loadLibrary()
        browseCatalog()
        if let selectedGame {
            let selectedIdentity = Self.identity(for: selectedGame)
            let refreshedGame = (libraryGames + catalogGames).first { Self.identity(for: $0) == selectedIdentity }
            if let refreshedGame { selectGame(refreshedGame) }
        }
    }

    private func updateSelectedGameOwnership(gameIdentity: String, variantId: String, inLibrary: Bool) {
        guard let selectedGame, Self.identity(for: selectedGame) == gameIdentity else { return }
        selectedGame.isInLibrary = inLibrary
        for variant in selectedGame.variants where variant.id == variantId {
            variant.inLibrary = inLibrary
            variant.librarySelected = inLibrary
        }
    }

    private func setActionMessage(_ message: String) {
        actionMessage = message
        errorMessage = ""
    }

    private func configureCatalogService() {
        let userId = session.userId.isEmpty ? account.userId : session.userId
        OPNGameServiceSwiftAdapter.configureCatalogSession(accessToken: session.accessToken, idToken: session.idToken, userId: userId)
    }

    private func refreshAuthIfNeeded(error: String) -> Bool {
        guard error.contains("401"), !authRefreshInFlight else { return false }
        authRefreshInFlight = true
        isLoading = false
        isLoadingPanels = false
        errorMessage = "Refreshing NVIDIA session..."
        onRefreshAuth()
        return true
    }

    static func identity(for game: OPNCatalogGameObject) -> String {
        if !game.id.isEmpty { return game.id }
        if !game.uuid.isEmpty { return game.uuid }
        if !game.launchAppId.isEmpty { return game.launchAppId }
        return game.title
    }

    static func preferredVariantIndex(for game: OPNCatalogGameObject) -> Int {
        if let index = game.variants.firstIndex(where: { $0.librarySelected }) { return index }
        if let index = game.variants.firstIndex(where: { $0.inLibrary }) { return index }
        return game.variants.isEmpty ? -1 : 0
    }

    private static func parseStoreAccounts(_ account: NSDictionary) -> [CatalogStoreAccount] {
        guard let stores = account["stores"] as? [NSDictionary] else { return [] }
        return stores.map { store in
            let syncing = store["syncing"] as? NSDictionary
            return CatalogStoreAccount(
                store: store["store"] as? String ?? "",
                userDisplayName: store["userDisplayName"] as? String ?? "",
                expiresIn: store["expiresIn"] as? String ?? "",
                userIdentifier: store["userIdentifier"] as? String ?? "",
                hasAccountLinkingData: store["hasAccountLinkingData"] as? Bool ?? false,
                hasAccountSyncingData: store["hasAccountSyncingData"] as? Bool ?? false,
                totalSyncedGames: syncing?["totalNumberOfSyncedGfnGames"] as? Int ?? 0,
                syncState: syncing?["syncState"] as? String ?? "",
                syncDate: syncing?["syncDate"] as? String ?? ""
            )
        }
    }

    private static func parseStoreDefinition(_ definition: NSDictionary) -> CatalogStoreDefinition {
        let metadata = definition["accountLinkingMetadata"] as? NSDictionary
        return CatalogStoreDefinition(
            store: definition["store"] as? String ?? "",
            label: definition["label"] as? String ?? "",
            smallImageUrl: definition["smallImageUrl"] as? String ?? "",
            isAccountLinkingSupported: metadata?["isSupported"] as? Bool ?? false,
            isAccountLinkingRequired: metadata?["isRequired"] as? Bool ?? false,
            accountLinkingLabel: metadata?["label"] as? String ?? ""
        )
    }
}

struct CatalogSectionModel: Identifiable, Equatable {
    enum Kind: Equatable {
        case catalog
        case library
        case panel
    }

    let id: String
    let title: String
    let games: [OPNCatalogGameObject]
    let kind: Kind

    func visibleGames(expanded: Bool) -> [OPNCatalogGameObject] {
        expanded ? games : Array(games.prefix(18))
    }
}

struct CatalogStoreAccount: Identifiable, Equatable {
    var id: String { store }
    let store: String
    let userDisplayName: String
    let expiresIn: String
    let userIdentifier: String
    let hasAccountLinkingData: Bool
    let hasAccountSyncingData: Bool
    let totalSyncedGames: Int
    let syncState: String
    let syncDate: String
}

struct CatalogStoreDefinition: Identifiable, Equatable {
    var id: String { store }
    let store: String
    let label: String
    let smallImageUrl: String
    let isAccountLinkingSupported: Bool
    let isAccountLinkingRequired: Bool
    let accountLinkingLabel: String
}

private extension OPNCatalogPanelSectionObject {
    func sectionIdentity(fallbackPanelId: String) -> String {
        if !id.isEmpty { return id }
        let titlePart = title.isEmpty ? "section" : title
        return [fallbackPanelId, titlePart].filter { !$0.isEmpty }.joined(separator: ":")
    }
}

private extension OPNCatalogGameObject {
    var primaryStoreURL: URL? {
        variants.compactMap { URL(string: $0.storeUrl) }.first
    }
}
