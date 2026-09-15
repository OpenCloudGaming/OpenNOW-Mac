import SwiftUI

/// Steam Controller-only remapping: a category sidebar, the live
/// controller diagram (tap any control to select it), and a binding panel on the right for
/// whatever's selected. Every control can go to a gamepad-button chord (today's default),
/// a keyboard key, a mouse action, or off; trackpads and sticks additionally get a
/// continuous-motion "Behavior" (mouse / scroll wheel / joystick / disabled).
///
/// Chrome follows the modal spec in DESIGN.md: accent top bar, App Bar header, Stroke Subtle
/// rules, square controls throughout, and every size multiplied by the interface scale.
struct SteamControllerMappingView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.opnUIScale) var uiScale
    @ObservedObject var store: SteamControllerMappingStore

    init(store: SteamControllerMappingStore = .shared) {
        _store = ObservedObject(wrappedValue: store)
    }
    @StateObject var liveModel = SteamControllerTestModel()
    @State var draft: SteamControllerMappingProfile?
    @State var selectedControl: SteamControllerControl = .leftGrip
    @State var bindingKindOverride: BindingKind?
    @FocusState private var nameFieldFocused: Bool

    private static let sidebarWidth: CGFloat = 168
    private static let bindingPanelWidth: CGFloat = 320

    private var sheetSize: CGSize {
        SteamControllerSheetMetrics.size(width: 1120, height: 720, uiScale: uiScale)
    }

    enum BindingKind: String, CaseIterable, Identifiable {
        case gamepad, keyboard, mouse, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .gamepad: "Gamepad"
            case .keyboard: "Keyboard"
            case .mouse: "Mouse"
            case .off: "Off"
            }
        }
    }

    private var savedProfile: SteamControllerMappingProfile? {
        store.activeProfile
    }

    private var hasUnsavedChanges: Bool {
        guard let draft, let savedProfile else { return false }
        return draft != savedProfile
    }

    var body: some View {
        VStack(spacing: 0) {
            SteamControllerModalTopBar()
            SteamControllerModalHeader(
                eyebrow: "STEAM CONTROLLER",
                title: "Steam Controller Mapping",
                uiScale: uiScale,
                onClose: { dismiss() }
            )
            SteamControllerModalRule()
            profileBar
                .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
                .padding(.vertical, OPNDesign.Spacing.contentVertical(scale: uiScale))
                // The profile dropdown's open panel is an overlay confined to this row's own
                // paint order (see OPNDropdownMenu's zIndex note); without this, the sidebar and
                // diagram painted after it in this VStack still draw on top of it.
                .zIndex(1)
            SteamControllerModalRule()
            if draft != nil {
                configuratorLayout
            } else {
                noProfileMessage
            }
            SteamControllerModalRule()
            footer
        }
        .frame(
            minWidth: sheetSize.width,
            idealWidth: sheetSize.width,
            minHeight: sheetSize.height,
            idealHeight: sheetSize.height
        )
        .background(OPNDesign.Surface.deep)
        .foregroundStyle(OPNDesign.Text.primary)
        .onExitCommand { dismiss() }
        .onAppear {
            liveModel.start()
            draft = savedProfile
        }
        .onDisappear { liveModel.stop() }
        .onChange(of: store.activeProfileID) {
            draft = savedProfile
        }
        .onChange(of: selectedControl) {
            bindingKindOverride = nil
        }
    }

    private var profileBar: some View {
        HStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            profilePicker
            if draft != nil {
                nameField
                SteamControllerChip(
                    label: "Delete",
                    isSelected: false,
                    systemImage: "trash",
                    fontSize: 11,
                    fillsWidth: false,
                    uiScale: uiScale
                ) {
                    if let id = savedProfile?.id, store.profiles.count > 1 {
                        store.deleteProfile(id)
                    }
                }
                .disabled(store.profiles.count <= 1)
                .help("Delete this profile")
            }

            Spacer()

            Button("New Profile") { store.createProfile(named: "") }
                .buttonStyle(OPNCompactButtonStyle(uiScale: uiScale))
        }
    }

    /// The styled dropdown, not a native `Menu`: the system menu renders rounded chrome the rest
    /// of the app shell does not have.
    private var profilePicker: some View {
        OPNDropdownMenu(
            items: store.profiles.map { profile in
                OPNDropdownItem(
                    id: profile.id.uuidString,
                    title: profile.name.isEmpty ? "Untitled" : profile.name,
                    isSelected: profile.id == savedProfile?.id,
                    action: { store.setActiveProfile(profile.id) }
                )
            }
        ) {
            HStack(spacing: 6 * uiScale) {
                Text(savedProfile?.name ?? "Default")
                    .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.settingsFont(size: 9 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.tertiary)
            }
            .padding(.horizontal, OPNDesign.Spacing.controlRow(scale: uiScale))
            .frame(height: 30 * uiScale)
            .background(OPNDesign.Fill.neutral(0.075))
            .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .fixedSize()
        .help("Selecting another profile discards unsaved changes.")
    }

    private var nameField: some View {
        TextField("Profile name", text: draftNameBinding)
            .textFieldStyle(.plain)
            .font(.settingsFont(size: 14 * uiScale))
            .foregroundStyle(OPNDesign.Text.primary)
            .tint(OPNDesign.accent)
            .focused($nameFieldFocused)
            .padding(.horizontal, OPNDesign.Spacing.controlRow(scale: uiScale))
            .frame(width: 200 * uiScale, height: 30 * uiScale)
            .background(OPNDesign.Surface.field)
            .overlay {
                Rectangle().stroke(
                    nameFieldFocused ? OPNDesign.accent : OPNDesign.Stroke.regular,
                    lineWidth: nameFieldFocused ? 2 : 1
                )
            }
    }

    private var draftNameBinding: Binding<String> {
        Binding(get: { draft?.name ?? "" }, set: { draft?.name = $0 })
    }

    private var footer: some View {
        HStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            if hasUnsavedChanges {
                Text("UNSAVED CHANGES")
                    .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(OPNDesign.Semantic.warning)
            }
            Spacer()
            Button("CANCEL") { dismiss() }
                .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
                .keyboardShortcut(.cancelAction)

            Button("SAVE") {
                if let draft { store.updateProfile(draft) }
                SteamControllerHIDMonitor.shared.refreshCaptureConfiguration()
                dismiss()
            }
            .buttonStyle(VendorGetInButtonStyle(uiScale: uiScale))
            .keyboardShortcut(.defaultAction)
            .disabled(!hasUnsavedChanges)
            .opacity(hasUnsavedChanges ? 1 : 0.46)
        }
        .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
        .padding(.vertical, OPNDesign.Spacing.small(scale: uiScale))
    }

    private var noProfileMessage: some View {
        VStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            Image(systemName: "gamecontroller")
                .font(.settingsFont(size: 40 * uiScale))
                .foregroundStyle(OPNDesign.Text.muted.opacity(0.5))
            Text("No profile selected")
                .font(.settingsFont(size: 14 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Layout

    private var configuratorLayout: some View {
        HStack(spacing: 0) {
            categorySidebar
                .frame(width: Self.sidebarWidth * uiScale)
            Rectangle()
                .fill(OPNDesign.Stroke.subtle)
                .frame(width: 1)
            ScrollView {
                VStack(spacing: OPNDesign.Spacing.section(scale: uiScale)) {
                    SteamControllerDiagramView(
                        snapshot: liveModel.snapshot,
                        selectedControl: selectedControl,
                        onSelectControl: { selectedControl = $0 }
                    )
                    Text("Click any control to bind it")
                        .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.muted)
                }
                .padding(OPNDesign.Spacing.xLarge(scale: uiScale))
                .frame(maxWidth: .infinity)
            }
            Rectangle()
                .fill(OPNDesign.Stroke.subtle)
                .frame(width: 1)
            bindingPanel
                .frame(width: Self.bindingPanelWidth * uiScale)
        }
        .frame(maxHeight: .infinity)
    }

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 2 * uiScale) {
            ForEach(SteamControllerMappingCategory.allCases) { category in
                SteamControllerCategoryRow(
                    label: category.label,
                    systemImage: category.systemImage,
                    isActive: selectedControl.category == category,
                    uiScale: uiScale
                ) {
                    selectedControl = SteamControllerControl.allCases.first(where: { $0.category == category }) ?? selectedControl
                }
            }
            Spacer()
        }
        .padding(.vertical, OPNDesign.Spacing.section(scale: uiScale))
        .frame(maxHeight: .infinity)
        .background(OPNDesign.Surface.panelRaised)
    }

    // MARK: - Binding panel

    private var bindingPanel: some View {
        let control = selectedControl
        let target = draft?.binding(for: control) ?? .passthroughButton
        let held = isHeld(control)
        let committedKind = bindingKind(for: target)
        let displayedKind = bindingKindOverride ?? committedKind

        return ScrollView {
            VStack(alignment: .leading, spacing: OPNDesign.Spacing.medium(scale: uiScale)) {
                // The badge sizes to its label. A fixed width truncated the long ones — every pad
                // and stick control reads "R. Pad Click", not "R4".
                HStack(spacing: OPNDesign.Spacing.section(scale: uiScale)) {
                    Text(control.label)
                        .font(.settingsFont(size: 13 * uiScale, weight: .bold))
                        .foregroundStyle(held ? OPNDesign.onAccent : OPNDesign.Text.primary)
                        .fixedSize()
                        .padding(.horizontal, OPNDesign.Spacing.xSmall(scale: uiScale))
                        .frame(minWidth: 48 * uiScale)
                        .frame(height: 26 * uiScale)
                        .background(held ? OPNDesign.accent : OPNDesign.Fill.neutral(0.075))
                        .overlay {
                            Rectangle().stroke(
                                held ? OPNDesign.accent : OPNDesign.Stroke.subtle,
                                lineWidth: 1
                            )
                        }
                    Text(control.category.label)
                        .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }

                if let padSettingsKind = padSettingsKind(for: control) {
                    behaviorSection(padSettingsKind)
                    SteamControllerModalRule()
                    SteamControllerEyebrow(text: "CLICK BINDING", uiScale: uiScale)
                }

                SteamControllerOptionPicker(
                    options: BindingKind.allCases.map { (value: $0, label: $0.label) },
                    selection: displayedKind,
                    uiScale: uiScale
                ) { newKind in
                    bindingKindOverride = newKind
                    switch newKind {
                    case .off:
                        draft?.bindings[control] = .disabled
                    case .gamepad:
                        if committedKind != .gamepad { draft?.bindings[control] = .passthroughButton }
                    case .keyboard, .mouse:
                        break // wait for the recorder / chip picker below to commit a concrete value
                    }
                }

                switch displayedKind {
                case .gamepad:
                    gamepadEditor(control: control, target: target)
                case .keyboard:
                    keyboardEditor(control: control, target: target)
                case .mouse:
                    mouseEditor(control: control, target: target)
                case .off:
                    EmptyView()
                }

                Spacer(minLength: 0)

                Text("While a control is bound to a gamepad combo, L1/R1/L2/R2 in that combo land first and the rest follow a moment later so games register them as modifier + press.")
                    .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.muted)
            }
            .padding(OPNDesign.Spacing.card(scale: uiScale))
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(OPNDesign.Surface.panel)
    }

    private func isHeld(_ control: SteamControllerControl) -> Bool {
        switch control {
        case .leftTrigger: liveModel.snapshot.leftTrigger > 0.5
        case .rightTrigger: liveModel.snapshot.rightTrigger > 0.5
        case .leftPadClick: liveModel.snapshot.leftPad.pressed
        case .rightPadClick: liveModel.snapshot.rightPad.pressed
        default:
            control.gamepadButton.map { liveModel.snapshot.buttons.contains($0) } ?? false
        }
    }

    private func bindingKind(for target: SteamControllerBindingTarget) -> BindingKind {
        switch target {
        case .passthroughButton, .gamepadChord: .gamepad
        case .keyboardKey: .keyboard
        case .mouseButton, .mouseScroll: .mouse
        case .disabled: .off
        }
    }

}

/// Sidebar category row, on the Main Menu row spec: accent tint plus a 3px accent leading bar when
/// active, white 0.08 on hover.
private struct SteamControllerCategoryRow: View {
    let label: String
    let systemImage: String
    let isActive: Bool
    let uiScale: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: OPNDesign.Spacing.section(scale: uiScale)) {
                Image(systemName: systemImage)
                    .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                    .frame(width: 16 * uiScale)
                Text(label)
                    .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, OPNDesign.Spacing.controlRow(scale: uiScale))
            .frame(height: 30 * uiScale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(alignment: .leading) {
                if isActive {
                    Rectangle()
                        .fill(OPNDesign.accent)
                        .frame(width: 3 * uiScale)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .opnMotion(OPNDesign.Motion.hover, value: isHovering)
    }

    private var foreground: Color {
        if isActive { return OPNDesign.accentInk }
        return isHovering ? OPNDesign.Text.primary : OPNDesign.Text.secondary
    }

    private var background: Color {
        if isActive { return OPNDesign.accent.opacity(0.095) }
        return isHovering ? OPNDesign.Stroke.subtle : .clear
    }
}
