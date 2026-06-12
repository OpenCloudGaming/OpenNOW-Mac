import AppKit
import GameController
import QuartzCore

private final class OPNWeakObject<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}

private final class OPNUncheckedSendableValue<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

private enum OPNStreamingScreen: Int {
    case emailEntry = 0
    case store = 2
    case catalog = 3
}

private struct OPNActivePromptButton: OptionSet {
    let rawValue: UInt16
    static let a = OPNActivePromptButton(rawValue: 1 << 0)
    static let y = OPNActivePromptButton(rawValue: 1 << 2)
}

@MainActor private func opnButton(_ title: String, _ frame: NSRect, _ background: NSColor, _ textColor: NSColor, _ bordered: Bool, _ borderColor: NSColor?) -> NSButton { OPNUIHelpers.button(title: title, frame: frame, background: background, textColor: textColor, bordered: bordered, borderColor: borderColor) }

private func opnActivePromptButtons() -> OPNActivePromptButton {
    guard let pad = GCController.controllers().first?.extendedGamepad else { return [] }
    var buttons: OPNActivePromptButton = []
    if pad.buttonA.value > 0.5 { buttons.insert(.a) }
    if pad.buttonY.value > 0.5 { buttons.insert(.y) }
    return buttons
}

private func opnCloudmatchOptions(_ regions: [OPNStreamRegionOption]) -> [OPNCloudmatchServerOption] {
    regions.map { OPNCloudmatchServerOption(name: $0.name, url: $0.url, latencyMs: $0.latencyMs, automatic: $0.automatic) }
}

private func opnGet<T>(_ object: NSObject, _ key: String, as type: T.Type = T.self) -> T? { object.value(forKey: key) as? T }
private func opnSet(_ object: NSObject, _ key: String, _ value: Any?) { object.setValue(value, forKey: key) }
private func opnBool(_ object: NSObject, _ key: String) -> Bool { (object.value(forKey: key) as? NSNumber)?.boolValue ?? (object.value(forKey: key) as? Bool ?? false) }
private func opnInt(_ object: NSObject, _ key: String) -> Int { (object.value(forKey: key) as? NSNumber)?.intValue ?? (object.value(forKey: key) as? Int ?? 0) }
private func opnDouble(_ object: NSObject, _ key: String) -> Double { (object.value(forKey: key) as? NSNumber)?.doubleValue ?? (object.value(forKey: key) as? Double ?? 0) }
private func opnSendInt(_ object: NSObject, _ selectorName: String, _ value: Int) {
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector) else { return }
    typealias Message = @convention(c) (AnyObject, Selector, Int) -> Void
    unsafeBitCast(object.method(for: selector), to: Message.self)(object, selector, value)
}

@MainActor
extension NSObject {
    @objc func hasVisibleStreamingController() -> Bool {
        guard let streamingController = opnGet(self, "streamingController", as: OPNStreamViewController.self) else { return false }
        if opnBool(self, "streamDashboardHomeVisible") { return true }
        if opnGet(self, "window", as: NSWindow.self)?.contentViewController === streamingController { return true }
        OPNSentry.logInfoMessage("[AppDelegate] Clearing stale streaming controller before launch/session check")
        opnSet(self, "streamingController", nil)
        opnSet(self, "currentStreamTitle", nil)
        return false
    }

    @objc func toggleStreamDashboardHome() {
        guard opnGet(self, "streamingController", as: OPNStreamViewController.self) != nil else { return }
        opnBool(self, "streamDashboardHomeVisible") ? restoreVisibleStreamFromDashboard() : showStreamDashboardHome()
    }

    @objc func showStreamDashboardHome() {
        guard let streamingController = opnGet(self, "streamingController", as: OPNStreamViewController.self), !opnBool(self, "streamDashboardHomeVisible") else { return }
        opnSet(self, "streamDashboardHomeVisible", true)
        opnSet(self, "streamDashboardStartHoldBegan", CACurrentMediaTime())
        opnSet(self, "streamDashboardStartHoldConsumed", true)
        streamingController.setStreamInputSuppressed(true)
        guard let window = opnGet(self, "window", as: NSWindow.self) else { return }
        window.contentViewController = nil
        opnSendInt(self, "transitionToScreen:", OPNStreamingScreen.store.rawValue)
        opnGet(self, "rootView", as: NSObject.self)?.setValue(2, forKey: "mode")
        startStreamDashboardControllerPolling()
        OPNSentry.logInfoMessage("[AppDelegate] Stream dashboard Home shown")
    }

