import AppKit
import CoreGraphics
import SwiftUI

struct InputSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @AppStorage(OpenNOWInterfacePreferences.controllerModeEnabledKey) private var controllerModeEnabled = false
    @StateObject private var model = InterfaceSettingsViewModel()
    @State private var inputMonitoringGranted = InputSettingsPage.isInputMonitoringGranted

    private var isAnyControllerConnected: Bool { model.isAnyControllerConnected }

    private var activeGlyphs: ControllerInputGlyphSet { model.activeGlyphs }

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            mouseCard
            modeCard
            controlsCard
        }
        .onAppear {
            model.steamNavigator.start()
            inputMonitoringGranted = Self.isInputMonitoringGranted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            inputMonitoringGranted = Self.isInputMonitoringGranted
        }
        .onDisappear { model.steamNavigator.stop() }
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
            SettingsToggleRow(title: "Anti-AFK Mouse Movement", subtitle: "Moves the stream mouse every 60 seconds while a stream is active. Cmd-K toggles it in-stream.", isOn: viewModel.streamProfile.antiAFKMouseMovementEnabled, isCompact: true, uiScale: uiScale, action: viewModel.setAntiAFKMouseMovementEnabled)
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
                .foregroundStyle(OpenNOWDesign.Semantic.warning)
            VStack(alignment: .leading, spacing: 2 * uiScale) {
                Text("Input Monitoring Permission Required")
                    .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                Text("Grant permission in System Settings → Privacy & Security → Input Monitoring, or streams keep using the accelerated pointer.")
                    .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer()
            Button("Grant Permission") {
                SteamControllerHIDMonitor.shared.requestInputMonitoringPermission()
            }
            .buttonStyle(OpenNOWCompactButtonStyle(uiScale: uiScale))
        }
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
    /// Live TCC state for Input Monitoring. `CGPreflightListenEventAccess` only reports, it never
    /// prompts, so it is safe to call whenever the page appears or the app comes back to the front.
    nonisolated static var isInputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

    /// What the preference actually governs: whether a click on the video may take the pointer, and
    /// whether an absolute cursor is held inside the window. Following the seat into mouselook is
    /// deliberately not gated on it (`NativeWebRTCStreamView.allowsRelativeCapture`), and the
    /// release shortcut is Command-P (`WebRTCMediaStreamCommand.togglePointerCapture`, keyCode 35).
    nonisolated static let directMouseInputSubtitle = "Let a click on the video take the pointer for relative aiming, and keep an absolute game cursor inside the stream window. Command-P gives the pointer back. Games that hide their own cursor still switch to relative aiming with this off."

    static let sections: [SettingsSection] = [
        SettingsSection("mouse", "Mouse & Keyboard"),
        SettingsSection("mode", "Controller Mode"),
        SettingsSection("controls", "Controls")
    ]
}
