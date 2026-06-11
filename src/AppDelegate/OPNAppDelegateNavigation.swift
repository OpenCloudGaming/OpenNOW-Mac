import AppKit
import QuartzCore

private enum OPNNavigationScreen: Int32 {
    case emailEntry = 0
    case authenticating = 1
    case store = 2
    case catalog = 3
    case settings = 4
    case error = 5
    case oauthBrowser = 6
}

private enum OPNNavigationBackdropMode: Int {
    case auth = 0
    case store = 2
    case library = 3
    case settings = 4
}

private final class OPNNavigationWeakObject<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}

private final class OPNNavigationSendableValue<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

private func opnNavGet<T>(_ object: NSObject, _ key: String, as type: T.Type = T.self) -> T? { object.value(forKey: key) as? T }
private func opnNavSet(_ object: NSObject, _ key: String, _ value: Any?) { object.setValue(value, forKey: key) }
private func opnNavBool(_ object: NSObject, _ key: String) -> Bool { (object.value(forKey: key) as? NSNumber)?.boolValue ?? (object.value(forKey: key) as? Bool ?? false) }
private func opnNavInt(_ object: NSObject, _ key: String) -> Int32 { Int32((object.value(forKey: key) as? NSNumber)?.intValue ?? (object.value(forKey: key) as? Int ?? 0)) }

private func opnNavAppendFingerprintField(_ fingerprint: inout String, _ value: String) {
    fingerprint += "\(value.count):\(value)|"
}

private func opnNavFingerprintList(_ values: [String]) -> String {
    var fingerprint = "["
    for value in values.sorted() { opnNavAppendFingerprintField(&fingerprint, value) }
    fingerprint += "]"
    return fingerprint
}

private func opnNavGameLibraryFingerprint(_ games: [OPNCatalogGameObject]) -> String {
    var entries: [String] = []
    entries.reserveCapacity(games.count)
    for game in games {
        var entry = ""
        opnNavAppendFingerprintField(&entry, game.id)
        opnNavAppendFingerprintField(&entry, game.uuid)
        opnNavAppendFingerprintField(&entry, game.launchAppId)
        opnNavAppendFingerprintField(&entry, game.title)
        opnNavAppendFingerprintField(&entry, game.shortName)
        opnNavAppendFingerprintField(&entry, game.playabilityState)
        opnNavAppendFingerprintField(&entry, game.imageUrl)
        opnNavAppendFingerprintField(&entry, opnNavFingerprintList(game.availableStores))
        opnNavAppendFingerprintField(&entry, opnNavFingerprintList(game.genres))
        let variantEntries = game.variants.map { variant in
            var variantEntry = ""
            opnNavAppendFingerprintField(&variantEntry, variant.id)
            opnNavAppendFingerprintField(&variantEntry, variant.appStore)
            opnNavAppendFingerprintField(&variantEntry, variant.storeUrl)
            opnNavAppendFingerprintField(&variantEntry, variant.serviceStatus)
            opnNavAppendFingerprintField(&variantEntry, variant.librarySelected ? "1" : "0")
            opnNavAppendFingerprintField(&variantEntry, variant.inLibrary ? "1" : "0")
            return variantEntry
        }
        opnNavAppendFingerprintField(&entry, opnNavFingerprintList(variantEntries))
        entries.append(entry)
    }
    var fingerprint = ""
    for entry in entries.sorted() { opnNavAppendFingerprintField(&fingerprint, entry) }
    return fingerprint
}

private func opnNavPerform(_ object: NSObject, _ selectorName: String) {
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector) else { return }
    _ = object.perform(selector)
}

private func opnNavLaunchGame(_ object: NSObject, game: OPNCatalogGameObject, variantIndex: Int32, returnScreen: OPNNavigationScreen) {
    let selector = NSSelectorFromString("launchGameObject:variantIndex:returnScreenRaw:")
    guard object.responds(to: selector) else { return }
    typealias Message = @convention(c) (AnyObject, Selector, OPNCatalogGameObject, Int32, Int32) -> Void
    unsafeBitCast(object.method(for: selector), to: Message.self)(object, selector, game, variantIndex, returnScreen.rawValue)
}

private func opnNavOpenPurchaseURL(_ object: NSObject, purchaseURL: String, game: OPNCatalogGameObject, variantIndex: Int32) {
    let selector = NSSelectorFromString("openPurchaseURL:forGameObject:variantIndex:")
    guard object.responds(to: selector) else { return }
    typealias Message = @convention(c) (AnyObject, Selector, NSString, OPNCatalogGameObject, Int32) -> Void
    unsafeBitCast(object.method(for: selector), to: Message.self)(object, selector, purchaseURL as NSString, game, variantIndex)
}

private func opnNavMarkVariantUnowned(_ object: NSObject, game: OPNCatalogGameObject, variantIndex: Int32) {
    let selector = NSSelectorFromString("markVariantUnownedForGameObject:variantIndex:")
    guard object.responds(to: selector) else { return }
    typealias Message = @convention(c) (AnyObject, Selector, OPNCatalogGameObject, Int32) -> Void
    unsafeBitCast(object.method(for: selector), to: Message.self)(object, selector, game, variantIndex)
}

