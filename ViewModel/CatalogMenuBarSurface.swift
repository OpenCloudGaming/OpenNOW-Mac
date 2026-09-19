//  What the menu bar surface reads from the catalog: the phase of a launch in flight, the games it
//  can relaunch, and the bridge that lets a launch asked for outside the window land inside it.
//

import Foundation
import Observation

extension CatalogViewModel: OPNMenuBarSessionSource {
    /// The launch flow's state, reduced to what a status item can show.
    ///
    /// `streaming` is deliberately never produced here. The surface takes that from
    /// `StreamSessionLifecycle`, so it cannot disagree with the session that is actually running,
    /// and a teardown that has not reached this view model yet cannot leave a dead session on
    /// screen.
    var menuBarSnapshot: OPNMenuBarSessionSnapshot {
        OPNMenuBarSessionSnapshot(
            phase: menuBarPhase,
            title: menuBarTitle,
            recentGames: menuBarRecentGames
        )
    }

    private var menuBarPhase: OPNMenuBarSessionPhase {
        if isActiveStreamLaunchOverlayVisible, activeStreamConfiguration != nil {
            if let queuePosition = activeStreamProgress?.queuePosition, queuePosition > 0 {
                return .queued(position: queuePosition)
            }
            return .connecting
        }
        return launchFlowState == .idle ? .idle : .connecting
    }

    private var menuBarTitle: String {
        let configurationTitle = activeStreamConfiguration?.title ?? ""
        let progressTitle = activeStreamProgress?.title ?? ""
        let candidate = configurationTitle.isEmpty ? (progressTitle.isEmpty ? launchFlowTitle : progressTitle) : configurationTitle
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The three most recent games, with the box art the catalog can supply for them.
    ///
    /// `allKnownGames` rebuilds a concatenated array on every access, and this snapshot is read on
    /// every change the surface tracks — including each poll of a launch in flight — so the catalog
    /// is read once here and searched for all three rows, rather than once per row.
    private var menuBarRecentGames: [OPNMenuBarRecentGame] {
        let entries = recentlyPlayed.games.prefix(3)
        guard !entries.isEmpty else { return [] }
        let known = allKnownGames
        return entries.map { entry in
            OPNMenuBarRecentGame(
                title: entry.title,
                appId: entry.appId,
                artworkURL: Self.menuBarArtworkURL(forRecentGame: entry, in: known)
            )
        }
    }

    /// Box art for the menu's game rows. The catalog only knows a game it has loaded, so a list built
    /// before the catalog arrives simply has no artwork and the row falls back to its placeholder.
    private static func menuBarArtworkURL(forRecentGame entry: CatalogRecentlyPlayedGame, in known: [OPNCatalogGameObject]) -> String? {
        let match = known.first { Self.game($0, matchesApplicationID: entry.appId) }
            ?? known.first { $0.title.caseInsensitiveCompare(entry.title) == .orderedSame }
        let artwork = match?.imageUrl.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return artwork.isEmpty ? nil : artwork
    }

    func attachMenuBarSurface() {
        OPNMenuBarSessionModel.shared.attach(source: self)
    }

    func detachMenuBarSurface() {
        OPNMenuBarSessionModel.shared.detachSource(self)
    }

    /// Launching a game the menu bar offered. The catalog it came from may not be loaded — a window
    /// reopened from the menu bar starts fetching as it appears — so an unknown game is resolved by
    /// browsing for its title, the same way an unresolved shortcut is.
    func launchRecentGame(_ game: OPNMenuBarRecentGame) {
        configureCatalogService()
        let title = game.title.trimmingCharacters(in: .whitespacesAndNewlines)
        OPNLog.info(.launch, "Menu bar launching recent game appId=\(game.appId) title=\(title)")
        if let match = knownGame(matching: game, title: title) {
            selectGame(match)
            launch(game: match, variantIndex: Self.preferredVariantIndex(for: match))
            return
        }
        setActionMessage("Looking up \(title.isEmpty ? "the game" : title)...")
        browseForRecentGame(title: title, appId: game.appId)
    }

    private func knownGame(matching game: OPNMenuBarRecentGame, title: String) -> OPNCatalogGameObject? {
        if let match = allKnownGames.first(where: { Self.game($0, matchesApplicationID: game.appId) }) { return match }
        guard !title.isEmpty else { return nil }
        return allKnownGames.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    private func browseForRecentGame(title: String, appId: String) {
        guard !title.isEmpty else {
            reportLaunchFailure("This recent game has no title to look up.")
            return
        }
        let deliveryGate = CatalogDeliveryGate()
        gameService.browseCatalogObject(searchQuery: title, sortId: "relevance", filterIds: [], fetchCount: 24) { [weak self] success, result, error in
            guard let self, deliveryGate.claimFirstDelivery() else { return }
            guard success else {
                OPNLog.error(.launch, "Recent game catalog browse failed: \(error)")
                self.reportLaunchFailure(error.isEmpty ? "Unable to look up this recent game." : error)
                return
            }
            let games = result.games
            guard let match = self.matchRecentGame(in: games, title: title, appId: appId) else {
                OPNLog.error(.launch, "Recent game catalog browse returned no matching games")
                self.reportLaunchFailure("No GeForce NOW catalog entry was found for \(title).")
                return
            }
            OPNLog.info(.launch, "Resolved recent game from browse: gameId=\(match.id) launchAppId=\(match.launchAppId) title=\(match.title)")
            self.catalogGames = games
            self.selectGame(match)
            self.launch(game: match, variantIndex: Self.preferredVariantIndex(for: match))
        }
    }

    private func matchRecentGame(in games: [OPNCatalogGameObject], title: String, appId: String) -> OPNCatalogGameObject? {
        if let match = games.first(where: { Self.game($0, matchesApplicationID: appId) }) { return match }
        if let match = games.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) { return match }
        return games.first
    }
}
