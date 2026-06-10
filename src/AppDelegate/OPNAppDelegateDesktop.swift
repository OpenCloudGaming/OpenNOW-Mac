import AppKit
import GameController
import QuartzCore

private enum OPNDesktopScreen: Int32 {
    case emailEntry = 0
    case authenticating = 1
    case store = 2
    case catalog = 3
    case settings = 4
    case error = 5
    case oauthBrowser = 6
}

private enum OPNDesktopBackdropMode: Int {
    case store = 2
    case library = 3
    case settings = 4
}

private struct OPNDesktopGamepadButton: OptionSet, Sendable {
    let rawValue: UInt16

    static let up = Self(rawValue: 1 << 0)
    static let down = Self(rawValue: 1 << 1)
    static let left = Self(rawValue: 1 << 2)
    static let right = Self(rawValue: 1 << 3)
    static let a = Self(rawValue: 1 << 4)
    static let b = Self(rawValue: 1 << 5)
    static let y = Self(rawValue: 1 << 6)
    static let directions: Self = [.up, .down, .left, .right]
}

private final class OPNDesktopWeakObject<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}

private final class OPNDesktopSendableValue<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

private let opnDesktopWindowMinWidth: CGFloat = 1280.0
private let opnDesktopWindowMinHeight: CGFloat = 720.0
private let opnMainWindowFrameAutosaveName = "OpenNOW.MainWindowFrame"
private let opnMainWindowWasFullScreenKey = "OpenNOW.MainWindowWasFullScreen"
private let opnAccountManagementURLString = "https://www.nvidia.com/en-us/account/gfn/manage/"
private let opnDesktopAddAccountIdentifier = "__opennow_add_account__"

@MainActor private func opnDesktopColor(_ rgb: UInt32, alpha: CGFloat = 1.0) -> NSColor {
    OPNUIHelpers.color(rgb: rgb, alpha: alpha)
}

@MainActor private func opnDesktopLabel(_ text: String, _ frame: NSRect, _ size: CGFloat, _ color: NSColor, _ weight: NSFont.Weight = .regular, _ alignment: NSTextAlignment = .left) -> NSTextField {
    OPNUIHelpers.label(text: text, frame: frame, size: size, color: color, weight: weight, alignment: alignment)
}

private func opnDesktopMenuItem(_ title: String, _ action: Selector?, _ keyEquivalent: String, _ target: AnyObject?) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = target
    return item
}

private func opnDesktopMenuItem(_ title: String, _ action: Selector?, _ keyEquivalent: String, modifiers: NSEvent.ModifierFlags, target: AnyObject?) -> NSMenuItem {
    let item = opnDesktopMenuItem(title, action, keyEquivalent, target)
    item.keyEquivalentModifierMask = modifiers
    return item
}

@MainActor private func opnDesktopBrandIconRelativePaths() -> [String] {
    switch OPNUIHelpers.appIconThemePreference() {
    case 1:
        return ["assets/OpenNOW.icns", "assets/logo-mac.png", "assets/logo.png"]
    case 2:
        return ["assets/OpenNOW-SkyBlue.icns", "assets/logo-mac-SkyBlue.png", "assets/OpenNOW.icns", "assets/logo-mac.png", "assets/logo.png"]
    default:
        return ["assets/OpenNOW-Black.icns", "assets/logo-mac-Black.png", "assets/OpenNOW.icns", "assets/logo-mac.png", "assets/logo.png"]
    }
}

@MainActor private func opnDesktopBrandIconImage() -> NSImage? {
    let theme = OPNUIHelpers.appIconThemePreference()
    let resource = theme == 1 ? "OpenNOW" : (theme == 2 ? "OpenNOW-SkyBlue" : "OpenNOW-Black")
    if let path = Bundle.main.path(forResource: resource, ofType: "icns"), let image = NSImage(contentsOfFile: path) {
        return image
    }

    let workingDirectory = FileManager.default.currentDirectoryPath
    for relativePath in opnDesktopBrandIconRelativePaths() {
        let path = (workingDirectory as NSString).appendingPathComponent(relativePath)
        if let image = NSImage(contentsOfFile: path) { return image }
    }
    return nil
}

@MainActor private func opnDesktopConfigureLibraryWindow(_ window: NSWindow?) {
    guard let window else { return }
    window.styleMask.insert([.resizable, .fullSizeContentView])
    window.collectionBehavior.insert(.fullScreenPrimary)
    let minSize = NSSize(width: opnDesktopWindowMinWidth, height: opnDesktopWindowMinHeight)
    let minFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: minSize))
    window.minSize = minFrame.size
    window.maxSize = NSSize(width: 16000.0, height: 16000.0)
    window.contentMinSize = minSize
    window.contentMaxSize = NSSize(width: 16000.0, height: 16000.0)
    window.resizeIncrements = NSSize(width: 1.0, height: 1.0)
    window.contentResizeIncrements = NSSize(width: 1.0, height: 1.0)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.standardWindowButton(.closeButton)?.isHidden = false
    window.standardWindowButton(.miniaturizeButton)?.isHidden = false
    window.standardWindowButton(.zoomButton)?.isHidden = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = opnDesktopColor(0x101113)
}

private func opnDesktopGamepadButtons() -> OPNDesktopGamepadButton {
    guard let pad = GCController.controllers().first?.extendedGamepad else { return [] }
    var buttons: OPNDesktopGamepadButton = []
    let x = CGFloat(pad.leftThumbstick.xAxis.value)
    let y = CGFloat(pad.leftThumbstick.yAxis.value)
    if pad.dpad.up.value > 0.5 || y > 0.55 { buttons.insert(.up) }
    if pad.dpad.down.value > 0.5 || y < -0.55 { buttons.insert(.down) }
    if pad.dpad.left.value > 0.5 || x < -0.55 { buttons.insert(.left) }
    if pad.dpad.right.value > 0.5 || x > 0.55 { buttons.insert(.right) }
    if pad.buttonA.value > 0.5 { buttons.insert(.a) }
    if pad.buttonB.value > 0.5 { buttons.insert(.b) }
    if pad.buttonY.value > 0.5 { buttons.insert(.y) }
    return buttons
}

