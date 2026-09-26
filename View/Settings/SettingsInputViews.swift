import AppKit
import CoreGraphics
import SwiftUI

struct InputSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @AppStorage(OPNInterfacePreferences.controllerModeEnabledKey) private var controllerModeEnabled = false
    @StateObject private var model = InterfaceSettingsViewModel()
    @ObservedObject private var mappingStore = ControllerMappingStore.shared
    @State private var inputMonitoringGranted = InputSettingsPage.isInputMonitoringGranted
    @State private var showingControllerTest = false
    @State private var showingControllerMapping = false
    @State private var showingControllerOrder = false

    private var isAnyControllerConnected: Bool { model.isAnyControllerConnected }

    private var activeGlyphs: ControllerInputGlyphSet { model.activeGlyphs }

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            mouseCard
            modeCard
            controlsCard
            controllerToolsCard
            perGameMappingsCard
        }
        .onAppear {
            model.steamNavigator.start()
            inputMonitoringGranted = Self.isInputMonitoringGranted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            inputMonitoringGranted = Self.isInputMonitoringGranted
        }
        .onDisappear { model.steamNavigator.stop() }
        .sheet(isPresented: $showingControllerMapping) { ControllerMappingView() }
        .sheet(isPresented: $showingControllerOrder) { ControllerOrderView() }
        .sheet(isPresented: $showingControllerTest) {
            SteamControllerTestView()
        }
    }

    private var mouseCard: some View {
        SettingsCard(title: "Mouse & Keyboard", uiScale: uiScale) {
            SettingsToggleRow(title: "Direct Mouse Input", subtitle: Self.directMouseInputSubtitle, isOn: viewModel.streamProfile.directMouseInput, isCompact: true, uiScale: uiScale, action: viewModel.setDirectMouseInputEnabled)
            SettingsDivider(uiScale: uiScale)
            SettingsToggleRow(title: "Raw Mouse Input", subtitle: "Aim with unaccelerated HID deltas in relative mode instead of the pointer macOS has already accelerated. Reading mouse counts needs the Input Monitoring permission; without it the stream keeps the accelerated pointer. Mouse Sensitivity still applies.", isOn: viewModel.streamProfile.rawMouseInput, isCompact: true, uiScale: uiScale, action: viewModel.setRawMouseInputEnabled)
            if viewModel.streamProfile.rawMouseInput, !inputMonitoringGranted {
                SettingsDivider(uiScale: uiScale)
                rawMouseInputPermissionRow
            }
            SettingsDivider(uiScale: uiScale)
            SettingsSliderRow(title: "Mouse Sensitivity", valueText: "\(viewModel.streamProfile.mouseSensitivityPercent)%", value: Double(viewModel.streamProfile.mouseSensitivityPercent), range: Double(OPNStreamPreferences.mouseSensitivityRange.lowerBound)...Double(OPNStreamPreferences.mouseSensitivityRange.upperBound), step: Double(OPNStreamPreferences.mouseSensitivityStep), uiScale: uiScale, action: viewModel.setMouseSensitivityPercent)
            SettingsDivider(uiScale: uiScale)
            SettingsOptionRow(title: "Cursor", subtitle: "Which pointer is drawn while a game shows its own. Auto hides the Mac's whenever the stream is drawing one.", options: OPNCursorPolicy.allCases.map(\.label), selectedIndex: viewModel.streamProfile.cursorPolicy.rawValue, uiScale: uiScale, action: { viewModel.setCursorPolicyIndex(OPNCursorPolicy.from($0).rawValue) })
            SettingsDivider(uiScale: uiScale)
            SettingsToggleRow(title: "Suppress Input When Inactive", subtitle: "Avoid sending input while OpenNOW is not focused.", isOn: viewModel.streamProfile.suppressInputWhenInactive, isCompact: true, uiScale: uiScale, action: viewModel.setSuppressInputWhenInactive)
            SettingsDivider(uiScale: uiScale)
            SettingsToggleRow(title: "Anti-AFK Mouse Movement", subtitle: "Moves the stream mouse every 60 seconds while a stream is active. \(OPNKeybindings.standard.combo(for: .toggleAntiAFK).label) toggles it in-stream.", isOn: viewModel.streamProfile.antiAFKMouseMovementEnabled, isCompact: true, uiScale: uiScale, action: viewModel.setAntiAFKMouseMovementEnabled)
        }
        .settingsSection("mouse")
    }

    /// Raw counts come from the same HID access the Steam Controller path uses, so a player who has
    /// never enabled that has never been asked for it — and the setting would look like it does
    /// nothing. The grant is read from TCC here rather than from
    /// `SteamControllerHIDMonitor.inputMonitoringPermissionGranted`: that flag is only ever written
    /// by the Steam Controller activation path, so on this page it stays `false` for everyone who
    /// has not enabled Steam Controller support — a permanent, false warning that never cleared
    /// after the trip to System Settings either.
    private var rawMouseInputPermissionRow: some View {
        HStack(spacing: 12 * uiScale) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.uiSans(size: 14 * uiScale))
                .foregroundStyle(OPNDesign.Semantic.warning)
            VStack(alignment: .leading, spacing: 2 * uiScale) {
                Text("Input Monitoring Permission Required")
                    .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                Text("Grant permission in System Settings → Privacy & Security → Input Monitoring, or streams keep using the accelerated pointer.")
                    .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
            }
            Spacer()
            Button("Grant Permission") {
                SteamControllerHIDMonitor.shared.requestInputMonitoringPermission()
            }
            .buttonStyle(OPNCompactButtonStyle(uiScale: uiScale))
        }
    }

    private var modeCard: some View {
        SettingsCard(title: "Controller Mode", uiScale: uiScale) {
            HStack(alignment: .center, spacing: 18 * uiScale) {
                Rectangle()
                    .fill(controllerModeEnabled ? OPNDesign.accent : OPNDesign.Stroke.strong)
                    .frame(width: 4 * uiScale, height: 58 * uiScale)
                VStack(alignment: .leading, spacing: 6 * uiScale) {
                    Text(controllerModeEnabled ? "Controller mode is active" : "Desktop catalog mode is active")
                        .font(.settingsFont(size: 18 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                    Text("Controller mode replaces the catalog with a TV-style interface built for gamepads, while keeping keyboard and pointer fallback available.")
                        .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12 * uiScale)
                SettingsStatusPill(title: "INPUT", value: activeGlyphs.deviceName, positive: isAnyControllerConnected, uiScale: uiScale)
            }
            SettingsDivider(uiScale: uiScale)
            SettingsToggleRow(title: "Controller Mode", subtitle: "Use a clean Netflix-style catalog with large focus targets, controller shortcuts, and dynamic input glyphs.", isOn: controllerModeEnabled, uiScale: uiScale) { enabled in
                controllerModeEnabled = enabled
            }
        }
        .settingsSection("mode")
    }

    private var controlsCard: some View {
        SettingsCard(title: "Controls", uiScale: uiScale) {
            SettingsFlowLayout(spacing: 10 * uiScale) {
                InterfaceInputLegend(title: "Move", glyphs: [activeGlyphs.left, activeGlyphs.up, activeGlyphs.down, activeGlyphs.right], uiScale: uiScale)
                InterfaceInputLegend(title: "Select", glyphs: [activeGlyphs.confirm], uiScale: uiScale)
                InterfaceInputLegend(title: "Back", glyphs: [activeGlyphs.back], uiScale: uiScale)
                InterfaceInputLegend(title: "Search", glyphs: [activeGlyphs.search], uiScale: uiScale)
                InterfaceInputLegend(title: "Actions", glyphs: [activeGlyphs.actions], uiScale: uiScale)
                InterfaceInputLegend(title: "Rail", glyphs: [activeGlyphs.pageLeft, activeGlyphs.pageRight], uiScale: uiScale)
            }
            SettingsDivider(uiScale: uiScale)
            HStack(alignment: .center, spacing: 12 * uiScale) {
                Image(systemName: isAnyControllerConnected ? "gamecontroller.fill" : "keyboard")
                    .font(.settingsFont(size: 18 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.accentInk)
                    .frame(width: 34 * uiScale, height: 34 * uiScale)
                    .background(OPNDesign.accent.opacity(0.12))
                    .overlay { Rectangle().stroke(OPNDesign.accent.opacity(0.30), lineWidth: 1) }
                VStack(alignment: .leading, spacing: 4 * uiScale) {
                    Text(isAnyControllerConnected ? "Controller glyphs are live" : "Keyboard fallback is active")
                        .font(.settingsFont(size: 14 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                    Text(isAnyControllerConnected ? "Hints use symbols exposed by the connected game controller whenever the system provides them." : "Connect a controller to switch hints from keyboard keys to controller button glyphs automatically.")
                        .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .settingsSection("controls")
    }

    private var mappingRow: some View {
        HStack(spacing: 12 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text("Controller Mapping")
                    .font(.settingsFont(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                Text("Opt-in mappings for Steam, DualShock 4, and generic controllers. Each type keeps its own default, and a game can override it. Unassigned native controllers pass through unchanged.")
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Open Mapping") {
                showingControllerMapping = true
            }
            .buttonStyle(OPNCompactButtonStyle(uiScale: uiScale))
        }
    }

    private var controllerOrderRow: some View {
        HStack(spacing: 12 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                SettingsRowTitle(title: "Controller Order", isNew: OPNNewSettings.isNew(.controllerOrder), uiScale: uiScale)
                Text("Choose which connected controllers are Player 1–4. Mappings follow the controller type, so reordering does not change which profile applies.")
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Reorder Controllers") {
                OPNNewSettings.acknowledge(.controllerOrder)
                showingControllerOrder = true
            }
                .buttonStyle(OPNCompactButtonStyle(uiScale: uiScale))
        }
    }

    private var controllerToolsCard: some View {
        SettingsCard(title: "Controller Tools", uiScale: uiScale) {
            HStack {
                VStack(alignment: .leading, spacing: 5 * uiScale) {
                    Text("Test Controller")
                        .font(.settingsFont(size: 15 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                    Text("Verify live button presses, sticks, and triggers. Steam Controller and DualShock 4 use dedicated diagrams; other pads use a generic layout.")
                        .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                }
                Spacer()
                Button("Open Tester") {
                    showingControllerTest = true
                }
                .buttonStyle(OPNCompactButtonStyle(uiScale: uiScale))
            }
            SettingsDivider(uiScale: uiScale)
            mappingRow
            SettingsDivider(uiScale: uiScale)
            controllerOrderRow
        }
        .settingsSection("controller-tools")
    }

    /// The games whose controller mapping diverges from their type's default, and for which type.
    /// Without this list an override is written in-stream and named nowhere a reader can find it.
    private var perGameMappingsCard: some View {
        let overrides = viewModel.controllerMappingOverrideGames(from: mappingStore)
        return SettingsCard(title: "Per-Game Controller Mapping", uiScale: uiScale) {
            Text("A game can use its own profile for each controller type, leaving every other game on the type default. Disabling an override keeps it but stops it applying; removing it is permanent.")
                .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            perGameMappingRows(overrides)
        }
        .settingsSection("per-game-mappings")
    }

    /// A disabled override stays listed because disabling keeps it; removing it is permanent.
    @ViewBuilder
    private func perGameMappingRows(_ overrides: [SettingsControllerMappingOverride]) -> some View {
        if overrides.isEmpty {
            SettingsDivider(uiScale: uiScale)
            Text("No per-game overrides. Open Controller Mapping during a stream to apply one.")
                .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(overrides) { gameOverride in
            SettingsDivider(uiScale: uiScale)
            perGameMappingRow(gameOverride)
        }
    }

    private func perGameMappingRow(_ gameOverride: SettingsControllerMappingOverride) -> some View {
        HStack(spacing: 12 * uiScale) {
            VStack(alignment: .leading, spacing: 3 * uiScale) {
                Text(gameOverride.title)
                    .font(.settingsFont(size: 13 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .lineLimit(1)
                Text(gameOverride.subtitle)
                    .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(gameOverride.isEnabled && !gameOverride.isProfileMissing ? OPNDesign.Text.tertiary : OPNDesign.Text.muted)
            }
            Spacer(minLength: 8 * uiScale)
            SettingsActionButton(title: gameOverride.isEnabled ? "DISABLE" : "ENABLE", minimumWidth: 84 * uiScale, uiScale: uiScale) {
                viewModel.setControllerMappingOverrideEnabled(!gameOverride.isEnabled, catalogIdentity: gameOverride.catalogIdentity, family: gameOverride.family)
            }
            SettingsActionButton(title: "REMOVE", minimumWidth: 84 * uiScale, uiScale: uiScale) {
                viewModel.removeControllerMappingOverride(catalogIdentity: gameOverride.catalogIdentity, family: gameOverride.family)
            }
        }
        .padding(.horizontal, 12 * uiScale)
        .padding(.vertical, 10 * uiScale)
        .background(SettingsVendorLayout.row)
        .overlay { Rectangle().strokeBorder(OPNDesign.Stroke.subtle, lineWidth: 1) }
    }
}

extension InputSettingsPage {
    /// Live TCC state for Input Monitoring. `CGPreflightListenEventAccess` only reports, it never
    /// prompts, so it is safe to call whenever the page appears or the app comes back to the front.
    nonisolated static var isInputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

    /// What the preference actually governs: whether a click on the video may take the pointer, and
    /// whether an absolute cursor is held inside the window. Following the seat into mouselook is
    /// deliberately not gated on it (`NativeStreamView.allowsRelativeCapture`), and the
    /// release shortcut is Command-P (`StreamCommand.togglePointerCapture`, keyCode 35).
    nonisolated static var directMouseInputSubtitle: String {
        "Let a click on the video take the pointer for relative aiming, and keep an absolute game cursor inside the stream window. \(OPNKeybindings.standard.combo(for: .togglePointerCapture).spokenLabel) gives the pointer back. Games that hide their own cursor still switch to relative aiming with this off."
    }

    static let sections: [SettingsSection] = [
        SettingsSection("mouse", "Mouse & Keyboard"),
        SettingsSection("mode", "Controller Mode"),
        SettingsSection("controls", "Controls"),
        SettingsSection("controller-tools", "Controller Tools"),
        SettingsSection("per-game-mappings", "Per-Game Controller Mapping")
    ]
}
