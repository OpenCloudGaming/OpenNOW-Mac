import AppKit

typealias OPNBackdropView = NSView
typealias OPNGameCatalogView = NSView
typealias OPNSettingsView = NSView
typealias OPNEmailEntryView = NSView
typealias OPNAuthenticatingView = NSView
typealias OPNErrorView = NSView
typealias OPNLoadingView = NSView
typealias OPNCloudmatchServerPickerView = NSView
typealias OPNSessionReportView = NSView
typealias OPNQuitGameOverlayView = NSView
typealias OPNStatsOverlayView = NSView
typealias OPNShortcutLegendView = NSView
typealias OPNActiveSessionPromptView = NSView
typealias OPNOwnershipSyncProgressView = NSView
typealias OPNDesktopChromeView = NSView

@objc(OPNCloudmatchServerOption)
public final class OPNCloudmatchServerOption: NSObject {
    @objc public let name: String
    @objc public let url: String
    @objc public let latencyMs: Int
    @objc(isAutomatic) public let automatic: Bool

    @objc public var latencyText: String {
        if latencyMs < 0 { return "Measuring" }
        return automatic ? "Best \(latencyMs) ms" : "\(latencyMs) ms"
    }

    @objc public var detailText: String {
        if automatic {
            return latencyMs >= 0 ? "Lowest measured region" : "Best available region"
        }
        return name.isEmpty ? "Cloudmatch region" : name
    }

    @objc(initWithName:url:latencyMs:automatic:)
    public init(name: String, url: String, latencyMs: Int, automatic: Bool) {
        self.name = name.isEmpty ? "Cloudmatch" : name
        self.url = url.isEmpty ? "" : url
        self.latencyMs = latencyMs
        self.automatic = automatic
        super.init()
    }
}

@MainActor
enum OPNAppViewBridge {
    static func view(named className: String, frame: NSRect) -> NSView? {
        guard let viewClass = NSClassFromString(className) as? NSView.Type else { return nil }
        return viewClass.init(frame: frame)
    }

    static func view(named className: String, frame: NSRect, string: String) -> NSView? {
        guard let viewClass = NSClassFromString(className) as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("initWithFrame:\(className == "OPNSettingsView" ? "selectedSectionName:" : "message:")")
        guard viewClass.instancesRespond(to: selector) else { return view(named: className, frame: frame) }
        typealias Message = @convention(c) (AnyObject, Selector, NSRect, NSString?) -> NSObject
        let object = unsafeBitCast(viewClass.init().method(for: selector), to: Message.self)(viewClass.init(), selector, frame, string as NSString)
        return object as? NSView
    }

    static func errorView(frame: NSRect, message: String, canRetry: Bool) -> NSView? {
        guard let viewClass = NSClassFromString("OPNErrorView") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("initWithFrame:message:canRetry:")
        guard viewClass.instancesRespond(to: selector) else { return nil }
        typealias Message = @convention(c) (AnyObject, Selector, NSRect, NSString, Bool) -> NSObject
        let receiver = viewClass.init()
        let object = unsafeBitCast(receiver.method(for: selector), to: Message.self)(receiver, selector, frame, message as NSString, canRetry)
        return object as? NSView
    }

    static func serverPickerView(frame: NSRect, gameTitle: String) -> NSView? {
        guard let viewClass = NSClassFromString("OPNCloudmatchServerPickerView") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("initWithFrame:gameTitle:")
        guard viewClass.instancesRespond(to: selector) else { return nil }
        typealias Message = @convention(c) (AnyObject, Selector, NSRect, NSString) -> NSObject
        let receiver = viewClass.init()
        let object = unsafeBitCast(receiver.method(for: selector), to: Message.self)(receiver, selector, frame, gameTitle as NSString)
        return object as? NSView
    }

    static func activeSessionPromptView(frame: NSRect, sessionTitle: String, selectedGameTitle: String) -> NSView? {
        guard let viewClass = NSClassFromString("OPNActiveSessionPromptView") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("initWithFrame:sessionTitle:selectedGameTitle:")
        guard viewClass.instancesRespond(to: selector) else { return nil }
        typealias Message = @convention(c) (AnyObject, Selector, NSRect, NSString, NSString) -> NSObject
        let receiver = viewClass.init()
        let object = unsafeBitCast(receiver.method(for: selector), to: Message.self)(receiver, selector, frame, sessionTitle as NSString, selectedGameTitle as NSString)
        return object as? NSView
    }

