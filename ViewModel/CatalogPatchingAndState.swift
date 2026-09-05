//  Settings preferences, the patching poll a queued launch waits on, and the small state updates
//  the rest of the catalog makes.
//

import Foundation
import Observation

extension CatalogViewModel {
    func loadSettingsPreferences() {
        settingsPreferencesGeneration += 1
        let generation = settingsPreferencesGeneration
        settingsPreferencesTask?.cancel()
        settingsPreferencesTask = Task.detached(priority: .userInitiated) {
            let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
            let profile = OPNStreamPreferences.effectiveProfile(OPNStreamPreferences.loadProfile(), capabilities: capabilities)
            let snapshot = CatalogSettingsPreferencesSnapshot(
                capabilities: capabilities,
                profile: profile,
                remoteCoOpPreferences: OPNRemoteCoOpPreferencesStore.load(),
                selectedRegionUrl: OPNStreamPreferences.loadSelectedRegionUrl(),
                regionOptions: Self.launchRegionOptions(from: OPNStreamPreferences.loadCachedRegions()),
                microphoneDeviceOptions: OPNStreamPreferences.loadMicrophoneDeviceOptions()
            )
            await MainActor.run { [weak self] in
                guard let self, generation == self.settingsPreferencesGeneration, !Task.isCancelled else { return }
                self.streamCapabilities = snapshot.capabilities
                self.streamProfile = snapshot.profile
                self.remoteCoOpPreferences = snapshot.remoteCoOpPreferences
                self.selectedSettingsRegionUrl = snapshot.selectedRegionUrl
                self.settingsRegionOptions = snapshot.regionOptions
                self.unavailableSettingsRegionUrl = snapshot.selectedRegionUrl.isEmpty || snapshot.regionOptions.contains(where: { $0.url == snapshot.selectedRegionUrl }) ? "" : snapshot.selectedRegionUrl
                self.microphoneDeviceOptions = snapshot.microphoneDeviceOptions
                self.settingsPreferencesTask = nil
            }
        }
    }

    func refreshCatalogAfterOwnershipChange() {
        reloadLibraryAfterChange()
        browseCatalog()
        if let selectedGame {
            let selectedIdentity = Self.identity(for: selectedGame)
            let refreshedGame = (libraryGames + catalogGames).first { Self.identity(for: $0) == selectedIdentity }
            if let refreshedGame { selectGame(refreshedGame) }
        }
    }

    func schedulePatchingPollIfNeeded(immediate: Bool = true) {
        let patchingAppIds = patchingPollAppIds()
        guard !patchingAppIds.isEmpty else {
            deinitHandle.patchingPollTask?.cancel()
            deinitHandle.patchingPollTask = nil
            return
        }
        guard deinitHandle.patchingPollTask == nil else {
            if immediate {
                Task { @MainActor [weak self] in await self?.refreshPatchingStatuses() }
            }
            return
        }
        deinitHandle.patchingPollTask = Task { @MainActor [weak self] in
            if immediate { await self?.refreshPatchingStatuses() }
            while let self, !Task.isCancelled {
                let delaySeconds = UInt64(Int.random(in: 30...60))
                try? await Task.sleep(for: .seconds(delaySeconds))
                guard !Task.isCancelled else { return }
                await self.refreshPatchingStatuses()
                if self.patchingPollAppIds().isEmpty {
                    self.deinitHandle.patchingPollTask = nil
                    return
                }
            }
        }
    }

    func refreshPatchingStatuses() async {
        guard !patchingPollInFlight else { return }
        let appIds = patchingPollAppIds()
        guard !appIds.isEmpty else { return }
        patchingPollInFlight = true
        defer { patchingPollInFlight = false }
        let libraryResult = await fetchLibraryPatchStatuses()
        let targetedResult = await fetchAppPatchStatuses(appIds: appIds)
        var mergedStatuses = libraryResult.statuses
        CatalogPatchStatusLogic.mergePatchStatuses(targetedResult.statuses, into: &mergedStatuses)
        if !mergedStatuses.isEmpty {
            applyPatchingStatuses(mergedStatuses)
        }
        for error in [libraryResult.error, targetedResult.error] where !error.isEmpty {
            if refreshAuthIfNeeded(error: error) { return }
            OpenNOWLog.warning(.catalog, "App patch status poll failed: \(error)")
        }
    }