@MainActor private func opnNavConfigureLibraryWindow(_ window: NSWindow?) {
    guard let window else { return }
    window.styleMask.insert([.resizable, .fullSizeContentView])
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.minSize = NSSize(width: 960.0, height: 540.0)
    window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    window.contentMinSize = NSSize(width: 960.0, height: 540.0)
    window.resizeIncrements = NSSize(width: 1.0, height: 1.0)
    window.contentResizeIncrements = NSSize(width: 1.0, height: 1.0)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.standardWindowButton(.closeButton)?.isHidden = false
    window.standardWindowButton(.miniaturizeButton)?.isHidden = false
    window.standardWindowButton(.zoomButton)?.isHidden = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = OPNUIHelpers.color(rgb: 0x101014, alpha: 1.0)
}

@MainActor
extension NSObject {
    @objc func installLibraryRootIfNeeded() {
        guard let window = opnNavGet(self, "window", as: NSWindow.self), let contentView = window.contentView else { return }
        var rootView = opnNavGet(self, "rootView", as: OPNBackdropView.self)
        if rootView == nil || window.contentView !== rootView {
            window.contentViewController = nil
            let root = OPNBackdropView(frame: contentView.bounds)
            root.wantsLayer = true
            root.layer?.isOpaque = false
            root.autoresizingMask = [.width, .height]
            let selfBox = OPNNavigationWeakObject(self)
            root.onHomeSelected = { if let self = selfBox.value { if opnNavInt(self, "currentScreen") != OPNNavigationScreen.catalog.rawValue { self.transitionToScreen(OPNNavigationScreen.catalog.rawValue) }; opnNavGet(self, "rootView", as: OPNBackdropView.self)?.mode = OPNNavigationBackdropMode.library.rawValue } }
            root.onStoreSelected = { if let self = selfBox.value, opnNavInt(self, "currentScreen") != OPNNavigationScreen.store.rawValue { self.transitionToScreen(OPNNavigationScreen.store.rawValue) } }
            root.onLibrarySelected = { if let self = selfBox.value { if opnNavInt(self, "currentScreen") != OPNNavigationScreen.catalog.rawValue { self.transitionToScreen(OPNNavigationScreen.catalog.rawValue) }; opnNavGet(self, "rootView", as: OPNBackdropView.self)?.mode = OPNNavigationBackdropMode.library.rawValue } }
            root.onSearchSelected = { if let self = selfBox.value { if opnNavInt(self, "currentScreen") != OPNNavigationScreen.catalog.rawValue { self.transitionToScreen(OPNNavigationScreen.catalog.rawValue) }; opnNavGet(self, "rootView", as: OPNBackdropView.self)?.mode = OPNNavigationBackdropMode.library.rawValue } }
            root.onSettingsSelected = { if let self = selfBox.value, opnNavInt(self, "currentScreen") != OPNNavigationScreen.settings.rawValue { self.transitionToScreen(OPNNavigationScreen.settings.rawValue) } }
            root.onAccountSelected = { identifier in selfBox.value?.switchToAccountIdentifier(identifier) }
            root.onAddAccountSelected = { selfBox.value?.addAccount() }
            root.onSignOutSelected = { selfBox.value?.performServerLogout() }
            root.onExitSelected = { NSApp.terminate(nil) }
            window.contentView = root
            OPNUIHelpers.disableFocusHighlights(root)
            opnNavSet(self, "rootView", root)
            rootView = root
        }

        guard let rootView else { return }
        if opnNavGet(self, "contentContainer", as: NSView.self)?.superview !== rootView {
            let container = NSView(frame: rootView.bounds)
            container.wantsLayer = true
            container.layer?.isOpaque = false
            container.layer?.backgroundColor = NSColor.clear.cgColor
            container.autoresizingMask = [.width, .height]
            rootView.addSubview(container)
            opnNavSet(self, "contentContainer", container)
        }
        opnNavPerform(self, "installDesktopTopChromeIfNeeded")
        opnNavPerform(self, "installDesktopAccountSwitcherIfNeeded")
        opnNavPerform(self, "installDesktopSettingsPillIfNeeded")
    }

    @objc func configureContentContainerForScreen(_ screen: Int32) {
        if let root = opnNavGet(self, "rootView", as: OPNBackdropView.self) {
            if screen == OPNNavigationScreen.store.rawValue { root.mode = OPNNavigationBackdropMode.store.rawValue }
            else if screen == OPNNavigationScreen.catalog.rawValue { root.mode = OPNNavigationBackdropMode.library.rawValue }
            else if screen == OPNNavigationScreen.settings.rawValue { root.mode = OPNNavigationBackdropMode.settings.rawValue }
            else { root.mode = OPNNavigationBackdropMode.auth.rawValue }
        }
        guard let root = opnNavGet(self, "rootView", as: OPNBackdropView.self), let container = opnNavGet(self, "contentContainer", as: NSView.self) else { return }
        container.frame = root.bounds
        container.autoresizingMask = [.width, .height]
        opnNavPerform(self, "updateDesktopTopChrome")
        opnNavPerform(self, "updateDesktopSettingsPill")
    }

