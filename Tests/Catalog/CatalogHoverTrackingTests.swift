import AppKit
import Testing
@testable import OpenNOW

/// Covers the invalidation path the catalog hover tracker is built on: the highlight follows the
/// content when a scroll moves it under a stationary pointer, and it releases the tile that scrolled
/// away. The pointer is steered through the tracking surface's injected location, so no test moves
/// the real cursor. Hover is delivered outside SwiftUI's update pass, so every expectation waits for
/// it rather than reading it straight after the event.
@Suite(.serialized, .disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason))) @MainActor
struct CatalogHoverTrackingTests {
    @Test func aScrollMovesTheHighlightWithoutMovingThePointer() async {
        let fixture = HoverFixture()
        defer { fixture.close() }

        fixture.reconcileHover()
        await fixture.settleHover(on: "pageTile")

        // The rail tile is two clip views down: this needs every clip view above it, not the nearest.
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
        await fixture.settleHover(on: "railTile")

        fixture.scrollRail(to: 700)
        await fixture.settleHover(on: "railTile2")
        #expect(fixture.hoveredTile == "railTile2")
    }

    @Test func pointerMovementStillDrivesHoverWithoutAScroll() async throws {
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
        await fixture.settleHover(on: "pageTile")

        // The pointer slides sideways off the tile into the gutter beside it.
        fixture.pointCursor(at: NSPoint(x: 450, y: 50))
        fixture.pageTile.mouseMoved(with: event)
        await fixture.settleHover(on: nil)

        // And onto the rail, which the page scroll has brought under it.
        fixture.scrollPage(to: 100)
        fixture.pointCursor(at: NSPoint(x: 200, y: 50))
        fixture.railTile.mouseEntered(with: event)
        await fixture.settleHover(on: "railTile")

        fixture.pointCursor(at: NSPoint(x: 450, y: 50))
        fixture.railTile.mouseExited(with: event)
        await fixture.settleHover(on: nil)
    }

    /// The reported defect: the tracker wrote SwiftUI state synchronously, so a tile moving under a
    /// stationary pointer — or a dismantled one reporting its exit — wrote it inside the layout pass
    /// that caused the move, which SwiftUI reports as modifying state during view update.
    @Test func hoverIsDeliveredOutsideTheLayoutPassThatMovedTheTile() async {
        let fixture = HoverFixture()
        defer { fixture.close() }

        fixture.reconcileHover()
        #expect(fixture.hoveredTile == nil, "the state write landed inside the pass that reported the move")
        await fixture.settleHover(on: "pageTile")
    }

    @Test func aPointerOverTheClippedPartOfATileDoesNotHoverIt() async {
        let fixture = HoverFixture()
        defer { fixture.close() }

        // The straddling tile runs from rail x 300 to 700 while the rail viewport ends at 400, so the
        // pointer can be inside its bounds and outside the part of it the viewport shows.
        fixture.scrollPage(to: 100)

        fixture.pointCursor(at: NSPoint(x: 350, y: 50))
        fixture.reconcileHover()
        await fixture.settleHover(on: "straddlingTile")

        fixture.pointCursor(at: NSPoint(x: 450, y: 50))
        fixture.reconcileHover()
        await fixture.settleHover(on: nil)
    }
}

@MainActor
private final class HoverFixture {
    // The page viewport is wider than the rail, leaving a gutter at x 400..500 that no tile covers.
    let pageScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
    let pageDocument = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let railScrollView = NSScrollView(frame: NSRect(x: 0, y: 100, width: 400, height: 100))
    let railDocument = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 100))
    let pageTile = CatalogHoverTrackingNSView()
    let railTile = CatalogHoverTrackingNSView()
    let straddlingTile = CatalogHoverTrackingNSView()
    let railTile2 = CatalogHoverTrackingNSView()
    let window: NSWindow

    private let surfaces: [(surface: CatalogHoverTrackingNSView, name: String)]
    private(set) var hoveredTile: String?

    init() {
        surfaces = [
            (pageTile, "pageTile"),
            (railTile, "railTile"),
            (straddlingTile, "straddlingTile"),
            (railTile2, "railTile2"),
        ]

        pageScrollView.hasVerticalScroller = false
        pageScrollView.hasHorizontalScroller = false
        railScrollView.hasVerticalScroller = false
        railScrollView.hasHorizontalScroller = false

        pageTile.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        railTile.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        straddlingTile.frame = NSRect(x: 300, y: 0, width: 400, height: 100)
        railTile2.frame = NSRect(x: 700, y: 0, width: 400, height: 100)
        pageDocument.addSubview(pageTile)
        for surface in [railTile, straddlingTile, railTile2] {
            railDocument.addSubview(surface)
        }
        railScrollView.documentView = railDocument
        pageDocument.addSubview(railScrollView)
        pageScrollView.documentView = pageDocument

        window = NSWindow(contentRect: pageScrollView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pageScrollView
        window.orderFrontRegardless()

        for (surface, name) in surfaces {
            surface.onHover = { [weak self] isHovering in
                guard let self else { return }
                if isHovering {
                    self.hoveredTile = name
                } else if self.hoveredTile == name {
                    self.hoveredTile = nil
                }
            }
        }

        pointCursor(at: NSPoint(x: 200, y: 50))
    }

    func reconcileHover() {
        for (surface, _) in surfaces {
            surface.reconcileHoverState()
        }
    }

    func pointCursor(at pointInWindow: NSPoint) {
        let cursorOnScreen = window.convertPoint(toScreen: pointInWindow)
        for (surface, _) in surfaces {
            surface.cursorLocation = { cursorOnScreen }
        }
    }

    func scrollPage(to offset: CGFloat) {
        scroll(pageScrollView, to: NSPoint(x: 0, y: offset))
    }

    func scrollRail(to offset: CGFloat) {
        scroll(railScrollView, to: NSPoint(x: offset, y: 0))
    }

    /// Hover is delivered on the next main-actor turn, outside the update pass, and a clip view's
    /// bounds change reaches the surface a turn after that. Wait rather than assuming one turn.
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
