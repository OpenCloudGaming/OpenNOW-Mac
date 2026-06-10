import AppKit

OPNLogCapture.start()
OPNSentry.initializeSentry()

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = OPNAppDelegate()
app.delegate = delegate
app.run()

OPNSentry.closeSentry()
