import AppKit
import CryptoKit
import SwiftUI

/// Everything Valve's controllers need on this Mac: whether OpenNOW is holding the device, the two
/// system permissions that gate cursor control and input capture, rumble, and the way in to the
/// tester and the mapping editor.
struct SteamControllerSettingsPage: View {
    let uiScale: CGFloat
    @ObservedObject private var hidMonitor = SteamControllerHIDMonitor.shared
    @AppStorage(SteamControllerPreference.key) private var steamControllerSupportEnabled = false
    @ObservedObject private var mappingStore: SteamControllerMappingStore

    init(uiScale: CGFloat, mappingStore: SteamControllerMappingStore = .shared) {
        self.uiScale = uiScale
        _mappingStore = ObservedObject(wrappedValue: mappingStore)
    }
    @State private var showingControllerTest = false
    @State private var showingControllerMapping = false
    @State private var permissionResetInFlight = false
    @State private var permissionResetError: String?
    @State private var rumbleTestMessage: String?
    @State private var rumbleIntensityPercent = ControllerRumblePreference.loadIntensityPercent()
    @State private var accessibilityPermissionGranted = SteamControllerLocalCursorInjector.hasAccessibilityPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            // Rumble is for every controller (GameController pads through CoreHaptics, Steam
            // Controllers through their HID report), so it lives outside the Steam Controller
            // opt-in below rather than disappearing with it.
            SettingsCard(title: "Rumble", uiScale: uiScale) {
                SettingsSliderRow(
                    title: "Rumble Intensity",
                    valueText: rumbleIntensityPercent == 0 ? "Off" : "\(rumbleIntensityPercent)%",
                    value: Double(rumbleIntensityPercent),
                    range: Double(ControllerRumblePreference.range.lowerBound)...Double(ControllerRumblePreference.range.upperBound),
                    step: Double(ControllerRumblePreference.step),
                    uiScale: uiScale
                ) { value in
                    rumbleIntensityPercent = Int(value.rounded())
                    ControllerRumblePreference.saveIntensityPercent(rumbleIntensityPercent)
                }
                Text("Ceiling for every rumble the game sends, on every controller. Games scale only some of their effects with their own vibration setting; this scales all of them. Also on the stream HUD (⌘G) under Controllers.")
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))

                SettingsDivider(uiScale: uiScale)
                HStack {
                    VStack(alignment: .leading, spacing: 5 * uiScale) {
                        Text("Test Rumble")
                            .font(.settingsFont(size: 15 * uiScale, weight: .bold))
                            .foregroundStyle(.white.opacity(1))
                        Text(rumbleTestMessage ?? "Pulse the motors of every connected controller — Steam Controllers and GameController pads — at the intensity above, the way a game's rumble reaches them during a stream.")
                            .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    Spacer()
                    Button("Rumble All") {
                        let result = ControllerRumbleTester.pulseAllControllers()
                        rumbleTestMessage = result.summary
                    }
                    .buttonStyle(OpenNOWCompactButtonStyle(uiScale: uiScale))
                }
            }

            SettingsCard(title: "Steam Controller", uiScale: uiScale) {
                SettingsToggleRow(
                    title: "Steam Controller Support",
                    subtitle: steamControllerSupportEnabled ? "Valve Steam Controller input is forwarded to streams. Requires the Input Monitoring permission and the Steam client to be closed." : "Opt in to recognize Valve Steam Controllers (original and 2026 models) over USB, dongle, or Puck during streams.",
                    isOn: steamControllerSupportEnabled,
                    uiScale: uiScale,
                    action: setSteamControllerSupportEnabled
                )
            }

            if steamControllerSupportEnabled {
                SettingsCard(title: "Permissions", uiScale: uiScale) {
                    HStack(spacing: 12 * uiScale) {
                        Image(systemName: hidMonitor.inputMonitoringPermissionGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.uiSans(size: 14 * uiScale))
                            .foregroundStyle(hidMonitor.inputMonitoringPermissionGranted ? OpenNOWDesign.accent : .orange)

                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text(hidMonitor.inputMonitoringPermissionGranted ? "Input Monitoring Permission Granted" : "Input Monitoring Permission Required")
                                .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(0.88))
                            Text(hidMonitor.inputMonitoringPermissionGranted ? "Steam Controller HID access is enabled" : "Grant permission in System Settings → Privacy & Security → Input Monitoring")
                                .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.58))
                        }

                        Spacer()

                        if !hidMonitor.inputMonitoringPermissionGranted {
                            HStack(spacing: 8 * uiScale) {
                                Button("Grant Permission") {
                                    hidMonitor.requestInputMonitoringPermission()
                                }
                                .buttonStyle(OpenNOWCompactButtonStyle(uiScale: uiScale))

                                Button(permissionResetInFlight ? "Resetting…" : "Reset Permission") {
                                    resetInputMonitoringPermission()
                                }
                                .buttonStyle(OpenNOWCompactButtonStyle(role: .destructive, uiScale: uiScale))
                                .disabled(permissionResetInFlight)
                                .help("Clears the stale Input Monitoring entry for this app via tccutil, then quits and relaunches OpenNOW.")
                            }
                        } else {
                            Button(permissionResetInFlight ? "Resetting…" : "Reset Permission") {
                                resetInputMonitoringPermission()
                            }
                            .buttonStyle(OpenNOWCompactButtonStyle(role: .destructive, uiScale: uiScale))
                            .disabled(permissionResetInFlight)
                            .help("Clears the stale Input Monitoring entry for this app via tccutil, then quits and relaunches OpenNOW.")
                        }
                    }

                    SettingsDivider(uiScale: uiScale)
                    HStack(spacing: 12 * uiScale) {
                        Image(systemName: accessibilityPermissionGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.uiSans(size: 14 * uiScale))
                            .foregroundStyle(accessibilityPermissionGranted ? OpenNOWDesign.accent : .orange)

                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text(accessibilityPermissionGranted ? "Accessibility Permission Granted" : "Accessibility Permission Required")
                                .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(0.88))
                            Text(accessibilityPermissionGranted ? "Holding the Steam button lets the right pad move the real macOS cursor mid-stream." : "Without it, holding the Steam button and moving a pad does nothing during a stream. Grant permission in System Settings → Privacy & Security → Accessibility.")
                                .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.58))
                        }

                        Spacer()

                        if !accessibilityPermissionGranted {
                            Button("Grant Permission") {
                                SteamControllerLocalCursorInjector.requestAccessibilityPermission()
                            }
                            .buttonStyle(OpenNOWCompactButtonStyle(uiScale: uiScale))
                        }
                    }
                    .onAppear { accessibilityPermissionGranted = SteamControllerLocalCursorInjector.hasAccessibilityPermission }
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                        accessibilityPermissionGranted = SteamControllerLocalCursorInjector.hasAccessibilityPermission
                    }
                }

                SettingsCard(title: "Status", uiScale: uiScale) {
                    HStack(spacing: 16 * uiScale) {
                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text("Monitor Status")
                                .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(0.58))
                            HStack(spacing: 6 * uiScale) {
                                Circle()
                                    .fill(hidMonitor.isMonitorActive ? OpenNOWDesign.accent : .red)
                                    .frame(width: 8 * uiScale, height: 8 * uiScale)
                                Text(hidMonitor.isMonitorActive ? "Active" : "Inactive")
                                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.88))
                            }
                        }

                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text("Controllers Connected")
                                .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(0.58))
                            Text("\(SteamControllerHIDMonitor.connectedControllerCount)")
                                .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.88))
                        }

                        Spacer()
                    }
                }

                SettingsCard(title: "Tools", uiScale: uiScale) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5 * uiScale) {
                            Text("Test Controller")
                                .font(.settingsFont(size: 15 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(1))
                            Text("Open a visual tester to verify button presses, stick positions, and trigger values.")
                                .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.58))
                        }
                        Spacer()
                        Button("Open Tester") {
                            showingControllerTest = true
                        }
                        .buttonStyle(OpenNOWCompactButtonStyle(uiScale: uiScale))
                    }

                    SettingsDivider(uiScale: uiScale)
                    HStack {
                        VStack(alignment: .leading, spacing: 5 * uiScale) {
                            Text("Controller Mapping")
                                .font(.settingsFont(size: 15 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(1))
                            Text(mappingStore.activeProfile.map { "Profile \"\($0.name)\" is applied to streams." } ?? "Bind every button, pad, and stick to a keyboard key, mouse action, or gamepad combo.")
                                .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.58))
                        }
                        Spacer()
                        Button("Open Mapping") {
                            showingControllerMapping = true
                        }
                        .buttonStyle(OpenNOWCompactButtonStyle(uiScale: uiScale))
                    }
                }
            }
        }
        .sheet(isPresented: $showingControllerTest) {
            SteamControllerTestView()
        }
        .sheet(isPresented: $showingControllerMapping) {
            SteamControllerMappingView()
        }
        .alert(
            "Reset Failed",
            isPresented: Binding(
                get: { permissionResetError != nil },
                set: { presented in if !presented { permissionResetError = nil } }
            )
        ) {
            Button("OK") { permissionResetError = nil }
        } message: {
            Text(permissionResetError ?? "")
        }
    }

    private func setSteamControllerSupportEnabled(_ enabled: Bool) {
        steamControllerSupportEnabled = enabled
        SteamControllerHIDMonitor.shared.setEnabled(enabled)
    }

    private func resetInputMonitoringPermission() {
        guard !permissionResetInFlight else { return }
        permissionResetInFlight = true
        Task.detached {
            do {
                try SteamControllerHIDMonitor.resetInputMonitoringPermissionViaTccUtil(thenRelaunch: true)
            } catch {
                await MainActor.run {
                    permissionResetInFlight = false
                    permissionResetError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}
