import AppKit
import SwiftUI

/// Precise, tile-sized hover tracking for catalog tiles.
///
/// The content stays in the enclosing SwiftUI graph and only an empty AppKit view rides along
/// behind it as the tracking surface. An earlier version hosted the content inside a per-tile
/// `NSHostingView` instead, which gave every tile its own nested view graph: sizing a rail had to
/// recurse into each one, and every update reassigned `rootView` with a full copy of the
/// environment (never equal, so always a rebuild, down to a fresh `NSAppearance` per tile). With a
/// few hundred tiles on the home page that was the whole scroll budget and then some.
struct CatalogHoverTracker<Content: View>: View {
    private let onHover: (Bool) -> Void
    private let content: Content

    init(onHover: @escaping (Bool) -> Void, @ViewBuilder content: () -> Content) {
        self.onHover = onHover
        self.content = content()
    }

    var body: some View {
        content
            .background(CatalogHoverTrackingSurface(onHover: onHover))
    }
}

private struct CatalogHoverTrackingSurface: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> CatalogHoverTrackingNSView {
        let view = CatalogHoverTrackingNSView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: CatalogHoverTrackingNSView, context: Context) {
        nsView.onHover = onHover
    }

    static func dismantleNSView(_ nsView: CatalogHoverTrackingNSView, coordinator: ()) {
        nsView.tearDown()
    }
}

final class CatalogHoverTrackingNSView: NSView {
    var onHover: ((Bool) -> Void)?

    /// Where the pointer is, in screen coordinates. Injectable so a test can hold the pointer still
    /// without moving the real one.
    var cursorLocation: @MainActor () -> NSPoint = { NSEvent.mouseLocation }

    private var isHovering = false
    private var movementObservers: [AppKitViewMovementObserver] = []

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        // Precise tile-sized tracking rect. `.inVisibleRect` resolves to the
        // enclosing scroll clip region for these views, which lights an entire
        // row at once.
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { reconcileHoverState() }
    override func mouseMoved(with event: NSEvent) { reconcileHoverState() }
    override func mouseExited(with event: NSEvent) { reconcileHoverState() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { applyHoverState(false) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeContentMovement()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeContentMovement()
    }

    func tearDown() {
        applyHoverState(false)
        movementObservers = []
    }

    func reconcileHoverState() {
        applyHoverState(isCursorInsideBounds())
    }

    private func applyHoverState(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        onHover?(hovering)
    }

    private func isCursorInsideBounds() -> Bool {
        guard let window else { return false }
        // `visibleRect` is the clip region in this view's coordinates, not intersected with its own
        // bounds, so it has to be combined with them: on its own it also covers the gutter beside a tile
        // narrower than its viewport, and the bounds alone cover the part a scroll has clipped away.
        let hoverableBounds = bounds.intersection(visibleRect)
        guard !hoverableBounds.isEmpty else { return false }
        let pointInWindow = window.convertPoint(fromScreen: cursorLocation())
        return hoverableBounds.contains(convert(pointInWindow, from: nil))
    }

    // Scrolling moves tiles under a stationary cursor without producing any mouse event of its own, so
    // the pointer alone cannot tell a tile that the content moved. Watch the geometry of the surfaces
    // the tile rides in instead, and recompute on each change.
    private func observeContentMovement() {
        // Dropping the observations here is also what releases the tile: `NotificationCenter` retains
        // the `object` a block observer is registered against, so observing this view is a cycle until
        // this array is emptied. Every teardown path goes through this method or `tearDown()`.
        movementObservers = []
        guard window != nil else { return }
        for view in movementSources() {
            movementObservers.append(AppKitViewMovementObserver(view: view) { [weak self] in
                self?.reconcileHoverState()
            })
        }
    }

    // The tile itself and every scroll surface above it: the clip view that scrolls, that clip view's
    // document view, and the scroll view that can be repositioned around it. A rail tile is in two of
    // each, its own rail and the page, and either one moving puts it under a different pointer.
    private func movementSources() -> [NSView] {
        var sources: [NSView] = [self]
        var node: NSView? = superview
        while let current = node {
            if let clipView = current as? NSClipView {
                sources.append(clipView)
                if let documentView = clipView.documentView { sources.append(documentView) }
                if let scrollView = clipView.superview as? NSScrollView { sources.append(scrollView) }
            }
            node = current.superview
        }
        return sources
    }
}
