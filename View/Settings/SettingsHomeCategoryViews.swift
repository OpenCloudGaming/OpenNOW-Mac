import SwiftUI

/// Settings → Look: the reader's own arrangement of the home rails. Every rail the catalog can draw
/// is listed, including the ones switched off, so a hidden category is always findable again.
struct HomeCategorySettingsCard: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    private var rails: [CatalogHomeRail] { viewModel.homeRailRows }

    var body: some View {
        SettingsCard(title: "Home Categories", isNew: OPNNewSettings.isNew(.homeCategories), uiScale: uiScale) {
            Text("Drag the rails into the order you want and switch off the ones you would rather not see. A category the catalog adds later appears at the bottom.")
                .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsDivider(uiScale: uiScale)

            VStack(spacing: 6 * uiScale) {
                if rails.isEmpty {
                    Text("The home rails appear here once the catalog loads.")
                        .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4 * uiScale)
                }
                ForEach(rails) { rail in
                    HomeRailRow(
                        rail: rail,
                        uiScale: uiScale,
                        onSetVisibility: { isVisible in
                            OPNNewSettings.acknowledge(.homeCategories)
                            viewModel.setHomeRailVisible(rail.id, isVisible: isVisible)
                        },
                        onShift: { delta in
                            OPNNewSettings.acknowledge(.homeCategories)
                            viewModel.shiftHomeRail(rail.id, by: delta)
                        },
                        onDropOnRail: { draggedID in
                            OPNNewSettings.acknowledge(.homeCategories)
                            viewModel.moveHomeRail(draggedID, to: rail.id)
                        }
                    )
                }
            }

            if viewModel.isHomeCustomized {
                SettingsDivider(uiScale: uiScale)
                HStack {
                    Spacer(minLength: 0)
                    SettingsActionButton(title: "RESET ORDER", tone: .secondary, uiScale: uiScale) {
                        OPNNewSettings.acknowledge(.homeCategories)
                        viewModel.resetHomeRailCustomization()
                    }
                }
            }
        }
    }
}

/// One rail: a drag handle, its title, and its visibility switch. Dragging reorders with a pointer;
/// under a gamepad, confirm switches the rail on or off and left/right moves it one place.
private struct HomeRailRow: View {
    let rail: CatalogHomeRail
    let uiScale: CGFloat
    let onSetVisibility: @MainActor @Sendable (Bool) -> Void
    let onShift: @MainActor @Sendable (Int) -> Void
    let onDropOnRail: @MainActor @Sendable (String) -> Void

    @State private var focusIdentity = ControllerFocusIdentity()

    var body: some View {
        HStack(spacing: 12 * uiScale) {
            Image(systemName: "line.3.horizontal")
                .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.muted)
                .frame(width: 18 * uiScale)
                .accessibilityHidden(true)
            Text(rail.title)
                .font(.settingsFont(size: 14 * uiScale, weight: .bold))
                .foregroundStyle(rail.isVisible ? OPNDesign.Text.primary : OPNDesign.Text.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8 * uiScale)
            Toggle(
                isOn: Binding(get: { rail.isVisible }, set: { onSetVisibility($0) }),
                uiScale: uiScale
            )
        }
        .padding(.horizontal, 12 * uiScale)
        .padding(.vertical, 8 * uiScale)
        .background(OPNDesign.Fill.neutral(0.045))
        .overlay { Rectangle().strokeBorder(OPNDesign.Stroke.subtle, lineWidth: 1) }
        .draggable(rail.id)
        .dropDestination(for: String.self) { droppedIDs, _ in
            guard let draggedID = droppedIDs.first, draggedID != rail.id else { return false }
            Task { @MainActor in onDropOnRail(draggedID) }
            return true
        }
        .controllerFocusable(
            focusIdentity,
            activate: { onSetVisibility(!rail.isVisible) },
            adjust: { delta in onShift(delta) }
        )
        .accessibilityLabel(rail.title)
        .accessibilityValue(rail.isVisible ? "Shown" : "Hidden")
    }
}
