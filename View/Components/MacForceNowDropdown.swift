import AppKit
import SwiftUI

struct MacForceNowDropdownItem: Identifiable {
    let id: String
    let title: String
    var isSelected = false
    let action: () -> Void
}

struct MacForceNowDropdownRow: View {
    let title: String
    var isSelected = false
    let action: () -> Void

    @Environment(\.opnUIScale) private var uiScale
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: MacForceNowDesign.Spacing.xSmall(scale: uiScale)) {
                Text(title)
                    .nvidiaFont(size: 12, weight: .bold)
                    .foregroundStyle(isHovering ? MacForceNowDesign.Text.primary : MacForceNowDesign.Text.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .nvidiaFont(size: 11, weight: .bold)
                        .foregroundStyle(MacForceNowDesign.accent)
                }
            }
            .padding(.horizontal, MacForceNowDesign.Spacing.controlRow(scale: uiScale))
            .frame(maxWidth: .infinity, minHeight: 30 * uiScale, alignment: .leading)
            .background(isHovering ? Color.white.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct MacForceNowDropdownPanel: View {
    let items: [MacForceNowDropdownItem]
    var width: CGFloat?

    @Environment(\.opnUIScale) private var uiScale

    static func minimumWidth(scale: CGFloat) -> CGFloat {
        208 * scale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                MacForceNowDropdownRow(title: item.title, isSelected: item.isSelected, action: item.action)
            }
        }
        .padding(.vertical, MacForceNowDesign.Spacing.menuPanelVertical(scale: uiScale))
        .frame(width: width ?? Self.minimumWidth(scale: uiScale))
        .background(MacForceNowDesign.Surface.panelRaised)
        .overlay {
            Rectangle()
                .stroke(MacForceNowDesign.Stroke.regular, lineWidth: 1)
        }
    }
}

struct MacForceNowDropdownMenu<Label: View>: View {
    let items: [MacForceNowDropdownItem]
    var isDisabled = false
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
    }

    private var anchorSpacing: CGFloat {
        MacForceNowDesign.Spacing.xxSmall(scale: uiScale)
    }

    private var panelWidth: CGFloat {
        max(MacForceNowDropdownPanel.minimumWidth(scale: uiScale), triggerSize.width)
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
        MacForceNowDropdownPanel(items: dismissingItems, width: panelWidth)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                panelHeight = height
            }
    }

    private var dismissingItems: [MacForceNowDropdownItem] {
        items.map { item in
            MacForceNowDropdownItem(id: item.id, title: item.title, isSelected: item.isSelected) {
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
        guard let probeView, let window = probeView.window else {
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
