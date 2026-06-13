import Cocoa

import AppKit

@objc(OPNAppDelegateWrapper)
@MainActor
public final class OPNAppDelegate: NSObject, NSApplicationDelegate {
    private let legacyDelegate: NSApplicationDelegate?

    public override init() {
        OPNLogCapture.start()
        OPNSentry.initializeSentry()
        let delegateClass = NSClassFromString("AppDelegate") as? NSObject.Type
        legacyDelegate = delegateClass?.init() as? NSApplicationDelegate
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        guard let legacyDelegate else {
            NSApp.terminate(nil)
            return
        }
        legacyDelegate.applicationDidFinishLaunching?(notification)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        legacyDelegate?.applicationWillTerminate?(notification)
        OPNSentry.closeSentry()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        legacyDelegate?.applicationShouldTerminateAfterLastWindowClosed?(sender) ?? true
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        legacyDelegate?.applicationShouldTerminate?(sender) ?? .terminateNow
    }
}
