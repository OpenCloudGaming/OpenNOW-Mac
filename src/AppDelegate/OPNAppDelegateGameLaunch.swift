import AppKit

private enum OPNGameLaunchScreen: Int32 {
    case emailEntry = 0
    case store = 2
    case catalog = 3
}

private struct OPNGameLaunchSyncObservation: Sendable {
    var hasData = false
    var totalNumberOfSyncedGfnGames = 0
    var syncState = ""
    var syncDate = ""
}

private struct OPNGameLaunchStoreAccount: Sendable {
    var store = ""
    var hasAccountSyncingData = false
    var syncObservation = OPNGameLaunchSyncObservation()
}

private struct OPNGameLaunchStoreDefinition: Sendable {
    var store = ""
    var features: Set<String> = []
    var supportedVariantIds: Set<String> = []
    var linkingSupported = false
    var linkingRequired = false
}

private final class OPNGameLaunchWeakObject<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}

private final class OPNGameLaunchSendableValue<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

private final class OPNGameLaunchSyncRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var accepted = false
    private var authFailed = false
    private var storedError = ""

    func record(success: Bool, store: String, error: String) {
        lock.lock()
        if success {
            accepted = true
        } else {
            if storedError.isEmpty { storedError = error }
            if OPNAppDelegateSupport.unauthorizedError(error) { authFailed = true }
            OPNSentry.logErrorMessage("[AppDelegate] Sync request failed for \(store): \(error)")
        }
        lock.unlock()
    }

    var snapshot: (Bool, Bool, String) {
        lock.lock()
        defer { lock.unlock() }
        return (accepted, authFailed, storedError)
    }
}

private func opnGameLaunchGet<T>(_ object: NSObject, _ key: String, as type: T.Type = T.self) -> T? { object.value(forKey: key) as? T }
private func opnGameLaunchSet(_ object: NSObject, _ key: String, _ value: Any?) { object.setValue(value, forKey: key) }
private func opnGameLaunchBool(_ object: NSObject, _ key: String) -> Bool { (object.value(forKey: key) as? NSNumber)?.boolValue ?? (object.value(forKey: key) as? Bool ?? false) }
private func opnGameLaunchInt(_ object: NSObject, _ key: String) -> Int { (object.value(forKey: key) as? NSNumber)?.intValue ?? (object.value(forKey: key) as? Int ?? 0) }

private func opnGameLaunchAppendFingerprintField(_ fingerprint: inout String, _ value: String) {
    fingerprint += "\(value.count):\(value)|"
}

private func opnGameLaunchFingerprintList(_ values: [String]) -> String {
    var fingerprint = "["
    for value in values.sorted() { opnGameLaunchAppendFingerprintField(&fingerprint, value) }
    fingerprint += "]"
    return fingerprint
}

private func opnGameLaunchLibraryFingerprint(_ games: [OPNCatalogGameObject]) -> String {
    var entries: [String] = []
    entries.reserveCapacity(games.count)
    for game in games {
        var entry = ""
        opnGameLaunchAppendFingerprintField(&entry, game.id)
        opnGameLaunchAppendFingerprintField(&entry, game.uuid)
        opnGameLaunchAppendFingerprintField(&entry, game.launchAppId)
        opnGameLaunchAppendFingerprintField(&entry, game.title)
        opnGameLaunchAppendFingerprintField(&entry, game.shortName)
        opnGameLaunchAppendFingerprintField(&entry, game.playabilityState)
        opnGameLaunchAppendFingerprintField(&entry, game.imageUrl)
        opnGameLaunchAppendFingerprintField(&entry, opnGameLaunchFingerprintList(game.availableStores))
        opnGameLaunchAppendFingerprintField(&entry, opnGameLaunchFingerprintList(game.genres))
        let variants = game.variants.map { variant in
            var variantEntry = ""
            opnGameLaunchAppendFingerprintField(&variantEntry, variant.id)
            opnGameLaunchAppendFingerprintField(&variantEntry, variant.appStore)
            opnGameLaunchAppendFingerprintField(&variantEntry, variant.storeUrl)
            opnGameLaunchAppendFingerprintField(&variantEntry, variant.serviceStatus)
            opnGameLaunchAppendFingerprintField(&variantEntry, variant.librarySelected ? "1" : "0")
            opnGameLaunchAppendFingerprintField(&variantEntry, variant.inLibrary ? "1" : "0")
            return variantEntry
        }
        opnGameLaunchAppendFingerprintField(&entry, opnGameLaunchFingerprintList(variants))
        entries.append(entry)
    }
    var fingerprint = ""
    for entry in entries.sorted() { opnGameLaunchAppendFingerprintField(&fingerprint, entry) }
    return fingerprint
}

private func opnGameLaunchPerform(_ object: NSObject, _ selectorName: String) {
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector) else { return }
    _ = object.perform(selector)
}

private func opnGameLaunchSendScreen(_ object: NSObject, _ selectorName: String, _ screen: Int32) {
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector) else { return }
    typealias Message = @convention(c) (AnyObject, Selector, Int32) -> Void
    unsafeBitCast(object.method(for: selector), to: Message.self)(object, selector, screen)
}

private func opnGameLaunchStartStream(_ object: NSObject, title: String, appId: String, apiToken: String, accountLinked: Bool, selectedStore: String, returnScreen: Int32, resumeSessionId: String = "", resumeServer: String = "") {
    let selector = NSSelectorFromString("startStreamWithTitleString:appIdString:apiTokenString:accountLinked:selectedStoreString:returnScreenRaw:resumeSessionIdString:resumeServerString:")
    guard object.responds(to: selector) else { return }
    typealias Message = @convention(c) (AnyObject, Selector, NSString, NSString, NSString, Bool, NSString, Int, NSString, NSString) -> Void
    unsafeBitCast(object.method(for: selector), to: Message.self)(object, selector, title as NSString, appId as NSString, apiToken as NSString, accountLinked, selectedStore as NSString, Int(returnScreen), resumeSessionId as NSString, resumeServer as NSString)
}

private func opnGameLaunchShowError(_ object: NSObject, message: String, canRetry: Bool) {
    let selector = NSSelectorFromString("showErrorMessage:canRetry:")
    guard object.responds(to: selector) else { return }
    typealias Message = @convention(c) (AnyObject, Selector, NSString, Bool) -> Void
    unsafeBitCast(object.method(for: selector), to: Message.self)(object, selector, message as NSString, canRetry)
}

private func opnGameLaunchVariant(_ game: OPNCatalogGameObject, _ variantIndex: Int32) -> OPNCatalogGameVariantObject? {
    let index = Int(variantIndex)
    guard index >= 0, index < game.variants.count else { return nil }
    return game.variants[index]
}

private func opnGameLaunchVariantOwned(_ variant: OPNCatalogGameVariantObject) -> Bool {
    OPNGameRemediationBridge.gameVariantOwnedForLaunch(inLibrary: variant.inLibrary, librarySelected: variant.librarySelected, serviceStatus: variant.serviceStatus)
}

private func opnGameLaunchChooseAccountLinked(_ game: OPNCatalogGameObject, _ variant: OPNCatalogGameVariantObject?) -> Bool {
    if game.playType == "INSTALL_TO_PLAY" { return false }
    if let variant { return opnGameLaunchVariantOwned(variant) }
    if game.isInLibrary { return true }
    return game.variants.contains(where: opnGameLaunchVariantOwned)
}

