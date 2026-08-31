//
//  SettingsControllerViews.swift
//  OpenNOW
//

import AppKit
import CryptoKit
import SwiftUI

struct ExperimentalFeaturesSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @AppStorage(RecordingEditorBetaPreference.key) private var recordingEditorEarlyBetaEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "Alpha Access", uiScale: uiScale) {
                SettingsToggleRow(
                    title: "Remote Co-Op Alpha",
                    subtitle: viewModel.remoteCoOpPreferences.isAlphaOptedIn ? "Remote Co-Op settings are available from Gameplay settings." : "Opt in before Remote Co-Op settings, preferences, and stream HUD controls appear.",
                    isOn: viewModel.remoteCoOpPreferences.isAlphaOptedIn,
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpAlphaOptedIn
                )
            }

            SettingsCard(title: "Recording", uiScale: uiScale) {
                SettingsToggleRow(
                    title: "Recording Editor Early Beta",
                    subtitle: recordingEditorEarlyBetaEnabled ? "Trim, arrange, crop, audio, and export tools are unlocked in Recordings." : "Opt in before recording editor controls appear in Recordings.",
                    isOn: recordingEditorEarlyBetaEnabled,
                    uiScale: uiScale,
                    action: setRecordingEditorEarlyBetaEnabled
                )
            }
        }
    }

    private func setRecordingEditorEarlyBetaEnabled(_ enabled: Bool) {
        recordingEditorEarlyBetaEnabled = enabled
    }
}

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
    @State private var accessibilityPermissionGranted = SteamControllerLocalCursorInjector.hasAccessibilityPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
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
                            .font(.nvidiaSans(size: 14 * uiScale))
                            .foregroundStyle(hidMonitor.inputMonitoringPermissionGranted ? OpenNOWDesign.accent : .orange)

                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text(hidMonitor.inputMonitoringPermissionGranted ? "Input Monitoring Permission Granted" : "Input Monitoring Permission Required")
                                .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(0.88))
                            Text(hidMonitor.inputMonitoringPermissionGranted ? "Steam Controller HID access is enabled" : "Grant permission in System Settings → Privacy & Security → Input Monitoring")
                                .font(.settingsNvidia(size: 11 * uiScale, weight: .medium))
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
                            .font(.nvidiaSans(size: 14 * uiScale))
                            .foregroundStyle(accessibilityPermissionGranted ? OpenNOWDesign.accent : .orange)

                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text(accessibilityPermissionGranted ? "Accessibility Permission Granted" : "Accessibility Permission Required")
                                .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(0.88))
                            Text(accessibilityPermissionGranted ? "Holding the Steam button lets the right pad move the real macOS cursor mid-stream." : "Without it, holding the Steam button and moving a pad does nothing during a stream. Grant permission in System Settings → Privacy & Security → Accessibility.")
                                .font(.settingsNvidia(size: 11 * uiScale, weight: .medium))
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
                                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(0.58))
                            HStack(spacing: 6 * uiScale) {
                                Circle()
                                    .fill(hidMonitor.isMonitorActive ? OpenNOWDesign.accent : .red)
                                    .frame(width: 8 * uiScale, height: 8 * uiScale)
                                Text(hidMonitor.isMonitorActive ? "Active" : "Inactive")
                                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.88))
                            }
                        }

                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text("Devices Matched")
                                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(0.58))
                            Text("\(hidMonitor.matchedDeviceCount)")
                                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.88))
                        }

                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text("Controllers Connected")
                                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(0.58))
                            Text("\(SteamControllerHIDMonitor.connectedControllerCount)")
                                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.88))
                        }

                        Spacer()
                    }
                }

                SettingsCard(title: "Tools", uiScale: uiScale) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5 * uiScale) {
                            Text("Test Controller")
                                .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(1))
                            Text("Open a visual tester to verify button presses, stick positions, and trigger values.")
                                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
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
                                .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(1))
                            Text(mappingStore.activeProfile.map { "Profile \"\($0.name)\" is applied to streams." } ?? "Bind every button, pad, and stick to a keyboard key, mouse action, or gamepad combo.")
                                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
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

