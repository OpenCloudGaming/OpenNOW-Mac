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
        // A tile that is clipped out of its scroll view cannot be hovered, and on the home page most
        // of them are: the page is an eager stack of rails, so every rail below the fold still holds
        // its tiles. Checking the cheap clipping test first also keeps a tile scrolled past the top
        // of the clip view from claiming a pointer that is over the bar above it.
        guard let window, !visibleRect.isEmpty else { return false }
        let pointInWindow = window.convertPoint(fromScreen: cursorLocation())
        return bounds.contains(convert(pointInWindow, from: nil))
    }

    // Scrolling moves tiles under a stationary cursor without producing any mouse event of its own,
    // so the pointer alone cannot tell a tile that the content moved: the tile that scrolled under
    // the cursor never hears about it, and the one that scrolled away keeps a highlight it no
    // longer earns. Watch the content moving instead - every clip view this tile lives in, and each
    // of their document views, for scroll offset and size changes - and recompute on each. A clip
    // view only posts when its offset or size actually changes, so a catalog at rest schedules
    // nothing at all, where the timer it replaces woke the run loop 16.7 times a second for as long
    // as any tile was hovered.
    private func observeContentMovement() {
        movementObservers = []
        guard window != nil else { return }
        for clipView in ancestorClipViews() {
            for view in [clipView, clipView.documentView].compactMap({ $0 }) {
                movementObservers.append(AppKitViewMovementObserver(view: view) { [weak self] in
                    self?.reconcileHoverState()
                })
            }
        }
    }

    // Every clip view above this tile, not just the nearest one: a rail tile sits in its own
    // horizontal rail and in the page's vertical stack, and either of them scrolling moves it under
    // the cursor.
    private func ancestorClipViews() -> [NSClipView] {
        var clipViews: [NSClipView] = []
        var node: NSView? = superview
        while let current = node {
            if let clipView = current as? NSClipView { clipViews.append(clipView) }
            node = current.superview
        }
        return clipViews
    }
}
