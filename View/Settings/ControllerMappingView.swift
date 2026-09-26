import Combine
import SwiftUI

struct ControllerMappingView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.opnUIScale) var uiScale
    @ObservedObject var store: ControllerMappingStore
    /// Whether a Remote Co-Op session is running. Guests keep the global Steam profile, so the
    /// sheet says so instead of letting a host discover a mapping that only half applies.
    let isRemoteCoOpActive: Bool
    /// Pad commands while the sheet is open over a stream. Empty from Settings, where the page's own
    /// focus registry drives the pad instead.
    let padCommands: AnyPublisher<ControllerInputCommand, Never>
    /// Confirms an override change where the sheet has no message surface of its own.
    let onAnnounce: ((String) -> Void)?

    init(
        store: ControllerMappingStore = .shared,
        isRemoteCoOpActive: Bool = false,
        padCommands: AnyPublisher<ControllerInputCommand, Never> = Empty().eraseToAnyPublisher(),
        onAnnounce: ((String) -> Void)? = nil
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.isRemoteCoOpActive = isRemoteCoOpActive
        self.padCommands = padCommands
        self.onAnnounce = onAnnounce
    }
    @StateObject var liveModel = ControllerMappingLiveModel()
    @StateObject var padFocus = ControllerSettingsFocusModel()
    @Environment(\.controllerPageCommand) private var pageCommand
    @State var isDeleteConfirmationPresented = false
    @State var isDiscardConfirmationPresented = false
    @State var pendingDiscardAction: (() -> Void)?
    @ObservedObject var devices = ControllerMappingDevices.shared
    @State var selection = ControllerMappingSelection.none
    @State var draft: ControllerMappingProfile?
    @State var selectedControl: ControllerControl = .leftGrip
    @State var bindingKindOverride: BindingKind?
    @State var calibration = GyroCalibrationSession()
    @FocusState private var nameFieldFocused: Bool

    private static let sidebarWidth: CGFloat = 168
    private static let bindingPanelWidth: CGFloat = 320
    /// A dropdown panel is an overlay, so it obeys sibling paint order. The type picker must clear
    /// every row below it; every other row only has to clear the configurator underneath.
    static let typePickerRowZIndex: Double = 2
    static let stackedRowZIndex: Double = 1

    private var sheetSize: CGSize {
        SteamControllerSheetMetrics.size(width: 1120, height: 720, uiScale: uiScale)
    }

    enum BindingKind: String, CaseIterable, Identifiable {
        case gamepad, keyboard, mouse, actions, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .gamepad: "Gamepad"
            case .keyboard: "Keyboard"
            case .mouse: "Mouse"
            case .actions: "HUD & Actions"
            case .off: "Off"
            }
        }
    }

    var resolvedSelection: ControllerMappingSelection { selection.resolved(devices: devices.devices) }
    var family: ControllerFamily {
        guard case .family(let family) = resolvedSelection else { return .generic }
        return family
    }
    /// The first connected pad of the selected type, used only to drive the live diagram. The
    /// mapping itself resolves by type, so this never gates which profile is edited.
    var selectedDevice: ControllerMappingDevice? { devices.devices.first { $0.family == family } }
    var selectedDeviceID: InputDeviceID? { selectedDevice?.id }
    var availableControls: [ControllerControl] { selectedDevice?.controls ?? family.controls }
    /// Decision 1's chain, including the running game when there is one.
    var savedProfile: ControllerMappingProfile? { store.profile(for: family) }

    var hasUnsavedChanges: Bool {
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
            }
            if resolvedSelection != .none {
                profileEditorContent
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
        .onExitCommand { requestDismiss() }
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
        // Sheet-owned pad focus: a sheet over the stream sits outside the Settings page that owns the
        // settings registry, and overriding the environment here keeps its row order to itself.
        .environment(\.controllerSettingsFocus, padFocus)
        .environment(\.controllerFocusedRowID, padFocus.isActive ? padFocus.focusedID : nil)
        .environment(\.controllerFocusActive, padFocus.isActive)
        .environment(\.controllerRowCommand, padFocus.rowCommand)
        .coordinateSpace(name: controllerSettingsFocusSpace)
        .onPreferenceChange(ControllerFocusOrderKey.self) { padFocus.setOrder($0) }
        .onReceive(padCommands) { applyPadCommand($0) }
        .onChange(of: pageCommand) { _, command in
            guard let command else { return }
            applyPadCommand(command.command)
        }
        .onDisappear { padFocus.setActive(false) }
        .opnConfirmation(
            isPresented: $isDeleteConfirmationPresented,
            eyebrow: "DELETE PROFILE",
            title: deleteConfirmationTitle,
            message: deleteConfirmationMessage,
            actions: [
                OPNConfirmationAction("CANCEL", role: .cancel) { },
                OPNConfirmationAction("DELETE", role: .destructive) { performProfileDelete() },
            ]
        )
        .opnConfirmation(
            isPresented: $isDiscardConfirmationPresented,
            eyebrow: "UNSAVED CHANGES",
            title: "Discard changes?",
            message: "Edits to \"\(draft?.name ?? "this profile")\" will be lost.",
            actions: [
                OPNConfirmationAction("KEEP EDITING", role: .cancel) { pendingDiscardAction = nil },
                OPNConfirmationAction("DISCARD", role: .destructive) { confirmDiscard() },
            ]
        )
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

    var profileBar: some View {
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
                    requestProfileDelete()
                }
                .help("Delete this profile")
                .controllerFocusable(id: "mapping-delete", activate: { requestProfileDelete() })
            }

            Spacer()

            Button("New Profile") {
                createProfile()
            }
                .buttonStyle(OPNCompactButtonStyle(uiScale: uiScale))
                .controllerFocusable(id: "mapping-new-profile", activate: { createProfile() })
        }
    }

    /// The styled dropdown, not a native `Menu`: the system menu renders rounded chrome the rest
    /// of the app shell does not have.
    private var profilePicker: some View {
        OPNDropdownMenu(
            items: [OPNDropdownItem(id: "passthrough", title: family == .steam ? "Steam defaults" : "No mapping (passthrough)",
                                    isSelected: savedProfile == nil, action: { requestProfileSelection(nil) })] + store.profiles.filter { $0.family == family }.map { profile in
                OPNDropdownItem(
                    id: profile.id.uuidString,
                    title: profile.name.isEmpty ? "Untitled" : profile.name,
                    isSelected: profile.id == savedProfile?.id,
                    action: { requestProfileSelection(profile.id) }
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
        .help("Selecting another profile asks before discarding unsaved changes.")
        .controllerFocusable(id: "mapping-profile", adjust: { cycleProfile(delta: $0) })
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

    private func updateSelectedController() {
        liveModel.selectedDeviceID = selectedDeviceID
        selectedControl = availableControls.first ?? .faceA
        bindingKindOverride = nil
        draft = savedProfile
    }

    var noProfileMessage: some View {
        VStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            Image(systemName: "gamecontroller")
                .font(.settingsFont(size: 40 * uiScale))
                .foregroundStyle(OPNDesign.Text.muted.opacity(0.5))
            Text("Direct passthrough. Select or create a profile to enable custom mappings")
                .font(.settingsFont(size: 14 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Layout

    var configuratorLayout: some View {
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
                        case .actions:
                            if committedKind != .actions { draft?.bindings[control] = ControllerMappingProfile.guideDefault }
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
                    case .actions:
                        actionsEditor(control: control, target: target)
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
        case .streamCommand: .actions
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
