import AppKit
import SwiftUI

struct OPNDropdownItem: Identifiable {
    let id: String
    let title: String
    var isSelected = false
    var isDestructive = false
    /// Draws a 1px Stroke Subtle rule above this row, separating it from the group before it.
    var startsGroup = false
    let action: () -> Void
}

struct OPNDropdownRow: View {
    let title: String
    var isSelected = false
    var isDestructive = false
    let action: () -> Void

    @Environment(\.opnUIScale) private var uiScale
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                Text(title)
                    .catalogFont(size: 12, weight: .bold)
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .catalogFont(size: 11, weight: .bold)
                        .foregroundStyle(OPNDesign.accent)
                }
            }
            .padding(.horizontal, OPNDesign.Spacing.controlRow(scale: uiScale))
            .frame(maxWidth: .infinity, minHeight: 30 * uiScale, alignment: .leading)
            .background(isHovering ? Color.white.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var foreground: Color {
        if isDestructive { return OPNDesign.Semantic.destructive }
        return isHovering ? OPNDesign.Text.primary : OPNDesign.Text.secondary
    }
}

struct OPNDropdownPanel: View {
    let items: [OPNDropdownItem]
    var width: CGFloat?
    var visibleItemCount: Int?

    @Environment(\.opnUIScale) private var uiScale

    static func minimumWidth(scale: CGFloat) -> CGFloat {
        208 * scale
    }

    static func rowHeight(scale: CGFloat) -> CGFloat {
        30 * scale
    }

    var body: some View {
        Group {
            if let visibleItemCount, visibleItemCount > 0 {
                ScrollView(.vertical) {
                    rows
                }
                .contentMargins(.trailing, 12, for: .scrollContent)
                .frame(height: CGFloat(min(items.count, visibleItemCount)) * Self.rowHeight(scale: uiScale))
            } else {
                rows
            }
        }
        .padding(.vertical, OPNDesign.Spacing.menuPanelVertical(scale: uiScale))
        .frame(minWidth: width == nil ? Self.minimumWidth(scale: uiScale) : nil)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .frame(width: width)
        .background(OPNDesign.Surface.panelRaised)
        .overlay {
            Rectangle()
                .stroke(OPNDesign.Stroke.regular, lineWidth: 1)
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                if item.startsGroup {
                    Rectangle()
                        .fill(OPNDesign.Stroke.subtle)
                        .frame(height: 1)
                        .padding(.vertical, OPNDesign.Spacing.xxSmall(scale: uiScale))
                }
                OPNDropdownRow(
                    title: item.title,
                    isSelected: item.isSelected,
                    isDestructive: item.isDestructive,
                    action: item.action
                )
            }
        }
    }
}

struct OPNDropdownMenu<Label: View>: View {
    let items: [OPNDropdownItem]
    var isDisabled = false
    var visibleItemCount: Int?
    /// Opens leftward by default, for a menu whose trigger sits at the right edge of a narrow column
    /// (the HUD sidebar) where opening right would cover the video. An edge check still wins if there
    /// is not enough room to the left.
    var opensLeftByDefault = false
    @ViewBuilder let label: () -> Label

    @Environment(\.opnUIScale) private var uiScale
    @State private var isPresented = false
    @State private var triggerSize: CGSize = .zero
    @State private var panelHeight: CGFloat = 0
    @State private var spaceProbe = DropdownSpaceProbe()

