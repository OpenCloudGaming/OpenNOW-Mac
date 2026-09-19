import AppKit

/// The app's single main window, as AppKit sees it. SwiftUI owns the window, so the scene identity
/// (`Window(id: "main")`) is the only handle the app has on it.
@MainActor
enum OPNMainWindow {
    static let identifier = "main"

    static func existing() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == identifier }
    }

    /// Brings the window up the way the menu bar asks for it: a window sitting in the Dock comes back
    /// with its place kept, and one that was closed outright is rebuilt by the scene that owns it.
    static func reveal() {
        guard let window = existing(), window.isMiniaturized else { return }
        window.deminiaturize(nil)
    }
}

/// Enforces `OPNWindowClosePreferences.behavior` on the main window's close button.
///
/// The quit choice is enforced here rather than left to AppKit's last-window hook: a status item
/// puts an `NSStatusBarWindow` in `NSApp.windows`, and with one present AppKit no longer calls
/// `applicationShouldTerminateAfterLastWindowClosed` when the main window closes. Quitting is
/// therefore explicit, and still goes through `applicationShouldTerminate`, so the in-stream quit
/// decision is asked exactly as it was.
///
/// `NSWindow.delegate` is a single slot and SwiftUI owns it, so this cannot simply *be* the delegate:
/// the guard installs a proxy that answers `windowShouldClose` and forwards every other delegate
/// message to whatever SwiftUI installed, which keeps the window's own behaviour (restoration, focus,
/// full screen) exactly as it was. `NSWindowDelegate.windowWillClose` and friends still reach SwiftUI.
///
/// The proxy is re-asserted whenever the main window updates or becomes key: a swap SwiftUI made
/// after the first install would otherwise drop the guard without anything noticing.
@MainActor
enum OPNMainWindowCloseGuard {
    private static var observerTokens: [NSObjectProtocol] = []
    private static var proxy: OPNMainWindowCloseDelegateProxy?

    /// The quit itself, as a seam: the tests assert that closing the button asks for termination
    /// without ending the process running them.
    static var terminateApplication: () -> Void = { NSApp.terminate(nil) }

    static func install() {
        guard observerTokens.isEmpty else { return }
        for name in [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                // The notification itself is never carried across the isolation boundary: the main
                // window is looked up on the main actor instead.
                MainActor.assumeIsolated {
                    guard let window = OPNMainWindow.existing() else { return }
                    install(on: window)
                }
            }
            observerTokens.append(token)
        }
    }

    static func uninstall() {
        for token in observerTokens { NotificationCenter.default.removeObserver(token) }
        observerTokens.removeAll()
        if let window = OPNMainWindow.existing(), window.delegate === proxy, let forwardee = proxy?.forwardee {
            window.delegate = forwardee
        }
        proxy = nil
    }

    /// Attaches to the main window only. Every other window — the Remote Co-Op guest window — keeps
    /// closing exactly the way it always has.
    static func install(on window: NSWindow) {
        guard window.identifier?.rawValue == OPNMainWindow.identifier else { return }
        let displaced = window.delegate
        if displaced === proxy { return }
        // The delegate slot is never taken before SwiftUI claims it. A window still being set up
        // presents itself through SwiftUI's own delegate, and displacing it at that point leaves the
        // window created but never shown — live-verified: the app launched with no window at all.
        // An already-visible window with no delegate is past that point and safe to take over, which
        // is the backstop for a window SwiftUI never claims.
        guard displaced != nil || window.isVisible else { return }
        let proxy = OPNMainWindowCloseDelegateProxy(forwardee: displaced)
        window.delegate = proxy
        Self.proxy = proxy
        OPNLog.info(.app, "Main window close guard installed; \(OPNWindowClosePreferences.behavior.rawValue) closes the window")
    }
}

/// The main window's delegate while the guard is installed.
///
/// `forwardee` is weak on purpose: SwiftUI's delegate belongs to SwiftUI, and keeping it alive here
/// would keep a torn-down window's owner receiving delegate messages. If it goes away, this proxy
/// still answers the one message the guard exists for.
@MainActor
final class OPNMainWindowCloseDelegateProxy: NSObject, NSWindowDelegate {
    /// Read from ObjC message forwarding — `responds(to:)` and `forwardingTarget(for:)` are
    /// nonisolated entry points that AppKit calls on the main thread only. The unchecked annotation
    /// states that, rather than claiming a thread safety this type does not have.
    private(set) nonisolated(unsafe) weak var forwardee: NSWindowDelegate?

    init(forwardee: NSWindowDelegate?) {
        self.forwardee = forwardee
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return forwardee?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        guard let forwardee, forwardee.responds(to: aSelector) else { return nil }
        return forwardee
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Whatever SwiftUI installed gets the first word: it owns the window, and a refusal it has
        // already made must not be overridden by a close-button preference.
        if let forwardee, forwardee.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))),
           forwardee.windowShouldClose?(sender) == false {
            return false
        }
        let behavior = OPNWindowClosePreferences.behavior
        OPNLog.info(.app, "Main window close button answered with \(behavior.rawValue)")
        switch behavior {
        case .quitApplication:
            // Asked before the close so the window never outlives the decision: the app is quitting,
            // not merely losing its window. The stream quit-decision path is inside this call.
            OPNMainWindowCloseGuard.terminateApplication()
            return true
        case .keepRunningInDock, .menuBarOnly:
            // The window closes; `applicationShouldTerminateAfterLastWindowClosed` refuses the quit,
            // which is what keeps the app alive. Whether it then sits in the Dock or withdraws to the
            // menu bar is `OPNDockIconController`'s decision, not the close button's.
            return true
        }
    }
}
