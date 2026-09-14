import AppKit
import SwiftUI

struct OPNDropdownItem: Identifiable {
    let id: String
    let title: String
    var isSelected = false
    let action: () -> Void
}

struct OPNDropdownRow: View {
    let title: String
    var isSelected = false
    let action: () -> Void

    @Environment(\.opnUIScale) private var uiScale
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                Text(title)
                    .catalogFont(size: 12, weight: .bold)
                    .foregroundStyle(isHovering ? OPNDesign.Text.primary : OPNDesign.Text.secondary)
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
                OPNDropdownRow(title: item.title, isSelected: item.isSelected, action: item.action)
            }
        }
    }
}

struct OPNDropdownMenu<Label: View>: View {
    let items: [OPNDropdownItem]
    var isDisabled = false
    var visibleItemCount: Int?
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
        .overlay(alignment: .topLeading) {
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

    @ViewBuilder
    private var panel: some View {
        let maximumHeight = spaceProbe.spaceBelow - anchorSpacing

        if spaceProbe.isConstrained, maximumHeight > 0, panelHeight > maximumHeight {
            ScrollView(.vertical) {
                measuredPanel
            }
            .frame(width: panelWidth, height: maximumHeight)
            .offset(y: triggerSize.height + anchorSpacing)
        } else {
            measuredPanel
                .offset(y: triggerSize.height + anchorSpacing)
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
            OPNDropdownItem(id: item.id, title: item.title, isSelected: item.isSelected) {
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
    private(set) var isConstrained = false

    func refresh() {
        guard let probeView, probeView.window != nil else {
            isConstrained = false
            return
        }
        let frameInWindow = probeView.convert(probeView.bounds, to: nil)
        spaceBelow = max(frameInWindow.minY, 0)
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