private func opnGameLaunchFirstOwnedVariantIndex(_ game: OPNCatalogGameObject, excluded: Int32) -> Int32 {
    for (index, variant) in game.variants.enumerated() where Int32(index) != excluded && !variant.id.isEmpty && opnGameLaunchVariantOwned(variant) { return Int32(index) }
    return -1
}

private func opnGameLaunchGameMatches(_ lhs: OPNCatalogGameObject, _ rhs: OPNCatalogGameObject) -> Bool {
    (!rhs.id.isEmpty && lhs.id == rhs.id) || (!rhs.uuid.isEmpty && lhs.uuid == rhs.uuid)
}

private func opnGameLaunchSelectedOwnedVariantIndex(_ game: OPNCatalogGameObject, requestedVariant: OPNCatalogGameVariantObject?) -> Int32 {
    guard let requestedVariant else { return -1 }
    for (index, variant) in game.variants.enumerated() {
        let sameVariant = (!requestedVariant.id.isEmpty && variant.id == requestedVariant.id) || (!requestedVariant.appStore.isEmpty && variant.appStore.caseInsensitiveCompare(requestedVariant.appStore) == .orderedSame)
        if sameVariant && opnGameLaunchVariantOwned(variant) { return Int32(index) }
    }
    return -1
}

private func opnGameLaunchLibraryContainsOwnedVariant(_ games: [OPNCatalogGameObject], requestedGame: OPNCatalogGameObject, requestedVariant: OPNCatalogGameVariantObject?) -> Bool {
    for game in games where opnGameLaunchGameMatches(game, requestedGame) {
        if game.isInLibrary && requestedVariant == nil { return true }
        for variant in game.variants {
            let sameVariant = requestedVariant.map { (!$0.id.isEmpty && variant.id == $0.id) || (!$0.appStore.isEmpty && variant.appStore.caseInsensitiveCompare($0.appStore) == .orderedSame) } ?? false
            if sameVariant && opnGameLaunchVariantOwned(variant) { return true }
        }
    }
    return false
}

private func opnGameLaunchHasAppId(_ game: OPNCatalogGameObject, appId: Int) -> Bool {
    guard appId > 0 else { return false }
    let appIdString = String(appId)
    return game.id == appIdString || game.launchAppId == appIdString || game.variants.contains { $0.id == appIdString }
}

func opnGameLaunchTitleForActiveSession(appId: Int, games: [OPNCatalogGameObject]) -> String {
    guard appId > 0 else { return "Current Stream" }
    let appIdString = String(appId)
    for game in games {
        if game.id == appIdString || game.launchAppId == appIdString || game.variants.contains(where: { $0.id == appIdString }) {
            return game.title.isEmpty ? "Current Stream" : game.title
        }
    }
    return "Current Stream"
}

private func opnGameLaunchStoreDisplayName(_ store: String) -> String {
    OPNGameRemediationBridge.gameStoreDisplayName(store)
}

private func opnGameLaunchSyncSucceeded(_ state: String) -> Bool { state == "SYNC_SUCCESS" }
private func opnGameLaunchSyncFailed(_ state: String) -> Bool { ["SYNC_DENIED", "PROFILE_NOT_CREATED", "SYNC_FAILED"].contains(state) }

private func opnGameLaunchSyncChanged(_ current: OPNGameLaunchSyncObservation, _ baseline: OPNGameLaunchSyncObservation) -> Bool {
    guard current.hasData, baseline.hasData else { return false }
    return current.syncState != baseline.syncState || current.syncDate != baseline.syncDate || current.totalNumberOfSyncedGfnGames != baseline.totalNumberOfSyncedGfnGames
}

private func opnGameLaunchSyncFailureMessage(_ state: String, storeName: String) -> String {
    let displayStore = storeName.isEmpty ? "the selected store" : storeName
    if state == "SYNC_DENIED" { return "GeForce NOW could not sync \(displayStore) because the store account denied library access. Check your store privacy or connection settings, then try again." }
    if state == "PROFILE_NOT_CREATED" { return "GeForce NOW could not sync \(displayStore) because the store profile is not ready or could not be found. Open the store profile, then try again." }
    if state == "SYNC_FAILED" { return "GeForce NOW reported that \(displayStore) library sync failed. Try syncing again or open the store to check the account connection." }
    return "GeForce NOW did not report a successful \(displayStore) library sync before the timeout."
}

private func opnGameLaunchRemainingFooter(_ deadlineAt: Date) -> String {
    let remaining = max(0.0, deadlineAt.timeIntervalSinceNow)
    if remaining <= 0.0 { return "Doing one final library refresh." }
    return "About \(Int(ceil(remaining)))s left before showing manual options."
}

private func opnGameLaunchProgressMessage(current: OPNGameLaunchSyncObservation, baseline: OPNGameLaunchSyncObservation, storeName: String, deadlineAt: Date, attempt: Int) -> String {
    let displayStore = storeName.isEmpty ? "the selected store" : storeName
    let fresh = opnGameLaunchSyncChanged(current, baseline)
    if fresh && opnGameLaunchSyncSucceeded(current.syncState) { return "\(displayStore) sync finished. Checking if this game is now in your library..." }
    if fresh && opnGameLaunchSyncFailed(current.syncState) { return "\(displayStore) reported a sync problem. Refreshing once more before showing options..." }
    if deadlineAt.timeIntervalSinceNow > 0.0 { return "Waiting for \(displayStore) to update your GeForce NOW library... (\(max(1, attempt + 1)))" }
    return "Refreshing \(displayStore) library data one final time..."
}

private func opnGameLaunchStoreListName(_ stores: [String]) -> String {
    let names = stores.map(opnGameLaunchStoreDisplayName).filter { !$0.isEmpty }
    if names.isEmpty { return "connected stores" }
    if names.count == 1 { return names[0] }
    if names.count == 2 { return "\(names[0]) and \(names[1])" }
    return "\(names.dropLast().joined(separator: ", ")), and \(names.last ?? "")"
}

private func opnGameLaunchParseStoreAccounts(_ dictionary: NSDictionary) -> [OPNGameLaunchStoreAccount] {
    let stores = dictionary["stores"] as? [NSDictionary] ?? []
    return stores.map { item in
        let syncing = item["syncing"] as? NSDictionary ?? [:]
        return OPNGameLaunchStoreAccount(
            store: item["store"] as? String ?? "",
            hasAccountSyncingData: (item["hasAccountSyncingData"] as? NSNumber)?.boolValue ?? false,
            syncObservation: OPNGameLaunchSyncObservation(
                hasData: (item["hasAccountSyncingData"] as? NSNumber)?.boolValue ?? false,
                totalNumberOfSyncedGfnGames: (syncing["totalNumberOfSyncedGfnGames"] as? NSNumber)?.intValue ?? 0,
                syncState: syncing["syncState"] as? String ?? "",
                syncDate: syncing["syncDate"] as? String ?? ""
            )
        )
    }
}