    func fetchLibraryPatchStatuses() async -> (statuses: [String: OPNAppPatchStatus], error: String) {
        await withCheckedContinuation { continuation in
            gameService.fetchLibraryPatchStatuses { success, statuses, error in
                continuation.resume(returning: (success ? statuses : [:], success ? "" : error))
            }
        }
    }

    func fetchAppPatchStatuses(appIds: [String]) async -> (statuses: [String: OPNAppPatchStatus], error: String) {
        await withCheckedContinuation { continuation in
            gameService.fetchAppPatchStatuses(appIds: appIds) { success, statuses, error in
                continuation.resume(returning: (success ? statuses : [:], success ? "" : error))
            }
        }
    }

    func patchingPollAppIds() -> [String] {
        let ids = allKnownGames.filter(CatalogPatchStatusLogic.isPatching).compactMap(CatalogPatchStatusLogic.patchStatusAppId)
        return Array(Set(ids)).sorted()
    }

    func applyPatchingStatuses(_ statuses: [String: OPNAppPatchStatus]) {
        guard !statuses.isEmpty else { return }
        CatalogPatchStatusLogic.updatePatchingStatuses(in: &catalogGames, statuses: statuses)
        CatalogPatchStatusLogic.updatePatchingStatuses(in: &libraryGames, statuses: statuses)
        CatalogPatchStatusLogic.updatePatchingStatuses(in: &favoriteGames, statuses: statuses)
        CatalogPatchStatusLogic.updatePatchingStatuses(in: &marqueePanels, statuses: statuses)
        CatalogPatchStatusLogic.updatePatchingStatuses(in: &mainPanels, statuses: statuses)
        if let selectedGame, let status = CatalogPatchStatusLogic.patchStatus(for: selectedGame, statuses: statuses) {
            CatalogPatchStatusLogic.applyPatchingStatus(status, to: selectedGame)
        }
        launchQueuedPatchingGameIfReady()
    }





    func launchQueuedPatchingGameIfReady() {
        guard !queuedPatchingLaunchIdentity.isEmpty else { return }
        guard let game = allKnownGames.first(where: { Self.identity(for: $0) == queuedPatchingLaunchIdentity }) else { return }
        guard !CatalogPatchStatusLogic.isPatching(game) else { return }
        let variantIndex = queuedPatchingLaunchVariantIndex
        let title = queuedPatchingLaunchGameTitle.isEmpty ? (game.title.isEmpty ? "GeForce NOW" : game.title) : queuedPatchingLaunchGameTitle
        queuedPatchingLaunchIdentity = ""
        queuedPatchingLaunchVariantIndex = -1
        queuedPatchingLaunchGameTitle = ""
        actionMessage = "Patching finished. Launching \(title)..."
        selectGame(game)
        launch(game: game, variantIndex: variantIndex)
    }

    func selectedVariantIndexIfMatching(_ game: OPNCatalogGameObject) -> Int? {
        guard let selectedGame, Self.identity(for: selectedGame) == Self.identity(for: game) else { return nil }
        return selectedVariantIndex
    }

    func updateSelectedGameOwnership(gameIdentity: String, variantId: String, inLibrary: Bool) {
        guard !gameIdentity.isEmpty else { return }
        func apply(to game: OPNCatalogGameObject) {
            for variant in game.variants where variant.id == variantId {
                variant.inLibrary = inLibrary
                variant.librarySelected = inLibrary
            }
            game.isInLibrary = Self.gameHasOwnedVariant(game)
        }
        func update(_ games: [OPNCatalogGameObject]) {
            for game in games where Self.identity(for: game) == gameIdentity { apply(to: game) }
        }
        if let selectedGame, Self.identity(for: selectedGame) == gameIdentity { apply(to: selectedGame) }
        update(catalogGames)
        update(libraryGames)
        update(favoriteGames)
        update(marqueeGames)
        update(mainPanelGames)
        for games in fullSectionGames.values { update(games) }
    }