    static func sessionReportView(frame: NSRect, report: OPNSessionReportPayload) -> NSView? {
        guard let viewClass = NSClassFromString("OPNSessionReportView") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("initWithFrame:report:")
        guard viewClass.instancesRespond(to: selector) else { return nil }
        typealias Message = @convention(c) (AnyObject, Selector, NSRect, OPNSessionReportPayload) -> NSObject
        let receiver = viewClass.init()
        let object = unsafeBitCast(receiver.method(for: selector), to: Message.self)(receiver, selector, frame, report)
        return object as? NSView
    }
}

@MainActor
extension NSView {
    var mode: Int {
        get { getIntProperty("mode") }
        set { setIntProperty("setMode:", newValue) }
    }

    var accountName: String? {
        get { getObjectProperty("accountName", as: NSString.self) as String? }
        set { setObjectProperty("setAccountName:", newValue as NSString?) }
    }

    var accountStatus: String? {
        get { getObjectProperty("accountStatus", as: NSString.self) as String? }
        set { setObjectProperty("setAccountStatus:", newValue as NSString?) }
    }

    var accountAvatarImage: NSImage? {
        get { getObjectProperty("accountAvatarImage", as: NSImage.self) }
        set { setObjectProperty("setAccountAvatarImage:", newValue) }
    }

    var remainingPlayTime: String? {
        get { getObjectProperty("remainingPlayTime", as: NSString.self) as String? }
        set { setObjectProperty("setRemainingPlayTime:", newValue as NSString?) }
    }

    var gameCountText: String? {
        get { getObjectProperty("gameCountText", as: NSString.self) as String? }
        set { setObjectProperty("setGameCountText:", newValue as NSString?) }
    }

    var accountMenuItems: [[String: String]]? {
        get { getObjectProperty("accountMenuItems", as: NSArray.self) as? [[String: String]] }
        set { setObjectProperty("setAccountMenuItems:", newValue as NSArray?) }
    }

    var currentAccountIdentifier: String? {
        get { getObjectProperty("currentAccountIdentifier", as: NSString.self) as String? }
        set { setObjectProperty("setCurrentAccountIdentifier:", newValue as NSString?) }
    }

    var visible: Bool {
        get { getBoolProperty("visible") }
        set { setBoolProperty("setVisible:", newValue) }
    }

    var settingsSelected: Bool {
        get { getBoolProperty("settingsSelected") }
        set { setBoolProperty("setSettingsSelected:", newValue) }
    }

    var titleText: String {
        get { getObjectProperty("titleText", as: NSString.self) as String? ?? "" }
        set { setObjectProperty("setTitleText:", newValue as NSString) }
    }

    var messageText: String {
        get { getObjectProperty("messageText", as: NSString.self) as String? ?? "" }
        set { setObjectProperty("setMessageText:", newValue as NSString) }
    }

    var footerText: String {
        get { getObjectProperty("footerText", as: NSString.self) as String? ?? "" }
        set { setObjectProperty("setFooterText:", newValue as NSString) }
    }

    var message: String {
        get { getObjectProperty("message", as: NSString.self) as String? ?? "" }
        set { setObjectProperty("setMessage:", newValue as NSString) }
    }

    var messageLabel: NSTextField? {
        getObjectProperty("messageLabel", as: NSTextField.self)
    }

