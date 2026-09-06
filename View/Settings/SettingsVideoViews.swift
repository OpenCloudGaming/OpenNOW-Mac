import SwiftUI

/// Everything that decides what the stream looks like: the profile it runs under, the picture
/// geometry, the codec and colour it is encoded in, and how much bandwidth it is allowed.
struct VideoSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            profileCard
                .settingsSection("profile")

            SettingsColumns(uiScale: uiScale) {
                displayCard
                    .settingsSection("display")
                colourCard
                    .settingsSection("colour")
            } trailing: {
                bandwidthCard
                    .settingsSection("bandwidth")
                advancedCard
                    .settingsSection("advanced")
            }

            maintenanceCard
                .settingsSection("maintenance")
        }
    }

    private var profileCard: some View {
        SettingsCard(title: "Streaming Profile", uiScale: uiScale) {
            GameplayProfileOverview(
                mode: streamingProfileMode,
                resolution: viewModel.streamProfile.resolution.label,
                frameRate: "\(viewModel.streamProfile.fps) FPS",
                codec: viewModel.streamProfile.codec.label,
                bitrate: "\(viewModel.streamProfile.maxBitrateMbps) Mbps",
                colorPrecision: viewModel.streamProfile.colorQuality.label,
                uiScale: uiScale
            )
            let overrides = viewModel.streamingOverrideGames
            if !overrides.isEmpty {
                SettingsDivider(uiScale: uiScale)
                overrideList(overrides)
            }
        }
    }

    /// The games whose picture settings diverge from what the rows above show. Without this the
    /// override is invisible: it is written by the in-stream HUD, read at launch, and named nowhere
    /// the reader can find it again.
    private func overrideList(_ overrides: [SettingsOverriddenGame]) -> some View {
        VStack(alignment: .leading, spacing: 10 * uiScale) {
            Text("Per-game overrides")
                .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                .foregroundStyle(.white)
            Text("These games ignore the upscaling, pillarbox and frame pacing settings above and use their own.")
                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(overrides) { game in
                HStack(spacing: 12 * uiScale) {
                    Text(game.title)
                        .font(.settingsNvidia(size: 13 * uiScale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                    Spacer(minLength: 8 * uiScale)
                    SettingsActionButton(title: "RESET", minimumWidth: 92 * uiScale, uiScale: uiScale) {
                        viewModel.removeStreamingOverride(appId: game.appId)
                    }
                }
                .padding(.horizontal, 12 * uiScale)
                .padding(.vertical, 10 * uiScale)
                .background(SettingsVendorLayout.row)
                .overlay { Rectangle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The preset picker leads the card because it writes every value below it. Editing one of those
    /// values takes the profile to Custom, which is the only way an edit can survive.
    private var displayCard: some View {
        SettingsCard(title: "Display", uiScale: uiScale) {
            SettingsOptionRow(title: "Quality Preset", subtitle: "Balanced, Competitive, Data Saver and Cinematic write every value below. Editing any of them switches to Custom.", options: OPNStreamPreferences.streamingQualityProfileOptions.map(\.label), selectedIndex: viewModel.streamProfile.streamingQualityProfileIndex, uiScale: uiScale, action: viewModel.setStreamingQualityProfileIndex)
            SettingsDivider(uiScale: uiScale)
            SettingsOptionRow(title: "Aspect Ratio", subtitle: "Controls the available resolution list.", options: OPNStreamPreferences.aspectOptions.map(\.label), selectedIndex: viewModel.streamProfile.aspectIndex, uiScale: uiScale, action: viewModel.setAspectIndex)
            SettingsDivider(uiScale: uiScale)
            SettingsMenuRow(title: "Resolution", subtitle: "Current target: \(viewModel.streamProfile.resolution.label).", options: OPNStreamPreferences.resolutionOptions(forAspect: viewModel.streamProfile.aspectIndex).map(\.label), selectedIndex: viewModel.streamProfile.resolutionIndex, uiScale: uiScale, action: viewModel.setResolutionIndex)
            SettingsDivider(uiScale: uiScale)
            SettingsOptionRow(title: "Frame Rate", subtitle: "Limited by the active display refresh rate.", options: OPNStreamPreferences.fpsOptions.map { "\($0) FPS" }, selectedIndex: viewModel.streamProfile.fpsIndex, enabled: OPNStreamPreferences.fpsOptions.map { OPNStreamPreferences.fpsSupported($0, capabilities: viewModel.streamCapabilities) }, uiScale: uiScale, action: viewModel.setFpsIndex)
        }
    }

    private var colourCard: some View {
        SettingsCard(title: "Codec & Colour", uiScale: uiScale) {
            SettingsOptionRow(title: "Codec", subtitle: "Unavailable hardware codecs are disabled.", options: OPNStreamPreferences.codecOptions.map(\.label), selectedIndex: viewModel.streamProfile.codecIndex, enabled: OPNStreamPreferences.codecOptions.map { OPNStreamPreferences.codecSupported($0, capabilities: viewModel.streamCapabilities) }, uiScale: uiScale, action: viewModel.setCodecIndex)
            SettingsDivider(uiScale: uiScale)
            SettingsOptionRow(title: "Color Precision", subtitle: "10-bit modes require HEVC, AV1, or Auto support.", options: OPNStreamPreferences.colorQualityOptions.map(\.label), selectedIndex: viewModel.streamProfile.colorQualityIndex, enabled: OPNStreamPreferences.colorQualityOptions.map { OPNStreamPreferences.colorQualitySupported($0, codec: viewModel.streamProfile.codec, capabilities: viewModel.streamCapabilities) }, uiScale: uiScale, action: viewModel.setColorQualityIndex)
            SettingsDivider(uiScale: uiScale)
            SettingsToggleRow(title: "HDR", subtitle: hdrSubtitle, isOn: viewModel.streamProfile.enableHdr, uiScale: uiScale, action: viewModel.setHDREnabled)
            SettingsDivider(uiScale: uiScale)
            SettingsOptionRow(title: "SDR Color Space", subtitle: "Requested SDR color-space metadata.", options: OPNStreamPreferences.colorSpaceOptions.map(\.label), selectedIndex: viewModel.streamProfile.sdrColorSpaceIndex, uiScale: uiScale, action: viewModel.setSDRColorSpaceIndex)
            SettingsDivider(uiScale: uiScale)
            SettingsOptionRow(title: "HDR Color Space", subtitle: "Requested HDR color-space metadata.", options: OPNStreamPreferences.colorSpaceOptions.map(\.label), selectedIndex: viewModel.streamProfile.hdrColorSpaceIndex, uiScale: uiScale, action: viewModel.setHDRColorSpaceIndex)
            SettingsDivider(uiScale: uiScale)
            // What this Mac will actually do with the codec and colour above. It sits with them
            // rather than in a hardware report on another tab, because it is the answer to the
            // question the rows directly above it raise.
            SettingsInfoRow(label: "Decode on this Mac", value: OPNStreamPreferences.decodeAdvice(codec: viewModel.streamProfile.codec.value, resolution: viewModel.streamProfile.resolution.value, colorQualityLabel: viewModel.streamProfile.colorQuality.label, colorQuality: viewModel.streamProfile.colorQuality.value, fps: viewModel.streamProfile.fps), uiScale: uiScale)
            if let recommendation = OPNStreamPreferences.decodeRecommendation(resolution: viewModel.streamProfile.resolution.value, codec: viewModel.streamProfile.codec.value, targetFps: viewModel.streamProfile.fps) {
                SettingsDivider(uiScale: uiScale)
                SettingsInfoRow(label: "Recommended for this Mac", value: recommendation, uiScale: uiScale)
            }
        }
    }

    private var bandwidthCard: some View {
        SettingsCard(title: "Bandwidth", uiScale: uiScale) {
            SettingsMenuRow(title: "Maximum Bitrate", subtitle: "Higher bitrate improves clarity on stable connections.", options: OPNStreamPreferences.bitrateOptions.map(\.label), selectedIndex: viewModel.streamProfile.bitrateIndex, uiScale: uiScale, action: viewModel.setBitrateIndex)
            SettingsDivider(uiScale: uiScale)
            SettingsInfoRow(label: "Estimated Data Use", value: estimatedDataUsage, uiScale: uiScale)
        }
    }

    private var advancedCard: some View {
        SettingsDisclosureCard(title: "Advanced", summary: "Cloud G-Sync, HUD stream, colour fallback, power saver", storageKey: "video-advanced", uiScale: uiScale) {
            SettingsToggleRow(title: "Cloud G-Sync", subtitle: "Request cloud-side G-Sync when the server and stream mode support it.", isOn: viewModel.streamProfile.enableCloudGsync, isCompact: true, uiScale: uiScale, action: viewModel.setCloudGsyncEnabled)
            SettingsDivider(uiScale: uiScale)
            SettingsToggleRow(title: "Logical Resolution Fallback", subtitle: "Allow the stream request to fall back to logical display resolution.", isOn: viewModel.streamProfile.fallbackToLogicalResolution, isCompact: true, uiScale: uiScale, action: viewModel.setFallbackToLogicalResolution)
            SettingsDivider(uiScale: uiScale)
            SettingsOptionRow(title: "HUD Stream", subtitle: "Controls vendor HUD streaming metadata mode.", options: OPNStreamPreferences.hudStreamingModeOptions.map(\.label), selectedIndex: viewModel.streamProfile.hudStreamingModeIndex, uiScale: uiScale, action: viewModel.setHudStreamingModeIndex)
            SettingsDivider(uiScale: uiScale)
            SettingsToggleRow(title: "Power Saver", subtitle: "Reduce resource use when possible.", isOn: viewModel.streamProfile.enablePowerSaver, isCompact: true, uiScale: uiScale, action: viewModel.setPowerSaverEnabled)
        }
    }

    private var maintenanceCard: some View {
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

    private var streamingProfileMode: String {
        viewModel.streamProfile.allowsStreamingCustomization ? "Custom" : "\(viewModel.streamProfile.streamingQualityProfileOption.label) preset"
    }

    /// Says which way HDR will actually go on this Mac. The toggle can be on while the display
    /// reports no extended-range headroom, in which case the session negotiates SDR and the row
    /// would otherwise claim otherwise.
    private var hdrSubtitle: String {
        guard viewModel.streamCapabilities.hdrDisplaySupported else {
            return "This display reports no HDR headroom, so sessions stay SDR."
        }
        return "Streams a 10-bit HEVC or AV1 signal and presents it in extended range."
    }

    private var estimatedDataUsage: String {
        let gbPerHour = Double(viewModel.streamProfile.maxBitrateMbps) * 0.45
        return String(format: "Up to %.1f GB per hour at %d Mbps", gbPerHour, viewModel.streamProfile.maxBitrateMbps)
    }
}

extension VideoSettingsPage {
    static let sections: [SettingsSection] = [
        SettingsSection("profile", "Profile"),
        SettingsSection("display", "Display"),
        SettingsSection("colour", "Codec & Colour"),
        SettingsSection("bandwidth", "Bandwidth"),
        SettingsSection("advanced", "Advanced"),
        SettingsSection("maintenance", "Maintenance")
    ]
}
