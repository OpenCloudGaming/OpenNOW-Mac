import AppKit
import SwiftUI

struct CatalogHoverTracker<Content: View>: NSViewRepresentable {
    let onHover: (Bool) -> Void
    let content: Content

    init(onHover: @escaping (Bool) -> Void, @ViewBuilder content: () -> Content) {
        self.onHover = onHover
        self.content = content()
    }

    func makeNSView(context: Context) -> CatalogHoverTrackingNSView {
        let view = CatalogHoverTrackingNSView(rootView: AnyView(content.environment(\.self, context.environment)))
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: CatalogHoverTrackingNSView, context: Context) {
        nsView.onHover = onHover
        nsView.rootView = AnyView(content.environment(\.self, context.environment))
    }
}

final class CatalogHoverTrackingNSView: NSHostingView<AnyView> {
    var onHover: ((Bool) -> Void)?

    private var isHovering = false
    private var hoverMonitorTimer: Timer?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        // Precise tile-sized tracking rect. `.inVisibleRect` resolves to the
        // enclosing scroll clip region for these hosting views, which lights
        // an entire row at once.
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { reconcileHoverState() }
    override func mouseMoved(with event: NSEvent) { reconcileHoverState() }
    override func mouseExited(with event: NSEvent) { reconcileHoverState() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { applyHoverState(false) }
        super.viewWillMove(toWindow: newWindow)
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
