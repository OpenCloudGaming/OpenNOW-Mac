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

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                MacForceNowDropdownRow(title: item.title, isSelected: item.isSelected, action: item.action)
            }
        }
        .padding(.vertical, MacForceNowDesign.Spacing.menuPanelVertical(scale: uiScale))
        .frame(width: 208 * uiScale)
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
    @State private var triggerHeight: CGFloat = 0

    var body: some View {
        Button { isPresented.toggle() } label: { label() }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { triggerHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, newHeight in triggerHeight = newHeight }
                }
            )
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
                    MacForceNowDropdownPanel(items: dismissingItems)
                        .offset(y: triggerHeight + MacForceNowDesign.Spacing.xxSmall(scale: uiScale))
                }
            }
            .onExitCommand { isPresented = false }
            .onChange(of: items.map(\.id)) { _, _ in isPresented = false }
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