private func opnGameLaunchParseStoreDefinitions(_ dictionaries: [NSDictionary]) -> [OPNGameLaunchStoreDefinition] {
    dictionaries.map { item in
        let features = (item["features"] as? [NSDictionary] ?? []).reduce(into: Set<String>()) { result, feature in
            if ((feature["supported"] as? NSNumber)?.boolValue ?? false), let type = feature["type"] as? String { result.insert(type) }
        }
        let metadata = item["accountLinkingMetadata"] as? NSDictionary ?? [:]
        let supportedIds = Set(metadata["supportedVariantIds"] as? [String] ?? [])
        return OPNGameLaunchStoreDefinition(
            store: item["store"] as? String ?? "",
            features: features,
            supportedVariantIds: supportedIds,
            linkingSupported: (metadata["isSupported"] as? NSNumber)?.boolValue ?? false,
            linkingRequired: (metadata["isRequired"] as? NSNumber)?.boolValue ?? false
        )
    }
}

private func opnGameLaunchStoreDefinition(_ definitions: [OPNGameLaunchStoreDefinition], store: String) -> OPNGameLaunchStoreDefinition? {
    definitions.first { $0.store.caseInsensitiveCompare(store) == .orderedSame }
}

private func opnGameLaunchStoreAccount(_ accounts: [OPNGameLaunchStoreAccount], store: String) -> OPNGameLaunchStoreAccount? {
    accounts.first { $0.store.caseInsensitiveCompare(store) == .orderedSame }
}

private func opnGameLaunchDefinitionSupportsVariant(_ definition: OPNGameLaunchStoreDefinition?, variantId: String) -> Bool {
    guard let definition else { return false }
    return definition.supportedVariantIds.isEmpty || definition.supportedVariantIds.contains(variantId)
}

private func opnGameLaunchAutoResyncStores(game: OPNCatalogGameObject, definitions: [OPNGameLaunchStoreDefinition], accounts: [OPNGameLaunchStoreAccount]) -> [String] {
    var stores: [String] = []
    for variant in game.variants where !variant.appStore.isEmpty {
        let definition = opnGameLaunchStoreDefinition(definitions, store: variant.appStore)
        guard definition?.features.contains("AccountGamesSyncing") == true, opnGameLaunchDefinitionSupportsVariant(definition, variantId: variant.id), opnGameLaunchStoreAccount(accounts, store: variant.appStore) != nil else { continue }
        if !stores.contains(where: { $0.caseInsensitiveCompare(variant.appStore) == .orderedSame }) { stores.append(variant.appStore) }
    }
    return stores
}

@MainActor
extension NSObject {
    @objc(configureGameServiceTokensForSession:)
    func configureGameServiceTokens(session: OPNAuthSessionObject) {
        let apiToken = OPNAppDelegateSupport.authSessionToken(session)
        OPNGameServiceSwiftAdapter.setAccessToken(apiToken)
        OPNGameServiceSwiftAdapter.setAccountLinkingToken(apiToken)
    }

    @objc(refreshOwnershipAuthWithCompletion:)
    func refreshOwnershipAuth(completion: (@Sendable (Bool) -> Void)?) {
        let selfBox = OPNGameLaunchWeakObject(self)
        OPNAuthServiceDirect.shared.refreshSession(force: true) { success, freshObject, error in
            let freshBox = OPNGameLaunchSendableValue(freshObject)
            Task { @MainActor in
                guard let self = selfBox.value else { completion?(false); return }
                let freshObject = freshBox.value
                guard success, freshObject.isAuthenticated, !freshObject.accessToken.isEmpty else {
                    OPNSentry.logErrorMessage("[AppDelegate] Ownership auth refresh failed: \(error)")
                    completion?(false)
                    return
                }
                opnGameLaunchSet(self, "currentSession", freshObject)
                if opnGameLaunchBool(self, "pendingStayLoggedIn") { OPNAuthServiceDirect.shared.saveSession(freshObject) }
                self.configureGameServiceTokens(session: freshObject)
                opnGameLaunchPerform(self, "refreshAccountMenu")
                completion?(true)
            }
        }
    }

