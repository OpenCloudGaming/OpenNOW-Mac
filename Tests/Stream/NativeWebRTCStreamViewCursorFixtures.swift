//  Shared window fixture for pointer-capture tests: the cursor location and warp handler are
//  injected rather than read from the real pointer, so capture arms the same way regardless of
//  where the physical cursor sits (a screen-edge pointer used to make AppKit clamp the window
//  off-screen and fail capture for reasons unrelated to the code under test) and no test run
//  warps the operator's actual cursor.
//

import AppKit
@testable import OpenNOW

@MainActor func makeAbsoluteCursorCaptureWindow() -> (NSWindow, NativeWebRTCStreamView) {
    let contentFrame = NSRect(x: 100, y: 100, width: 1280, height: 720)
    let window = NSWindow(
        contentRect: contentFrame,
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    let view = NativeWebRTCStreamView(frame: window.contentView?.bounds ?? .zero)
    let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
    view.cursorLocationProvider = { center }
    view.cursorWarpHandler = { _ in }
    view.mouseInputMode = .absolute
    view.confinesCursorToWindowInAbsoluteMode = true
    view.cursorAssociationHandler = { _ in .success }
    window.contentView = view
    return (window, view)
}
