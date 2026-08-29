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

    private var isHovering = false
    private var hoverMonitorTimer: Timer?

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

    func tearDown() {
        applyHoverState(false)
        stopHoverMonitor()
    }

    private func reconcileHoverState() {
        applyHoverState(isCursorInsideBounds())
    }

    private func applyHoverState(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        onHover?(hovering)
        if hovering { startHoverMonitor() } else { stopHoverMonitor() }
    }

    private func isCursorInsideBounds() -> Bool {
        guard let window else { return false }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return bounds.contains(convert(pointInWindow, from: nil))
    }

    // Scrolling moves tiles under a stationary cursor, which produces no mouse events of its own.
    // The poll only runs while this tile believes it is hovered, so at most one is ever live.
    private func startHoverMonitor() {
        guard hoverMonitorTimer == nil else { return }
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileHoverState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverMonitorTimer = timer
    }

    private func stopHoverMonitor() {
        hoverMonitorTimer?.invalidate()
        hoverMonitorTimer = nil
    }
}
