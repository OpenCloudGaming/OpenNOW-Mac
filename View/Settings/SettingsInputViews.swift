import SwiftUI

struct InputSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @AppStorage(OpenNOWInterfacePreferences.controllerModeEnabledKey) private var controllerModeEnabled = false
    @StateObject private var model = InterfaceSettingsViewModel()

    private var isAnyControllerConnected: Bool { model.isAnyControllerConnected }

    private var activeGlyphs: ControllerInputGlyphSet { model.activeGlyphs }

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            mouseCard
            modeCard
            controlsCard
        }
        .onAppear { model.steamNavigator.start() }
        .onDisappear { model.steamNavigator.stop() }
    }

    private var mouseCard: some View {
        SettingsCard(title: "Mouse & Keyboard", uiScale: uiScale) {
            SettingsToggleRow(title: "Direct Mouse Input", subtitle: "Capture relative input and keep absolute game cursors inside the stream window. Use Command-G or Command-Q to release the pointer.", isOn: viewModel.streamProfile.directMouseInput, isCompact: true, uiScale: uiScale, action: viewModel.setDirectMouseInputEnabled)
            SettingsDivider(uiScale: uiScale)
            SettingsSliderRow(title: "Mouse Sensitivity", valueText: "\(viewModel.streamProfile.mouseSensitivityPercent)%", value: Double(viewModel.streamProfile.mouseSensitivityPercent), range: Double(OPNStreamPreferences.mouseSensitivityRange.lowerBound)...Double(OPNStreamPreferences.mouseSensitivityRange.upperBound), step: Double(OPNStreamPreferences.mouseSensitivityStep), uiScale: uiScale, action: viewModel.setMouseSensitivityPercent)
            SettingsDivider(uiScale: uiScale)
            SettingsToggleRow(title: "Suppress Input When Inactive", subtitle: "Avoid sending input while OpenNOW is not focused.", isOn: viewModel.streamProfile.suppressInputWhenInactive, isCompact: true, uiScale: uiScale, action: viewModel.setSuppressInputWhenInactive)
            SettingsDivider(uiScale: uiScale)
            SettingsToggleRow(title: "Anti-AFK Mouse Movement", subtitle: "Moves the stream mouse every 60 seconds while a stream is active. Cmd-K toggles it in-stream.", isOn: viewModel.streamProfile.antiAFKMouseMovementEnabled, isCompact: true, uiScale: uiScale, action: viewModel.setAntiAFKMouseMovementEnabled)
        }
        .settingsSection("mouse")
    }

    private var modeCard: some View {
        SettingsCard(title: "Controller Mode", uiScale: uiScale) {
            HStack(alignment: .center, spacing: 18 * uiScale) {
                Rectangle()
                    .fill(controllerModeEnabled ? OpenNOWDesign.accent : Color.white.opacity(0.18))
                    .frame(width: 4 * uiScale, height: 58 * uiScale)
                VStack(alignment: .leading, spacing: 6 * uiScale) {
                    Text(controllerModeEnabled ? "Controller mode is active" : "Desktop catalog mode is active")
                        .font(.settingsFont(size: 18 * uiScale, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Controller mode replaces the catalog with a TV-style interface built for gamepads, while keeping keyboard and pointer fallback available.")
                        .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
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
                    .foregroundStyle(OpenNOWDesign.accent)
                    .frame(width: 34 * uiScale, height: 34 * uiScale)
                    .background(OpenNOWDesign.accent.opacity(0.12))
                    .overlay { Rectangle().stroke(OpenNOWDesign.accent.opacity(0.30), lineWidth: 1) }
                VStack(alignment: .leading, spacing: 4 * uiScale) {
                    Text(isAnyControllerConnected ? "Controller glyphs are live" : "Keyboard fallback is active")
                        .font(.settingsFont(size: 14 * uiScale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(isAnyControllerConnected ? "Hints use symbols exposed by the connected game controller whenever the system provides them." : "Connect a controller to switch hints from keyboard keys to controller button glyphs automatically.")
                        .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .settingsSection("controls")
    }
}

extension InputSettingsPage {
    static let sections: [SettingsSection] = [
        SettingsSection("mouse", "Mouse & Keyboard"),
        SettingsSection("mode", "Controller Mode"),
        SettingsSection("controls", "Controls")
    ]
}
