//  The stream window's close button always asks.
//
//  `OPNMainWindowCloseGuard` attaches to the window whose scene identifier is `main` and is
//  explicitly documented as leaving every other window alone, so the dedicated stream window needs a
//  guard of its own: without one its close button would close the window, and the stream session
//  lives in that window's content (`NativeNVSTMediaStreamSurface` holds it in a `@StateObject`).
//  `applicationShouldTerminateAfterLastWindowClosed` decides whether the *app* dies; it does not save
//  the window's content.
//
//  The two guards are separate on purpose. The main window's behaviour is a user preference with
//  three outcomes; the stream window's is one fixed answer - show the stream controls panel and let
//  the user choose - with no setting of its own.
//
//  `windowShouldClose` always answers `false`. The window's lifetime belongs to
//  `OPNStreamWindowPresenter`, and a real close tears the hosting view down, which would end the
//  session without a decision. The handler decides whether to dismiss instead.
//

import AppKit

/// The stream window's delegate while the guard is installed.
///
/// `forwardee` is weak and unused in practice - the window is AppKit-owned, so there is no SwiftUI
/// delegate to displace - but it stays because the window is handed a `NSHostingView` as its content
/// and a future content owner would otherwise silently lose its delegate messages.
@MainActor
final class OPNStreamWindowCloseDelegateProxy: NSObject, NSWindowDelegate {
    /// Read from ObjC message forwarding, which AppKit only calls on the main thread.
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
        guard let window = sender as? OPNStreamWindow else { return false }
        if let forwardee, forwardee.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))),
           forwardee.windowShouldClose?(sender) == false {
            return false
        }
        // Never `true`: the presenter owns the window's lifetime. The handler dismisses the window
        // itself when the user's answer or a cancelled launch says it should go.
        _ = window.closeRequestHandler?()
        return false
    }
}

@MainActor
enum OPNStreamWindowCloseGuard {
    /// Installs on a freshly created stream window. Idempotent, so a window reused for a later
    /// session keeps one guard rather than a stack of them.
    @discardableResult
    static func install(on window: OPNStreamWindow) -> OPNStreamWindowCloseDelegateProxy {
        if let existing = window.delegate as? OPNStreamWindowCloseDelegateProxy { return existing }
        let proxy = OPNStreamWindowCloseDelegateProxy(forwardee: window.delegate)
        window.delegate = proxy
        OPNLog.info(.app, "Stream window close guard installed; the close button always asks")
        return proxy
    }

    /// Restores whatever delegate the window had, for the window's teardown.
    static func uninstall(from window: OPNStreamWindow) {
        guard let proxy = window.delegate as? OPNStreamWindowCloseDelegateProxy else { return }
        window.delegate = proxy.forwardee
    }
}
