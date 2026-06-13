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
        get { value(forKey: "mode") as? Int ?? 0 }
        set { setValue(newValue, forKey: "mode") }
    }

    var accountName: String? {
        get { value(forKey: "accountName") as? String }
        set { setValue(newValue, forKey: "accountName") }
    }

    var accountStatus: String? {
        get { value(forKey: "accountStatus") as? String }
        set { setValue(newValue, forKey: "accountStatus") }
    }

    var accountAvatarImage: NSImage? {
        get { value(forKey: "accountAvatarImage") as? NSImage }
        set { setValue(newValue, forKey: "accountAvatarImage") }
    }

    var remainingPlayTime: String? {
        get { value(forKey: "remainingPlayTime") as? String }
        set { setValue(newValue, forKey: "remainingPlayTime") }
    }

    var gameCountText: String? {
        get { value(forKey: "gameCountText") as? String }
        set { setValue(newValue, forKey: "gameCountText") }
    }

    var accountMenuItems: [[String: String]]? {
        get { value(forKey: "accountMenuItems") as? [[String: String]] }
        set { setValue(newValue, forKey: "accountMenuItems") }
    }

    var currentAccountIdentifier: String? {
        get { value(forKey: "currentAccountIdentifier") as? String }
        set { setValue(newValue, forKey: "currentAccountIdentifier") }
    }

    var onHomeSelected: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onHomeSelected") } }
    var onStoreSelected: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onStoreSelected") } }
    var onLibrarySelected: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onLibrarySelected") } }
    var onSearchSelected: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onSearchSelected") } }
    var onSettingsSelected: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onSettingsSelected") } }
    var onAccountSelected: ((String) -> Void)? { get { nil } set { setValue(newValue, forKey: "onAccountSelected") } }
    var onAddAccountSelected: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onAddAccountSelected") } }
    var onSignOutSelected: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onSignOutSelected") } }
    var onExitSelected: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onExitSelected") } }

    var onSelectGame: ((OPNCatalogGameObject, Int32) -> Void)? { get { nil } set { setValue(newValue, forKey: "onSelectGame") } }
    var onBuyGame: ((OPNCatalogGameObject, Int32, String) -> Void)? { get { nil } set { setValue(newValue, forKey: "onBuyGame") } }
    var onMarkGameUnowned: ((OPNCatalogGameObject, Int32) -> Void)? { get { nil } set { setValue(newValue, forKey: "onMarkGameUnowned") } }
    var onSignOut: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onSignOut") } }
    var onGameCountChanged: ((Int) -> Void)? { get { nil } set { setValue(newValue, forKey: "onGameCountChanged") } }
    var onCatalogBrowseRequested: ((String, String, [String]) -> Void)? { get { nil } set { setValue(newValue, forKey: "onCatalogBrowseRequested") } }
    var onInterfaceSettingsRequested: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onInterfaceSettingsRequested") } }
    var onStoreRequested: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onStoreRequested") } }
    var onRestartRequested: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onRestartRequested") } }
    var onExitRequested: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onExitRequested") } }
    var onBackRequested: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onBackRequested") } }
    var onCancel: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onCancel") } }
    var onQuit: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onQuit") } }
    var onRefresh: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onRefresh") } }
    var onConfirm: ((OPNCloudmatchServerOption) -> Void)? { get { nil } set { setValue(newValue, forKey: "onConfirm") } }
    var onCheckForUpdatesRequested: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onCheckForUpdatesRequested") } }
    var onContinue: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onContinue") } }
    var onDelete: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onDelete") } }
    var onDone: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onDone") } }
    var onRetry: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onRetry") } }
    var onBackToEmail: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onBackToEmail") } }
    var onSignInWithBrowser: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onSignInWithBrowser") } }
    var onManageAccountSelected: (() -> Void)? { get { nil } set { setValue(newValue, forKey: "onManageAccountSelected") } }

    var visible: Bool {
        get { value(forKey: "visible") as? Bool ?? false }
        set { setValue(newValue, forKey: "visible") }
    }

    var settingsSelected: Bool {
        get { value(forKey: "settingsSelected") as? Bool ?? false }
        set { setValue(newValue, forKey: "settingsSelected") }
    }

    var titleText: String {
        get { value(forKey: "titleText") as? String ?? "" }
        set { setValue(newValue, forKey: "titleText") }
    }

    var messageText: String {
        get { value(forKey: "messageText") as? String ?? "" }
        set { setValue(newValue, forKey: "messageText") }
    }

    var footerText: String {
        get { value(forKey: "footerText") as? String ?? "" }
        set { setValue(newValue, forKey: "footerText") }
    }

    var message: String {
        get { value(forKey: "message") as? String ?? "" }
        set { setValue(newValue, forKey: "message") }
    }

    var messageLabel: NSTextField? {
        value(forKey: "messageLabel") as? NSTextField
    }

    var adPlaybackEventHandler: ((String, String, Int, Int, String) -> Void)? {
        get { nil }
        set { setValue(newValue, forKey: "adPlaybackEventHandler") }
    }

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
}
