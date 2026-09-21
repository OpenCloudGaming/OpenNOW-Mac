import SwiftUI

struct ControllerMappingView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.opnUIScale) var uiScale
    @ObservedObject var store: ControllerMappingStore

    init(store: ControllerMappingStore = .shared) {
        _store = ObservedObject(wrappedValue: store)
    }
    @StateObject var liveModel = ControllerMappingLiveModel()
    @ObservedObject var devices = ControllerMappingDevices.shared
    @State var selection = ControllerMappingSelection.none
    @State var draft: ControllerMappingProfile?
    @State var selectedControl: ControllerControl = .leftGrip
    @State var bindingKindOverride: BindingKind?
    @State var calibration = GyroCalibrationSession()
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

    var resolvedSelection: ControllerMappingSelection { selection.resolved(devices: devices.devices) }
    var selectedDeviceID: InputDeviceID? {
        guard case .device(let id) = resolvedSelection else { return nil }
        return id
    }
    var selectedDevice: ControllerMappingDevice? { devices.devices.first { $0.id == selectedDeviceID } }
    var family: ControllerFamily { selectedDevice?.family ?? (resolvedSelection == .steamDefaults ? .steam : .generic) }
    var availableControls: [ControllerControl] { selectedDevice?.controls ?? (resolvedSelection == .steamDefaults ? ControllerFamily.steam.controls : []) }
    var savedProfile: ControllerMappingProfile? {
        if resolvedSelection == .steamDefaults { return store.activeProfile }
        guard let selectedDevice else { return nil }
        return store.profile(for: selectedDevice.id, family: selectedDevice.family)
    }

    private var hasUnsavedChanges: Bool {
        guard let draft, let savedProfile else { return false }
        return draft != savedProfile
    }

    var body: some View {
        VStack(spacing: 0) {
            SteamControllerModalTopBar()
            SteamControllerModalHeader(
                eyebrow: "CONTROLLER",
                title: "Controller Mapping",
                uiScale: uiScale,
                onClose: { dismiss() }
            )
            SteamControllerModalRule()
            if resolvedSelection == .none {
                disconnectedMessage
            } else {
                devicePicker
                    .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
                    .padding(.vertical, OPNDesign.Spacing.small(scale: uiScale))
                    .zIndex(2)
                SteamControllerModalRule()
                profileBar
                    .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
                    .padding(.vertical, OPNDesign.Spacing.contentVertical(scale: uiScale))
                    .zIndex(1)
                SteamControllerModalRule()
                if draft != nil {
                    configuratorLayout
                } else {
                    noProfileMessage
                }
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
            selection = resolvedSelection
            updateSelectedController()
        }
        .onDisappear { liveModel.stop() }
        .onChange(of: savedProfile) { draft = savedProfile }
        .onChange(of: resolvedSelection) { updateSelectedController() }
        .onChange(of: devices.devices) { selection = resolvedSelection }
        .onChange(of: selectedControl) {
            bindingKindOverride = nil
        }
        // The calibration passes read the live pad on the same cadence the snapshots arrive on, in
        // their own loop rather than off snapshot changes: a capture held perfectly still would
        // otherwise stop receiving samples at the exact moment it needs them.
        .task(id: calibration.isRunning) {
            guard calibration.isRunning else { return }
            while !Task.isCancelled, calibration.isRunning {
                calibration.ingest(liveModel.snapshot.motion,
                                   settings: draft?.gyro ?? ControllerGyroSettings(),
                                   deltaTime: ControllerMappingLiveModel.sampleInterval)
                try? await Task.sleep(for: ControllerMappingLiveModel.pollInterval)
            }
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
                    if let id = savedProfile?.id {
                        store.deleteProfile(id)
                    }
                }
                .help("Delete this profile")
            }

            Spacer()

            Button("New Profile") {
                let profile = store.createProfile(named: "", family: family, activateSteamDefault: resolvedSelection == .steamDefaults)
                selectProfile(profile.id)
            }
                .buttonStyle(OPNCompactButtonStyle(uiScale: uiScale))
        }
    }

    /// The styled dropdown, not a native `Menu`: the system menu renders rounded chrome the rest
    /// of the app shell does not have.
    private var profilePicker: some View {
        OPNDropdownMenu(
            items: [OPNDropdownItem(id: "passthrough", title: family == .steam ? "Steam defaults" : "No mapping (passthrough)",
                                    isSelected: savedProfile == nil, action: { selectProfile(nil) })] + store.profiles.filter { $0.family == family }.map { profile in
                OPNDropdownItem(
                    id: profile.id.uuidString,
                    title: profile.name.isEmpty ? "Untitled" : profile.name,
                    isSelected: profile.id == savedProfile?.id,
                    action: { selectProfile(profile.id) }
                )
            }
        ) {
            HStack(spacing: 6 * uiScale) {
                Text(savedProfile?.name ?? (family == .steam ? "Steam defaults" : "No mapping"))
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
            Button(resolvedSelection == .none ? "CLOSE" : "CANCEL") { dismiss() }
                .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
                .keyboardShortcut(.cancelAction)

            if resolvedSelection != .none {
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
        }
        .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
        .padding(.vertical, OPNDesign.Spacing.small(scale: uiScale))
    }

    private func updateSelectedController() {
        liveModel.selectedDeviceID = selectedDeviceID
        selectedControl = availableControls.first ?? .faceA
        bindingKindOverride = nil
        draft = savedProfile
    }

    private var disconnectedMessage: some View {
        VStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            Image(systemName: "gamecontroller")
                .font(.settingsFont(size: 40 * uiScale))
                .foregroundStyle(OPNDesign.Text.muted)
            Text("No controller connected")
                .font(.settingsFont(size: 20 * uiScale, weight: .bold))
            Text("Connect a controller to configure mappings. Your saved profiles are kept.")
                .font(.settingsFont(size: 14 * uiScale))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(OPNDesign.Spacing.xLarge(scale: uiScale))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noProfileMessage: some View {
        VStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            Image(systemName: "gamecontroller")
                .font(.settingsFont(size: 40 * uiScale))
                .foregroundStyle(OPNDesign.Text.muted.opacity(0.5))
            Text("Direct passthrough — select or create a profile to enable custom mappings")
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
            VStack(spacing: OPNDesign.Spacing.section(scale: uiScale)) {
                Text(family == .steam ? "Choose a control or click the diagram" : "Choose a control to bind it")
                    .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.muted)
                SettingsFlowLayout(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                    ForEach(availableControls.filter { $0.category == selectedControl.category }) { control in
                        SteamControllerChip(label: family.label(for: control), isSelected: selectedControl == control,
                                            fillsWidth: false, uiScale: uiScale) { selectedControl = control }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                ControllerMappingDiagram(family: family, snapshot: liveModel.snapshot, selectedControl: selectedControl,
                                         onSelectControl: { selectedControl = $0 })
            }
            .padding(OPNDesign.Spacing.xLarge(scale: uiScale))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ForEach(ControllerMappingCategory.allCases.filter { category in availableControls.contains { $0.category == category } }) { category in
                SteamControllerCategoryRow(
                    label: category.label,
                    systemImage: category.systemImage,
                    isActive: selectedControl.category == category,
                    uiScale: uiScale
                ) {
                    selectedControl = availableControls.first(where: { $0.category == category }) ?? selectedControl
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
                    Text(family.label(for: control))
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

                if control == .gyro {
                    // Gyro is a continuous source, not a press: it has behaviour and tuning, and no
                    // discrete binding, so the binding picker below is deliberately absent.
                    gyroSection()
                    Spacer(minLength: 0)
                } else {
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
            }
            .padding(OPNDesign.Spacing.card(scale: uiScale))
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(OPNDesign.Surface.panel)
    }

    private func isHeld(_ control: ControllerControl) -> Bool {
        switch control {
        case .leftTrigger: liveModel.snapshot.leftTrigger > 0.5
        case .rightTrigger: liveModel.snapshot.rightTrigger > 0.5
        case .leftPadClick: liveModel.snapshot.leftPad.pressed
        case .rightPadClick: liveModel.snapshot.rightPad.pressed
        case .touchpadClick: liveModel.snapshot.touchpad?.pressed == true
        default:
            control.gamepadButton.map { liveModel.snapshot.buttons.contains($0) } ?? false
        }
    }

    private func bindingKind(for target: ControllerBindingTarget) -> BindingKind {
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