    @objc func completeContentTransition(fromSubviews previousSubviews: [NSView], to view: NSView?, animated: Bool, forward: Bool) {
        guard let view, let container = opnNavGet(self, "contentContainer", as: NSView.self) else { return }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        guard animated, !previousSubviews.isEmpty else {
            view.alphaValue = 1.0
            previousSubviews.filter { $0 !== view }.forEach { $0.removeFromSuperview() }
            return
        }
        let offset: CGFloat = forward ? 22.0 : -22.0
        let finalFrame = container.bounds
        let startingFrame = finalFrame.offsetBy(dx: offset, dy: 0.0)
        let outgoingFrame = finalFrame.offsetBy(dx: -offset * 0.55, dy: 0.0)
        view.wantsLayer = true
        view.alphaValue = 0.0
        view.frame = startingFrame
        previousSubviews.filter { $0 !== view }.forEach { $0.wantsLayer = true; $0.alphaValue = 1.0 }
        let viewBox = OPNNavigationWeakObject(view)
        let previousSubviewsBox = OPNNavigationSendableValue(previousSubviews)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1.0
            view.animator().frame = finalFrame
            previousSubviews.filter { $0 !== view }.forEach { $0.animator().alphaValue = 0.0; $0.animator().frame = outgoingFrame }
        } completionHandler: {
            Task { @MainActor in
            guard let view = viewBox.value else { return }
            let previousSubviews = previousSubviewsBox.value
            view.alphaValue = 1.0
            view.frame = finalFrame
            previousSubviews.filter { $0 !== view }.forEach { $0.alphaValue = 1.0; $0.removeFromSuperview() }
            }
        }
    }

    @objc func transitionToScreen(_ screen: Int32) {
        installLibraryRootIfNeeded()
        let previousScreen = opnNavInt(self, "currentScreen")
        _ = OPNSentry.recordCounterMetric(key: "opennow.ui.screen_transition.count", value: 1, attributes: ["from": OPNAppDelegateSupport.screenName(forScreen: Int(previousScreen)), "to": OPNAppDelegateSupport.screenName(forScreen: Int(screen))])
        guard let container = opnNavGet(self, "contentContainer", as: NSView.self) else { return }
        var previousSubviews = container.subviews
        let animated = (previousScreen == OPNNavigationScreen.settings.rawValue && screen == OPNNavigationScreen.store.rawValue) || (OPNAppDelegateSupport.supportsDesktopNavigation(forScreen: Int(previousScreen)) && screen == OPNNavigationScreen.settings.rawValue)
        let forward = screen == OPNNavigationScreen.settings.rawValue
        configureContentContainerForScreen(screen)
        if !animated {
            previousSubviews.forEach { $0.removeFromSuperview() }
            previousSubviews = []
        }
        opnNavSet(self, "currentScreen", NSNumber(value: screen))
        opnNavPerform(self, "updateDesktopTopChrome")
        opnNavPerform(self, "updateDesktopSettingsPill")
        let bounds = container.bounds

        switch screen {
        case OPNNavigationScreen.emailEntry.rawValue:
            showEmailEntry(in: container, bounds: bounds)
        case OPNNavigationScreen.oauthBrowser.rawValue:
            showAuthenticating(message: "Opening browser for sign in...")
            let selfBox = OPNNavigationWeakObject(self)
            OPNAuthServiceDirect.shared.startOAuthLogin(providerIdpId: opnNavGet(self, "pendingProviderIdpId", as: String.self) ?? "") { success, session, error in
                let sessionBox = OPNNavigationSendableValue(session)
                Task { @MainActor in
                    guard let self = selfBox.value else { return }
                    let session = sessionBox.value
                    if success {
                        _ = OPNSentry.recordCounterMetric(key: "opennow.auth.login.count", value: 1, attributes: ["outcome": "success"])
                        opnNavSet(self, "currentSession", session)
                        if opnNavBool(self, "pendingStayLoggedIn") { OPNAuthServiceDirect.shared.saveSession(session) }
                        self.refreshAccountMenu()
                        self.transitionToStoreAfterProviderSelection(for: session)
                    } else {
                        _ = OPNSentry.recordCounterMetric(key: "opennow.auth.login.count", value: 1, attributes: ["outcome": "failure"])
                        self.showErrorMessage(error, canRetry: true)
                    }
                }
            }
        case OPNNavigationScreen.store.rawValue:
            showStore(in: container, bounds: bounds, previousSubviews: previousSubviews, animated: animated, forward: forward)
        case OPNNavigationScreen.catalog.rawValue:
            showCatalog(in: container, bounds: bounds)
        case OPNNavigationScreen.settings.rawValue:
            showSettings(in: container, bounds: bounds, previousSubviews: previousSubviews, animated: animated, forward: forward)
        default:
            break
        }
    }

    private func showEmailEntry(in container: NSView, bounds: NSRect) {
        let view = OPNEmailEntryView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        let selfBox = OPNNavigationWeakObject(self)
        let viewBox = OPNNavigationWeakObject(view)
        view.onSignInWithBrowser = {
            guard let self = selfBox.value, let signInView = viewBox.value else { return }
            let selected = signInView.selectedProviderIdentifier()
            opnNavSet(self, "pendingProviderIdpId", selected.isEmpty ? "PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg" : selected)
            opnNavSet(self, "pendingStayLoggedIn", OPNAuthServiceDirect.shared.getStayLoggedIn())
            self.transitionToScreen(OPNNavigationScreen.oauthBrowser.rawValue)
        }
        OPNGameServiceSwiftAdapter.fetchProviderInfo(idpId: opnNavGet(self, "pendingProviderIdpId", as: String.self) ?? "") { success, providerInfo, selectedEndpoint, _ in
            let providerInfoBox = OPNNavigationSendableValue(providerInfo)
            let selectedEndpointBox = OPNNavigationSendableValue(selectedEndpoint)
            Task { @MainActor in
                guard let self = selfBox.value, let providerView = viewBox.value, providerView.superview === opnNavGet(self, "contentContainer", as: NSView.self) else { return }
                let providerInfo = providerInfoBox.value
                let selectedEndpoint = selectedEndpointBox.value
                var ids: [String] = []
                var labels: [String] = []
                for provider in providerInfo.endpoints where !provider.idpId.isEmpty {
                    ids.append(provider.idpId)
                    labels.append(provider.loginProviderCode == "BPC" ? "bro.game" : (provider.loginProviderDisplayName.isEmpty ? (provider.loginProviderCode.isEmpty ? "NVIDIA" : provider.loginProviderCode) : provider.loginProviderDisplayName))
                }
                if ids.isEmpty { ids = ["PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg"]; labels = ["NVIDIA"] }
                let selected = selectedEndpoint.idpId.isEmpty ? (opnNavGet(self, "pendingProviderIdpId", as: String.self) ?? "") : selectedEndpoint.idpId
                providerView.setProviderItems(ids: ids, labels: labels, selectedId: selected.isEmpty ? "PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg" : selected)
                if !success { OPNSentry.logErrorMessage("[AppDelegate] Provider discovery failed; using NVIDIA default for login") }
            }
        }
        container.addSubview(view)
        OPNUIHelpers.disableFocusHighlights(view)
        opnNavGet(self, "window", as: NSWindow.self)?.title = "OpenNOW"
    }

    private func showStore(in container: NSView, bounds: NSRect, previousSubviews: [NSView], animated: Bool, forward: Bool) {
        OPNDiscordPresence.updateBrowsing()
        opnNavConfigureLibraryWindow(opnNavGet(self, "window", as: NSWindow.self))
        opnNavSet(self, "catalogView", nil)
        let restoring = opnNavGet(self, "storeView", as: OPNGameCatalogView.self) != nil
        updateAccountChrome()
        let store = opnNavGet(self, "storeView", as: OPNGameCatalogView.self) ?? OPNGameCatalogView(frame: bounds)
        store.frame = bounds
        store.autoresizingMask = [.width, .height]
        opnNavSet(self, "storeView", store)
        if !restoring { configureStoreCallbacks(store) }
        container.addSubview(store)
        completeContentTransition(fromSubviews: previousSubviews, to: store, animated: animated, forward: forward)
        OPNUIHelpers.disableFocusHighlights(store)
        opnNavGet(self, "window", as: NSWindow.self)?.title = "OpenNOW - Store"
        DispatchQueue.main.async { [weak store, weak self] in
            guard let self, let store, opnNavInt(self, "currentScreen") == OPNNavigationScreen.store.rawValue, opnNavGet(self, "storeView", as: OPNGameCatalogView.self) === store else { return }
            self.loadStoreContent(for: store, refreshOnly: restoring)
        }
    }

    private func configureStoreCallbacks(_ store: OPNGameCatalogView) {
        let selfBox = OPNNavigationWeakObject(self)
        store.onSelectGame = { game, variantIndex in if let self = selfBox.value { opnNavLaunchGame(self, game: game, variantIndex: variantIndex, returnScreen: .store) } }
        store.onBuyGame = { game, variantIndex, purchaseURL in if let self = selfBox.value { opnNavOpenPurchaseURL(self, purchaseURL: purchaseURL, game: game, variantIndex: variantIndex) } }
        store.onMarkGameUnowned = { game, variantIndex in if let self = selfBox.value { opnNavMarkVariantUnowned(self, game: game, variantIndex: variantIndex) } }
        store.onBackRequested = { selfBox.value?.transitionToScreen(OPNNavigationScreen.store.rawValue) }
    }

    private func loadStoreContent(for store: OPNGameCatalogView, refreshOnly: Bool) {
        guard opnNavGet(self, "storeView", as: OPNGameCatalogView.self) === store else { return }
        guard let delegate = self as? OPNAppDelegateLegacy else { return }
        let accountIdentifier = OPNAppDelegateSupport.authSessionIdentifier(delegate.currentSession)
        if refreshOnly {
            delegate.refreshGameLibraryInBackground()
        } else {
            if delegate.hasCachedFeaturedGames, delegate.cachedFeaturedGamesAccountIdentifier == accountIdentifier {
                store.setFeaturedGameObjects(delegate.cachedFeaturedGameObjects)
            }
            if delegate.hasCachedStorePanels, delegate.cachedStorePanelsAccountIdentifier == accountIdentifier {
                store.setPanelObjects(delegate.cachedStorePanelObjects)
            }
            if delegate.hasCachedGameLibrary, delegate.cachedGameLibraryAccountIdentifier == accountIdentifier {
                store.setLibraryGameObjects(delegate.cachedGameLibraryObjects)
            } else {
                delegate.fetchGameLibrary(canRetry: true) { [weak self] success, games in
                    guard let self, success, OPNAppDelegateSupport.authSessionIdentifier(delegate.currentSession) == accountIdentifier else { return }
                    delegate.cachedGameLibraryObjects = games
                    delegate.cachedGameLibraryFingerprint = opnNavGameLibraryFingerprint(games)
                    delegate.cachedGameLibraryAccountIdentifier = accountIdentifier
                    delegate.hasCachedGameLibrary = true
                    if opnNavGet(self, "storeView", as: OPNGameCatalogView.self) === store {
                        store.setLibraryGameObjects(games)
                    }
                }
            }
            delegate.refreshFeaturedGamesForCatalog(canRetry: true)
            delegate.loadStorePanels(canRetry: true)
        }
    }

    private func showCatalog(in container: NSView, bounds: NSRect) {
        OPNDiscordPresence.updateBrowsing()
        opnNavConfigureLibraryWindow(opnNavGet(self, "window", as: NSWindow.self))
        opnNavSet(self, "storeView", nil)
        opnNavSet(self, "settingsView", nil)
        let catalog = OPNGameCatalogView(frame: bounds)
        catalog.autoresizingMask = [.width, .height]
        opnNavSet(self, "catalogView", catalog)
        configureCatalogCallbacks(catalog)
        updateCatalogAccount(catalog)
        updateAccountChrome()
        container.addSubview(catalog)
        OPNUIHelpers.disableFocusHighlights(catalog)
        opnNavGet(self, "window", as: NSWindow.self)?.title = "OpenNOW"
        if let session = opnNavGet(self, "currentSession", as: OPNAuthSessionObject.self), (session.displayName.isEmpty || OPNAppDelegateSupport.stringLooksLikeEmail(session.displayName)), !session.accessToken.isEmpty {
            catalog.setLoading(true)
            let selfBox = OPNNavigationWeakObject(self)
            let sessionBox = OPNNavigationSendableValue(session)
            OPNAuthServiceDirect.shared.fetchStarFleetUserInfo(accessToken: session.accessToken) { success, info, _ in
                let infoBox = OPNNavigationSendableValue(info)
                Task { @MainActor in
                    guard let self = selfBox.value else { return }
                    let session = sessionBox.value
                    let info = infoBox.value
                    if success, let info, let name = OPNAppDelegateSupport.displayName(fromUserInfo: info) {
                        session.displayName = name
                        if let email = info["email"] as? String, !email.isEmpty { session.email = email }
                        if opnNavBool(self, "pendingStayLoggedIn") { OPNAuthServiceDirect.shared.saveSession(session) }
                        opnNavGet(self, "catalogView", as: OPNGameCatalogView.self)?.setUserName(name)
                        opnNavGet(self, "rootView", as: OPNBackdropView.self)?.accountName = name
                        self.refreshAccountAvatar()
                        self.refreshAccountMenu()
                        self.refreshAccountSummary()
                    }
                    opnNavPerform(self, "loadGamesIntoCatalog")
                }
            }
        } else {
            opnNavPerform(self, "loadGamesIntoCatalog")
        }
    }

    private func configureCatalogCallbacks(_ catalog: OPNGameCatalogView) {
        let selfBox = OPNNavigationWeakObject(self)
        catalog.onSignOut = { selfBox.value?.performServerLogout() }
        catalog.onGameCountChanged = { count in
            guard let self = selfBox.value, let root = opnNavGet(self, "rootView", as: OPNBackdropView.self) else { return }
            root.gameCountText = "\(count) \(count == 1 ? "game" : "games")"
        }
        catalog.onInterfaceSettingsRequested = { selfBox.value?.transitionToScreen(OPNNavigationScreen.settings.rawValue) }
        catalog.onStoreRequested = { selfBox.value?.transitionToScreen(OPNNavigationScreen.store.rawValue) }
        catalog.onExitRequested = { NSApp.terminate(nil) }
        catalog.onRestartRequested = { if let self = selfBox.value { opnNavPerform(self, "restartApplication") } }
        catalog.onSelectGame = { game, variantIndex in if let self = selfBox.value { opnNavLaunchGame(self, game: game, variantIndex: variantIndex, returnScreen: .catalog) } }
        catalog.onMarkGameUnowned = { game, variantIndex in if let self = selfBox.value { opnNavMarkVariantUnowned(self, game: game, variantIndex: variantIndex) } }
        catalog.onCatalogBrowseRequested = { [weak catalog] searchQuery, sortId, filterIds in
            guard let self = selfBox.value, let catalog, opnNavGet(self, "catalogView", as: OPNGameCatalogView.self) === catalog else { return }
            (self as? OPNAppDelegateLegacy)?.browseCatalog(searchQuery: searchQuery, sortId: sortId, filterIds: filterIds, canRetry: true, retryAttempt: 0)
        }
    }

    private func updateCatalogAccount(_ catalog: OPNGameCatalogView) {
        guard let session = opnNavGet(self, "currentSession", as: OPNAuthSessionObject.self) else { return }
        let displayName = session.displayName
        let name = displayName.isEmpty ? OPNAppDelegateSupport.authSessionDisplayName(session) : displayName
        catalog.setUserName(name)
        opnNavGet(self, "rootView", as: OPNBackdropView.self)?.accountName = name
    }

    private func showSettings(in container: NSView, bounds: NSRect, previousSubviews: [NSView], animated: Bool, forward: Bool) {
        opnNavConfigureLibraryWindow(opnNavGet(self, "window", as: NSWindow.self))
        updateAccountChrome()
        let settings = OPNSettingsView(frame: bounds, selectedSectionName: nil)
        settings.autoresizingMask = [.width, .height]
        let selfBox = OPNNavigationWeakObject(self)
        settings.onBackRequested = { selfBox.value?.transitionToScreen(OPNNavigationScreen.store.rawValue) }
        settings.onCheckForUpdatesRequested = { if let self = selfBox.value { opnNavPerform(self, "checkForApplicationUpdates") } }
        opnNavSet(self, "settingsView", settings)
        container.addSubview(settings)
        completeContentTransition(fromSubviews: previousSubviews, to: settings, animated: animated, forward: forward)
        OPNUIHelpers.disableFocusHighlights(settings)
        opnNavGet(self, "window", as: NSWindow.self)?.title = "OpenNOW - Settings"
    }

    private func updateAccountChrome() {
        guard let root = opnNavGet(self, "rootView", as: OPNBackdropView.self), let session = opnNavGet(self, "currentSession", as: OPNAuthSessionObject.self) else { return }
        root.accountName = OPNAppDelegateSupport.authSessionDisplayName(session)
        root.accountStatus = OPNAppDelegateSupport.displayTier(session.membershipTier)
        root.remainingPlayTime = "--"
        root.gameCountText = ""
        opnNavSet(self, "currentRemainingPlayTimeAvailable", false)
        refreshAccountAvatar()
        refreshAccountMenu()
        refreshAccountSummary()
        refreshStreamRegions()
    }

    @objc func refreshAccountSummary() { refreshAccountSummary(retry: true) }

    @objc(refreshAccountSummaryWithRetry:)
    func refreshAccountSummary(retry canRetry: Bool) {
        guard let root = opnNavGet(self, "rootView", as: OPNBackdropView.self), let session = opnNavGet(self, "currentSession", as: OPNAuthSessionObject.self), !session.accessToken.isEmpty else { return }
        root.accountStatus = OPNAppDelegateSupport.displayTier(session.membershipTier)
        OPNGameServiceSwiftAdapter.setAccessToken(OPNAppDelegateSupport.authSessionToken(session))
        let selfBox = OPNNavigationWeakObject(self)
        let sessionBox = OPNNavigationSendableValue(session)
        OPNGameServiceSwiftAdapter.fetchSubscriptionInfo(userId: session.userId) { success, subscription, error in
            let subscriptionBox = OPNNavigationSendableValue(subscription)
            Task { @MainActor in
                guard let self = selfBox.value, let root = opnNavGet(self, "rootView", as: OPNBackdropView.self) else { return }
                let session = sessionBox.value
                let subscription = subscriptionBox.value
                if !success, canRetry, OPNAppDelegateSupport.unauthorizedError(error) {
                    OPNAuthServiceDirect.shared.refreshSession(force: true) { refreshSuccess, freshObject, _ in
                        let freshObjectBox = OPNNavigationSendableValue(freshObject)
                        Task { @MainActor in
                            guard let self = selfBox.value else { return }
                            let freshObject = freshObjectBox.value
                            if refreshSuccess {
                                opnNavSet(self, "currentSession", freshObject)
                                if opnNavBool(self, "pendingStayLoggedIn") { OPNAuthServiceDirect.shared.saveSession(freshObject) }
                                self.refreshAccountMenu()
                                self.refreshAccountSummary(retry: false)
                            } else {
                                OPNSentry.logErrorMessage("[AppDelegate] Subscription token refresh failed after unauthorized response")
                            }
                        }
                    }
                    return
                }
                guard success else { OPNSentry.logErrorMessage("[AppDelegate] Subscription fetch failed: \(error)"); return }
                root.accountStatus = OPNAppDelegateSupport.displayTier(subscription.membershipTier)
                root.remainingPlayTime = OPNAppDelegateSupport.formatRemainingPlayTime(forSubscription: subscription)
                opnNavSet(self, "currentRemainingPlayTimeHours", subscription.remainingHours)
                opnNavSet(self, "currentRemainingPlayTimeUnlimited", subscription.isUnlimited)
                opnNavSet(self, "currentRemainingPlayTimeAvailable", true)
                opnNavPerform(self, "updateDesktopAccountSwitcher")
                session.membershipTier = subscription.membershipTier
                if OPNAuthServiceDirect.shared.getStayLoggedIn() { OPNAuthServiceDirect.shared.saveSession(session) }
            }
        }
    }

    @objc func refreshAccountAvatar() {
        guard let root = opnNavGet(self, "rootView", as: OPNBackdropView.self), let session = opnNavGet(self, "currentSession", as: OPNAuthSessionObject.self) else { return }
        let email = session.email
        root.accountAvatarImage = nil
        guard let avatarURLString = OPNAppDelegateSupport.gravatarURLString(forEmail: email), let url = URL(string: avatarURLString) else { return }
        let request = NSMutableURLRequest(url: url)
        let trace = OPNSentry.traceHTTPRequest(request, name: "Account avatar image")
        let selfBox = OPNNavigationWeakObject(self)
        URLSession.shared.dataTask(with: request as URLRequest) { data, _, error in
            guard error == nil, let data, let image = NSImage(data: data) else { trace?.setStatus(false); trace?.finish(); return }
            trace?.setStatus(true)
            trace?.finish()
            Task { @MainActor in
                guard let self = selfBox.value, let root = opnNavGet(self, "rootView", as: OPNBackdropView.self), opnNavGet(self, "currentSession", as: OPNAuthSessionObject.self)?.email == email else { return }
                root.accountAvatarImage = image
                opnNavPerform(self, "rebuildDesktopAccountSwitcher")
            }
        }.resume()
    }

    @objc func refreshStreamRegions() {
        guard let session = opnNavGet(self, "currentSession", as: OPNAuthSessionObject.self), !session.accessToken.isEmpty else { return }
        let token = OPNAppDelegateSupport.authSessionToken(session)
        OPNGameServiceSwiftAdapter.setAccessToken(token)
        OPNGameServiceSwiftAdapter.fetchProviderInfo(idpId: session.idpId) { _, _, endpoint, _ in
            let providerBaseURL = endpoint.streamingServiceUrl.isEmpty ? OPNGameServiceSwiftAdapter.providerStreamingBaseURL() : endpoint.streamingServiceUrl
            OPNStreamPreferences.fetchRegions(token: token, providerStreamingBaseUrl: providerBaseURL) { _ in
                OPNGameServiceSwiftAdapter.setStreamingBaseUrl(OPNStreamPreferences.loadSelectedStreamingBaseUrl())
                OPNGameServiceSwiftAdapter.prewarmLaunchData()
                NotificationCenter.default.post(name: Notification.Name("OpenNOW.StreamRegionsUpdated"), object: nil)
            }
        }
    }

    @objc func refreshAccountMenu() {
        guard let root = opnNavGet(self, "rootView", as: OPNBackdropView.self), let currentSession = opnNavGet(self, "currentSession", as: OPNAuthSessionObject.self) else { return }
        let currentIdentifier = OPNAppDelegateSupport.authSessionIdentifier(currentSession)
        let items = OPNAuthServiceDirect.shared.loadSavedSessions().compactMap { session -> [String: String]? in
            let identifier = OPNAppDelegateSupport.authSessionIdentifier(session)
            guard !identifier.isEmpty else { return nil }
            return ["identifier": identifier, "label": identifier == currentIdentifier ? OPNAppDelegateSupport.authSessionDisplayName(currentSession) : OPNAppDelegateSupport.authSessionDisplayName(session)]
        }
        root.accountMenuItems = items
        root.currentAccountIdentifier = currentIdentifier
        opnNavPerform(self, "rebuildDesktopAccountSwitcher")
        opnNavPerform(self, "updateDesktopAccountSwitcher")
    }

    @objc func desktopSettingsPillClicked(_ sender: NSButton?) {
        if opnNavInt(self, "currentScreen") == OPNNavigationScreen.settings.rawValue {
            transitionToScreen(OPNNavigationScreen.store.rawValue)
        } else if OPNAppDelegateSupport.supportsDesktopNavigation(forScreen: Int(opnNavInt(self, "currentScreen"))) {
            transitionToScreen(OPNNavigationScreen.settings.rawValue)
        }
    }

    @objc func desktopAccountTypePillClicked(_ sender: NSButton?) {
        let urlString = "https://www.nvidia.com/en-us/account/gfn/manage/"
        guard let url = URL(string: urlString), url.scheme?.isEmpty == false, url.host?.isEmpty == false else {
            OPNSentry.logErrorMessage("[AppDelegate] Invalid account management URL: \(urlString)")
            NSSound.beep()
            return
        }
        OPNSentry.logInfoMessage("[AppDelegate] Opening account management URL")
        if !NSWorkspace.shared.open(url) {
            OPNSentry.logErrorMessage("[AppDelegate] Failed to open account management URL")
            NSSound.beep()
        }
    }

    @objc(transitionToStoreAfterProviderSelectionForSession:)
    func transitionToStoreAfterProviderSelection(for session: OPNAuthSessionObject) {
        OPNGameServiceSwiftAdapter.setAccessToken(OPNAppDelegateSupport.authSessionToken(session))
        let selfBox = OPNNavigationWeakObject(self)
        OPNGameServiceSwiftAdapter.fetchProviderInfo(idpId: session.idpId) { _, _, _, _ in
            Task { @MainActor in selfBox.value?.transitionToScreen(OPNNavigationScreen.store.rawValue) }
        }
    }

    @objc func addAccount() {
        opnNavSet(self, "pendingStayLoggedIn", true)
        transitionToScreen(OPNNavigationScreen.emailEntry.rawValue)
    }

    @objc func switchToAccountIdentifier(_ identifier: String) {
        guard !identifier.isEmpty, let currentSession = opnNavGet(self, "currentSession", as: OPNAuthSessionObject.self), identifier != OPNAppDelegateSupport.authSessionIdentifier(currentSession) else { return }
        OPNAuthServiceDirect.shared.setActiveSessionUserId(identifier)
        let selected = OPNAuthServiceDirect.shared.loadSavedSession(userId: identifier)
        guard selected.isAuthenticated else { return }
        opnNavSet(self, "catalogBrowseGeneration", Int((opnNavGet(self, "catalogBrowseGeneration", as: NSNumber.self)?.intValue ?? 0) + 1))
        opnNavSet(self, "gameLibraryRefreshInFlight", false)
        opnNavSet(self, "featuredGamesRefreshInFlight", false)
        opnNavSet(self, "activeSessionsRefreshInFlight", false)
        opnNavPerform(self, "stopGameLibraryRefreshTimer")
        opnNavSet(self, "currentSession", selected)
        OPNGameServiceSwiftAdapter.setUserId(OPNAppDelegateSupport.authSessionIdentifier(selected))
        if OPNAppDelegateSupport.authSessionAccessTokenValid(selected) { transitionToStoreAfterProviderSelection(for: selected); return }
        showAuthenticating(message: "Refreshing session...")
        let selfBox = OPNNavigationWeakObject(self)
        OPNAuthServiceDirect.shared.refreshSession(force: false) { success, freshObject, _ in
            let freshObjectBox = OPNNavigationSendableValue(freshObject)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                let freshObject = freshObjectBox.value
                if success {
                    opnNavSet(self, "currentSession", freshObject)
                    OPNAuthServiceDirect.shared.saveSession(freshObject)
                    self.refreshAccountMenu()
                    self.transitionToStoreAfterProviderSelection(for: freshObject)
                } else {
                    let fallback = OPNAuthServiceDirect.shared.loadSavedSession()
                    if fallback.isAuthenticated, OPNAppDelegateSupport.authSessionAccessTokenValid(fallback) {
                        opnNavSet(self, "currentSession", fallback)
                        self.transitionToStoreAfterProviderSelection(for: fallback)
                    } else {
                        opnNavSet(self, "currentSession", OPNAuthSessionObject())
                        self.transitionToScreen(OPNNavigationScreen.emailEntry.rawValue)
                    }
                }
            }
        }
    }

    @objc func performServerLogout() {
        let idToken = opnNavGet(self, "currentSession", as: OPNAuthSessionObject.self)?.idToken ?? ""
        showAuthenticating(message: "Signing out...")
        let selfBox = OPNNavigationWeakObject(self)
        OPNAuthServiceDirect.shared.serverLogout(idToken: idToken, locale: OPNLocale.currentGFNLocale()) { _, _ in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                opnNavConfigureLibraryWindow(opnNavGet(self, "window", as: NSWindow.self))
                let next = OPNAuthServiceDirect.shared.loadSavedSession()
                if next.isAuthenticated, OPNAppDelegateSupport.authSessionAccessTokenValid(next) {
                    opnNavSet(self, "currentSession", next)
                    self.transitionToScreen(OPNNavigationScreen.store.rawValue)
                    return
                }
                opnNavSet(self, "currentSession", OPNAuthSessionObject())
                opnNavSet(self, "hasCachedGameLibrary", false)
                opnNavSet(self, "pendingProviderIdpId", "PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg")
                opnNavSet(self, "pendingStayLoggedIn", true)
                self.refreshAccountMenu()
                self.transitionToScreen(OPNNavigationScreen.emailEntry.rawValue)
            }
        }
    }

    @objc(showAuthenticatingWithMessage:)
    func showAuthenticating(message: String) {
        opnNavGet(self, "rootView", as: OPNBackdropView.self)?.mode = OPNNavigationBackdropMode.auth.rawValue
        guard let container = opnNavGet(self, "contentContainer", as: NSView.self) else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        let overlay = OPNAuthenticatingView(frame: container.bounds, message: message)
        container.addSubview(overlay)
        opnNavSet(self, "currentScreen", NSNumber(value: OPNNavigationScreen.authenticating.rawValue))
    }

    @objc(showErrorMessage:canRetry:)
    func showErrorMessage(_ errorMessage: String?, canRetry: Bool) {
        let currentScreen = opnNavInt(self, "currentScreen")
        let retryScreen = [OPNNavigationScreen.store.rawValue, OPNNavigationScreen.catalog.rawValue, OPNNavigationScreen.settings.rawValue].contains(currentScreen) ? (OPNNavigationScreen(rawValue: currentScreen) ?? .emailEntry) : .emailEntry
        opnNavGet(self, "rootView", as: OPNBackdropView.self)?.mode = OPNNavigationBackdropMode.auth.rawValue
        guard let container = opnNavGet(self, "contentContainer", as: NSView.self) else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        var message = OPNGFNError.userFacingMessage(errorMessage: errorMessage ?? "", gameTitle: opnNavGet(self, "currentStreamTitle", as: String.self) ?? "")
        if message.isEmpty { message = "An unknown error occurred." }
        OPNLogCapture.appendEvent("[AppDelegate] Presenting error: \(message)")
        OPNLogCapture.copyCapturedLogToClipboard(message)
        message += "\n\nFull log copied to clipboard."
        let view = OPNErrorView(frame: container.bounds, message: message, canRetry: canRetry)
        let selfBox = OPNNavigationWeakObject(self)
        view.onRetry = { selfBox.value?.transitionToScreen(retryScreen.rawValue) }
        view.onBackToEmail = {
            guard let self = selfBox.value else { return }
            opnNavSet(self, "pendingProviderIdpId", "PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg")
            opnNavSet(self, "pendingStayLoggedIn", OPNAuthServiceDirect.shared.getStayLoggedIn())
            self.transitionToScreen(OPNNavigationScreen.emailEntry.rawValue)
        }
        container.addSubview(view)
        opnNavSet(self, "currentScreen", NSNumber(value: OPNNavigationScreen.error.rawValue))
    }
}