    func updateGameFavoriteState(identity: String, isFavorited: Bool) {
        guard !identity.isEmpty else { return }
        func update(_ games: [OPNCatalogGameObject]) {
            for game in games where Self.identity(for: game) == identity {
                game.isFavorited = isFavorited
            }
        }
        if selectedGame.map(Self.identity(for:)) == identity { selectedGame?.isFavorited = isFavorited }
        update(catalogGames)
        update(libraryGames)
        update(favoriteGames)
        update(marqueeGames)
        update(mainPanelGames)
        for games in fullSectionGames.values { update(games) }
    }

    func setActionMessage(_ message: String) {
        actionMessage = message
        errorMessage = ""
    }

    /// The one place a failed launch is recorded. Writes the transient banner as well, so surfaces
    /// that only read `errorMessage` are unchanged.
    func reportLaunchFailure(_ message: String) {
        errorMessage = message
        launchErrorMessage = message
    }

    /// The message any catalog surface should show: the sticky launch failure outlives the
    /// transient status line that a refetch clears.
    var displayedErrorMessage: String {
        errorMessage.isEmpty ? launchErrorMessage : errorMessage
    }

    func dismissLaunchError() {
        launchErrorMessage = ""
        if !errorMessage.isEmpty { errorMessage = "" }
    }

    nonisolated static func titleGroupingKey(for game: OPNCatalogGameObject) -> String {
        let normalized = game.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? identity(for: game) : normalized
    }

    nonisolated static func dedupedByTitleGrouping(_ games: [OPNCatalogGameObject]) -> [OPNCatalogGameObject] {
        var indexByKey: [String: Int] = [:]
        var result: [OPNCatalogGameObject] = []
        result.reserveCapacity(games.count)
        for game in games {
            let key = titleGroupingKey(for: game)
            if let existingIndex = indexByKey[key] {
                if preferredSKU(game, over: result[existingIndex]) {
                    result[existingIndex] = game
                }
            } else {
                indexByKey[key] = result.count
                result.append(game)
            }
        }
        return result
    }

    nonisolated private static func preferredSKU(_ candidate: OPNCatalogGameObject, over current: OPNCatalogGameObject) -> Bool {
        if candidate.isInLibrary != current.isInLibrary { return candidate.isInLibrary }
        return candidate.variants.count > current.variants.count
    }




    static func hasMarqueeHeroArtwork(_ game: OPNCatalogGameObject) -> Bool {
        for key in ["MARQUEE_HERO_IMAGE", "marquee_hero_image"] {
            if game.imageUrlsByType[key]?.contains(where: { !$0.isEmpty }) == true { return true }
        }
        return false
    }

    func syncingOwnershipMessage(for game: OPNCatalogGameObject) -> String {
        let stores = CatalogAccountParsing.uniqueNonEmpty(game.variants.map { displayName(forStore: $0.appStore) })
        if stores.isEmpty { return "Syncing connected game libraries..." }
        if stores.count == 1 { return "Syncing \(stores[0]) game library..." }
        return "Syncing \(stores.dropLast().joined(separator: ", ")) and \(stores.last ?? "") game libraries..."
    }

