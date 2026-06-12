import Cocoa

import AppKit

@objc(OPNAppDelegateWrapper)
@MainActor
final class OPNAppDelegate: NSObject, NSApplicationDelegate {
    private let legacyDelegate: NSApplicationDelegate?

    override init() {
        OPNLogCapture.start()
        OPNSentry.initializeSentry()
        let delegateClass = NSClassFromString("AppDelegate") as? NSObject.Type
        legacyDelegate = delegateClass?.init() as? NSApplicationDelegate
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let legacyDelegate else {
            NSApp.terminate(nil)
            return
        }
        legacyDelegate.applicationDidFinishLaunching?(notification)
    }

    func applicationWillTerminate(_ notification: Notification) {
        legacyDelegate?.applicationWillTerminate?(notification)
        OPNSentry.closeSentry()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        legacyDelegate?.applicationShouldTerminateAfterLastWindowClosed?(sender) ?? true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        legacyDelegate?.applicationShouldTerminate?(sender) ?? .terminateNow
    }
}
