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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