    func matchingGame(for shortcut: GFNGameShortcut, in games: [OPNCatalogGameObject]) -> OPNCatalogGameObject? {
        let identifiers = Set([shortcut.cmsId, shortcut.shortName, shortcut.parentGameId].map { $0.lowercased() }.filter { !$0.isEmpty })
        if !identifiers.isEmpty {
            for game in games where game.matchesGFNShortcutIdentifiers(identifiers) { return game }
        }
        let title = shortcut.lookupTitle
        guard !title.isEmpty else { return nil }
        return games.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    func variantIndex(for shortcut: GFNGameShortcut, in game: OPNCatalogGameObject) -> Int {
        if !shortcut.cmsId.isEmpty, let index = game.variants.firstIndex(where: { $0.id.caseInsensitiveCompare(shortcut.cmsId) == .orderedSame }) {
            return index
        }
        return Self.preferredVariantIndex(for: game)
    }

    func resolveSelectedStoreURL(completion: @escaping @Sendable (URL?) -> Void) {
        guard let selectedGame else {
            completion(nil)
            return
        }
        let variantIndex = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: selectedGame)
        if variantIndex >= 0, variantIndex < selectedGame.variants.count {
            let variant = selectedGame.variants[variantIndex]
            if let url = URL(string: variant.storeUrl), !variant.storeUrl.isEmpty {
                completion(url)
                return
            }
        }
        if let url = selectedGame.primaryStoreURL {
            completion(url)
            return
        }
        gameService.resolveStoreURL(game: selectedGame.swiftValue, variantIndex: max(variantIndex, 0)) { [weak self] success, storeURL, _ in
            guard self != nil else { return }
            completion(success ? URL(string: storeURL) : nil)
        }
    }

    func configureCatalogService() {
        let userId = session.userId.isEmpty ? account.userId : session.userId
        gameService.configureCatalogSession(accessToken: session.accessToken, idToken: session.idToken, userId: userId)
    }

    func refreshAuthIfNeeded(error: String) -> Bool {
        guard error.contains("401"), !authRefreshInFlight else { return false }
        authRefreshInFlight = true
        isLoading = false
        isLoadingPanels = false
        isLoadingMarquee = false
        errorMessage = "Refreshing NVIDIA session..."
        Task { [weak self] in
            guard let self else { return }
            let refreshed = await onRefreshAuth()
            authRefreshInFlight = false
            guard refreshed else {
                errorMessage = "Unable to refresh your NVIDIA session. Sign out and sign in again."
                return
            }
            errorMessage = ""
            loadCatalogDataAfterProviderConfiguration(forceCatalogRefresh: true)
        }
        return true
    }

    nonisolated static func identity(for game: OPNCatalogGameObject) -> String {
        if !game.id.isEmpty { return game.id }
        if !game.uuid.isEmpty { return game.uuid }
        if !game.launchAppId.isEmpty { return game.launchAppId }
        return game.title
    }

    static func favoriteAppId(for game: OPNCatalogGameObject) -> String {
        if !game.id.isEmpty { return game.id }
        return game.uuid
    }

    static func game(_ game: OPNCatalogGameObject, matchesApplicationID applicationID: String) -> Bool {
        guard !applicationID.isEmpty else { return false }
        for value in [game.id, game.uuid, game.launchAppId, game.shortName] where value == applicationID {
            return true
        }
        return game.variants.contains { $0.id == applicationID }
    }

    static func looseIdentityMatches(_ lhs: OPNCatalogGameObject, _ rhs: OPNCatalogGameObject) -> Bool {
        let lhsIdentity = identity(for: lhs)
        let rhsIdentity = identity(for: rhs)
        if !lhsIdentity.isEmpty, !rhsIdentity.isEmpty, lhsIdentity == rhsIdentity { return true }
        return !lhs.title.isEmpty && lhs.title.caseInsensitiveCompare(rhs.title) == .orderedSame
    }

