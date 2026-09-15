import AppKit
import CryptoKit
import SwiftUI

/// Everything Valve's controllers need on this Mac: whether OpenNOW is holding the device, the two
/// system permissions that gate cursor control and input capture, rumble, and Steam-only mappings.
/// The shared controller tester stays in Controller Tools on the Input page.
struct SteamControllerSettingsPage: View {
    let uiScale: CGFloat
    @ObservedObject private var hidMonitor = SteamControllerHIDMonitor.shared
    @ObservedObject private var mappingStore = SteamControllerMappingStore.shared
    @State private var showingControllerMapping = false
    @AppStorage(SteamControllerPreference.key) private var steamControllerSupportEnabled = false
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
                    .foregroundStyle(OPNDesign.Text.tertiary)

                SettingsDivider(uiScale: uiScale)
                HStack {
                    VStack(alignment: .leading, spacing: 5 * uiScale) {
                        Text("Test Rumble")
                            .font(.settingsFont(size: 15 * uiScale, weight: .bold))
                            .foregroundStyle(OPNDesign.Text.primary)
                        Text(rumbleTestMessage ?? "Pulse the motors of every connected controller — Steam Controllers and GameController pads — at the intensity above, the way a game's rumble reaches them during a stream.")
                            .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                            .foregroundStyle(OPNDesign.Text.tertiary)
                    }
                    Spacer()
                    Button("Rumble All") {
                        let result = ControllerRumbleTester.pulseAllControllers()
                        rumbleTestMessage = result.summary
                    }
                    .buttonStyle(OPNCompactButtonStyle(uiScale: uiScale))
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
                SettingsDivider(uiScale: uiScale)
                mappingRow
            }

            if steamControllerSupportEnabled {
                SettingsCard(title: "Permissions", uiScale: uiScale) {
                    HStack(spacing: 12 * uiScale) {
                        Image(systemName: hidMonitor.inputMonitoringPermissionGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.uiSans(size: 14 * uiScale))
                            .foregroundStyle(hidMonitor.inputMonitoringPermissionGranted ? OPNDesign.accentInk : OPNDesign.Semantic.warning)

                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text(hidMonitor.inputMonitoringPermissionGranted ? "Input Monitoring Permission Granted" : "Input Monitoring Permission Required")
                                .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                                .foregroundStyle(OPNDesign.Text.primary)
                            Text(hidMonitor.inputMonitoringPermissionGranted ? "Steam Controller HID access is enabled" : "Grant permission in System Settings → Privacy & Security → Input Monitoring")
                                .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                                .foregroundStyle(OPNDesign.Text.tertiary)
                        }

                        Spacer()

                        if !hidMonitor.inputMonitoringPermissionGranted {
                            HStack(spacing: 8 * uiScale) {
                                Button("Grant Permission") {
                                    hidMonitor.requestInputMonitoringPermission()
                                }
                                .buttonStyle(OPNCompactButtonStyle(uiScale: uiScale))

                                Button(permissionResetInFlight ? "Resetting…" : "Reset Permission") {
                                    resetInputMonitoringPermission()
                                }
                                .buttonStyle(OPNCompactButtonStyle(role: .destructive, uiScale: uiScale))
                                .disabled(permissionResetInFlight)
                                .help("Clears the stale Input Monitoring entry for this app via tccutil, then quits and relaunches OpenNOW.")
                            }
                        } else {
                            Button(permissionResetInFlight ? "Resetting…" : "Reset Permission") {
                                resetInputMonitoringPermission()
                            }
                            .buttonStyle(OPNCompactButtonStyle(role: .destructive, uiScale: uiScale))
                            .disabled(permissionResetInFlight)
                            .help("Clears the stale Input Monitoring entry for this app via tccutil, then quits and relaunches OpenNOW.")
                        }
                    }

                    SettingsDivider(uiScale: uiScale)
                    HStack(spacing: 12 * uiScale) {
                        Image(systemName: accessibilityPermissionGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.uiSans(size: 14 * uiScale))
                            .foregroundStyle(accessibilityPermissionGranted ? OPNDesign.accentInk : OPNDesign.Semantic.warning)

                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text(accessibilityPermissionGranted ? "Accessibility Permission Granted" : "Accessibility Permission Required")
                                .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                                .foregroundStyle(OPNDesign.Text.primary)
                            Text(accessibilityPermissionGranted ? "Holding the Steam button lets the right pad move the real macOS cursor mid-stream." : "Without it, holding the Steam button and moving a pad does nothing during a stream. Grant permission in System Settings → Privacy & Security → Accessibility.")
                                .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                                .foregroundStyle(OPNDesign.Text.tertiary)
                        }

                        Spacer()

                        if !accessibilityPermissionGranted {
                            Button("Grant Permission") {
                                SteamControllerLocalCursorInjector.requestAccessibilityPermission()
                            }
                            .buttonStyle(OPNCompactButtonStyle(uiScale: uiScale))
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
                                .foregroundStyle(OPNDesign.Text.tertiary)
                            HStack(spacing: 6 * uiScale) {
                                Circle()
                                    .fill(hidMonitor.isMonitorActive ? OPNDesign.accent : .red)
                                    .frame(width: 8 * uiScale, height: 8 * uiScale)
                                Text(hidMonitor.isMonitorActive ? "Active" : "Inactive")
                                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                                    .foregroundStyle(OPNDesign.Text.primary)
                            }
                        }

                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text("Controllers Connected")
                                .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                                .foregroundStyle(OPNDesign.Text.tertiary)
                            Text("\(SteamControllerHIDMonitor.connectedControllerCount)")
                                .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                                .foregroundStyle(OPNDesign.Text.primary)
                        }

                        Spacer()
                    }
                }
            }
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

    private var mappingRow: some View {
        HStack(spacing: 12 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text("Steam Controller Mapping")
                    .font(.settingsFont(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                Text(mappingStore.activeProfile.map { "Steam Controller profile \"\($0.name)\" is applied to streams." }
                     ?? "Bind Steam Controller buttons, pads, and sticks to keyboard keys, mouse actions, or gamepad combos.")
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
