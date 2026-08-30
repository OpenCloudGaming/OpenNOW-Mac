import SwiftUI

/// Steam Input / Steam Deck-style controller remapping: a category sidebar, the live
/// controller diagram (tap any control to select it), and a binding panel on the right for
/// whatever's selected. Every control can go to a gamepad-button chord (today's default),
/// a keyboard key, a mouse action, or off; trackpads and sticks additionally get a
/// continuous-motion "Behavior" (mouse / scroll wheel / joystick / disabled).
struct SteamControllerMappingView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store: SteamControllerMappingStore

    init(store: SteamControllerMappingStore = .shared) {
        _store = ObservedObject(wrappedValue: store)
    }
    @StateObject var liveModel = SteamControllerTestModel()
    @State var draft: SteamControllerMappingProfile?
    @State var selectedControl: SteamControllerControl = .leftGrip
    @State var bindingKindOverride: BindingKind?

    private static let backgroundColor = OpenNOWDesign.Surface.deep
    private static let panelColor = Color(red: 24 / 255, green: 25 / 255, blue: 24 / 255)
    private static let sidebarColor = Color(red: 21 / 255, green: 22 / 255, blue: 21 / 255)

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
            header
            Divider().overlay(Color.white.opacity(0.12))
            profileBar
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
            Divider().overlay(Color.white.opacity(0.12))
            if draft != nil {
                configuratorLayout
            } else {
                noProfileMessage
            }
            Divider().overlay(Color.white.opacity(0.12))
            footer
        }
        .frame(minWidth: 1120, idealWidth: 1120, minHeight: 720, idealHeight: 720)
        .background(Self.backgroundColor)
        .foregroundStyle(.white)
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

    private var header: some View {
        HStack {
            Image(systemName: "gamecontroller.fill")
                .font(.nvidiaSans(size: 18))
                .foregroundStyle(OpenNOWDesign.accent)
            Text("CONTROLLER MAPPING")
                .font(OpenNOWNVIDIAFont.font(size: 15, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.78))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.nvidiaSans(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var profileBar: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(store.profiles) { profile in
                    Button(profile.name) { store.setActiveProfile(profile.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(savedProfile?.name ?? "Default")
                        .font(OpenNOWNVIDIAFont.font(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.nvidiaSans(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Selecting another profile discards unsaved changes.")

            if draft != nil {
                TextField("Profile name", text: draftNameBinding)
                    .textFieldStyle(.plain)
                    .font(OpenNOWNVIDIAFont.font(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 10)
                    .frame(width: 200, height: 30)
                    .background(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button {
                    if let id = savedProfile?.id, store.profiles.count > 1 {
                        store.deleteProfile(id)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.nvidiaSans(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(store.profiles.count <= 1)
                .help("Delete this profile")
            }

            Spacer()

            Button("New Profile") {
                store.createProfile(named: "")
            }
            .font(OpenNOWNVIDIAFont.font(size: 12, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(OpenNOWDesign.accent)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .buttonStyle(.plain)
        }
    }

    private var draftNameBinding: Binding<String> {
        Binding(get: { draft?.name ?? "" }, set: { draft?.name = $0 })
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if hasUnsavedChanges {
                Text("Unsaved changes")
                    .font(OpenNOWNVIDIAFont.font(size: 11, weight: .medium))
                    .foregroundStyle(.orange.opacity(0.85))
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .font(OpenNOWNVIDIAFont.font(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 18)
                .frame(height: 32)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .buttonStyle(.plain)

            Button("Save") {
                if let draft { store.updateProfile(draft) }
                SteamControllerHIDMonitor.shared.refreshCaptureConfiguration()
                dismiss()
            }
            .font(OpenNOWNVIDIAFont.font(size: 12, weight: .bold))
            .foregroundStyle(hasUnsavedChanges ? .black : .black.opacity(0.4))
            .padding(.horizontal, 22)
            .frame(height: 32)
            .background(OpenNOWDesign.accent.opacity(hasUnsavedChanges ? 1 : 0.35))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .buttonStyle(.plain)
            .disabled(!hasUnsavedChanges)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var noProfileMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller")
                .font(.nvidiaSans(size: 44))
                .foregroundStyle(.white.opacity(0.15))
            Text("No profile selected")
                .font(OpenNOWNVIDIAFont.font(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Layout

    private var configuratorLayout: some View {
        HStack(spacing: 0) {
            categorySidebar
                .frame(width: 168)
            Divider().overlay(Color.white.opacity(0.12))
            ScrollView {
                VStack(spacing: 10) {
                    SteamControllerDiagramView(
                        snapshot: liveModel.snapshot,
                        selectedControl: selectedControl,
                        onSelectControl: { selectedControl = $0 },
                        backgroundColor: Self.backgroundColor
                    )
                    Text("Click any control to bind it")
                        .font(OpenNOWNVIDIAFont.font(size: 10, weight: .medium))
                        .tracking(0.3)
                        .foregroundStyle(.white.opacity(0.25))
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            Divider().overlay(Color.white.opacity(0.12))
            bindingPanel
                .frame(width: 320)
        }
        .frame(maxHeight: .infinity)
    }

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SteamControllerMappingCategory.allCases) { category in
                Button {
                    selectedControl = SteamControllerControl.allCases.first(where: { $0.category == category }) ?? selectedControl
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: category.systemImage)
                            .font(.nvidiaSans(size: 12, weight: .semibold))
                            .frame(width: 16)
                        Text(category.label)
                            .font(OpenNOWNVIDIAFont.font(size: 12, weight: .bold))
                    }
                    .foregroundStyle(selectedControl.category == category ? OpenNOWDesign.accent : .white.opacity(0.6))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selectedControl.category == category ? OpenNOWDesign.accent.opacity(0.12) : Color.clear)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .frame(maxHeight: .infinity)
        .background(Self.sidebarColor)
    }

    // MARK: - Binding panel

    private var bindingPanel: some View {
        let control = selectedControl
        let target = draft?.binding(for: control) ?? .passthroughButton
        let held = isHeld(control)
        let committedKind = bindingKind(for: target)
        let displayedKind = bindingKindOverride ?? committedKind

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text(control.label)
                        .font(OpenNOWNVIDIAFont.font(size: 13, weight: .bold))
                        .foregroundStyle(held ? .black : .white.opacity(0.9))
                        .frame(width: 44, height: 26)
                        .background(held ? OpenNOWDesign.accent : Color.white.opacity(0.08))
                        .clipShape(Capsule())
                    Text(control.category.label)
                        .font(OpenNOWNVIDIAFont.font(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer(minLength: 0)
                }

                if let padSettingsKind = padSettingsKind(for: control) {
                    behaviorSection(padSettingsKind)
                    Divider().overlay(Color.white.opacity(0.1))
                    Text("CLICK BINDING")
                        .font(OpenNOWNVIDIAFont.font(size: 9, weight: .bold))
                        .tracking(1.0)
                        .foregroundStyle(.white.opacity(0.35))
                }

                Picker("", selection: Binding(
                    get: { displayedKind },
                    set: { newKind in
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
                )) {
                    ForEach(BindingKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

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
                    .font(OpenNOWNVIDIAFont.font(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(20)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Self.panelColor)
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