    func assignOnHomeSelected(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnHomeSelected:") }
    func assignOnStoreSelected(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnStoreSelected:") }
    func assignOnLibrarySelected(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnLibrarySelected:") }
    func assignOnSearchSelected(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnSearchSelected:") }
    func assignOnSettingsSelected(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnSettingsSelected:") }
    func assignOnAccountSelected(_ callback: @escaping (String) -> Void) { assignStringCallback(callback, setter: "setOnAccountSelected:") }
    func assignOnAddAccountSelected(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnAddAccountSelected:") }
    func assignOnSignOutSelected(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnSignOutSelected:") }
    func assignOnExitSelected(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnExitSelected:") }
    func assignOnSelectGame(_ callback: @escaping (OPNCatalogGameObject, Int32) -> Void) { assignCatalogGameVariantCallback(callback, setter: "setOnSelectGame:") }
    func assignOnBuyGame(_ callback: @escaping (OPNCatalogGameObject, Int32, String) -> Void) { assignCatalogGamePurchaseCallback(callback, setter: "setOnBuyGame:") }
    func assignOnMarkGameUnowned(_ callback: @escaping (OPNCatalogGameObject, Int32) -> Void) { assignCatalogGameVariantCallback(callback, setter: "setOnMarkGameUnowned:") }
    func assignOnSignOut(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnSignOut:") }
    func assignOnGameCountChanged(_ callback: @escaping (Int) -> Void) { assignIntCallback(callback, setter: "setOnGameCountChanged:") }
    func assignOnCatalogBrowseRequested(_ callback: @escaping (String, String, [String]) -> Void) { assignCatalogBrowseCallback(callback, setter: "setOnCatalogBrowseRequested:") }
    func assignOnInterfaceSettingsRequested(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnInterfaceSettingsRequested:") }
    func assignOnStoreRequested(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnStoreRequested:") }
    func assignOnRestartRequested(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnRestartRequested:") }
    func assignOnExitRequested(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnExitRequested:") }
    func assignOnBackRequested(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnBackRequested:") }
    func assignOnCancel(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnCancel:") }
    func assignOnQuit(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnQuit:") }
    func assignOnRefresh(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnRefresh:") }
    func assignOnConfirm(_ callback: @escaping (OPNCloudmatchServerOption) -> Void) { assignCloudmatchOptionCallback(callback, setter: "setOnConfirm:") }
    func assignOnCheckForUpdatesRequested(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnCheckForUpdatesRequested:") }
    func assignOnContinue(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnContinue:") }
    func assignOnDelete(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnDelete:") }
    func assignOnDone(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnDone:") }
    func assignOnRetry(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnRetry:") }
    func assignOnBackToEmail(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnBackToEmail:") }
    func assignOnSignInWithBrowser(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnSignInWithBrowser:") }
    func assignOnManageAccountSelected(_ callback: @escaping () -> Void) { assignVoidCallback(callback, setter: "setOnManageAccountSelected:") }
    func assignAdPlaybackEventHandler(_ callback: @escaping (String, String, Int, Int, String) -> Void) { assignAdPlaybackCallback(callback, setter: "setAdPlaybackEventHandler:") }

    func selectedProviderIdentifier() -> String {
        let selector = NSSelectorFromString("selectedProviderIdentifier")
        guard responds(to: selector) else { return "" }
        typealias Message = @convention(c) (AnyObject, Selector) -> NSString
        return unsafeBitCast(method(for: selector), to: Message.self)(self, selector) as String
    }

    func setProviderItems(ids: [String], labels: [String], selectedId: String) {
        let selector = NSSelectorFromString("setProviderItemsWithIds:labels:selectedId:")
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, NSArray, NSArray, NSString) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector, ids as NSArray, labels as NSArray, selectedId as NSString)
    }

    func setFeaturedGameObjects(_ games: [OPNCatalogGameObject]) { performArraySelector("setFeaturedGameObjects:", games) }
    func setPanelObjects(_ panels: [OPNCatalogPanelObject]) { performArraySelector("setPanelObjects:", panels) }
    func setLibraryGameObjects(_ games: [OPNCatalogGameObject]) { performArraySelector("setLibraryGameObjects:", games) }
    func setGameObjects(_ games: [OPNCatalogGameObject]) { performArraySelector("setGameObjects:", games) }
    func setActiveSessionAppIds(_ appIds: [NSNumber]) { performArraySelector("setActiveSessionAppIds:", appIds) }
    func cycleFocusedGamepadVariant() { performVoidSelector("cycleFocusedGamepadVariant") }

    func setCatalogBrowseResultObject(_ result: OPNCatalogBrowseResultObject?) {
        let selector = NSSelectorFromString("setCatalogBrowseResultObject:")
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, OPNCatalogBrowseResultObject?) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector, result)
    }

    func setError(_ message: String) {
        let selector = NSSelectorFromString("setError:")
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, NSString) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector, message as NSString)
    }

    func setOptions(_ options: [OPNCloudmatchServerOption], selectedRegionUrl: String, refreshing: Bool) {
        let selector = NSSelectorFromString("setOptions:selectedRegionUrl:refreshing:")
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, NSArray, NSString, Bool) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector, options as NSArray, selectedRegionUrl as NSString, refreshing)
    }

    func setStatusMessage(_ message: String, isError: Bool) {
        let selector = NSSelectorFromString("setStatusMessage:isError:")
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, NSString, Bool) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector, message as NSString, isError)
    }

    func setRefreshing(_ refreshing: Bool) {
        let selector = NSSelectorFromString("setRefreshing:")
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector, refreshing)
    }

    func setLoading(_ loading: Bool) {
        let selector = NSSelectorFromString("setLoading:")
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector, loading)
    }

    func setUserName(_ name: String) {
        let selector = NSSelectorFromString("setUserName:")
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, NSString) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector, name as NSString)
    }

    func setSteps(_ steps: [String], currentStepIndex: Int) {
        let selector = NSSelectorFromString("setSteps:currentStepIndex:")
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, NSArray, Int) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector, steps as NSArray, currentStepIndex)
    }

    func startAnimating() { performVoidSelector("startAnimating") }
    func stopAnimating() { performVoidSelector("stopAnimating") }
    func updateQueuePosition(_ queuePosition: Int) { performIntSelector("updateQueuePosition:", queuePosition) }
    func clearAdPresentation() { performVoidSelector("clearAdPresentation") }

    func updateAdState(_ adState: NSDictionary) {
        let selector = NSSelectorFromString("updateAdState:")
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, NSDictionary) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector, adState)
    }

    func update(latencyMs: Int, bitrateMbps: Double, packetsLost: Int64, resolution: String, fps: Int, renderFps: Double, codec: String, enhancement: String, framesDropped: UInt64) {
        let selector = NSSelectorFromString("updateLatencyMs:bitrateMbps:packetsLost:resolution:fps:renderFps:codec:enhancement:framesDropped:")
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, Int, Double, Int64, NSString, Int, Double, NSString, NSString, UInt64) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector, latencyMs, bitrateMbps, packetsLost, resolution as NSString, fps, renderFps, codec as NSString, enhancement as NSString, framesDropped)
    }

    func moveGamepadFocus(by delta: Int) { performIntSelector("moveGamepadFocusBy:", delta) }
    func moveGamepadFocusByRows(_ rows: Int, columns: Int) {
        let selector = NSSelectorFromString("moveGamepadFocusByRows:columns:")
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, Int, Int) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector, rows, columns)
    }
    func activateGamepadFocus() { performVoidSelector("activateGamepadFocus") }
    func moveGamepadSelection(by delta: Int) { performIntSelector("moveGamepadSelectionBy:", delta) }
    func activateGamepadSelection() { performVoidSelector("activateGamepadSelection") }

    private func performVoidSelector(_ name: String) {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector)
    }

    private func performIntSelector(_ name: String, _ value: Int) {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector, value)
    }