    var body: some View {
        Button {
            spaceProbe.refresh()
            isPresented.toggle()
        } label: { label() }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { triggerSize = proxy.size }
                    .onChange(of: proxy.size) { _, newSize in triggerSize = newSize }
            }
        )
        .background(DropdownSpaceProbeView(probe: spaceProbe))
        .overlay {
            if isPresented {
                Color.black.opacity(0.001)
                    .frame(width: 6000, height: 6000)
                    .contentShape(Rectangle())
                    .onTapGesture { isPresented = false }
            }
        }
        .overlay(alignment: panelAlignment) {
            if isPresented {
                panel
            }
        }
        .onExitCommand { isPresented = false }
        .onChange(of: items.map(\.id)) { _, _ in isPresented = false }
        // The panel is an overlay, so it still obeys sibling paint order: without this an open
        // menu draws underneath any control laid out after it.
        .zIndex(isPresented ? 1 : 0)
    }

    private var anchorSpacing: CGFloat {
        OPNDesign.Spacing.xxSmall(scale: uiScale)
    }

    private var panelWidth: CGFloat {
        max(OPNDropdownPanel.minimumWidth(scale: uiScale), triggerSize.width)
    }

    /// Opens away from the window edge the panel would otherwise run past.
    ///
    /// A menu near the right of a narrow sidebar used to open rightward, off the sidebar and over the
    /// video, where it read as a translucent, garbled list. The same applies vertically.
    private var opensLeft: Bool {
        guard spaceProbe.isConstrained else { return opensLeftByDefault }
        if opensLeftByDefault {
            // Stay inside the narrow column, but never off the window's left edge.
            return spaceProbe.spaceLeft >= panelWidth || spaceProbe.spaceLeft > spaceProbe.spaceRight
        }
        return spaceProbe.spaceRight < panelWidth && spaceProbe.spaceLeft > spaceProbe.spaceRight
    }

    private var opensUp: Bool {
        guard spaceProbe.isConstrained, panelHeight > 0 else { return false }
        return spaceProbe.spaceBelow < panelHeight && spaceProbe.spaceAbove > spaceProbe.spaceBelow
    }

    private var panelAlignment: Alignment {
        switch (opensLeft, opensUp) {
        case (false, false): return .topLeading
        case (true, false): return .topTrailing
        case (false, true): return .bottomLeading
        case (true, true): return .bottomTrailing
        }
    }

    private var panelVerticalOffset: CGFloat {
        let magnitude = triggerSize.height + anchorSpacing
        return opensUp ? -magnitude : magnitude
    }

    @ViewBuilder
    private var panel: some View {
        let available = (opensUp ? spaceProbe.spaceAbove : spaceProbe.spaceBelow) - anchorSpacing

        if spaceProbe.isConstrained, available > 0, panelHeight > available {
            ScrollView(.vertical) {
                measuredPanel
            }
            .frame(width: panelWidth, height: available)
            .offset(y: panelVerticalOffset)
        } else {
            measuredPanel
                .offset(y: panelVerticalOffset)
        }
    }

    private var measuredPanel: some View {
        OPNDropdownPanel(items: dismissingItems, width: panelWidth, visibleItemCount: visibleItemCount)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                panelHeight = height
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
                isPresented = false
                item.action()
            }
        }
    }
}

@MainActor
private final class DropdownSpaceProbe {
    weak var probeView: NSView?
    private(set) var spaceBelow: CGFloat = 0
    private(set) var spaceAbove: CGFloat = 0
    private(set) var spaceLeft: CGFloat = 0
    private(set) var spaceRight: CGFloat = 0
    private(set) var isConstrained = false

    func refresh() {
        guard let probeView, let content = probeView.window?.contentView else {
            isConstrained = false
            return
        }
        // AppKit window coordinates are bottom-left origin, so `minY` is the room below the trigger and
        // `maxY` the room above it. All four are needed: the panel is opened away from whichever edge
        // it would otherwise run off.
        let frameInWindow = probeView.convert(probeView.bounds, to: nil)
        let bounds = content.bounds
        spaceBelow = max(frameInWindow.minY - bounds.minY, 0)
        spaceAbove = max(bounds.maxY - frameInWindow.maxY, 0)
        spaceLeft = max(frameInWindow.minX - bounds.minX, 0)
        spaceRight = max(bounds.maxX - frameInWindow.maxX, 0)
        isConstrained = true
    }
}

private struct DropdownSpaceProbeView: NSViewRepresentable {
    let probe: DropdownSpaceProbe

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        probe.probeView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        probe.probeView = nsView
    }
}