@objc(OPNAppDelegateLegacy)
@MainActor
final class OPNAppDelegateLegacy: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    @objc dynamic var window: NSWindow?
    @objc dynamic var contentContainer: NSView?
    @objc dynamic var currentScreen: Int32 = OPNDesktopScreen.emailEntry.rawValue
    @objc dynamic var pendingProviderIdpId = ""
    @objc dynamic var pendingStayLoggedIn = false
    @objc dynamic var currentSession = OPNAuthSessionObject()
    @objc dynamic var rootView: OPNBackdropView?
    @objc dynamic var catalogView: OPNGameCatalogView?
    @objc dynamic var settingsView: OPNSettingsView?
    @objc dynamic var storeView: OPNGameCatalogView?
    @objc dynamic var streamingController: OPNStreamViewController?
    @objc dynamic var sessionReportView: OPNSessionReportView?
    @objc dynamic var currentStreamTitle = ""
    @objc dynamic var activeStreamReturnScreen: Int32 = OPNDesktopScreen.store.rawValue
    @objc dynamic var streamDashboardHomeVisible = false
    @objc dynamic var streamDashboardControllerTimer: Timer?
    @objc dynamic var streamDashboardStartHoldBegan: CFTimeInterval = 0.0
    @objc dynamic var streamDashboardStartHoldConsumed = false
    @objc dynamic var gameLibraryRefreshTimer: Timer?
    var cachedGameLibraryObjects: [OPNCatalogGameObject] = []
    var cachedFeaturedGameObjects: [OPNCatalogGameObject] = []
    var cachedStorePanelObjects: [OPNCatalogPanelObject] = []
    var cachedGameLibraryFingerprint = ""
    var cachedGameLibraryAccountIdentifier = ""
    var cachedFeaturedGamesAccountIdentifier = ""
    var cachedStorePanelsAccountIdentifier = ""
    @objc dynamic var hasCachedGameLibrary = false
    @objc dynamic var hasCachedFeaturedGames = false
    @objc dynamic var hasCachedStorePanels = false
    @objc dynamic var gameLibraryRefreshInFlight = false
    @objc dynamic var featuredGamesRefreshInFlight = false
    @objc dynamic var activeSessionsRefreshInFlight = false
    @objc dynamic var ownershipSyncOverlayView: NSView?
    @objc dynamic var ownershipSyncTitleLabel: NSTextField?
    @objc dynamic var ownershipSyncMessageLabel: NSTextField?
    @objc dynamic var ownershipSyncFooterLabel: NSTextField?
    @objc dynamic var ownershipSyncSpinner: NSProgressIndicator?
    @objc dynamic var catalogBrowseGeneration: Int = 0
    @objc dynamic var activeSessionResumeInFlight = false
    @objc dynamic var activeSessionResumeGeneration: Int = 0
    @objc dynamic var activeSessionPromptView: NSView?
    @objc dynamic var activeSessionContinueHandler: (() -> Void)?
    @objc dynamic var activeSessionDeleteHandler: (() -> Void)?
    @objc dynamic var activeSessionPromptControllerTimer: Timer?
    @objc dynamic var activeSessionPromptPreviousButtons: UInt16 = 0
    @objc dynamic var cloudmatchServerPickerView: OPNCloudmatchServerPickerView?
    @objc dynamic var cloudmatchServerPickerGeneration: Int = 0
    @objc dynamic var gameLaunchGeneration: Int = 0
    @objc dynamic var desktopTopChromeView: NSView?
    @objc dynamic var desktopBrandLabel: NSTextField?
    @objc dynamic var desktopAccountSwitcher: NSPopUpButton?
    @objc dynamic var desktopAccountTypePill: NSButton?
    @objc dynamic var desktopRemainingPlayTimePill: NSView?
    @objc dynamic var desktopRemainingPlayTimeLabel: NSTextField?
    @objc dynamic var desktopSettingsPillButton: NSButton?
    @objc dynamic var currentRemainingPlayTimeHours: Double = 0.0
    @objc dynamic var currentRemainingPlayTimeUnlimited = false
    @objc dynamic var currentRemainingPlayTimeAvailable = false
    @objc dynamic var githubUpdater: OPNGitHubUpdater?
    @objc dynamic var applicationUpdateCheckTimer: Timer?
    @objc dynamic var updateCheckInFlight = false
    @objc dynamic var desktopControllerTimer: Timer?
    @objc dynamic var desktopControllerPreviousButtons: UInt16 = 0
    @objc dynamic var desktopControllerHeldDirections: UInt16 = 0
    @objc dynamic var desktopControllerLastRepeatTime: CFTimeInterval = 0.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        _ = OPNSentry.recordCounterMetric(key: "opennow.app.launch.count", value: 1, attributes: nil)
        let launchTrace = OPNSentry.startTransaction(name: "OpenNOW launch", operation: "app.start", makeCurrent: true)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        installMainMenu()
        applyApplicationIconTheme()

        let frame = NSRect(x: 0.0, y: 0.0, width: opnDesktopWindowMinWidth, height: opnDesktopWindowMinHeight)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        self.window = window
        window.title = "OpenNOW"
        opnDesktopConfigureLibraryWindow(window)
        if !window.setFrameUsingName(opnMainWindowFrameAutosaveName) { window.center() }
        window.setFrameAutosaveName(opnMainWindowFrameAutosaveName)
        installLibraryRootIfNeeded()
        NotificationCenter.default.addObserver(self, selector: #selector(windowFullScreenStateChanged(_:)), name: NSWindow.didEnterFullScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowFullScreenStateChanged(_:)), name: NSWindow.didExitFullScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowGeometryChanged(_:)), name: NSWindow.didResizeNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(interfacePreferencesChanged(_:)), name: OPNInterfacePreferencesDidChangeNotification, object: nil)
        githubUpdater = OPNGitHubUpdater(owner: "OpenCloudGaming", repository: "OpenNOW-Mac")
        pendingProviderIdpId = "PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg"
        pendingStayLoggedIn = OPNAuthServiceDirect.shared.getStayLoggedIn()

        let saved = OPNAuthServiceDirect.shared.loadSavedSession()
        let shouldAutoSignIn = saved.isAuthenticated && OPNAuthServiceDirect.shared.getStayLoggedIn()
        let canUseSavedSessionAsIs = OPNAppDelegateSupport.authSessionAccessTokenValid(saved) && OPNAppDelegateSupport.authSessionClientTokenValid(saved)
        let canRefreshSavedSession = OPNAppDelegateSupport.authSessionAccessTokenValid(saved) || !saved.refreshToken.isEmpty || !saved.clientToken.isEmpty
        _ = OPNSentry.recordCounterMetric(key: "opennow.auth.startup.count", value: 1, attributes: [
            "saved_session": saved.isAuthenticated,
            "auto_sign_in": shouldAutoSignIn,
            "refresh_needed": shouldAutoSignIn && canRefreshSavedSession && !canUseSavedSessionAsIs
        ])
        if shouldAutoSignIn && canUseSavedSessionAsIs {
            currentSession = saved
            transitionToScreen(OPNDesktopScreen.store.rawValue)
        } else if shouldAutoSignIn && canRefreshSavedSession {
            showAuthenticating(message: "Refreshing session...")
            let selfBox = OPNDesktopWeakObject(self)
            OPNAuthServiceDirect.shared.refreshSession(force: false) { success, freshObject, _ in
                let freshBox = OPNDesktopSendableValue(freshObject)
                Task { @MainActor in
                    guard let self = selfBox.value else { return }
                    if success {
                        _ = OPNSentry.recordCounterMetric(key: "opennow.auth.refresh.count", value: 1, attributes: ["source": "startup", "outcome": "success"])
                        self.currentSession = freshBox.value
                        OPNAuthServiceDirect.shared.saveSession(freshBox.value)
                        self.refreshAccountMenu()
                        self.transitionToScreen(OPNDesktopScreen.store.rawValue)
                    } else {
                        _ = OPNSentry.recordCounterMetric(key: "opennow.auth.refresh.count", value: 1, attributes: ["source": "startup", "outcome": "failure"])
                        let fallback = OPNAuthServiceDirect.shared.loadSavedSession()
                        if fallback.isAuthenticated && OPNAppDelegateSupport.authSessionAccessTokenValid(fallback) {
                            self.currentSession = fallback
                            self.transitionToScreen(OPNDesktopScreen.store.rawValue)
                        } else {
                            self.transitionToScreen(OPNDesktopScreen.emailEntry.rawValue)
                        }
                    }
                }
            }
        } else {
            transitionToScreen(OPNDesktopScreen.emailEntry.rawValue)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        restoreSavedWindowPresentation()
        startApplicationUpdateChecks()
        startDesktopControllerPolling()
        launchTrace?.setStatus(true)
        launchTrace?.finish()
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        _ = OPNSentry.recordCounterMetric(key: "opennow.app.lifecycle.count", value: 1, attributes: ["phase": "terminate"])
        NotificationCenter.default.removeObserver(self)
        window?.saveFrame(usingName: opnMainWindowFrameAutosaveName)
        saveWindowPresentation()
        stopApplicationUpdateChecks()
        stopDesktopControllerPolling()
        stopGameLibraryRefreshTimer()
        stopActiveSessionPromptControllerPolling()
        stopStreamDashboardControllerPolling()
        desktopAccountSwitcher = nil
        desktopRemainingPlayTimePill = nil
        desktopRemainingPlayTimeLabel = nil
        streamingController?.shutdownForApplicationTermination()
        streamingController = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        _ = sender
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = sender
        streamingController?.shutdownForApplicationTermination()
        streamingController = nil
        return .terminateNow
    }

    @objc func installMainMenu() {
        let appName = ProcessInfo.processInfo.processName.isEmpty ? "OpenNOW" : ProcessInfo.processInfo.processName
        let mainMenu = NSMenu(title: "")

        let appMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: appName)
        appMenuItem.submenu = appMenu
        appMenu.addItem(opnDesktopMenuItem("About " + appName, #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", NSApp))
        appMenu.addItem(.separator())
        appMenu.addItem(opnDesktopMenuItem("Settings...", #selector(showSettingsFromMenu(_:)), ",", self))
        appMenu.addItem(opnDesktopMenuItem("Check for Updates...", #selector(checkForUpdatesFromMenu(_:)), "", self))
        appMenu.addItem(.separator())
        let servicesMenu = NSMenu(title: "Services")
        let servicesItem = opnDesktopMenuItem("Services", nil, "", nil)
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(opnDesktopMenuItem("Hide " + appName, #selector(NSApplication.hide(_:)), "h", NSApp))
        appMenu.addItem(opnDesktopMenuItem("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option], target: NSApp))
        appMenu.addItem(opnDesktopMenuItem("Show All", #selector(NSApplication.unhideAllApplications(_:)), "", NSApp))
        appMenu.addItem(.separator())
        appMenu.addItem(opnDesktopMenuItem("Quit " + appName, #selector(NSApplication.terminate(_:)), "q", NSApp))

        let fileMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(opnDesktopMenuItem("Refresh Library", #selector(refreshLibraryFromMenu(_:)), "r", self))
        fileMenu.addItem(.separator())
        fileMenu.addItem(opnDesktopMenuItem("Close Window", #selector(NSWindow.performClose(_:)), "w", nil))

        let editMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(opnDesktopMenuItem("Undo", NSSelectorFromString("undo:"), "z", nil))
        editMenu.addItem(opnDesktopMenuItem("Redo", NSSelectorFromString("redo:"), "Z", modifiers: [.command, .shift], target: nil))
        editMenu.addItem(.separator())
        editMenu.addItem(opnDesktopMenuItem("Cut", #selector(NSText.cut(_:)), "x", nil))
        editMenu.addItem(opnDesktopMenuItem("Copy", #selector(NSText.copy(_:)), "c", nil))
        editMenu.addItem(opnDesktopMenuItem("Paste", #selector(NSText.paste(_:)), "v", nil))
        editMenu.addItem(opnDesktopMenuItem("Delete", #selector(NSText.delete(_:)), "", nil))
        editMenu.addItem(opnDesktopMenuItem("Select All", #selector(NSText.selectAll(_:)), "a", nil))

        let viewMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(opnDesktopMenuItem("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control], target: nil))

        let accountMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        mainMenu.addItem(accountMenuItem)
        let accountMenu = NSMenu(title: "Account")
        accountMenuItem.submenu = accountMenu
        accountMenu.addItem(opnDesktopMenuItem("Manage NVIDIA Account...", #selector(openAccountManagementFromMenu(_:)), "", self))

        let windowMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(opnDesktopMenuItem("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", nil))
        windowMenu.addItem(opnDesktopMenuItem("Zoom", #selector(NSWindow.performZoom(_:)), "", nil))
        windowMenu.addItem(.separator())
        windowMenu.addItem(opnDesktopMenuItem("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", NSApp))
        NSApp.windowsMenu = windowMenu

        let helpMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        helpMenu.addItem(opnDesktopMenuItem("OpenNOW Help", #selector(openOpenNOWWebsiteFromMenu(_:)), "?", self))
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = mainMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showSettingsFromMenu(_:)) {
            return OPNAppDelegateSupport.supportsDesktopNavigation(forScreen: Int(currentScreen)) && !hasVisibleStreamingController()
        }
        if menuItem.action == #selector(refreshLibraryFromMenu(_:)) {
            return currentSession.isAuthenticated && !gameLibraryRefreshInFlight && !hasVisibleStreamingController()
        }
        if menuItem.action == #selector(checkForUpdatesFromMenu(_:)) {
            return !updateCheckInFlight
        }
        return true
    }

    @objc func showSettingsFromMenu(_ sender: Any?) {
        _ = sender
        if OPNAppDelegateSupport.supportsDesktopNavigation(forScreen: Int(currentScreen)) && !hasVisibleStreamingController() {
            transitionToScreen(OPNDesktopScreen.settings.rawValue)
        }
    }

    @objc func refreshLibraryFromMenu(_ sender: Any?) {
        _ = sender
        guard currentSession.isAuthenticated, !gameLibraryRefreshInFlight, !hasVisibleStreamingController() else { return }
        refreshGameLibraryInBackground()
        refreshFeaturedGamesForCatalog(canRetry: true)
        refreshActiveSessionsForCatalog()
    }

    @objc func checkForUpdatesFromMenu(_ sender: Any?) {
        _ = sender
        checkForApplicationUpdates(showingCurrentStatus: true)
    }

    @objc func openAccountManagementFromMenu(_ sender: Any?) {
        _ = sender
        OPNAppDelegateSupport.openExternalURLString(opnAccountManagementURLString)
    }

    @objc func openOpenNOWWebsiteFromMenu(_ sender: Any?) {
        _ = sender
        OPNAppDelegateSupport.openExternalURLString("https://github.com/OpenCloudGaming/OpenNOW-Mac")
    }

    @objc func restoreSavedWindowPresentation() {
        guard UserDefaults.standard.bool(forKey: opnMainWindowWasFullScreenKey) else { return }
        let selfBox = OPNDesktopWeakObject(self)
        DispatchQueue.main.async {
            guard let self = selfBox.value, let window = self.window, !OPNAppDelegateSupport.windowIsFullScreen(window) else { return }
            window.toggleFullScreen(nil)
        }
    }

    @objc func saveWindowPresentation() {
        UserDefaults.standard.set(OPNAppDelegateSupport.windowIsFullScreen(window), forKey: opnMainWindowWasFullScreenKey)
        UserDefaults.standard.synchronize()
    }

    @objc func restartApplication() {
        window?.saveFrame(usingName: opnMainWindowFrameAutosaveName)
        saveWindowPresentation()
        let task = Process()
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension.lowercased() == "app" {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", bundleURL.path]
        } else {
            var executablePath = ProcessInfo.processInfo.arguments.first ?? Bundle.main.executablePath ?? ""
            if !executablePath.isEmpty && !(executablePath as NSString).isAbsolutePath {
                executablePath = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(executablePath)
            }
            task.executableURL = executablePath.isEmpty ? nil : URL(fileURLWithPath: executablePath)
            task.arguments = []
            task.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        }

        do {
            guard task.executableURL != nil else { throw CocoaError(.fileNoSuchFile) }
            try task.run()
            NSApp.terminate(self)
        } catch {
            OPNSentry.logErrorMessage("[AppDelegate] Restart launch failed: \(error.localizedDescription)")
        }
    }

    @objc func startApplicationUpdateChecks() {
        guard applicationUpdateCheckTimer == nil else { return }
        let selfBox = OPNDesktopWeakObject(self)
        DispatchQueue.main.async { selfBox.value?.checkForApplicationUpdates(showingCurrentStatus: false) }
        applicationUpdateCheckTimer = Timer.scheduledTimer(timeInterval: 60.0 * 60.0, target: self, selector: #selector(applicationUpdateCheckTimerFired(_:)), userInfo: nil, repeats: true)
    }

    @objc func stopApplicationUpdateChecks() {
        applicationUpdateCheckTimer?.invalidate()
        applicationUpdateCheckTimer = nil
    }

    @objc func applicationUpdateCheckTimerFired(_ timer: Timer) {
        _ = timer
        checkForApplicationUpdates(showingCurrentStatus: false)
    }

    @objc func checkForApplicationUpdates() {
        checkForApplicationUpdates(showingCurrentStatus: true)
    }

    @objc(checkForApplicationUpdatesShowingCurrentStatus:)
    func checkForApplicationUpdates(showingCurrentStatus showCurrentStatus: Bool) {
        guard !updateCheckInFlight else { return }
        updateCheckInFlight = true
        if githubUpdater == nil { githubUpdater = OPNGitHubUpdater(owner: "OpenCloudGaming", repository: "OpenNOW-Mac") }
        guard let githubUpdater else { updateCheckInFlight = false; return }
        let selfBox = OPNDesktopWeakObject(self)
        githubUpdater.checkForUpdate { release, error in
            let releaseBox = OPNDesktopSendableValue(release)
            let errorBox = OPNDesktopSendableValue(error)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                self.updateCheckInFlight = false
                if let error = errorBox.value {
                    guard showCurrentStatus else { return }
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Update check failed"
                    alert.informativeText = error.localizedDescription.isEmpty ? "OpenNOW could not check GitHub Releases." : error.localizedDescription
                    alert.addButton(withTitle: "OK")
                    if let window = self.window { alert.beginSheetModal(for: window, completionHandler: nil) }
                    return
                }
                guard let release = releaseBox.value else {
                    guard showCurrentStatus else { return }
                    let alert = NSAlert()
                    alert.messageText = "OpenNOW is up to date"
                    alert.informativeText = "Version \(githubUpdater.currentVersion) is the latest release available on GitHub."
                    alert.addButton(withTitle: "OK")
                    if let window = self.window { alert.beginSheetModal(for: window, completionHandler: nil) }
                    return
                }

                var notes = release.releaseNotes.isEmpty ? "No release notes were provided." : release.releaseNotes
                if notes.count > 1400 { notes = String(notes.prefix(1400)) + "\n..." }
                let alert = NSAlert()
                alert.messageText = "OpenNOW \(release.version) is available"
                alert.informativeText = "Current version: \(githubUpdater.currentVersion)\n\nThis update is required to continue using OpenNOW.\n\n\(notes)"
                alert.addButton(withTitle: "Install and Relaunch")
                guard let window = self.window else { return }
                alert.beginSheetModal(for: window) { _ in
                    self.updateCheckInFlight = true
                    githubUpdater.installRelease(release) { launchedInstaller, installError in
                        let installErrorBox = OPNDesktopSendableValue(installError)
                        Task { @MainActor in
                            guard let self = selfBox.value else { return }
                            self.updateCheckInFlight = false
                            if !launchedInstaller || installErrorBox.value != nil {
                                let installAlert = NSAlert()
                                installAlert.alertStyle = .warning
                                installAlert.messageText = "Update install failed"
                                installAlert.informativeText = installErrorBox.value?.localizedDescription ?? "OpenNOW could not install the downloaded update."
                                installAlert.addButton(withTitle: "OK")
                                if let window = self.window { installAlert.beginSheetModal(for: window, completionHandler: nil) }
                                return
                            }
                            NSApp.terminate(self)
                        }
                    }
                }
            }
        }
    }

    @objc func windowFullScreenStateChanged(_ notification: Notification) {
        guard notification.object as AnyObject? === window else { return }
        saveWindowPresentation()
        layoutDesktopTopChrome()
        layoutDesktopAccountSwitcher()
        layoutDesktopSettingsPill()
    }

    @objc func windowGeometryChanged(_ notification: Notification) {
        guard notification.object as AnyObject? === window else { return }
        layoutDesktopTopChrome()
        layoutDesktopAccountSwitcher()
        layoutDesktopSettingsPill()
    }

    @objc func interfacePreferencesChanged(_ notification: Notification) {
        _ = notification
        applyApplicationIconTheme()
        applyInterfacePreferencesToCurrentScreen()
    }

    @objc func applyApplicationIconTheme() {
        if let icon = opnDesktopBrandIconImage() { NSApp.applicationIconImage = icon }
    }

    @objc func applyInterfacePreferencesToCurrentScreen() {
        guard let rootView else { return }
        if currentScreen == OPNDesktopScreen.store.rawValue { rootView.mode = OPNDesktopBackdropMode.store.rawValue }
        else if currentScreen == OPNDesktopScreen.catalog.rawValue { rootView.mode = OPNDesktopBackdropMode.library.rawValue }
        else if currentScreen == OPNDesktopScreen.settings.rawValue { rootView.mode = OPNDesktopBackdropMode.settings.rawValue }
        updateDesktopTopChrome()
        updateDesktopAccountSwitcher()
    }

    @objc func installDesktopTopChromeIfNeeded() {
        guard let rootView else { return }
        if desktopTopChromeView != nil, desktopTopChromeView?.superview !== rootView {
            desktopTopChromeView = nil
            desktopBrandLabel = nil
        }
        if desktopTopChromeView == nil {
            let chrome = NSView(frame: .zero)
            chrome.wantsLayer = true
            chrome.layer?.backgroundColor = NSColor.clear.cgColor
            desktopTopChromeView = chrome

            let brandLabel = opnDesktopLabel("OpenNOW", .zero, 18.0, opnDesktopColor(0xF5F5F7), .black)
            brandLabel.lineBreakMode = .byTruncatingTail
            brandLabel.wantsLayer = true
            brandLabel.layer?.shadowColor = NSColor.black.cgColor
            brandLabel.layer?.shadowOpacity = 0.95
            brandLabel.layer?.shadowRadius = 3.0
            brandLabel.layer?.shadowOffset = .zero
            desktopBrandLabel = brandLabel
            chrome.addSubview(brandLabel)
            rootView.addSubview(chrome, positioned: .above, relativeTo: contentContainer)
        }
        applyApplicationIconTheme()
        layoutDesktopTopChrome()
    }

    @objc func installDesktopAccountSwitcherIfNeeded() {
        guard let rootView else { return }
        if desktopAccountSwitcher != nil, desktopAccountSwitcher?.superview !== rootView {
            desktopAccountSwitcher = nil
            desktopAccountTypePill = nil
            desktopRemainingPlayTimePill = nil
            desktopRemainingPlayTimeLabel = nil
        }
        guard desktopAccountSwitcher == nil else { return }
        let switcher = NSPopUpButton(frame: .zero, pullsDown: false)
        switcher.target = self
        switcher.action = #selector(desktopAccountSwitcherChanged(_:))
        switcher.isBordered = false
        switcher.font = NSFont.systemFont(ofSize: 12.0, weight: .semibold)
        switcher.contentTintColor = opnDesktopColor(0xF5F5F7, alpha: 0.96)
        switcher.focusRingType = .none
        switcher.wantsLayer = true
        switcher.layer?.cornerRadius = 18.0
        switcher.layer?.backgroundColor = opnDesktopColor(0x000000, alpha: 0.50).cgColor
        switcher.layer?.borderColor = NSColor.clear.cgColor
        switcher.layer?.borderWidth = 0.0
        switcher.layer?.shadowColor = NSColor.black.cgColor
        switcher.layer?.shadowOpacity = 0.0
        switcher.layer?.shadowRadius = 0.0
        switcher.layer?.shadowOffset = .zero
        desktopAccountSwitcher = switcher
        rootView.addSubview(switcher, positioned: .above, relativeTo: desktopTopChromeView)

        let accountTypePill = NSButton(frame: .zero)
        accountTypePill.isBordered = false
        accountTypePill.bezelStyle = .regularSquare
        accountTypePill.setButtonType(.momentaryChange)
        accountTypePill.focusRingType = .none
        accountTypePill.target = self
        accountTypePill.action = #selector(desktopAccountTypePillClicked(_:))
        accountTypePill.title = ""
        accountTypePill.wantsLayer = true
        accountTypePill.layer?.cornerRadius = 10.0
        accountTypePill.layer?.backgroundColor = opnDesktopColor(0x000000, alpha: 0.50).cgColor
        accountTypePill.layer?.borderColor = NSColor.clear.cgColor
        accountTypePill.layer?.borderWidth = 0.0
        accountTypePill.layer?.shadowColor = NSColor.black.cgColor
        accountTypePill.layer?.shadowOpacity = 0.0
        accountTypePill.layer?.shadowRadius = 0.0
        accountTypePill.layer?.shadowOffset = .zero
        desktopAccountTypePill = accountTypePill
        rootView.addSubview(accountTypePill, positioned: .above, relativeTo: switcher)

        let playTimePill = NSView(frame: .zero)
        playTimePill.wantsLayer = true
        playTimePill.layer?.cornerRadius = 14.0
        playTimePill.layer?.backgroundColor = opnDesktopColor(0x000000, alpha: 0.50).cgColor
        playTimePill.layer?.borderColor = NSColor.clear.cgColor
        playTimePill.layer?.borderWidth = 0.0
        playTimePill.layer?.shadowColor = NSColor.black.cgColor
        playTimePill.layer?.shadowOpacity = 0.0
        playTimePill.layer?.shadowRadius = 0.0
        playTimePill.layer?.shadowOffset = .zero
        desktopRemainingPlayTimePill = playTimePill

        let playTimeLabel = opnDesktopLabel("Playtime: --", .zero, 11.0, opnDesktopColor(0xF5F5F7, alpha: 0.92), .bold, .center)
        playTimeLabel.lineBreakMode = .byTruncatingTail
        desktopRemainingPlayTimeLabel = playTimeLabel
        playTimePill.addSubview(playTimeLabel)
        rootView.addSubview(playTimePill, positioned: .above, relativeTo: desktopTopChromeView)

        rebuildDesktopAccountSwitcher()
        layoutDesktopAccountSwitcher()
        updateDesktopAccountSwitcher()
    }

    @objc func installDesktopSettingsPillIfNeeded() {
        guard let rootView else { return }
        if desktopSettingsPillButton != nil, desktopSettingsPillButton?.superview !== rootView { desktopSettingsPillButton = nil }
        guard desktopSettingsPillButton == nil else { return }
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.toggle)
        button.focusRingType = .none
        button.target = self
        button.action = #selector(desktopSettingsPillClicked(_:))
        button.wantsLayer = true
        button.layer?.backgroundColor = opnDesktopColor(0x000000, alpha: 0.50).cgColor
        button.layer?.borderColor = NSColor.clear.cgColor
        button.layer?.borderWidth = 0.0
        button.layer?.shadowColor = NSColor.black.cgColor
        button.layer?.shadowOpacity = 0.0
        button.layer?.shadowRadius = 0.0
        button.layer?.shadowOffset = .zero
        desktopSettingsPillButton = button
        rootView.addSubview(button, positioned: .above, relativeTo: desktopRemainingPlayTimePill ?? desktopTopChromeView)
        updateDesktopSettingsPill()
    }

    @objc func layoutDesktopTopChrome() {
        guard let desktopTopChromeView, let rootView, let desktopBrandLabel else { return }
        let width = rootView.bounds.width
        let height = rootView.bounds.height
        let scale = OPNAppDelegateSupport.desktopChromeScale(forHeight: height)
        let chromeHeight = floor(140.0 * scale)
        desktopTopChromeView.frame = NSRect(x: 0.0, y: 0.0, width: width, height: chromeHeight)
        let brandX = max(48.0, floor(width * 0.024))
        let brandFont = NSFont.systemFont(ofSize: 18.0 * scale, weight: .black)
        desktopBrandLabel.font = brandFont
        desktopBrandLabel.attributedStringValue = NSAttributedString(string: "OpenNOW", attributes: [
            .font: brandFont,
            .foregroundColor: opnDesktopColor(0xF5F5F7),
            .strokeColor: NSColor.black,
            .strokeWidth: -3.0
        ])
        desktopBrandLabel.frame = NSRect(x: brandX, y: floor((chromeHeight - 28.0 * scale) * 0.5), width: 180.0 * scale, height: 28.0 * scale)
    }

    @objc func layoutDesktopAccountSwitcher() {
        guard let desktopAccountSwitcher, let desktopAccountTypePill, let desktopRemainingPlayTimePill, let desktopRemainingPlayTimeLabel, let rootView else { return }
        let width = rootView.bounds.width
        let scale = OPNAppDelegateSupport.desktopChromeScale(forHeight: rootView.bounds.height)
        let switcherWidth = min(180.0, max(150.0, width * 0.10))
        let controlHeight = floor(44.0 * scale)
        let accountX = max(24.0, width - switcherWidth - 58.0 * scale)
        let accountY = floor((140.0 * scale - controlHeight) * 0.5)
        desktopAccountSwitcher.frame = NSRect(x: accountX, y: accountY, width: switcherWidth, height: controlHeight)
        let accountTypeHeight = floor(20.0 * scale)
        let accountTypeY = accountY + controlHeight + 6.0 * scale
        desktopAccountTypePill.frame = NSRect(x: accountX + 10.0 * scale, y: accountTypeY, width: switcherWidth - 20.0 * scale, height: accountTypeHeight)
        desktopAccountTypePill.layer?.cornerRadius = accountTypeHeight * 0.5
        let pillWidth = 172.0 * scale
        desktopRemainingPlayTimePill.frame = NSRect(x: accountX - pillWidth - 14.0 * scale, y: accountY, width: pillWidth, height: controlHeight)
        desktopRemainingPlayTimePill.layer?.cornerRadius = controlHeight * 0.5
        desktopRemainingPlayTimeLabel.font = NSFont.systemFont(ofSize: 11.0 * scale, weight: .bold)
        desktopRemainingPlayTimeLabel.frame = desktopRemainingPlayTimePill.bounds.insetBy(dx: 12.0 * scale, dy: 13.0 * scale)
    }

    @objc func layoutDesktopSettingsPill() {
        guard let desktopSettingsPillButton, let rootView else { return }
        let width = rootView.bounds.width
        let scale = OPNAppDelegateSupport.desktopChromeScale(forHeight: rootView.bounds.height)
        let switcherWidth = min(180.0, max(150.0, width * 0.10))
        let controlHeight = floor(44.0 * scale)
        let buttonWidth = floor(124.0 * scale)
        let gap = 14.0 * scale
        let accountX = max(24.0, width - switcherWidth - 58.0 * scale)
        let accountY = floor((140.0 * scale - controlHeight) * 0.5)
        let leftNeighborX = desktopRemainingPlayTimePill?.isHidden == true ? accountX : (desktopRemainingPlayTimePill?.frame.minX ?? accountX)
        desktopSettingsPillButton.frame = NSRect(x: max(24.0, leftNeighborX - buttonWidth - gap), y: accountY, width: buttonWidth, height: controlHeight)
        desktopSettingsPillButton.layer?.cornerRadius = controlHeight * 0.5
    }

    @objc func updateDesktopTopChrome() {
        installDesktopTopChromeIfNeeded()
        updateDesktopAccountSwitcher()
        updateDesktopSettingsPill()
        guard let desktopTopChromeView else { return }
        let visible = OPNAppDelegateSupport.supportsDesktopNavigation(forScreen: Int(currentScreen))
        desktopTopChromeView.isHidden = !visible
        if visible { layoutDesktopTopChrome() }
    }

    @objc func updateDesktopAccountSwitcher() {
        installDesktopAccountSwitcherIfNeeded()
        guard let desktopAccountSwitcher else { return }
        let visible = OPNAppDelegateSupport.supportsDesktopNavigation(forScreen: Int(currentScreen))
        desktopAccountSwitcher.isHidden = !visible
        let accountType = (rootView?.accountStatus ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let accountTypeVisible = visible && !accountType.isEmpty
        desktopAccountTypePill?.isHidden = !accountTypeVisible
        let scale = OPNAppDelegateSupport.desktopChromeScale(forHeight: rootView?.bounds.height ?? 0.0)
        let accountTypeTitle = accountType.isEmpty ? "" : accountType + " Account"
        desktopAccountTypePill?.attributedTitle = NSAttributedString(string: accountTypeTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 9.5 * scale, weight: .black),
            .foregroundColor: opnDesktopColor(0xF5F5F7, alpha: 0.96)
        ])
        let remainingPlayTime = (rootView?.remainingPlayTime ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let playTimeVisible = visible && !remainingPlayTime.isEmpty
        desktopRemainingPlayTimePill?.isHidden = !playTimeVisible
        desktopRemainingPlayTimeLabel?.stringValue = remainingPlayTime.isEmpty ? "Playtime: --" : "Playtime: \(remainingPlayTime)"
        guard visible else { return }
        layoutDesktopAccountSwitcher()
        layoutDesktopSettingsPill()
    }

    @objc func updateDesktopSettingsPill() {
        installDesktopSettingsPillIfNeeded()
        guard let desktopSettingsPillButton else { return }
        let visible = OPNAppDelegateSupport.supportsDesktopNavigation(forScreen: Int(currentScreen))
        desktopSettingsPillButton.isHidden = !visible
        guard visible else { return }
        let selected = currentScreen == OPNDesktopScreen.settings.rawValue
        desktopSettingsPillButton.state = selected ? .on : .off
        let textColor = selected ? opnDesktopColor(0x000000, alpha: 0.96) : opnDesktopColor(0xF5F5F7, alpha: 0.96)
        let backgroundColor = selected ? opnDesktopColor(0x34C759, alpha: 0.94) : opnDesktopColor(0x000000, alpha: 0.50)
        let font = NSFont.systemFont(ofSize: 12.0 * OPNAppDelegateSupport.desktopChromeScale(forHeight: rootView?.bounds.height ?? 0.0), weight: .bold)
        desktopSettingsPillButton.layer?.backgroundColor = backgroundColor.cgColor
        desktopSettingsPillButton.attributedTitle = NSAttributedString(string: "Settings", attributes: [.font: font, .foregroundColor: textColor])
        layoutDesktopSettingsPill()
    }

    @objc func rebuildDesktopAccountSwitcher() {
        guard let desktopAccountSwitcher else { return }
        desktopAccountSwitcher.removeAllItems()
        let currentIdentifierString = OPNAppDelegateSupport.authSessionIdentifier(currentSession)
        var selectedIndex = 0
        var addedAnyAccount = false
        let savedSessions = OPNAuthServiceDirect.shared.loadSavedSessions()
        for sessionObject in savedSessions {
            let identifier = OPNAppDelegateSupport.authSessionIdentifier(sessionObject)
            guard !identifier.isEmpty else { continue }
            let isCurrentSession = identifier == currentIdentifierString
            let sessionForDisplay = isCurrentSession ? currentSession : sessionObject
            desktopAccountSwitcher.addItem(withTitle: OPNAppDelegateSupport.authSessionDisplayName(sessionForDisplay))
            let item = desktopAccountSwitcher.lastItem
            item?.representedObject = identifier
            item?.image = OPNAppDelegateSupport.accountSwitcherImage(forSession: sessionForDisplay, currentAvatar: isCurrentSession ? rootView?.accountAvatarImage : nil)
            if isCurrentSession { selectedIndex = desktopAccountSwitcher.numberOfItems - 1 }
            addedAnyAccount = true
        }

        if !addedAnyAccount && currentSession.isAuthenticated {
            desktopAccountSwitcher.addItem(withTitle: OPNAppDelegateSupport.authSessionDisplayName(currentSession))
            desktopAccountSwitcher.lastItem?.representedObject = currentIdentifierString
            desktopAccountSwitcher.lastItem?.image = OPNAppDelegateSupport.accountSwitcherImage(forSession: currentSession, currentAvatar: rootView?.accountAvatarImage)
        }

        if desktopAccountSwitcher.numberOfItems > 0 { desktopAccountSwitcher.menu?.addItem(.separator()) }
        desktopAccountSwitcher.addItem(withTitle: "Add Account...")
        desktopAccountSwitcher.lastItem?.representedObject = opnDesktopAddAccountIdentifier
        if selectedIndex >= 0 && selectedIndex < desktopAccountSwitcher.numberOfItems { desktopAccountSwitcher.selectItem(at: selectedIndex) }
    }

    @objc func desktopAccountSwitcherChanged(_ sender: NSPopUpButton) {
        let identifier = sender.selectedItem?.representedObject as? String ?? ""
        if identifier == opnDesktopAddAccountIdentifier {
            addAccount()
            return
        }
        switchToAccountIdentifier(identifier)
        rebuildDesktopAccountSwitcher()
    }

    @objc func startDesktopControllerPolling() {
        guard desktopControllerTimer == nil else { return }
        desktopControllerPreviousButtons = 0
        desktopControllerHeldDirections = 0
        desktopControllerLastRepeatTime = 0.0
        desktopControllerTimer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(pollDesktopController(_:)), userInfo: nil, repeats: true)
    }

    @objc func stopDesktopControllerPolling() {
        desktopControllerTimer?.invalidate()
        desktopControllerTimer = nil
        desktopControllerPreviousButtons = 0
        desktopControllerHeldDirections = 0
        desktopControllerLastRepeatTime = 0.0
    }

    @objc func pollDesktopController(_ timer: Timer) {
        _ = timer
        if !OPNAppDelegateSupport.supportsDesktopNavigation(forScreen: Int(currentScreen)) || activeSessionPromptView != nil || cloudmatchServerPickerView != nil || streamDashboardHomeVisible || (streamingController != nil && window?.contentViewController === streamingController) {
            desktopControllerPreviousButtons = 0
            desktopControllerHeldDirections = 0
            return
        }
        let buttons = opnDesktopGamepadButtons()
        let previous = OPNDesktopGamepadButton(rawValue: desktopControllerPreviousButtons)
        let pressed = OPNDesktopGamepadButton(rawValue: buttons.rawValue & ~previous.rawValue)
        let directions = buttons.intersection(.directions)
        let now = CACurrentMediaTime()
        if directions.isEmpty {
            desktopControllerHeldDirections = 0
            desktopControllerLastRepeatTime = 0.0
        } else if directions.rawValue != desktopControllerHeldDirections || now - desktopControllerLastRepeatTime >= 0.18 {
            desktopControllerHeldDirections = directions.rawValue
            desktopControllerLastRepeatTime = now
            routeDesktopGamepadButtons(directions.rawValue)
        }

        let actions = pressed.intersection([.a, .b, .y])
        if !actions.isEmpty { routeDesktopGamepadButtons(actions.rawValue) }
        desktopControllerPreviousButtons = buttons.rawValue
    }

    @objc(routeDesktopGamepadButtons:)
    func routeDesktopGamepadButtons(_ rawButtons: UInt16) {
        let buttons = OPNDesktopGamepadButton(rawValue: rawButtons)
        if buttons.contains(.b) {
            if currentScreen == OPNDesktopScreen.settings.rawValue { transitionToScreen(OPNDesktopScreen.store.rawValue) }
            return
        }

        if currentScreen == OPNDesktopScreen.catalog.rawValue {
            if buttons.contains(.left) { catalogView?.moveGamepadFocus(by: -1) }
            if buttons.contains(.right) { catalogView?.moveGamepadFocus(by: 1) }
            if buttons.contains(.y) { catalogView?.cycleFocusedGamepadVariant() }
            if buttons.contains(.a) { catalogView?.activateGamepadFocus() }
            return
        }

        if currentScreen == OPNDesktopScreen.store.rawValue {
            var rowDelta = 0
            var columnDelta = 0
            if buttons.contains(.up) { rowDelta -= 1 }
            if buttons.contains(.down) { rowDelta += 1 }
            if buttons.contains(.left) { columnDelta -= 1 }
            if buttons.contains(.right) { columnDelta += 1 }
            if rowDelta != 0 || columnDelta != 0 { storeView?.moveGamepadFocusByRows(rowDelta, columns: columnDelta) }
            if buttons.contains(.y) { storeView?.cycleFocusedGamepadVariant() }
            if buttons.contains(.a) { storeView?.activateGamepadFocus() }
            return
        }

        if currentScreen == OPNDesktopScreen.settings.rawValue {
            var delta = 0
            if buttons.contains(.up) { delta -= 1 }
            if buttons.contains(.down) { delta += 1 }
            if delta != 0 { settingsView?.moveGamepadSelection(by: delta) }
            if buttons.contains(.a) { settingsView?.activateGamepadSelection() }
        }
    }
}