struct GameplaySettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    var body: some View {
        let qualityLocked = !viewModel.streamingQualityProfileAllowsCustomization
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "Streaming Profile", uiScale: uiScale) {
                GameplayProfileOverview(
                    mode: streamingProfileMode,
                    resolution: viewModel.streamProfile.resolution.label,
                    frameRate: "\(viewModel.streamProfile.fps) FPS",
                    codec: viewModel.streamProfile.codec.label,
                    bitrate: "\(viewModel.streamProfile.maxBitrateMbps) Mbps",
                    colorPrecision: viewModel.streamProfile.colorQuality.label,
                    dataUsage: estimatedDataUsage,
                    uiScale: uiScale
                )
            }

            SettingsCard(title: "Streaming Quality", uiScale: uiScale) {
                SettingsOptionRow(title: "Aspect Ratio", subtitle: qualityLocked ? lockedProfileSubtitle : "Controls the available resolution list.", options: OPNStreamPreferences.aspectOptions.map(\.label), selectedIndex: viewModel.streamProfile.aspectIndex, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setAspectIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "Resolution", subtitle: qualityLocked ? lockedProfileSubtitle : "Current target: \(viewModel.streamProfile.resolution.label).", options: OPNStreamPreferences.resolutionOptions(forAspect: viewModel.streamProfile.aspectIndex).map(\.label), selectedIndex: viewModel.streamProfile.resolutionIndex, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setResolutionIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "Frame Rate", subtitle: qualityLocked ? lockedProfileSubtitle : "Limited by the active display refresh rate.", options: OPNStreamPreferences.fpsOptions.map { "\($0) FPS" }, selectedIndex: viewModel.streamProfile.fpsIndex, enabled: OPNStreamPreferences.fpsOptions.map { OPNStreamPreferences.fpsSupported($0, capabilities: viewModel.streamCapabilities) }, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setFpsIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "Codec", subtitle: qualityLocked ? lockedProfileSubtitle : "Unavailable hardware codecs are disabled.", options: OPNStreamPreferences.codecOptions.map(\.label), selectedIndex: viewModel.streamProfile.codecIndex, enabled: OPNStreamPreferences.codecOptions.map { OPNStreamPreferences.codecSupported($0, capabilities: viewModel.streamCapabilities) }, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setCodecIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "Maximum Bitrate", subtitle: qualityLocked ? lockedProfileSubtitle : "Higher bitrate improves clarity on stable connections.", options: OPNStreamPreferences.bitrateOptions.map(\.label), selectedIndex: viewModel.streamProfile.bitrateIndex, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setBitrateIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "Color Precision", subtitle: qualityLocked ? lockedProfileSubtitle : "10-bit modes require HEVC, AV1, or Auto support.", options: OPNStreamPreferences.colorQualityOptions.map(\.label), selectedIndex: viewModel.streamProfile.colorQualityIndex, enabled: OPNStreamPreferences.colorQualityOptions.map { OPNStreamPreferences.colorQualitySupported($0, codec: viewModel.streamProfile.codec, capabilities: viewModel.streamCapabilities) }, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setColorQualityIndex)
            }

            SettingsCard(title: "Stream Transport", uiScale: uiScale) {
                SettingsToggleRow(title: "Native/NVST Transport", subtitle: "Off uses the default WebRTC session path. On requests native NVST secure RTSP transport with matching CloudMatch headers.", isOn: viewModel.streamProfile.transportMode.value == "nvst", uiScale: uiScale, action: viewModel.setNVSTTransportEnabled)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "Quality Profile", subtitle: "Maps to the vendor streaming profile sent with the session request.", options: OPNStreamPreferences.streamingQualityProfileOptions.map(\.label), selectedIndex: viewModel.streamProfile.streamingQualityProfileIndex, uiScale: uiScale, action: viewModel.setStreamingQualityProfileIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Cloud G-Sync", subtitle: qualityLocked ? lockedProfileSubtitle : "Request cloud-side G-Sync when the server and stream mode support it.", isOn: viewModel.streamProfile.enableCloudGsync, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setCloudGsyncEnabled)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Logical Resolution Fallback", subtitle: qualityLocked ? lockedProfileSubtitle : "Allow the stream request to fall back to logical display resolution.", isOn: viewModel.streamProfile.fallbackToLogicalResolution, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setFallbackToLogicalResolution)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "HUD Stream", subtitle: qualityLocked ? lockedProfileSubtitle : "Controls vendor HUD streaming metadata mode.", options: OPNStreamPreferences.hudStreamingModeOptions.map(\.label), selectedIndex: viewModel.streamProfile.hudStreamingModeIndex, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setHudStreamingModeIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "SDR Color Space", subtitle: qualityLocked ? lockedProfileSubtitle : "Requested SDR color-space metadata.", options: OPNStreamPreferences.colorSpaceOptions.map(\.label), selectedIndex: viewModel.streamProfile.sdrColorSpaceIndex, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setSDRColorSpaceIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "HDR Color Space", subtitle: qualityLocked ? lockedProfileSubtitle : "Requested HDR color-space metadata.", options: OPNStreamPreferences.colorSpaceOptions.map(\.label), selectedIndex: viewModel.streamProfile.hdrColorSpaceIndex, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setHDRColorSpaceIndex)
            }

            SettingsCard(title: "Gameplay", uiScale: uiScale) {
                SettingsToggleRow(title: "L4S", subtitle: qualityLocked ? lockedProfileSubtitle : "Use low-latency scalable throughput when available.", isOn: viewModel.streamProfile.enableL4S, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setL4SEnabled)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "HDR", subtitle: qualityLocked ? lockedProfileSubtitle : "Requires a compatible display and stream capability.", isOn: viewModel.streamProfile.enableHdr, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setHDREnabled)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Power Saver", subtitle: qualityLocked ? lockedProfileSubtitle : "Reduce resource use when possible.", isOn: viewModel.streamProfile.enablePowerSaver, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setPowerSaverEnabled)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Prevent Display Sleep", subtitle: "Keeps the monitor awake while a stream is active.", isOn: viewModel.streamProfile.preventDisplaySleepWhileStreaming, uiScale: uiScale, action: viewModel.setPreventDisplaySleepWhileStreaming)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Direct Mouse Input", subtitle: "Capture relative input and keep absolute game cursors inside the stream window. Use Command-G or Command-Q to release the pointer.", isOn: viewModel.streamProfile.directMouseInput, uiScale: uiScale, action: viewModel.setDirectMouseInputEnabled)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Anti-AFK Mouse Movement", subtitle: "Moves the stream mouse every 60 seconds while a stream is active. Cmd-K toggles it in-stream.", isOn: viewModel.streamProfile.antiAFKMouseMovementEnabled, uiScale: uiScale, action: viewModel.setAntiAFKMouseMovementEnabled)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Suppress Input When Inactive", subtitle: "Avoid sending input while OpenNOW is not focused.", isOn: viewModel.streamProfile.suppressInputWhenInactive, uiScale: uiScale, action: viewModel.setSuppressInputWhenInactive)
            }

            SettingsCard(title: "Recording", uiScale: uiScale) {
                SettingsSliderRow(title: "Video Bitrate", valueText: recordingVideoBitrateText, value: Double(viewModel.streamProfile.recordingVideoBitrateMbps), range: 0...200, step: 1, uiScale: uiScale, action: viewModel.setRecordingVideoBitrateMbps)
                SettingsDivider(uiScale: uiScale)
                SettingsSliderRow(title: "Audio Bitrate", valueText: "\(viewModel.streamProfile.recordingAudioBitrateKbps) Kbps", value: Double(viewModel.streamProfile.recordingAudioBitrateKbps), range: 64...320, step: 16, uiScale: uiScale, action: viewModel.setRecordingAudioBitrateKbps)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Record Enhanced Video", subtitle: "Capture the enhanced/upscaled stream frame when available, with native decoded frames as fallback.", isOn: viewModel.streamProfile.recordingEnhancedVideoEnabled, uiScale: uiScale, action: viewModel.setRecordingEnhancedVideoEnabled)
            }

            SettingsCard(title: "Audio", uiScale: uiScale) {
                SettingsSliderRow(title: "Game Volume", valueText: percentText(viewModel.streamProfile.gameVolume), value: viewModel.streamProfile.gameVolume, range: 0...1, step: 0.01, uiScale: uiScale, action: viewModel.setGameVolume)
                SettingsDivider(uiScale: uiScale)
                SettingsSliderRow(title: "Microphone Volume", valueText: percentText(viewModel.streamProfile.microphoneVolume), value: viewModel.streamProfile.microphoneVolume, range: 0...1, step: 0.01, uiScale: uiScale, action: viewModel.setMicrophoneVolume)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "Microphone Mode", subtitle: "Controls how voice input is sent to the stream.", options: OPNStreamPreferences.microphoneModeOptions.map(\.label), selectedIndex: selectedMicrophoneModeIndex, uiScale: uiScale, action: { viewModel.setMicrophoneMode(OPNStreamPreferences.microphoneModeOptions[$0].value) })
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "Microphone Device", subtitle: "Current input device for OpenNOW streams.", options: viewModel.microphoneDeviceOptions.map(\.label), selectedIndex: selectedMicrophoneDeviceIndex, uiScale: uiScale, action: { viewModel.setMicrophoneDeviceId(viewModel.microphoneDeviceOptions[$0].uniqueId) })
            }

            SettingsCard(title: "Profile Maintenance", uiScale: uiScale) {
                HStack(alignment: .center, spacing: 16 * uiScale) {
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 4 * uiScale, height: 48 * uiScale)
                    VStack(alignment: .leading, spacing: 5 * uiScale) {
                        Text("Restore default streaming settings")
                            .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Resets resolution, FPS, codec, bitrate, color precision, latency, HDR, L4S, input, audio, and enhancement options.")
                            .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.56))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12 * uiScale)
                    SettingsActionButton(title: "RESTORE DEFAULTS", minimumWidth: 150 * uiScale, uiScale: uiScale) { viewModel.restoreStreamingProfileDefaults() }
                }
                .padding(12 * uiScale)
                .background(SettingsVendorLayout.row)
                .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
            }
        }
    }

    private var selectedMicrophoneModeIndex: Int {
        OPNStreamPreferences.microphoneModeOptions.firstIndex { $0.value == viewModel.streamProfile.microphoneMode } ?? 0
    }

    private var selectedMicrophoneDeviceIndex: Int {
        viewModel.microphoneDeviceOptions.firstIndex { $0.uniqueId == viewModel.streamProfile.microphoneDeviceId } ?? 0
    }

    private var streamingProfileMode: String {
        viewModel.streamProfile.allowsStreamingCustomization ? "Custom" : "\(viewModel.streamProfile.streamingQualityProfileOption.label) preset"
    }

    private var lockedProfileSubtitle: String {
        "Managed by the \(viewModel.streamProfile.streamingQualityProfileOption.label) quality profile. Select Custom to edit."
    }

    private var estimatedDataUsage: String {
        let gbPerHour = Double(viewModel.streamProfile.maxBitrateMbps) * 0.45
        return String(format: "Up to %.1f GB per hour at %d Mbps", gbPerHour, viewModel.streamProfile.maxBitrateMbps)
    }

    private var recordingVideoBitrateText: String {
        viewModel.streamProfile.recordingVideoBitrateMbps == 0 ? "Auto" : "\(viewModel.streamProfile.recordingVideoBitrateMbps) Mbps"
    }

    private func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

