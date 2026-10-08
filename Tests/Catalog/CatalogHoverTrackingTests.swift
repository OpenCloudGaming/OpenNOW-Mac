import AppKit
import Testing
@testable import OpenNOW

/// Covers the invalidation path the catalog hover tracker is built on: the highlight follows the
/// content when a scroll moves it under a stationary pointer, and it releases the tile that scrolled
/// away. The pointer is steered through the tracking surface's injected location, so no test moves
/// the real cursor.
@Suite(.serialized, .disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason))) @MainActor
struct CatalogHoverTrackingTests {
    @Test func aScrollMovesTheHighlightWithoutMovingThePointer() async {
        let fixture = HoverFixture()
        defer { fixture.close() }

        fixture.reconcileHover()
        #expect(fixture.hoveredTile == "pageTile")

        // The page scrolls the rail under the pointer: the rail tile is two clip views down, so this
        // only works if the tracker watches every clip view above it, not just the nearest one.
        fixture.scrollPage(to: 100)
        await fixture.settleHover(on: "railTile")
        #expect(fixture.hoveredTile == "railTile")

        // The pointer is now over the empty run below the rail.
        fixture.scrollPage(to: 300)
        await fixture.settleHover(on: nil)
        #expect(fixture.hoveredTile == nil)
    }

    @Test func aRailScrollMovesTheHighlightAcrossTheRow() async {
        let fixture = HoverFixture()
        defer { fixture.close() }

        fixture.scrollPage(to: 100)
        fixture.reconcileHover()
        #expect(fixture.hoveredTile == "railTile")

        fixture.scrollRail(to: 400)
        await fixture.settleHover(on: "railTile2")
        #expect(fixture.hoveredTile == "railTile2")
    }

    @Test func pointerMovementStillDrivesHoverWithoutAScroll() throws {
        let fixture = HoverFixture()
        defer { fixture.close() }
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        fixture.pointCursor(at: NSPoint(x: 200, y: 50))
        fixture.pageTile.mouseEntered(with: event)
        #expect(fixture.hoveredTile == "pageTile")

        // The pointer slides sideways off the tile into the gutter beside it.
        fixture.pointCursor(at: NSPoint(x: 450, y: 50))
        fixture.pageTile.mouseMoved(with: event)
        #expect(fixture.hoveredTile == nil)

        // And onto the rail, which the page scroll has brought under it.
        fixture.scrollPage(to: 100)
        fixture.pointCursor(at: NSPoint(x: 200, y: 50))
        fixture.railTile.mouseEntered(with: event)
        #expect(fixture.hoveredTile == "railTile")

        fixture.pointCursor(at: NSPoint(x: 450, y: 50))
        fixture.railTile.mouseExited(with: event)
        #expect(fixture.hoveredTile == nil)
    }
}

@MainActor
private final class HoverFixture {
    // The page viewport is wider than the rail, leaving a gutter at x 400..500 that no tile covers.
    let pageScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
    let pageDocument = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let railScrollView = NSScrollView(frame: NSRect(x: 0, y: 100, width: 400, height: 100))
    let railDocument = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
    let pageTile = CatalogHoverTrackingNSView()
    let railTile = CatalogHoverTrackingNSView()
    let railTile2 = CatalogHoverTrackingNSView()
    let window: NSWindow

    private(set) var hoveredTile: String?

    init() {
        pageScrollView.hasVerticalScroller = false
        pageScrollView.hasHorizontalScroller = false
        railScrollView.hasVerticalScroller = false
        railScrollView.hasHorizontalScroller = false

        pageTile.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        railTile.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        railTile2.frame = NSRect(x: 400, y: 0, width: 400, height: 100)
        pageDocument.addSubview(pageTile)
        railDocument.addSubview(railTile)
        railDocument.addSubview(railTile2)
        railScrollView.documentView = railDocument
        pageDocument.addSubview(railScrollView)
        pageScrollView.documentView = pageDocument

        window = NSWindow(contentRect: pageScrollView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pageScrollView
        window.orderFrontRegardless()

        for (surface, name) in [(pageTile, "pageTile"), (railTile, "railTile"), (railTile2, "railTile2")] {
            surface.onHover = { [weak self] hovering in
                guard let self else { return }
                if hovering {
                    self.hoveredTile = name
                } else if self.hoveredTile == name {
                    self.hoveredTile = nil
                }
            }
        }

        // The pointer rests in the middle of the viewport until a test steers it. The surfaces
        // resolve it through this closure so no test has to move the real cursor.
        let cursorOnScreen = window.convertPoint(toScreen: NSPoint(x: 200, y: 50))
        for surface in [pageTile, railTile, railTile2] {
            surface.cursorLocation = { cursorOnScreen }
        }
    }

    func reconcileHover() {
        for surface in [pageTile, railTile, railTile2] {
            surface.reconcileHoverState()
        }
    }

    func pointCursor(at pointInWindow: NSPoint) {
        let cursorOnScreen = window.convertPoint(toScreen: pointInWindow)
        for surface in [pageTile, railTile, railTile2] {
            surface.cursorLocation = { cursorOnScreen }
        }
    }

    func scrollPage(to offset: CGFloat) {
        scroll(pageScrollView, to: NSPoint(x: 0, y: offset))
    }

    func scrollRail(to offset: CGFloat) {
        scroll(railScrollView, to: NSPoint(x: offset, y: 0))
    }

    /// The clip view posts its bounds change through a main-queue notification, so the hover state
    /// settles a turn later. Wait for it rather than assuming a single turn is enough.
    func settleHover(on expected: String?) async {
        for _ in 0..<20 {
            if hoveredTile == expected { return }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func close() {
        window.close()
    }

    private func scroll(_ scrollView: NSScrollView, to origin: NSPoint) {
        let clipView = scrollView.contentView
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }
}