    @objc(showOwnershipSyncProgressForGameTitle:storeName:)
    func showOwnershipSyncProgress(gameTitle: String, storeName: String) {
        guard let parentView = opnGameLaunchGet(self, "window", as: NSWindow.self)?.contentView else { return }
        if opnGameLaunchGet(self, "ownershipSyncOverlayView", as: NSView.self) == nil {
            let overlay = OPNOwnershipSyncProgressView(frame: parentView.bounds)
            overlay.autoresizingMask = [.width, .height]
            opnGameLaunchSet(self, "ownershipSyncOverlayView", overlay)
            OPNUIHelpers.disableFocusHighlights(overlay)
        }
        updateOwnershipSyncProgressTitle("Syncing Store Library")
        let title = gameTitle.isEmpty ? "this game" : gameTitle
        let store = storeName.isEmpty ? "the selected store" : storeName
        updateOwnershipSyncProgressMessage("Asking GeForce NOW to sync \(store) for \(title).")
        updateOwnershipSyncProgressFooter("Waiting for GeForce NOW library updates.")
        guard let overlay = opnGameLaunchGet(self, "ownershipSyncOverlayView", as: NSView.self) else { return }
        if overlay.superview !== parentView {
            overlay.removeFromSuperview()
            overlay.frame = parentView.bounds
            parentView.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
    }

    @objc(updateOwnershipSyncProgressTitle:)
    func updateOwnershipSyncProgressTitle(_ title: String) {
        opnGameLaunchGet(self, "ownershipSyncOverlayView", as: OPNOwnershipSyncProgressView.self)?.titleText = title.isEmpty ? "Syncing Store Library" : title
    }

    @objc(updateOwnershipSyncProgressMessage:)
    func updateOwnershipSyncProgressMessage(_ message: String) {
        opnGameLaunchGet(self, "ownershipSyncOverlayView", as: OPNOwnershipSyncProgressView.self)?.messageText = message.isEmpty ? "Syncing your store library..." : message
    }

    @objc(updateOwnershipSyncProgressFooter:)
    func updateOwnershipSyncProgressFooter(_ footer: String) {
        opnGameLaunchGet(self, "ownershipSyncOverlayView", as: OPNOwnershipSyncProgressView.self)?.footerText = footer.isEmpty ? "Waiting for GeForce NOW library updates." : footer
    }

    @objc func dismissOwnershipSyncProgress() {
        opnGameLaunchGet(self, "ownershipSyncOverlayView", as: NSView.self)?.removeFromSuperview()
        opnGameLaunchSet(self, "ownershipSyncOverlayView", nil)
        opnGameLaunchSet(self, "ownershipSyncTitleLabel", nil)
        opnGameLaunchSet(self, "ownershipSyncMessageLabel", nil)
        opnGameLaunchSet(self, "ownershipSyncFooterLabel", nil)
        opnGameLaunchSet(self, "ownershipSyncSpinner", nil)
    }

    @objc(launchGameObject:variantIndex:returnScreenRaw:)
    func launchGameObject(_ game: OPNCatalogGameObject, variantIndex: Int32, returnScreen: Int32) {
        guard opnGameLaunchGet(self, "streamingController", as: OPNStreamViewController.self) == nil else {
            _ = OPNSentry.recordCounterMetric(key: "opennow.game.launch.count", value: 1, attributes: ["outcome": "ignored_active_stream"])
            OPNSentry.logInfoMessage("[AppDelegate] Ignoring game launch while stream is active: title=\(game.title), id=\(game.id)")
            return
        }
        let launchGeneration = opnGameLaunchInt(self, "gameLaunchGeneration") + 1
        opnGameLaunchSet(self, "gameLaunchGeneration", launchGeneration)
        OPNSentry.logInfoMessage("[AppDelegate] Game selected: title=\(game.title), id=\(game.id), uuid=\(game.uuid), variantIndex=\(variantIndex)")
        _ = OPNSentry.recordCounterMetric(key: "opennow.game.launch.count", value: 1, attributes: ["outcome": "selected", "return_screen": OPNAppDelegateSupport.screenName(forScreen: Int(returnScreen)), "variant_selected": variantIndex >= 0])
        guard let currentSession = opnGameLaunchGet(self, "currentSession", as: OPNAuthSessionObject.self) else { return }
        let apiToken = OPNAppDelegateSupport.authSessionToken(currentSession)
        configureGameServiceTokens(session: currentSession)
        let selectedVariant = opnGameLaunchVariant(game, variantIndex)
        let effectiveAppId = selectedVariant?.id.isEmpty == false ? selectedVariant?.id ?? "" : (game.launchAppId.isEmpty ? game.id : game.launchAppId)
        let selectedStore = selectedVariant?.appStore ?? ""
        let accountLinked = opnGameLaunchChooseAccountLinked(game, selectedVariant)
        let selfBox = OPNGameLaunchWeakObject(self)
        let continueLaunch: @MainActor (Bool) -> Void = { accountLinkedForLaunch in
            guard let self = selfBox.value, opnGameLaunchInt(self, "gameLaunchGeneration") == launchGeneration, opnGameLaunchGet(self, "streamingController", as: OPNStreamViewController.self) == nil else { return }
            self.continueLaunchAfterServerSelection(game: game, appId: effectiveAppId, apiToken: apiToken, accountLinked: accountLinkedForLaunch, selectedStore: selectedStore, returnScreen: returnScreen, launchGeneration: launchGeneration)
        }
        let beginServerSelection: @MainActor (Bool) -> Void = { accountLinkedForLaunch in
            guard let self = selfBox.value, opnGameLaunchInt(self, "gameLaunchGeneration") == launchGeneration else { return }
            self.showCloudmatchServerPicker(gameTitle: game.title.isEmpty ? "Selected Game" : game.title, apiToken: apiToken) { confirmed in
                Task { @MainActor in
                    guard confirmed, let self = selfBox.value, opnGameLaunchInt(self, "gameLaunchGeneration") == launchGeneration else {
                        if !confirmed { _ = OPNSentry.recordCounterMetric(key: "opennow.game.launch.count", value: 1, attributes: ["outcome": "server_selection_cancelled"]) }
                        return
                    }
                    _ = OPNSentry.recordCounterMetric(key: "opennow.game.launch.count", value: 1, attributes: ["outcome": "server_selection_confirmed"])
                    continueLaunch(accountLinkedForLaunch)
                }
            }
        }
        if presentOwnershipRemediationIfNeeded(game: game, variantIndex: variantIndex, accountLinked: accountLinked, continueHandler: beginServerSelection) { return }
        beginServerSelection(accountLinked)
    }

    private func continueLaunchAfterServerSelection(game: OPNCatalogGameObject, appId: String, apiToken: String, accountLinked: Bool, selectedStore: String, returnScreen: Int32, launchGeneration: Int) {
        let selfBox = OPNGameLaunchWeakObject(self)
        let gameBox = OPNGameLaunchSendableValue(game)
        let streamingBaseUrl = OPNStreamPreferences.loadSelectedStreamingBaseUrl(forGame: appId)
        OPNActiveSessionService.fetchActiveSessions(accessToken: apiToken, streamingBaseUrl: streamingBaseUrl) { ok, sessions, error in
            let sessionsBox = OPNGameLaunchSendableValue(sessions)
            Task { @MainActor in
                guard let self = selfBox.value, opnGameLaunchInt(self, "gameLaunchGeneration") == launchGeneration, opnGameLaunchGet(self, "streamingController", as: OPNStreamViewController.self) == nil else { return }
                let game = gameBox.value
                if !ok {
                    if OPNAppDelegateSupport.sessionProbeAuthenticationError(error) {
                        _ = OPNSentry.recordCounterMetric(key: "opennow.game.launch.count", value: 1, attributes: ["outcome": "active_probe_auth_failure"])
                        opnGameLaunchShowError(self, message: error, canRetry: true)
                        return
                    }
                    _ = OPNSentry.recordCounterMetric(key: "opennow.game.launch.count", value: 1, attributes: ["outcome": "active_probe_failure_continue"])
                    opnGameLaunchStartStream(self, title: game.title, appId: appId, apiToken: apiToken, accountLinked: accountLinked, selectedStore: selectedStore, returnScreen: returnScreen)
                    return
                }
                let sessions = sessionsBox.value
                let requestedSession = sessions.first { opnGameLaunchHasAppId(game, appId: $0.appId) }
                if let requestedSession {
                    _ = OPNSentry.recordCounterMetric(key: "opennow.game.launch.count", value: 1, attributes: ["outcome": "resume_same_game"])
                    opnGameLaunchStartStream(self, title: game.title.isEmpty ? "Current Stream" : game.title, appId: requestedSession.appId > 0 ? String(requestedSession.appId) : appId, apiToken: apiToken, accountLinked: true, selectedStore: "", returnScreen: returnScreen, resumeSessionId: requestedSession.sessionId, resumeServer: requestedSession.serverIp)
                    return
                }
                guard let activeSession = sessions.first else {
                    _ = OPNSentry.recordCounterMetric(key: "opennow.game.launch.count", value: 1, attributes: ["outcome": "start_new_no_active_session"])
                    opnGameLaunchStartStream(self, title: game.title, appId: appId, apiToken: apiToken, accountLinked: accountLinked, selectedStore: selectedStore, returnScreen: returnScreen)
                    return
                }
                _ = OPNSentry.recordCounterMetric(key: "opennow.game.launch.count", value: 1, attributes: ["outcome": "active_session_prompt"])
                let cachedGames = opnGameLaunchGet(self, "cachedGameLibraryObjects", as: [OPNCatalogGameObject].self) ?? []
                let sessionTitle = opnGameLaunchTitleForActiveSession(appId: activeSession.appId, games: cachedGames)
                self.showActiveSessionPrompt(sessionTitle: sessionTitle, selectedGameTitle: game.title.isEmpty ? "Selected Game" : game.title) {
                    opnGameLaunchStartStream(self, title: sessionTitle.isEmpty ? "Current Stream" : sessionTitle, appId: activeSession.appId > 0 ? String(activeSession.appId) : appId, apiToken: apiToken, accountLinked: true, selectedStore: "", returnScreen: returnScreen, resumeSessionId: activeSession.sessionId, resumeServer: activeSession.serverIp)
                } deleteHandler: {
                    self.showAuthenticating(message: "Deleting existing session...")
                    OPNActiveSessionService.stopSession(accessToken: apiToken, sessionId: activeSession.sessionId, serverIp: activeSession.serverIp) { stopOK, stopError in
                        Task { @MainActor in
                            guard let self = selfBox.value else { return }
                            if !stopOK { opnGameLaunchShowError(self, message: stopError.isEmpty ? "Unable to delete the existing session." : stopError, canRetry: true); return }
                            opnGameLaunchStartStream(self, title: gameBox.value.title, appId: appId, apiToken: apiToken, accountLinked: accountLinked, selectedStore: selectedStore, returnScreen: returnScreen)
                        }
                    }
                }
            }
        }
    }

    private func presentOwnershipRemediationIfNeeded(game: OPNCatalogGameObject, variantIndex: Int32, accountLinked: Bool, continueHandler: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard let variant = opnGameLaunchVariant(game, variantIndex) else { return false }
        if game.playType == "INSTALL_TO_PLAY" {
            let alert = NSAlert()
            alert.messageText = "Install Required"
            alert.informativeText = "This game must be installed or prepared through the selected store before GeForce NOW can launch it."
            alert.addButton(withTitle: "Open Store")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: opnGameLaunchGet(self, "window", as: NSWindow.self)!) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                self.openPurchaseURL("", for: game, variantIndex: variantIndex)
            }
            return true
        }
        let selfBox = OPNGameLaunchWeakObject(self)
        let gameBox = OPNGameLaunchSendableValue(game)
        let variantBox = OPNGameLaunchSendableValue(variant)
        OPNGameServiceSwiftAdapter.fetchStoreDefinitionDictionaries { definitionsOK, definitionDictionaries, definitionsError in
            let definitionBox = OPNGameLaunchSendableValue(definitionDictionaries)
            Task { @MainActor in
                if !definitionsOK { OPNSentry.logErrorMessage("[AppDelegate] Store definitions unavailable for ownership flow: \(definitionsError)") }
                OPNGameServiceSwiftAdapter.fetchUserAccountDictionary { accountOK, accountDictionary, accountError in
                    let accountBox = OPNGameLaunchSendableValue(accountDictionary)
                    Task { @MainActor in
                        guard let self = selfBox.value else { return }
                        let game = gameBox.value
                        let variant = variantBox.value
                        if !accountOK { OPNSentry.logErrorMessage("[AppDelegate] User account unavailable for ownership flow: \(accountError)") }
                        let definitions = definitionsOK ? opnGameLaunchParseStoreDefinitions(definitionBox.value) : []
                        let accounts = accountOK ? opnGameLaunchParseStoreAccounts(accountBox.value) : []
                        let autoStores = opnGameLaunchVariantOwned(variant) ? [] : opnGameLaunchAutoResyncStores(game: game, definitions: definitions, accounts: accounts)
                        if !autoStores.isEmpty { self.autoResyncOwnership(game: game, variantIndex: variantIndex, stores: autoStores, definitions: definitions, retryingAuth: false, continueHandler: continueHandler); return }
                        self.presentOwnershipOptions(game: game, variantIndex: variantIndex, definitions: definitions, accounts: accounts, continueHandler: continueHandler)
                    }
                }
            }
        }
        return true
    }

    private func presentOwnershipOptions(game: OPNCatalogGameObject, variantIndex: Int32, definitions: [OPNGameLaunchStoreDefinition], accounts: [OPNGameLaunchStoreAccount], continueHandler: @escaping @MainActor (Bool) -> Void) {
        guard let variant = opnGameLaunchVariant(game, variantIndex) else { return }
        let storeName = opnGameLaunchStoreDisplayName(variant.appStore)
        let definition = opnGameLaunchStoreDefinition(definitions, store: variant.appStore)
        let connected = opnGameLaunchStoreAccount(accounts, store: variant.appStore) != nil
        let selectedOwned = opnGameLaunchVariantOwned(variant)
        let ownedVariantIndex = opnGameLaunchFirstOwnedVariantIndex(game, excluded: variantIndex)
        let gameOwnedOnDifferentVariant = !selectedOwned && (ownedVariantIndex >= 0 || game.isInLibrary)
        let variantSupported = opnGameLaunchDefinitionSupportsVariant(definition, variantId: variant.id)
        let linkingSupported = variantSupported && (definition?.features.contains("AccountLinkingSso") == true || definition?.linkingSupported == true)
        let syncSupported = variantSupported && definition?.features.contains("AccountGamesSyncing") == true
        let requiredLinkMissing = selectedOwned && linkingSupported && definition?.linkingRequired == true && !connected
        if selectedOwned && !requiredLinkMissing { continueHandler(true); return }

        let alert = NSAlert()
        var actions: [String] = []
        alert.messageText = requiredLinkMissing ? "Link Store Account" : (gameOwnedOnDifferentVariant ? "Selected Store Not Owned" : (connected && syncSupported ? "Sync Store Library" : "Add Game to Library"))
        if gameOwnedOnDifferentVariant {
            alert.informativeText = "You own \(game.title) on another store, but the selected \(storeName) version is not marked as owned in your GeForce NOW library."
            if ownedVariantIndex >= 0 { alert.addButton(withTitle: "Launch Owned Version"); actions.append("launchOwned") }
            if connected && syncSupported { alert.addButton(withTitle: "Sync Selected Store"); actions.append("sync") }
            else if !connected && linkingSupported { alert.addButton(withTitle: "Link Selected Store"); actions.append("link") }
        } else if requiredLinkMissing {
            alert.informativeText = "\(game.title) requires a linked \(storeName) account before GeForce NOW can launch it."
            alert.addButton(withTitle: "Link Account"); actions.append("link")
        } else if !connected && linkingSupported {
            alert.informativeText = "\(game.title) is not marked as owned for \(storeName). Link your \(storeName) account, then OpenNOW will ask GeForce NOW to sync your library."
            alert.addButton(withTitle: "Link Account"); actions.append("link")
        } else if connected && syncSupported {
            alert.informativeText = "\(game.title) is not marked as owned for \(storeName). Sync your \(storeName) library through GeForce NOW to refresh ownership."
            alert.addButton(withTitle: "Sync Library"); actions.append("sync")
        } else {
            alert.informativeText = "\(game.title) is not marked as owned in your GeForce NOW library for \(storeName). Mark it as owned through GeForce NOW or open the store to purchase or claim it."
        }
        if !requiredLinkMissing { alert.addButton(withTitle: "Mark as Owned"); actions.append("markOwned") }
        alert.addButton(withTitle: "Open Store"); actions.append("openStore")
        alert.addButton(withTitle: "Cancel"); actions.append("cancel")
        alert.beginSheetModal(for: opnGameLaunchGet(self, "window", as: NSWindow.self)!) { [weak self] response in
            guard let self else { return }
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard index >= 0, index < actions.count else { return }
            switch actions[index] {
            case "launchOwned": self.launchGameObject(game, variantIndex: ownedVariantIndex, returnScreen: Int32(opnGameLaunchInt(self, "currentScreen")))
            case "link": self.linkAccount(game: game, variantIndex: variantIndex, store: variant.appStore, syncAfterLink: !requiredLinkMissing, retryingAuth: false, continueHandler: continueHandler)
            case "sync": self.syncOwnership(game: game, variantIndex: variantIndex, store: variant.appStore, retryingAuth: false, continueHandler: continueHandler)
            case "markOwned": self.markVariantOwned(game: game, variantIndex: variantIndex, continueHandler: continueHandler)
            case "openStore": self.openPurchaseURL("", for: game, variantIndex: variantIndex)
            default: break
            }
        }
    }

    private func autoResyncOwnership(game: OPNCatalogGameObject, variantIndex: Int32, stores: [String], definitions: [OPNGameLaunchStoreDefinition], retryingAuth: Bool, continueHandler: @escaping @MainActor (Bool) -> Void) {
        let storeListName = opnGameLaunchStoreListName(stores)
        showOwnershipSyncProgress(gameTitle: game.title, storeName: storeListName)
        updateOwnershipSyncProgressTitle("Checking Connected Libraries")
        updateOwnershipSyncProgressMessage("\(retryingAuth ? "Retrying" : "Asking") GeForce NOW to sync \(storeListName) before showing ownership options.")
        let selfBox = OPNGameLaunchWeakObject(self)
        let gameBox = OPNGameLaunchSendableValue(game)
        fetchAccountAndSyncBaselines(stores: stores) { baselines in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                self.updateOwnershipSyncProgressFooter("Sending sync requests to GeForce NOW...")
                self.syncStores(stores, retryingAuth: retryingAuth) { anyAccepted, unauthorized, firstError in
                    Task { @MainActor in
                        guard let self = selfBox.value else { return }
                        if unauthorized && !retryingAuth {
                            self.updateOwnershipSyncProgressMessage("Refreshing your GeForce NOW sign-in, then retrying connected-library sync...")
                            self.refreshOwnershipAuth { _ in Task { @MainActor in
                                guard let self = selfBox.value else { return }
                                self.autoResyncOwnership(game: gameBox.value, variantIndex: variantIndex, stores: stores, definitions: definitions, retryingAuth: true, continueHandler: continueHandler)
                            } }
                            return
                        }
                        guard anyAccepted else {
                            if !firstError.isEmpty { OPNSentry.logErrorMessage("[AppDelegate] Auto-resync could not start for any connected store: \(firstError)") }
                            self.dismissOwnershipSyncProgress()
                            OPNGameServiceSwiftAdapter.fetchUserAccountDictionary { ok, dictionary, _ in
                                let dictionaryBox = OPNGameLaunchSendableValue(dictionary)
                                Task { @MainActor in
                                    guard let self = selfBox.value else { return }
                                    self.presentOwnershipOptions(game: gameBox.value, variantIndex: variantIndex, definitions: definitions, accounts: ok ? opnGameLaunchParseStoreAccounts(dictionaryBox.value) : [], continueHandler: continueHandler)
                                }
                            }
                            return
                        }
                        self.updateOwnershipSyncProgressMessage("GeForce NOW accepted connected-library sync. Monitoring refreshed library data...")
                        self.monitorAutoResyncOwnership(game: gameBox.value, variantIndex: variantIndex, stores: stores, baselines: baselines, deadlineAt: Date(timeIntervalSinceNow: 15.0), attempt: 0, continueHandler: continueHandler) {
                            self.dismissOwnershipSyncProgress()
                            OPNGameServiceSwiftAdapter.fetchUserAccountDictionary { ok, dictionary, _ in
                                let dictionaryBox = OPNGameLaunchSendableValue(dictionary)
                                Task { @MainActor in
                                    guard let self = selfBox.value else { return }
                                    self.presentOwnershipOptions(game: gameBox.value, variantIndex: variantIndex, definitions: definitions, accounts: ok ? opnGameLaunchParseStoreAccounts(dictionaryBox.value) : [], continueHandler: continueHandler)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func fetchAccountAndSyncBaselines(stores: [String], completion: @escaping @Sendable ([String: OPNGameLaunchSyncObservation]) -> Void) {
        OPNGameServiceSwiftAdapter.fetchUserAccountDictionary { ok, dictionary, error in
            if !ok { OPNSentry.logErrorMessage("[AppDelegate] User account unavailable before sync baseline: \(error)") }
            let accounts = ok ? opnGameLaunchParseStoreAccounts(dictionary) : []
            var baselines: [String: OPNGameLaunchSyncObservation] = [:]
            for store in stores { baselines[store.lowercased()] = opnGameLaunchStoreAccount(accounts, store: store)?.syncObservation ?? OPNGameLaunchSyncObservation() }
            completion(baselines)
        }
    }

    private func syncStores(_ stores: [String], retryingAuth: Bool, completion: @escaping @Sendable (Bool, Bool, String) -> Void) {
        let group = DispatchGroup()
        let state = OPNGameLaunchSyncRequestState()
        for store in stores {
            group.enter()
            OPNGameServiceSwiftAdapter.syncAccountProvider(store: store) { success, error in
                state.record(success: success, store: store, error: error)
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let snapshot = state.snapshot
            completion(snapshot.0, snapshot.1, snapshot.2)
        }
    }

    private func monitorAutoResyncOwnership(game: OPNCatalogGameObject, variantIndex: Int32, stores: [String], baselines: [String: OPNGameLaunchSyncObservation], deadlineAt: Date, attempt: Int, continueHandler: @escaping @MainActor (Bool) -> Void, fallbackHandler: @escaping @MainActor () -> Void) {
        updateOwnershipSyncProgressMessage("Checking connected libraries after \(opnGameLaunchStoreListName(stores)) sync... (\(max(1, attempt + 1)))")
        updateOwnershipSyncProgressFooter(opnGameLaunchRemainingFooter(deadlineAt))
        let selfBox = OPNGameLaunchWeakObject(self)
        let gameBox = OPNGameLaunchSendableValue(game)
        OPNGameServiceSwiftAdapter.fetchUserAccountDictionary { accountOK, dictionary, error in
            let dictionaryBox = OPNGameLaunchSendableValue(dictionary)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                let game = gameBox.value
                let accounts = accountOK ? opnGameLaunchParseStoreAccounts(dictionaryBox.value) : []
                if !accountOK { OPNSentry.logErrorMessage("[AppDelegate] User account unavailable while monitoring auto-resync: \(error)") }
                var freshFailure = ""
                for store in stores {
                    let current = opnGameLaunchStoreAccount(accounts, store: store)?.syncObservation ?? OPNGameLaunchSyncObservation()
                    let baseline = baselines[store.lowercased()] ?? OPNGameLaunchSyncObservation()
                    if opnGameLaunchSyncChanged(current, baseline), opnGameLaunchSyncFailed(current.syncState), freshFailure.isEmpty { freshFailure = opnGameLaunchSyncFailureMessage(current.syncState, storeName: opnGameLaunchStoreDisplayName(store)) }
                }
                let freshFailureBox = OPNGameLaunchSendableValue(freshFailure)
                self.refreshLibraryAfterOwnershipChange(game: game, variantIndex: variantIndex, requireGame: true) { owned in
                    Task { @MainActor in
                        guard let self = selfBox.value else { return }
                        let freshFailure = freshFailureBox.value
                        if owned { self.dismissOwnershipSyncProgress(); continueHandler(true); return }
                        if !freshFailure.isEmpty { fallbackHandler(); return }
                        if deadlineAt.timeIntervalSinceNow <= 0.0 { fallbackHandler(); return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            guard let self = selfBox.value else { return }
                            self.monitorAutoResyncOwnership(game: gameBox.value, variantIndex: variantIndex, stores: stores, baselines: baselines, deadlineAt: deadlineAt, attempt: attempt + 1, continueHandler: continueHandler, fallbackHandler: fallbackHandler)
                        }
                    }
                }
            }
        }
    }

    private func markVariantOwned(game: OPNCatalogGameObject, variantIndex: Int32, continueHandler: @escaping @MainActor (Bool) -> Void) {
        guard let variant = opnGameLaunchVariant(game, variantIndex), !variant.id.isEmpty else { NSSound.beep(); return }
        let selfBox = OPNGameLaunchWeakObject(self)
        let gameBox = OPNGameLaunchSendableValue(game)
        let variantId = variant.id
        OPNGameServiceSwiftAdapter.addOwnedVariant(variantId) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                guard success else { self.showSimpleAlert(title: "Unable to Mark as Owned", message: error.isEmpty ? "GeForce NOW did not accept the ownership update." : error); return }
                OPNGameServiceSwiftAdapter.selectOwnedVariant(variantId) { selectOK, selectError in
                    if !selectOK { OPNSentry.logErrorMessage("[AppDelegate] selectOwnedVariant failed after addOwnedVariant: \(selectError)") }
                    Task { @MainActor in
                        guard let self = selfBox.value else { return }
                        self.refreshLibraryAfterOwnershipChange(game: gameBox.value, variantIndex: variantIndex, requireGame: false) { _ in Task { @MainActor in continueHandler(true) } }
                    }
                }
            }
        }
    }

    @objc(markVariantUnownedForGameObject:variantIndex:)
    func markVariantUnowned(game: OPNCatalogGameObject, variantIndex: Int32) {
        guard let variant = opnGameLaunchVariant(game, variantIndex), !variant.id.isEmpty, opnGameLaunchVariantOwned(variant) else { NSSound.beep(); return }
        let storeName = opnGameLaunchStoreDisplayName(variant.appStore)
        let alert = NSAlert()
        alert.messageText = "Mark Store Version as Unowned?"
        alert.informativeText = "This removes the \(storeName) version of \(game.title) from your GeForce NOW library. You can add it again later by syncing your library or marking it as owned."
        alert.addButton(withTitle: "Mark as Unowned")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: opnGameLaunchGet(self, "window", as: NSWindow.self)!) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let selfBox = OPNGameLaunchWeakObject(self)
            let gameBox = OPNGameLaunchSendableValue(game)
            let variantId = variant.id
            self.showOwnershipSyncProgress(gameTitle: game.title, storeName: storeName)
            self.updateOwnershipSyncProgressTitle("Updating GeForce NOW Library")
            self.updateOwnershipSyncProgressMessage("Asking GeForce NOW to mark the \(storeName) version as unowned.")
            self.updateOwnershipSyncProgressFooter("Refreshing library data after the update.")
            OPNGameServiceSwiftAdapter.removeOwnedVariant(variantId) { success, error in
                Task { @MainActor in
                    guard let self = selfBox.value else { return }
                    let alreadyUnowned = !success && OPNAppDelegateSupport.notFoundError(error)
                    guard success || alreadyUnowned else { self.dismissOwnershipSyncProgress(); self.showSimpleAlert(title: "Unable to Mark as Unowned", message: error.isEmpty ? "GeForce NOW did not accept the ownership update." : error); return }
                    self.updateOwnershipSyncProgressMessage("\(storeName) was updated. Refreshing your GeForce NOW library...")
                    self.refreshLibraryAfterOwnershipChange(game: gameBox.value, variantIndex: variantIndex, requireGame: false) { _ in Task { @MainActor in
                        guard let self = selfBox.value else { return }
                        self.dismissOwnershipSyncProgress()
                    } }
                }
            }
        }
    }

    private func syncOwnership(game: OPNCatalogGameObject, variantIndex: Int32, store: String, retryingAuth: Bool, continueHandler: @escaping @MainActor (Bool) -> Void) {
        let storeName = opnGameLaunchStoreDisplayName(store)
        showOwnershipSyncProgress(gameTitle: game.title, storeName: storeName)
        if retryingAuth { updateOwnershipSyncProgressMessage("Retrying \(storeName) sync with a refreshed GeForce NOW session.") }
        updateOwnershipSyncProgressFooter("Reading current store sync state...")
        let selfBox = OPNGameLaunchWeakObject(self)
        let gameBox = OPNGameLaunchSendableValue(game)
        fetchAccountAndSyncBaselines(stores: [store]) { baselines in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                self.updateOwnershipSyncProgressFooter("Sending sync request to GeForce NOW...")
                if !retryingAuth { self.updateOwnershipSyncProgressMessage("Asking GeForce NOW to sync \(storeName) library ownership.") }
                OPNGameServiceSwiftAdapter.syncAccountProvider(store: store) { success, error in
                    Task { @MainActor in
                        guard let self = selfBox.value else { return }
                        let game = gameBox.value
                        if !success {
                            if !retryingAuth, OPNAppDelegateSupport.unauthorizedError(error) {
                                self.updateOwnershipSyncProgressMessage("Refreshing your GeForce NOW sign-in, then retrying sync...")
                                self.refreshOwnershipAuth { _ in Task { @MainActor in
                                    guard let self = selfBox.value else { return }
                                    self.syncOwnership(game: gameBox.value, variantIndex: variantIndex, store: store, retryingAuth: true, continueHandler: continueHandler)
                                } }
                                return
                            }
                            self.dismissOwnershipSyncProgress()
                            self.showOwnershipFailureOptions(title: "Library Sync Failed", message: error.isEmpty ? "GeForce NOW could not start the store library sync." : error, game: game, variantIndex: variantIndex, continueHandler: continueHandler)
                            return
                        }
                        self.updateOwnershipSyncProgressMessage("GeForce NOW accepted the sync. Monitoring store sync status...")
                        self.monitorOwnershipSync(game: game, variantIndex: variantIndex, store: store, baseline: baselines[store.lowercased()] ?? OPNGameLaunchSyncObservation(), deadlineAt: Date(timeIntervalSinceNow: 15.0), attempt: 0) { owned, failure in
                            Task { @MainActor in
                                guard let self = selfBox.value else { return }
                                let game = gameBox.value
                                self.dismissOwnershipSyncProgress()
                                if owned { continueHandler(true); return }
                                self.showOwnershipFailureOptions(title: failure.isEmpty ? "Game Not Found After Sync" : "Library Sync Failed", message: failure.isEmpty ? "GeForce NOW synced \(storeName), but this game still was not reported as owned. You can mark it as owned through GeForce NOW or open the store to check purchase/claim status." : failure, game: game, variantIndex: variantIndex, continueHandler: continueHandler)
                            }
                        }
                    }
                }
            }
        }
    }

    private func monitorOwnershipSync(game: OPNCatalogGameObject, variantIndex: Int32, store: String, baseline: OPNGameLaunchSyncObservation, deadlineAt: Date, attempt: Int, completion: @escaping @Sendable (Bool, String) -> Void) {
        let storeName = opnGameLaunchStoreDisplayName(store)
        updateOwnershipSyncProgressMessage("Waiting for \(storeName) to update your GeForce NOW library...")
        updateOwnershipSyncProgressFooter(opnGameLaunchRemainingFooter(deadlineAt))
        let selfBox = OPNGameLaunchWeakObject(self)
        let gameBox = OPNGameLaunchSendableValue(game)
        OPNGameServiceSwiftAdapter.fetchUserAccountDictionary { accountOK, dictionary, error in
            let dictionaryBox = OPNGameLaunchSendableValue(dictionary)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                let game = gameBox.value
                if !accountOK { OPNSentry.logErrorMessage("[AppDelegate] User account unavailable while monitoring sync: \(error)") }
                let current = accountOK ? (opnGameLaunchStoreAccount(opnGameLaunchParseStoreAccounts(dictionaryBox.value), store: store)?.syncObservation ?? OPNGameLaunchSyncObservation()) : OPNGameLaunchSyncObservation()
                self.updateOwnershipSyncProgressMessage(opnGameLaunchProgressMessage(current: current, baseline: baseline, storeName: storeName, deadlineAt: deadlineAt, attempt: attempt))
                self.updateOwnershipSyncProgressFooter(opnGameLaunchRemainingFooter(deadlineAt))
                self.refreshLibraryAfterOwnershipChange(game: game, variantIndex: variantIndex, requireGame: true) { owned in
                    if owned { completion(true, ""); return }
                    if opnGameLaunchSyncChanged(current, baseline), opnGameLaunchSyncFailed(current.syncState) { completion(false, opnGameLaunchSyncFailureMessage(current.syncState, storeName: storeName)); return }
                    if deadlineAt.timeIntervalSinceNow <= 0.0 { completion(false, opnGameLaunchSyncChanged(current, baseline) && !opnGameLaunchSyncSucceeded(current.syncState) ? opnGameLaunchSyncFailureMessage(current.syncState, storeName: storeName) : ""); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        guard let self = selfBox.value else { return }
                        self.monitorOwnershipSync(game: gameBox.value, variantIndex: variantIndex, store: store, baseline: baseline, deadlineAt: deadlineAt, attempt: attempt + 1, completion: completion)
                    }
                }
            }
        }
    }

    private func linkAccount(game: OPNCatalogGameObject, variantIndex: Int32, store: String, syncAfterLink: Bool, retryingAuth: Bool, continueHandler: @escaping @MainActor (Bool) -> Void) {
        let selfBox = OPNGameLaunchWeakObject(self)
        let gameBox = OPNGameLaunchSendableValue(game)
        OPNGameServiceSwiftAdapter.startAccountLinking(store: store) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                let game = gameBox.value
                if !success {
                    if !retryingAuth, OPNAppDelegateSupport.unauthorizedError(error) {
                        self.refreshOwnershipAuth { _ in Task { @MainActor in
                            guard let self = selfBox.value else { return }
                            self.linkAccount(game: gameBox.value, variantIndex: variantIndex, store: store, syncAfterLink: syncAfterLink, retryingAuth: true, continueHandler: continueHandler)
                        } }
                        return
                    }
                    self.showOwnershipFailureOptions(title: "Account Linking Failed", message: error.isEmpty ? "GeForce NOW did not complete account linking." : error, game: game, variantIndex: variantIndex, continueHandler: continueHandler)
                    return
                }
                syncAfterLink ? self.syncOwnership(game: game, variantIndex: variantIndex, store: store, retryingAuth: false, continueHandler: continueHandler) : continueHandler(true)
            }
        }
    }

    private func refreshLibraryAfterOwnershipChange(game: OPNCatalogGameObject, variantIndex: Int32, requireGame: Bool, completion: @escaping @Sendable (Bool) -> Void) {
        let requestedVariant = opnGameLaunchVariant(game, variantIndex)
        let selfBox = OPNGameLaunchWeakObject(self)
        let gameBox = OPNGameLaunchSendableValue(game)
        let requestedVariantBox = OPNGameLaunchSendableValue(requestedVariant)
        OPNGameServiceSwiftAdapter.fetchLibraryGameObjects { success, games, _ in
            let gamesBox = OPNGameLaunchSendableValue(games)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                let game = gameBox.value
                let requestedVariant = requestedVariantBox.value
                var owned = false
                if success {
                    let games = gamesBox.value
                    let accountIdentifier = OPNAppDelegateSupport.authSessionIdentifier(opnGameLaunchGet(self, "currentSession", as: OPNAuthSessionObject.self))
                    if let delegate = self as? OPNAppDelegateLegacy {
                        delegate.cachedGameLibraryObjects = games
                        delegate.cachedGameLibraryFingerprint = opnGameLaunchLibraryFingerprint(games)
                        delegate.cachedGameLibraryAccountIdentifier = accountIdentifier
                        delegate.hasCachedGameLibrary = true
                    }
                    if opnGameLaunchInt(self, "currentScreen") == OPNGameLaunchScreen.catalog.rawValue, let catalog = opnGameLaunchGet(self, "catalogView", as: OPNGameCatalogView.self) { catalog.setGameObjects(games) }
                    else if opnGameLaunchInt(self, "currentScreen") == OPNGameLaunchScreen.store.rawValue, let store = opnGameLaunchGet(self, "storeView", as: OPNGameCatalogView.self) { store.setLibraryGameObjects(games) }
                    owned = opnGameLaunchLibraryContainsOwnedVariant(games, requestedGame: game, requestedVariant: requestedVariant)
                }
                completion(requireGame ? owned : true)
            }
        }
    }

    private func showOwnershipFailureOptions(title: String, message: String, game: OPNCatalogGameObject, variantIndex: Int32, continueHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Mark as Owned")
        alert.addButton(withTitle: "Open Store")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: opnGameLaunchGet(self, "window", as: NSWindow.self)!) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { self.markVariantOwned(game: game, variantIndex: variantIndex, continueHandler: continueHandler) }
            if response == .alertSecondButtonReturn { self.openPurchaseURL("", for: game, variantIndex: variantIndex) }
        }
    }

    private func showSimpleAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: opnGameLaunchGet(self, "window", as: NSWindow.self)!, completionHandler: nil)
    }

    @objc(openPurchaseURL:forGameObject:variantIndex:)
    func openPurchaseURL(_ purchaseURL: String?, for game: OPNCatalogGameObject, variantIndex: Int32) {
        let trimmed = (purchaseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let selfBox = OPNGameLaunchWeakObject(self)
            let gameBox = OPNGameLaunchSendableValue(game)
            OPNGameServiceSwiftAdapter.resolveStoreURL(game: game, variantIndex: Int(variantIndex)) { success, storeURL, error in
                Task { @MainActor in
                    guard let self = selfBox.value else { return }
                    let game = gameBox.value
                    guard success, !storeURL.isEmpty else {
                        OPNSentry.logErrorMessage("[AppDelegate] Store URL resolution failed for title=\(game.title), id=\(game.id), variantIndex=\(variantIndex), error=\(error)")
                        NSSound.beep()
                        return
                    }
                    self.openPurchaseURL(storeURL, for: game, variantIndex: variantIndex)
                }
            }
            return
        }
        guard let url = URL(string: trimmed), url.scheme?.isEmpty == false, url.host?.isEmpty == false else {
            OPNSentry.logErrorMessage("[AppDelegate] Invalid purchase URL for title=\(game.title), id=\(game.id), variantIndex=\(variantIndex), url=\(trimmed)")
            NSSound.beep()
            return
        }
        OPNSentry.logInfoMessage("[AppDelegate] Opening purchase URL for title=\(game.title), id=\(game.id), variantIndex=\(variantIndex)")
        if !NSWorkspace.shared.open(url) {
            OPNSentry.logErrorMessage("[AppDelegate] Failed to open purchase URL for title=\(game.title), id=\(game.id), variantIndex=\(variantIndex)")
            NSSound.beep()
        }
    }
}