    static func playtimeAccountIdentifier(account: LoginAccount, session: LoginSession) -> String {
        for value in [session.userId, account.userId, account.externalUserId, account.email] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed.lowercased() }
        }
        return "default"
    }

    static func snapshotObject(for game: OPNCatalogGameObject) -> OPNCatalogGameObject {
        OPNCatalogGameObject(game: game.swiftValue)
    }

    /// Our own extension, not `.gfnpc`: the official GeForce NOW app owns that type in Launch
    /// Services, so a shortcut we wrote opened their client instead of this one.
    static func safeShortcutFilename(_ title: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/").union(.newlines).union(.controlCharacters)
        let sanitized = title.components(separatedBy: invalidCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = sanitized.isEmpty ? "Cloud Game" : sanitized
        return "\(baseName) on OpenNOW.opennow"
    }

    func requestSelectedGameReveal(for game: OPNCatalogGameObject, sectionId: String) {
        selectedGameRevealSequence += 1
        selectedGameRevealRequest = CatalogGameRevealRequest(sectionId: sectionId, gameIdentity: Self.identity(for: game), sequence: selectedGameRevealSequence)
    }

    static func shortcutCMSId(for game: OPNCatalogGameObject, variant: OPNCatalogGameVariantObject?) -> String {
        for value in [variant?.id ?? "", game.launchAppId, game.id] where isPositiveInteger(value) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let variantId = game.variants.map(\.id).first(where: isPositiveInteger) {
            return variantId.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let variantId = variant?.id, !variantId.isEmpty { return variantId }
        return identity(for: game)
    }

    static func launchGame(from shortcut: GFNGameShortcut, title: String) -> OPNCatalogGameObject? {
        let cmsId = shortcut.cmsId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPositiveInteger(cmsId) else { return nil }
        let game = OPNCatalogGameObject()
        game.id = shortcut.parentGameId.isEmpty ? cmsId : shortcut.parentGameId
        game.uuid = game.id
        game.launchAppId = cmsId
        game.title = title.isEmpty ? "GeForce NOW" : title
        game.shortName = shortcut.shortName
        game.isInLibrary = true
        let variant = OPNCatalogGameVariantObject()
        variant.id = cmsId
        variant.inLibrary = true
        variant.librarySelected = true
        game.variants = [variant]
        return game
    }

    static func isPositiveInteger(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let intValue = Int(trimmed) else { return false }
        return intValue > 0
    }

    func resolveGameForDetails(_ game: OPNCatalogGameObject) -> OPNCatalogGameObject {
        resolveGameForDetails(game, preferredSectionId: "")
    }

    func resolveGameForDetails(_ game: OPNCatalogGameObject, preferredSectionId: String) -> OPNCatalogGameObject {
        if !preferredSectionId.isEmpty,
           let section = catalogSections.first(where: { $0.id == preferredSectionId }),
           let sectionGame = section.games.first(where: { Self.looseIdentityMatches($0, game) }) {
            return sectionGame
        }
        for section in catalogSections {
            if let sectionGame = section.games.first(where: { Self.looseIdentityMatches($0, game) }) {
                return sectionGame
            }
        }
        return game
    }

    static func preferredVariantIndex(for game: OPNCatalogGameObject) -> Int {
        if let index = game.variants.firstIndex(where: { $0.librarySelected }) { return index }
        if let index = game.variants.firstIndex(where: { $0.inLibrary }) { return index }
        return game.variants.isEmpty ? -1 : 0
    }

    static func variantIsOwned(_ variant: OPNCatalogGameVariantObject, in game: OPNCatalogGameObject) -> Bool {
        variant.inLibrary || variant.librarySelected || OPNGameRemediation.gameServiceStatusOwnedForLaunch(variant.serviceStatus) || (game.variants.count == 1 && game.isInLibrary)
    }

    static func gameHasOwnedVariant(_ game: OPNCatalogGameObject) -> Bool {
        game.variants.contains { $0.inLibrary || $0.librarySelected || OPNGameRemediation.gameServiceStatusOwnedForLaunch($0.serviceStatus) }
    }

    static func visibleSubscriptionIds(for variant: OPNCatalogGameVariantObject) -> [String] {
        CatalogAccountParsing.uniqueNonEmpty([variant.librarySubscription] + variant.subscriptionIds).filter { $0.caseInsensitiveCompare("NONE") != .orderedSame }
    }

    static func variantIsUnavailable(_ variant: OPNCatalogGameVariantObject) -> Bool {
        let status = variant.serviceStatus.lowercased()
        return status.contains("not") || status.contains("unavailable") || status.contains("unsupported")
    }
}