    private func performArraySelector<T>(_ name: String, _ value: [T]) {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, NSArray) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector, value as NSArray)
    }

    private func getObjectProperty<T>(_ name: String, as type: T.Type) -> T? {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return nil }
        typealias Message = @convention(c) (AnyObject, Selector) -> AnyObject?
        return unsafeBitCast(method(for: selector), to: Message.self)(self, selector) as? T
    }

    private func setObjectProperty(_ name: String, _ value: AnyObject?) {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector, value)
    }

    private func getIntProperty(_ name: String) -> Int {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return 0 }
        typealias Message = @convention(c) (AnyObject, Selector) -> Int
        return unsafeBitCast(method(for: selector), to: Message.self)(self, selector)
    }

    private func setIntProperty(_ name: String, _ value: Int) {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector, value)
    }

    private func getBoolProperty(_ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return false }
        typealias Message = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method(for: selector), to: Message.self)(self, selector)
    }

    private func setBoolProperty(_ name: String, _ value: Bool) {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method(for: selector), to: Message.self)(self, selector, value)
    }

    private func assignVoidCallback(_ callback: @escaping () -> Void, setter name: String) {
        let block: VoidCallback = callback
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, VoidCallback?) -> Void
        withExtendedLifetime(block) {
            unsafeBitCast(method(for: selector), to: Message.self)(self, selector, block)
        }
    }

    private func assignStringCallback(_ callback: @escaping (String) -> Void, setter name: String) {
        let block: StringCallback = { value in callback(value as String) }
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, StringCallback?) -> Void
        withExtendedLifetime(block) {
            unsafeBitCast(method(for: selector), to: Message.self)(self, selector, block)
        }
    }

    private func assignCatalogGameVariantCallback(_ callback: @escaping (OPNCatalogGameObject, Int32) -> Void, setter name: String) {
        let block: CatalogGameVariantCallback = callback
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, CatalogGameVariantCallback?) -> Void
        withExtendedLifetime(block) {
            unsafeBitCast(method(for: selector), to: Message.self)(self, selector, block)
        }
    }

    private func assignCatalogGamePurchaseCallback(_ callback: @escaping (OPNCatalogGameObject, Int32, String) -> Void, setter name: String) {
        let block: CatalogGamePurchaseCallback = { game, variantIndex, purchaseURL in callback(game, variantIndex, purchaseURL as String) }
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, CatalogGamePurchaseCallback?) -> Void
        withExtendedLifetime(block) {
            unsafeBitCast(method(for: selector), to: Message.self)(self, selector, block)
        }
    }

    private func assignIntCallback(_ callback: @escaping (Int) -> Void, setter name: String) {
        let block: IntCallback = callback
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, IntCallback?) -> Void
        withExtendedLifetime(block) {
            unsafeBitCast(method(for: selector), to: Message.self)(self, selector, block)
        }
    }

    private func assignCatalogBrowseCallback(_ callback: @escaping (String, String, [String]) -> Void, setter name: String) {
        let block: CatalogBrowseCallback = { searchQuery, sortId, filterIds in callback(searchQuery as String, sortId as String, filterIds as? [String] ?? []) }
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, CatalogBrowseCallback?) -> Void
        withExtendedLifetime(block) {
            unsafeBitCast(method(for: selector), to: Message.self)(self, selector, block)
        }
    }

    private func assignCloudmatchOptionCallback(_ callback: @escaping (OPNCloudmatchServerOption) -> Void, setter name: String) {
        let block: CloudmatchOptionCallback = callback
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, CloudmatchOptionCallback?) -> Void
        withExtendedLifetime(block) {
            unsafeBitCast(method(for: selector), to: Message.self)(self, selector, block)
        }
    }

    private func assignAdPlaybackCallback(_ callback: @escaping (String, String, Int, Int, String) -> Void, setter name: String) {
        let block: AdPlaybackCallback = { event, adId, positionMs, durationMs, errorMessage in callback(event as String, adId as String, positionMs, durationMs, errorMessage as String) }
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Message = @convention(c) (AnyObject, Selector, AdPlaybackCallback?) -> Void
        withExtendedLifetime(block) {
            unsafeBitCast(method(for: selector), to: Message.self)(self, selector, block)
        }
    }
}

private typealias VoidCallback = @convention(block) () -> Void
private typealias StringCallback = @convention(block) (NSString) -> Void
private typealias CatalogGameVariantCallback = @convention(block) (OPNCatalogGameObject, Int32) -> Void
private typealias CatalogGamePurchaseCallback = @convention(block) (OPNCatalogGameObject, Int32, NSString) -> Void
private typealias IntCallback = @convention(block) (Int) -> Void
private typealias CatalogBrowseCallback = @convention(block) (NSString, NSString, NSArray) -> Void
private typealias CloudmatchOptionCallback = @convention(block) (OPNCloudmatchServerOption) -> Void
private typealias AdPlaybackCallback = @convention(block) (NSString, NSString, Int, Int, NSString) -> Void