struct GameplayProfileOverview: View {
    let mode: String
    let resolution: String
    let frameRate: String
    let codec: String
    let bitrate: String
    let colorPrecision: String
    let dataUsage: String
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * uiScale) {
            HStack(alignment: .center, spacing: 14 * uiScale) {
                VStack(alignment: .leading, spacing: 6 * uiScale) {
                    Text("Active streaming profile")
                        .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                        .foregroundStyle(.white)
                    Text("These values are sent to OpenNOW when a new stream starts.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer(minLength: 0)
                SettingsStatusPill(title: "MODE", value: mode, positive: mode != "Balanced defaults", uiScale: uiScale)
            }

            SettingsFlowLayout(spacing: 10 * uiScale) {
                GameplayProfileMetricTile(label: "Resolution", value: resolution, emphasized: true, uiScale: uiScale)
                GameplayProfileMetricTile(label: "Frame Rate", value: frameRate, emphasized: true, uiScale: uiScale)
                GameplayProfileMetricTile(label: "Codec", value: codec, uiScale: uiScale)
                GameplayProfileMetricTile(label: "Bitrate", value: bitrate, uiScale: uiScale)
                GameplayProfileMetricTile(label: "Color", value: colorPrecision, uiScale: uiScale)
                GameplayProfileMetricTile(label: "Data Usage", value: dataUsage, width: 260 * uiScale, uiScale: uiScale)
            }
        }
    }
}

struct GameplayProfileMetricTile: View {
    let label: String
    let value: String
    var emphasized = false
    var width: CGFloat?
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 7 * uiScale) {
            Text(label.uppercased())
                .font(.settingsNvidia(size: 9 * uiScale, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.44))
            Text(value.isEmpty ? "-" : value)
                .font(.settingsNvidia(size: (emphasized ? 16 : 14) * uiScale, weight: .bold))
                .foregroundStyle(emphasized ? OpenNOWDesign.accent : .white.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 13 * uiScale)
        .padding(.vertical, 11 * uiScale)
        .frame(width: width ?? ((emphasized ? 180 : 154) * uiScale), height: 72 * uiScale, alignment: .leading)
        .background(Color.white.opacity(emphasized ? 0.065 : 0.045))
        .overlay { Rectangle().stroke(emphasized ? OpenNOWDesign.accent.opacity(0.32) : Color.white.opacity(0.08), lineWidth: 1) }
    }
}
