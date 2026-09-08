import AppKit
import Testing
@testable import OpenNOW

/// The marker mounts as a full-size background of every `opnInterfaceScale` subtree, and the
/// stream's overlay layer is one of them - above the video surface. A hit-testable marker there ate
/// every mouse-down and scroll the stream needed while movement and keys still went through, which
/// read as "clicks stopped working in the stream" at any UI scale other than 1.
@MainActor
@Test func magnifiedSurfaceMarkerNeverTakesAMouseEvent() {
    let marker = OpenNOWMagnifiedSurfaceMarkerView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))

    #expect(marker.hitTest(NSPoint(x: 100, y: 50)) == nil)
    #expect(marker.hitTest(NSPoint(x: 0, y: 0)) == nil)
}
