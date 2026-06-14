//  CatalogViewModel.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import Backend
import Foundation

private final class CatalogWeakObject<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}

private final class CatalogSendableValue<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

@MainActor
final class CatalogViewModel: ObservableObject {
    @Published var searchQuery = ""
    @Published var selectedSortId = "last_played"
    @Published var isLoading = false
    @Published var isLoadingPanels = false
    @Published var errorMessage = ""
    @Published var launchMessage = ""
    @Published var marqueePanels: [OPNCatalogPanelObject] = []
    @Published var mainPanels: [OPNCatalogPanelObject] = []
    @Published var catalogGames: [OPNCatalogGameObject] = []
    @Published var selectedGame: OPNCatalogGameObject?
    @Published var selectedVariantIndex = -1

    let account: LoginAccount
    let session: LoginSession

    private var hasLoaded = false
    private var browseGeneration = 0

    init(account: LoginAccount, session: LoginSession) {
        self.account = account
        self.session = session
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

    var catalogSections: [(title: String, games: [OPNCatalogGameObject])] {
        var sections: [(String, [OPNCatalogGameObject])] = []
        var seenTitles = Set<String>()
        for panel in mainPanels {
            for section in panel.sections where !section.games.isEmpty {
                let title = section.title.isEmpty ? panel.title : section.title
                let resolvedTitle = title.isEmpty ? "Featured Games" : title
                guard !seenTitles.contains(resolvedTitle) else { continue }
                seenTitles.insert(resolvedTitle)
                sections.append((resolvedTitle, Array(section.games.prefix(18))))
            }
        }
        if !catalogGames.isEmpty {
            sections.insert((searchQuery.trimmed.isEmpty ? "Recently Added" : "Search Results", catalogGames), at: 0)
        }
        return Array(sections.prefix(8))
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        configureCatalogService()
        loadPanels()
        browseCatalog()
    }

    func refresh() {
        configureCatalogService()
        loadPanels()
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
            filterIds: [],
            fetchCount: 96
        ) { success, result, error in
            let resultBox = CatalogSendableValue(result)
            Task { @MainActor in
                guard let self = selfBox.value, generation == self.browseGeneration else { return }
                self.isLoading = false
                guard success else {
                    self.errorMessage = error.isEmpty ? "Unable to browse the GeForce NOW catalog." : error
                    return
                }
                self.catalogGames = resultBox.value.games
                if self.selectedGame == nil {
                    self.selectGame(self.featuredGames.first ?? self.catalogGames.first)
                }
            }
        }
    }

    func selectGame(_ game: OPNCatalogGameObject?) {
        selectedGame = game
        selectedVariantIndex = game.map { Self.preferredVariantIndex(for: $0) } ?? -1
        launchMessage = ""
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
                    if self.selectedGame == nil { self.selectGame(self.featuredGames.first) }
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
                    if self.selectedGame == nil { self.selectGame(self.featuredGames.first ?? self.catalogGames.first) }
                } else if self.errorMessage.isEmpty {
                    self.errorMessage = error.isEmpty ? "Unable to load GeForce NOW home panels." : error
                }
            }
        }
    }

    private func configureCatalogService() {
        let userId = session.userId.isEmpty ? account.userId : session.userId
        OPNGameServiceSwiftAdapter.setAccessToken(session.accessToken)
        OPNGameServiceSwiftAdapter.setAccountLinkingToken(session.accessToken)
        OPNGameServiceSwiftAdapter.setUserId(userId)
        OPNGameServiceSwiftAdapter.setVpcId("GFN-PC")
        OPNGameServiceSwiftAdapter.prewarmLaunchData()
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
}
