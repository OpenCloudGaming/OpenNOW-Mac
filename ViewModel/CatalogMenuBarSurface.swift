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
            recentGames: menuBarRecentGames,
            resumableSessionTitle: menuBarResumableSessionTitle
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

    /// The title of a resumable session while nothing streams locally: a seat this Mac paused, or one
    /// another device is holding. Nil when the launch flow is busy or there is nothing to resume.
    private var menuBarResumableSessionTitle: String? {
        guard isActiveHomeSessionVisible, activeHomeSession?.isResumable == true else { return nil }
        let title = activeHomeSessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Current Stream" : title
    }

    private var menuBarTitle: String {
        let configurationTitle = activeStreamConfiguration?.title ?? ""
        let progressTitle = activeStreamProgress?.title ?? ""
        let candidate = configurationTitle.isEmpty ? (progressTitle.isEmpty ? launchFlowTitle : progressTitle) : configurationTitle
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The three most recent games as persisted for an account, mapped for the menu bar without the
    /// catalog. Used when no window exists to hand the live list over — a windowless launch — so the
    /// rows still appear, with title-only placeholders for artwork until a window loads the catalog.
    static func persistedMenuBarRecentGames(accountIdentifier: String) -> [OPNMenuBarRecentGame] {
        guard !accountIdentifier.isEmpty else { return [] }
        let entries = CatalogRecentlyPlayed.load(accountIdentifier: accountIdentifier).games
        var rows: [OPNMenuBarRecentGame] = []
        var seenTitles = Set<String>()
        for entry in entries {
            let key = entry.title.lowercased()
            guard !key.isEmpty, seenTitles.insert(key).inserted else { continue }
            rows.append(OPNMenuBarRecentGame(title: entry.title, appId: entry.appId, artworkURL: entry.artworkURL))
            if rows.count == 3 { break }
        }
        return rows
    }

    /// The three most recent games, with the box art the catalog can supply for them.
    ///
    /// The store keeps the same game under two id namespaces — the vendor history records the
    /// catalog identity, while a locally-finished session records the numeric launch app id — so the
    /// rows are deduped by the resolved catalog game rather than by the raw entry, exactly as the
    /// Jump Back In rail already does. A title-only entry the catalog cannot resolve falls back to
    /// its title as the dedupe key.
    ///
    /// `allKnownGames` rebuilds a concatenated array on every access, and this snapshot is read on
    /// every change the surface tracks — including each poll of a launch in flight — so the catalog
    /// is read once here and searched for all three rows, rather than once per row.
    private var menuBarRecentGames: [OPNMenuBarRecentGame] {
        guard !recentlyPlayed.games.isEmpty else { return [] }
        let known = allKnownGames
        var rows: [OPNMenuBarRecentGame] = []
        var seenIdentities = Set<String>()
        for entry in recentlyPlayed.games {
            let game = Self.menuBarGame(matching: entry, in: known)
            let identity = game.map { Self.identity(for: $0) } ?? ""
            let dedupeKey = (identity.isEmpty ? entry.title : identity).lowercased()
            guard !dedupeKey.isEmpty, seenIdentities.insert(dedupeKey).inserted else { continue }
            rows.append(OPNMenuBarRecentGame(
                title: game?.title ?? entry.title,
                appId: identity.isEmpty ? entry.appId : identity,
                artworkURL: Self.menuBarArtworkURL(for: game) ?? entry.artworkURL
            ))
            if rows.count == 3 { break }
        }
        return rows
    }

    private static func menuBarGame(matching entry: CatalogRecentlyPlayedGame, in known: [OPNCatalogGameObject]) -> OPNCatalogGameObject? {
        known.first { Self.game($0, matchesApplicationID: entry.appId) }
            ?? known.first { !$0.title.isEmpty && $0.title.caseInsensitiveCompare(entry.title) == .orderedSame }
    }

    /// Box art for the menu's game rows. The catalog only knows a game it has loaded, so a list built
    /// before the catalog arrives simply has no artwork and the row falls back to its placeholder.
    private static func menuBarArtworkURL(for game: OPNCatalogGameObject?) -> String? {
        let artwork = game?.imageUrl.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
    /// Resuming a session the menu bar detected but is not streaming locally. The vendor session is
    /// already allocated, so this hands the resume to the same home-page path, with the same guard.
    func resumeSession() {
        OPNLog.info(.launch, "Menu bar resuming the resumable session")
        resumeActiveHomeSession()
    }

    /// Opening the menu is the moment a session started on another device becomes relevant, so the
    /// active-session lookup runs again rather than waiting for the next launch or session end.
    func refreshActiveSession() {
        checkActiveHomeSession()
    }

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
