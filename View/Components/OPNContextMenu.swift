import AppKit
import SwiftUI

/// The frame of reference and row registry for a custom context menu.
///
/// The surface that owns the rows registers itself as the anchor and each row registers its view;
/// a right-click is resolved to a row only when it happens. No hit-testing view sits over the rows,
/// so the left clicks, drags, and hover they own are untouched, and no per-scroll-frame measurement
/// is needed.
@MainActor
final class OPNContextSurface {
    weak var anchorView: NSView?
    private var rowViews: [UUID: WeakView] = [:]

    func registerRow(_ id: UUID, view: NSView) {
        rowViews[id] = WeakView(view)
    }

    func unregisterRow(_ id: UUID, view: NSView) {
        guard rowViews[id]?.view === view else { return }
        rowViews[id] = nil
    }

    /// True when the click lands anywhere inside the owning surface, rows or not.
    func contains(event: NSEvent) -> Bool {
        guard let anchorView, event.window === anchorView.window else { return false }
        let localPoint = anchorView.convert(event.locationInWindow, from: nil)
        return anchorView.bounds.contains(localPoint)
    }

    /// Resolves a click to the row under it and the point in the surface's top-left space, or nil
    /// when it misses every row.
    func resolve(event: NSEvent) -> (id: UUID, point: CGPoint)? {
        guard let anchorView, event.window === anchorView.window else { return nil }
        let anchorPoint = anchorView.convert(event.locationInWindow, from: nil)
        guard anchorView.bounds.contains(anchorPoint) else { return nil }

        for (id, box) in rowViews {
            guard let view = box.view, view.window === event.window else { continue }
            let rowPoint = view.convert(event.locationInWindow, from: nil)
            if view.bounds.contains(rowPoint) {
                return (id, CGPoint(x: anchorPoint.x, y: anchorView.bounds.height - anchorPoint.y))
            }
        }
        return nil
    }

    private final class WeakView {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }
}

/// Installs the surface's single context-click monitor and registers the surface's anchor view.
/// Placed as the owner's background; it draws nothing.
struct OPNContextMenuHost: NSViewRepresentable {
    let surface: OPNContextSurface
    let onContextClick: (UUID, CGPoint) -> Void
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> OPNContextHostView {
        let view = OPNContextHostView()
        view.surface = surface
        view.onContextClick = onContextClick
        view.onDismiss = onDismiss
        surface.anchorView = view
        view.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: OPNContextHostView, context: Context) {
        nsView.surface = surface
        nsView.onContextClick = onContextClick
        nsView.onDismiss = onDismiss
        surface.anchorView = nsView
    }

    static func dismantleNSView(_ nsView: OPNContextHostView, coordinator: ()) {
        nsView.stopMonitoring()
        nsView.onContextClick = nil
        nsView.onDismiss = nil
        if nsView.surface?.anchorView === nsView {
            nsView.surface?.anchorView = nil
        }
    }
}

final class OPNContextHostView: NSView {
    var surface: OPNContextSurface?
    var onContextClick: ((UUID, CGPoint) -> Void)?
    var onDismiss: (() -> Void)?
    private var monitor: Any?

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, let surface else { return event }
        let isContextClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard isContextClick else { return event }

        // A click outside the surface still closes an open menu, but is left for whatever owns it.
        guard surface.contains(event: event) else {
            onDismiss?()
            return event
        }

        if let hit = surface.resolve(event: event) {
            onContextClick?(hit.id, hit.point)
        } else {
            onDismiss?()
        }
        return nil
    }
}

/// Registers one row's view with the surface so a click can be resolved to it. Placed as the row's
/// background; it draws nothing and never takes part in hit testing.
struct OPNContextRowAnchor: NSViewRepresentable {
    let surface: OPNContextSurface
    let id: UUID

    func makeNSView(context: Context) -> OPNContextRowView {
        let view = OPNContextRowView()
        view.surface = surface
        view.id = id
        surface.registerRow(id, view: view)
        return view
    }

    func updateNSView(_ nsView: OPNContextRowView, context: Context) {
        nsView.surface = surface
        nsView.id = id
        surface.registerRow(id, view: nsView)
    }

    static func dismantleNSView(_ nsView: OPNContextRowView, coordinator: ()) {
        guard let surface = nsView.surface, let id = nsView.id else { return }
        surface.unregisterRow(id, view: nsView)
    }
}

final class OPNContextRowView: NSView {
    var surface: OPNContextSurface?
    var id: UUID?
}

/// The styled right-click menu: a square Dropdown panel anchored at the pointer, presented as an
/// overlay on the surface that owns the rows so their scroll view cannot clip it. A click outside
/// or Escape dismisses; the panel clamps to the surface and flips above the pointer when it would
/// not fit below.
struct OPNContextMenuOverlay: View {
    let items: [OPNDropdownItem]
    let anchor: CGPoint
    let dismiss: () -> Void

    @Environment(\.opnUIScale) private var uiScale
    @State private var panelSize: CGSize = .zero

    private var panelWidth: CGFloat {
        OPNDropdownPanel.minimumWidth(scale: uiScale)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)

                OPNDropdownPanel(items: dismissingItems, width: panelWidth)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { panelSize = $0 }
                    .offset(x: origin(in: proxy.size).x, y: origin(in: proxy.size).y)

                Button(action: dismiss) { EmptyView() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var dismissingItems: [OPNDropdownItem] {
        items.map { item in
            OPNDropdownItem(
                id: item.id,
                title: item.title,
                isSelected: item.isSelected,
                isDestructive: item.isDestructive,
                startsGroup: item.startsGroup
            ) {
                dismiss()
                item.action()
            }
        }
    }

    private func origin(in size: CGSize) -> CGPoint {
        let width = panelSize.width > 0 ? panelSize.width : panelWidth
        let height = panelSize.height
        let x = min(max(anchor.x, 0), max(size.width - width, 0))
        let y = anchor.y + height <= size.height ? anchor.y : max(anchor.y - height, 0)
        return CGPoint(x: x, y: y)
    }
}