    @objc func restoreVisibleStreamFromDashboard() {
        guard let streamingController = opnGet(self, "streamingController", as: OPNStreamViewController.self), let window = opnGet(self, "window", as: NSWindow.self) else { return }
        stopStreamDashboardControllerPolling()
        opnSet(self, "streamDashboardHomeVisible", false)
        let preservedFrame = window.frame
        let preserveFrame = !OPNAppDelegateSupport.windowIsFullScreen(window)
        streamingController.setInitialViewFrame(window.contentView?.bounds ?? .zero)
        streamingController.view.autoresizingMask = [.width, .height]
        configureStreamWindowForStreaming()
        window.contentViewController = streamingController
        OPNUIHelpers.disableFocusHighlights(streamingController.view)
        streamingController.setStreamInputSuppressed(false)
        if preserveFrame { window.setFrame(preservedFrame, display: true, animate: false) }
        window.makeKeyAndOrderFront(nil)
        OPNSentry.logInfoMessage("[AppDelegate] Stream restored from dashboard Home")
    }

    @objc func startStreamDashboardControllerPolling() {
        stopStreamDashboardControllerPolling()
        let timer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(pollStreamDashboardController(_:)), userInfo: nil, repeats: true)
        opnSet(self, "streamDashboardControllerTimer", timer)
    }

    @objc func stopStreamDashboardControllerPolling() {
        opnGet(self, "streamDashboardControllerTimer", as: Timer.self)?.invalidate()
        opnSet(self, "streamDashboardControllerTimer", nil)
        opnSet(self, "streamDashboardStartHoldBegan", 0)
        opnSet(self, "streamDashboardStartHoldConsumed", false)
    }

    @objc func pollStreamDashboardController(_ timer: Timer) {
        guard opnBool(self, "streamDashboardHomeVisible"), opnGet(self, "streamingController", as: OPNStreamViewController.self) != nil else { stopStreamDashboardControllerPolling(); return }
        let startDown = GCController.controllers().contains { $0.extendedGamepad?.buttonMenu.value ?? 0 > 0.5 }
        guard startDown else { opnSet(self, "streamDashboardStartHoldBegan", 0); opnSet(self, "streamDashboardStartHoldConsumed", false); return }
        let now = CACurrentMediaTime()
        let began = opnDouble(self, "streamDashboardStartHoldBegan")
        if began <= 0 { opnSet(self, "streamDashboardStartHoldBegan", now); return }
        guard !opnBool(self, "streamDashboardStartHoldConsumed"), now - began >= 3 else { return }
        opnSet(self, "streamDashboardStartHoldConsumed", true)
        restoreVisibleStreamFromDashboard()
    }

    @objc(showActiveSessionPromptWithSessionTitle:selectedGameTitle:continueHandler:deleteHandler:)
    func showActiveSessionPrompt(sessionTitle: String, selectedGameTitle: String, continueHandler: @escaping () -> Void, deleteHandler: @escaping () -> Void) {
        dismissActiveSessionPrompt()
        opnSet(self, "activeSessionContinueHandler", continueHandler)
        opnSet(self, "activeSessionDeleteHandler", deleteHandler)
        guard let host = opnGet(self, "contentContainer", as: NSView.self) ?? opnGet(self, "window", as: NSWindow.self)?.contentView else { return }
        let overlay = OPNActiveSessionPromptView(frame: host.bounds, sessionTitle: sessionTitle, selectedGameTitle: selectedGameTitle)
        overlay.autoresizingMask = [.width, .height]
        overlay.onContinue = { [weak self] in self?.activeSessionContinueClicked(nil) }
        overlay.onDelete = { [weak self] in self?.activeSessionDeleteClicked(nil) }
        opnSet(self, "activeSessionPromptView", overlay)
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        startActiveSessionPromptControllerPolling()
    }

    @objc func dismissActiveSessionPrompt() {
        stopActiveSessionPromptControllerPolling()
        opnGet(self, "activeSessionPromptView", as: NSView.self)?.removeFromSuperview()
        opnSet(self, "activeSessionPromptView", nil)
        opnSet(self, "activeSessionContinueHandler", nil)
        opnSet(self, "activeSessionDeleteHandler", nil)
    }

    @objc func startActiveSessionPromptControllerPolling() {
        guard opnGet(self, "activeSessionPromptControllerTimer", as: Timer.self) == nil else { return }
        opnSet(self, "activeSessionPromptPreviousButtons", opnActivePromptButtons().rawValue)
        opnSet(self, "activeSessionPromptControllerTimer", Timer.scheduledTimer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(pollActiveSessionPromptController), userInfo: nil, repeats: true))
    }

    @objc func stopActiveSessionPromptControllerPolling() {
        opnGet(self, "activeSessionPromptControllerTimer", as: Timer.self)?.invalidate()
        opnSet(self, "activeSessionPromptControllerTimer", nil)
        opnSet(self, "activeSessionPromptPreviousButtons", 0)
    }

    @objc func pollActiveSessionPromptController() {
        guard opnGet(self, "activeSessionPromptView", as: NSView.self) != nil else { stopActiveSessionPromptControllerPolling(); return }
        let buttons = opnActivePromptButtons()
        let pressed = OPNActivePromptButton(rawValue: buttons.rawValue & ~UInt16(opnInt(self, "activeSessionPromptPreviousButtons")))
        if pressed.contains(.a) { activeSessionContinueClicked(nil); return }
        if pressed.contains(.y) { activeSessionDeleteClicked(nil); return }
        opnSet(self, "activeSessionPromptPreviousButtons", buttons.rawValue)
    }

    @objc func activeSessionContinueClicked(_ sender: Any?) {
        let handler = value(forKey: "activeSessionContinueHandler") as? () -> Void
        dismissActiveSessionPrompt()
        handler?()
    }

    @objc func activeSessionDeleteClicked(_ sender: Any?) {
        let handler = value(forKey: "activeSessionDeleteHandler") as? () -> Void
        dismissActiveSessionPrompt()
        handler?()
    }

    @objc(showCloudmatchServerPickerForGameTitle:apiTokenString:completion:)
    func showCloudmatchServerPicker(gameTitle: String, apiToken: String, completion: @escaping (Bool) -> Void) {
        dismissCloudmatchServerPicker()
        guard let host = opnGet(self, "contentContainer", as: NSView.self) ?? opnGet(self, "window", as: NSWindow.self)?.contentView else { completion(false); return }
        let generation = opnInt(self, "cloudmatchServerPickerGeneration") + 1
        opnSet(self, "cloudmatchServerPickerGeneration", generation)
        let picker = OPNCloudmatchServerPickerView(frame: host.bounds, gameTitle: gameTitle)
        picker.autoresizingMask = [.width, .height]
        opnSet(self, "cloudmatchServerPickerView", picker)
        let cachedRegions = OPNStreamPreferences.loadCachedRegions()
        picker.setOptions(opnCloudmatchOptions(cachedRegions), selectedRegionUrl: OPNStreamPreferences.loadSelectedRegionUrl(), refreshing: true)
        picker.setStatusMessage(cachedRegions.isEmpty ? "Finding routes..." : "Refreshing ping...", isError: false)
        picker.onConfirm = { [weak self, weak picker] option in
            guard let self, let picker, opnGet(self, "cloudmatchServerPickerView", as: OPNCloudmatchServerPickerView.self) === picker else { return }
            OPNStreamPreferences.saveSelectedRegionUrl(option.url)
            OPNSentry.logInfoMessage("[AppDelegate] Cloudmatch server selected: \(option.url.isEmpty ? "automatic" : option.url)")
            self.dismissCloudmatchServerPicker()
            DispatchQueue.main.async { completion(true) }
        }
        picker.onCancel = { [weak self, weak picker] in
            guard let self, let picker, opnGet(self, "cloudmatchServerPickerView", as: OPNCloudmatchServerPickerView.self) === picker else { return }
            OPNSentry.logInfoMessage("[AppDelegate] Cloudmatch server selection cancelled")
            self.dismissCloudmatchServerPicker()
            DispatchQueue.main.async { completion(false) }
        }
        picker.onRefresh = { [weak self] in self?.refreshCloudmatchServerPicker(apiToken: apiToken, generation: generation) }
        host.addSubview(picker, positioned: .above, relativeTo: nil)
        opnGet(self, "window", as: NSWindow.self)?.makeFirstResponder(picker)
        refreshCloudmatchServerPicker(apiToken: apiToken, generation: generation)
    }

    @objc(refreshCloudmatchServerPickerWithTokenString:generation:)
    func refreshCloudmatchServerPicker(apiToken: String, generation: Int) {
        guard let picker = opnGet(self, "cloudmatchServerPickerView", as: OPNCloudmatchServerPickerView.self), generation == opnInt(self, "cloudmatchServerPickerGeneration") else { return }
        picker.setRefreshing(true)
        picker.setStatusMessage("Pinging routes...", isError: false)
        OPNGameServiceSwiftAdapter.setAccessToken(apiToken)
        let selfBox = OPNWeakObject(self)
        let pickerBox = OPNWeakObject(picker)
        OPNGameServiceSwiftAdapter.fetchProviderInfo(idpId: (opnGet(self, "currentSession", as: OPNAuthSessionObject.self)?.idpId ?? "")) { _, _, endpoint, _ in
            let endpointUrl = endpoint.streamingServiceUrl
            let baseURL = endpointUrl.isEmpty ? OPNGameServiceSwiftAdapter.providerStreamingBaseURL() : endpointUrl
            OPNStreamPreferences.fetchRegions(token: apiToken, providerStreamingBaseUrl: baseURL) { regions in
                DispatchQueue.main.async {
                    guard let self = selfBox.value, let picker = pickerBox.value else { return }
                    guard generation == opnInt(self, "cloudmatchServerPickerGeneration"), opnGet(self, "cloudmatchServerPickerView", as: OPNCloudmatchServerPickerView.self) === picker else { return }
                    picker.setOptions(opnCloudmatchOptions(regions), selectedRegionUrl: OPNStreamPreferences.loadSelectedRegionUrl(), refreshing: false)
                    picker.setStatusMessage(regions.isEmpty ? "Discovery failed. Automatic can still launch." : "Ping updated.", isError: regions.isEmpty)
                }
            }
        }
    }

    @objc func dismissCloudmatchServerPicker() {
        opnSet(self, "cloudmatchServerPickerGeneration", opnInt(self, "cloudmatchServerPickerGeneration") + 1)
        opnGet(self, "cloudmatchServerPickerView", as: OPNCloudmatchServerPickerView.self)?.removeFromSuperview()
        opnSet(self, "cloudmatchServerPickerView", nil)
    }

    @objc(startStreamWithTitleString:appIdString:apiTokenString:accountLinked:selectedStoreString:returnScreenRaw:resumeSessionIdString:resumeServerString:)
    func startStream(title: String, appId: String, apiToken: String, accountLinked: Bool, selectedStore: String, returnScreen: Int, resumeSessionId: String, resumeServer: String) {
        guard !hasVisibleStreamingController() else {
            OPNSentry.logInfoMessage("[AppDelegate] Ignoring stream start while stream is active: title=\(title), appId=\(appId)")
            return
        }
        let selfBox = OPNWeakObject(self)
        OPNAuthServiceDirect.shared.refreshSession(force: false) { refreshSuccess, freshObject, refreshError in
            let freshObjectBox = OPNUncheckedSendableValue(freshObject)
            Task { @MainActor in
            guard let self = selfBox.value, !self.hasVisibleStreamingController(), let window = opnGet(self, "window", as: NSWindow.self) else { return }
            let freshObject = freshObjectBox.value
            var effectiveToken = apiToken
            if refreshSuccess, freshObject.isAuthenticated, !OPNAppDelegateSupport.authSessionToken(freshObject).isEmpty {
                effectiveToken = OPNAppDelegateSupport.authSessionToken(freshObject)
                opnSet(self, "currentSession", freshObject)
                if opnBool(self, "pendingStayLoggedIn") { OPNAuthServiceDirect.shared.saveSession(freshObject) }
                self.perform(NSSelectorFromString("refreshAccountMenu"))
                OPNSentry.logInfoMessage("[AppDelegate] Auth token refreshed successfully before stream launch")
            } else if !OPNAppDelegateSupport.authSessionAccessTokenValid(opnGet(self, "currentSession", as: NSObject.self)) {
                OPNSentry.logErrorMessage("[AppDelegate] Auth token refresh failed before stream launch: \(refreshError)")
                opnSendInt(self, "transitionToScreen:", OPNStreamingScreen.emailEntry.rawValue)
                return
            }
            opnSet(self, "catalogView", nil)
            opnSet(self, "storeView", nil)
            opnSet(self, "settingsView", nil)
            let streamVC = OPNStreamViewController(gameTitle: title, appId: appId, apiToken: effectiveToken, accountLinked: accountLinked, selectedStore: selectedStore, resumeSessionId: resumeSessionId, resumeServer: resumeServer)
            if opnBool(self, "currentRemainingPlayTimeAvailable") {
                streamVC.setRemainingPlaytimeHours(opnDouble(self, "currentRemainingPlayTimeHours"), unlimited: opnBool(self, "currentRemainingPlayTimeUnlimited"))
            }
            opnSet(self, "currentStreamTitle", title.isEmpty ? "Current Stream" : title)
            opnSet(self, "activeStreamReturnScreen", returnScreen)
            opnSet(self, "streamDashboardHomeVisible", false)
            OPNDiscordPresence.updateLaunching(gameTitle: title)
            streamVC.onStreamEnd = { [weak self] success, error, report in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.stopStreamDashboardControllerPolling()
                    opnSet(self, "streamDashboardHomeVisible", false)
                    opnSet(self, "streamingController", nil)
                    opnSet(self, "currentStreamTitle", nil)
                    OPNDiscordPresence.clear()
                    opnSendInt(self, "transitionToScreen:", returnScreen)
                    if !success, !error.isEmpty { OPNLogCapture.appendEvent("[AppDelegate] Stream ended with error before report: \(error)") }
                    if report.shouldShow { self.perform(NSSelectorFromString("showSessionReport:"), with: report) }
                    else { OPNLogCapture.appendEvent("[AppDelegate] Session report suppressed score=\(report.displayScore) reason=\(report.displayReason)") }
                }
            }
            streamVC.onDashboardToggleRequested = { [weak self] in DispatchQueue.main.async { self?.toggleStreamDashboardHome() } }
            let preservedFrame = window.frame
            let preserveFrame = !OPNAppDelegateSupport.windowIsFullScreen(window)
            streamVC.setInitialViewFrame(window.contentView?.bounds ?? .zero)
            streamVC.view.autoresizingMask = [.width, .height]
            self.configureStreamWindowForStreaming()
            window.contentViewController = streamVC
            OPNUIHelpers.disableFocusHighlights(streamVC.view)
            if preserveFrame { window.setFrame(preservedFrame, display: true, animate: false) }
            opnSet(self, "streamingController", streamVC)
            window.makeKeyAndOrderFront(nil)
            if OPNUIHelpers.autoFullScreenEnabled(), !OPNAppDelegateSupport.windowIsFullScreen(window) {
                let windowBox = OPNWeakObject(window)
                DispatchQueue.main.async { if let window = windowBox.value, !OPNAppDelegateSupport.windowIsFullScreen(window) { window.toggleFullScreen(nil) } }
            }
            OPNSentry.logInfoMessage("[AppDelegate] Window setup complete")
            }
        }
    }

    @objc(checkForActiveSessionResumeIfNeededForScreenRaw:)
    func checkForActiveSessionResumeIfNeeded(screen: Int) {
        guard screen == OPNStreamingScreen.catalog.rawValue || screen == OPNStreamingScreen.store.rawValue else { return }
        guard opnGet(self, "streamingController", as: OPNStreamViewController.self) == nil, !opnBool(self, "activeSessionResumeInFlight") else { return }
        guard let currentSession = opnGet(self, "currentSession", as: OPNAuthSessionObject.self), currentSession.isAuthenticated, !currentSession.accessToken.isEmpty else { return }
        opnSet(self, "activeSessionResumeInFlight", true)
        let generation = opnInt(self, "activeSessionResumeGeneration") + 1
        opnSet(self, "activeSessionResumeGeneration", generation)
        let accountIdentifier = OPNAppDelegateSupport.authSessionIdentifier(currentSession)
        let apiToken = OPNAppDelegateSupport.authSessionToken(currentSession)
        let persistedSessionId = OPNActiveSessionService.loadPersistedActiveSessionId()
        let selfBox = OPNWeakObject(self)
        OPNActiveSessionService.fetchActiveSessions(accessToken: apiToken) { ok, sessions, error in
            let sessionsBox = OPNUncheckedSendableValue(sessions)
            DispatchQueue.main.async {
                guard let self = selfBox.value else { return }
                let sessions = sessionsBox.value
                opnSet(self, "activeSessionResumeInFlight", false)
                guard generation == opnInt(self, "activeSessionResumeGeneration") else { return }
                guard accountIdentifier == OPNAppDelegateSupport.authSessionIdentifier(opnGet(self, "currentSession", as: NSObject.self)) else { return }
                guard opnGet(self, "streamingController", as: OPNStreamViewController.self) == nil, opnInt(self, "currentScreen") == screen else { return }
                guard ok else { OPNSentry.logErrorMessage("[AppDelegate] Active session probe failed: \(error)"); return }
                let activeSession: OPNActiveSessionObject?
                if persistedSessionId.isEmpty {
                    activeSession = sessions.first { !$0.sessionId.isEmpty && !$0.serverIp.isEmpty && $0.appId > 0 }
                } else {
                    activeSession = sessions.first { $0.sessionId == persistedSessionId && !$0.serverIp.isEmpty && $0.appId > 0 }
                    if activeSession == nil { OPNActiveSessionService.clearPersistedActiveSessionId(persistedSessionId); return }
                }
                guard let activeSession else { return }
                let cachedGames = opnGet(self, "cachedGameLibraryObjects", as: [OPNCatalogGameObject].self) ?? []
                let title = opnGameLaunchTitleForActiveSession(appId: activeSession.appId, games: cachedGames)
                self.startStream(title: title.isEmpty ? "Current Stream" : title, appId: String(activeSession.appId), apiToken: apiToken, accountLinked: true, selectedStore: "", returnScreen: screen, resumeSessionId: activeSession.sessionId, resumeServer: activeSession.serverIp)
                OPNSentry.logInfoMessage("[AppDelegate] Silently resuming active session \(activeSession.sessionId) for appId=\(activeSession.appId)")
            }
        }
    }

    @objc func showSessionReport(_ report: OPNSessionReportPayload) {
        guard let contentContainer = opnGet(self, "contentContainer", as: NSView.self) else { return }
        opnGet(self, "sessionReportView", as: OPNSessionReportView.self)?.removeFromSuperview()
        let view = OPNSessionReportView(frame: contentContainer.bounds, report: report)
        view.autoresizingMask = [.width, .height]
        view.onDone = { [weak self] in
            guard let self else { return }
            opnGet(self, "sessionReportView", as: OPNSessionReportView.self)?.removeFromSuperview()
            opnSet(self, "sessionReportView", nil)
        }
        opnSet(self, "sessionReportView", view)
        contentContainer.addSubview(view, positioned: .above, relativeTo: nil)
        OPNUIHelpers.disableFocusHighlights(view)
        OPNLogCapture.appendEvent("[AppDelegate] Presented session health report")
    }

    @objc func configureStreamWindowForStreaming() {
        guard let window = opnGet(self, "window", as: NSWindow.self) else { return }
        window.title = "OpenNOW Stream"
        window.minSize = NSSize(width: 960.0, height: 540.0)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.backgroundColor = .black
        window.contentAspectRatio = NSSize(width: 16.0, height: 9.0)
    }
}
