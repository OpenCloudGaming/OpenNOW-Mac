import SwiftUI

struct CaptureSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            SettingsCard(title: "Recording", uiScale: uiScale) {
                SettingsOptionRow(
                    title: "Recording Mode",
                    subtitle: viewModel.streamProfile.recordingMode.subtitle,
                    options: OPNRecordingMode.allCases.map(\.label),
                    selectedIndex: selectedRecordingModeIndex,
                    uiScale: uiScale,
                    action: { viewModel.setRecordingMode(OPNRecordingMode.allCases[$0]) }
                )
                SettingsDivider(uiScale: uiScale)
                SettingsSliderRow(title: "Video Bitrate", valueText: recordingVideoBitrateText, value: Double(viewModel.streamProfile.recordingVideoBitrateMbps), range: 0...200, step: 1, uiScale: uiScale, action: viewModel.setRecordingVideoBitrateMbps)
                SettingsDivider(uiScale: uiScale)
                SettingsSliderRow(title: "Audio Bitrate", valueText: "\(viewModel.streamProfile.recordingAudioBitrateKbps) Kbps", value: Double(viewModel.streamProfile.recordingAudioBitrateKbps), range: 64...320, step: 16, uiScale: uiScale, action: viewModel.setRecordingAudioBitrateKbps)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Record Enhanced Video", subtitle: "Capture the enhanced/upscaled stream frame when available, with native decoded frames as fallback.", isOn: viewModel.streamProfile.recordingEnhancedVideoEnabled, uiScale: uiScale, action: viewModel.setRecordingEnhancedVideoEnabled)
            }
            .settingsSection("recording")
            if viewModel.streamProfile.recordingMode == .instantReplay {
                InstantReplayCard(viewModel: viewModel, uiScale: uiScale)
                    .settingsSection("recording")
            }
        }
    }

    /// Zero is the "let the encoder pick" sentinel rather than a real bitrate, so it reads as Auto.
    private var recordingVideoBitrateText: String {
        viewModel.streamProfile.recordingVideoBitrateMbps == 0 ? "Auto" : "\(viewModel.streamProfile.recordingVideoBitrateMbps) Mbps"
    }

    private var selectedRecordingModeIndex: Int {
        OPNRecordingMode.allCases.firstIndex(of: viewModel.streamProfile.recordingMode) ?? 0
    }
}

/// Instant Replay's own settings, drawn only in Instant Replay mode: a rolling window of the most
/// recent stream minutes, written to the same recordings library a manual recording lands in.
struct InstantReplayCard: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        SettingsCard(title: "Instant Replay", badge: .beta, isNew: OPNNewSettings.isNew(.instantReplay), uiScale: uiScale) {
            ReplayWindowDiagram(
                windowSeconds: Double(viewModel.streamProfile.recordingReplayBufferWindowSeconds),
                clipSeconds: Double(viewModel.streamProfile.recordingReplayClipSeconds),
                uiScale: uiScale
            )
            SettingsDivider(uiScale: uiScale)
            SettingsSliderRow(
                title: "Replay Length",
                valueText: replayLengthText,
                value: Double(viewModel.streamProfile.recordingReplayBufferWindowSeconds) / 60,
                range: 10...120,
                step: 10,
                uiScale: uiScale,
                action: { viewModel.setRecordingReplayBufferWindowSeconds($0 * 60) }
            )
            SettingsDivider(uiScale: uiScale)
            SettingsSliderRow(
                title: "Clip Length",
                valueText: clipLengthText,
                value: Double(viewModel.streamProfile.recordingReplayClipSeconds),
                range: StreamReplayBufferConfiguration.minimumClipSeconds...Double(clipLengthUpperBoundSeconds),
                step: 5,
                uiScale: uiScale,
                action: viewModel.setRecordingReplayClipSeconds
            )
            SettingsDivider(uiScale: uiScale)
            SettingsOptionRow(
                title: "Replay Quality",
                subtitle: replayQualitySubtitle,
                options: OPNStreamPreferences.replayQualityOptions.map(\.label),
                selectedIndex: viewModel.streamProfile.recordingReplayQualityIndex,
                uiScale: uiScale,
                action: viewModel.setRecordingReplayQualityIndex
            )
            SettingsDivider(uiScale: uiScale)
            SettingsSliderRow(
                title: "Storage Budget",
                valueText: storageBudgetText,
                value: Double(viewModel.streamProfile.recordingReplayStorageBudgetGB),
                range: Double(StreamReplayRetentionLibrary.minimumBudgetGigabytes)...Double(StreamReplayRetentionLibrary.maximumBudgetGigabytes),
                step: 5,
                uiScale: uiScale,
                action: viewModel.setRecordingReplayStorageBudgetGB
            )
            SettingsDivider(uiScale: uiScale)
            Text(sizesText)
                .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A clip can never be longer than the window it is cut from.
    private var clipLengthUpperBoundSeconds: Int {
        min(viewModel.streamProfile.recordingReplayBufferWindowSeconds, Int(StreamReplayBufferConfiguration.maximumClipSeconds))
    }

    private var replayQualitySubtitle: String {
        let option = OPNStreamPreferences.replayQualityOptions[viewModel.streamProfile.recordingReplayQualityIndex]
        guard option.maxHeight > 0 else {
            return "Encodes the replay at the stream's own resolution and bitrate."
        }
        let size = OPNVideoSize.capped(width: viewModel.streamProfile.resolution.width, height: viewModel.streamProfile.resolution.height, maxHeight: option.maxHeight)
        return "Encodes the replay at \(size.width)×\(size.height), capped at \(option.bitrateCeilingMbps) Mbps. Smaller footprints cost detail in fast motion."
    }

    private var replayLengthText: String {
        ReplayWindowDiagram.durationText(seconds: Double(viewModel.streamProfile.recordingReplayBufferWindowSeconds))
    }

    private var clipLengthText: String {
        ReplayWindowDiagram.durationText(seconds: Double(viewModel.streamProfile.recordingReplayClipSeconds))
    }

    private var storageBudgetText: String {
        "\(viewModel.streamProfile.recordingReplayStorageBudgetGB) GB"
    }

    /// What each number costs, at the size and bitrate the quality tier actually encodes: one saved
    /// clip, the window for the title being played, and the ceiling every title shares.
    private var sizesText: String {
        let profile = viewModel.streamProfile
        let quality = OPNStreamPreferences.replayQualityOptions[profile.recordingReplayQualityIndex]
        let recording = replayRecordingConfiguration(profile)
        let encodedSize = OPNVideoSize.capped(width: profile.resolution.width, height: profile.resolution.height, maxHeight: quality.maxHeight)
        let bytesPerSecond = StreamReplayBufferConfiguration.estimatedBytesPerSecond(
            recording: recording,
            width: encodedSize.width,
            height: encodedSize.height,
            bitrateCeilingMbps: quality.bitrateCeilingMbps
        )
        let clipBytes = Int64(bytesPerSecond * Double(profile.recordingReplayClipSeconds))
        let configuration = StreamReplayBufferConfiguration(
            recording: recording,
            windowSeconds: Double(profile.recordingReplayBufferWindowSeconds),
            clipSeconds: Double(profile.recordingReplayClipSeconds),
            maxHeight: quality.maxHeight,
            bitrateCeilingMbps: quality.bitrateCeilingMbps
        )
        let ringBytes = configuration.estimatedBufferBytes(width: profile.resolution.width, height: profile.resolution.height)
        let clipSize = ByteCountFormatter.string(fromByteCount: clipBytes, countStyle: .file)
        let ringSize = ByteCountFormatter.string(fromByteCount: ringBytes, countStyle: .file)
        return "Each clip is about \(clipSize). A title's window holds about \(ringSize) while it rolls, and keeps rolling the next time you play that title. Every title's window together is held to \(profile.recordingReplayStorageBudgetGB) GB, oldest footage first."
    }

    private func replayRecordingConfiguration(_ profile: OPNStreamPreferenceProfile) -> StreamRecordingConfiguration {
        StreamRecordingConfiguration(
            title: "Instant Replay",
            applicationID: "",
            width: profile.resolution.width,
            height: profile.resolution.height,
            fps: profile.fps,
            videoBitrateMbps: profile.recordingVideoBitrateMbps,
            audioBitrateKbps: profile.recordingAudioBitrateKbps,
            enhancedVideoEnabled: profile.recordingEnhancedVideoEnabled
        )
    }
}

extension CaptureSettingsPage {
    static let sections: [SettingsSection] = [
        SettingsSection("recording", "Recording"),
        SettingsSection("storage", "Storage"),
        SettingsSection("library", "Library"),
    ]
}

/// Where the captures are written: one row per library, each naming the folder in use and offering
/// the three things a reader wants from it — change it, put it back, or go there.
struct CaptureStorageCard: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        SettingsCard(title: "Storage", isNew: OPNNewSettings.isNew(.captureLocations), uiScale: uiScale) {
            if let notice = viewModel.captureLocations.migrationNotice {
                CaptureNoticeBanner(message: notice, uiScale: uiScale) {
                    viewModel.acknowledgeCaptureMigrationNotice()
                }
                SettingsDivider(uiScale: uiScale)
            }
            CaptureFolderRow(library: .screenshots, viewModel: viewModel, uiScale: uiScale)
            SettingsDivider(uiScale: uiScale)
            CaptureFolderRow(library: .recordings, viewModel: viewModel, uiScale: uiScale)
            if viewModel.captureLocations.isSharingOneFolder {
                SettingsDivider(uiScale: uiScale)
                Text("Both libraries point at one folder. That works, but the two sets of files sit together in Finder.")
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Semantic.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { viewModel.refreshCaptureLocations() }
    }
}

private struct CaptureFolderRow: View {
    let library: OPNCaptureLibrary
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * uiScale) {
            details
            actions
            lockedMessage
        }
        .disabled(!viewModel.isCaptureLocationEditingEnabled)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4 * uiScale) {
            Text(library.displayName)
                .font(.settingsFont(size: 15 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.primary)
            Text(displayPath)
                .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(displayPath)
            rejectionMessage
        }
    }

    private var actions: some View {
        HStack(spacing: 8 * uiScale) {
            SettingsActionButton(title: "CHANGE…", tone: .secondary, uiScale: uiScale) {
                viewModel.chooseCaptureDirectory(library)
            }
            SettingsActionButton(title: "RESET TO DEFAULT", tone: .secondary, uiScale: uiScale) {
                viewModel.resetCaptureDirectory(library)
            }
            SettingsActionButton(title: "REVEAL IN FINDER", tone: .secondary, uiScale: uiScale) {
                viewModel.revealCaptureDirectory(library)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var rejectionMessage: some View {
        if let reason = viewModel.captureLocations.directories[library]?.rejectionReason {
            Text(reason)
                .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Semantic.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var lockedMessage: some View {
        if !viewModel.isCaptureLocationEditingEnabled {
            Text("Folders cannot change while a stream is running.")
                .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.muted)
        }
    }

    private var displayPath: String {
        viewModel.captureDirectoryDisplayPath(for: library)
    }
}

private struct CaptureNoticeBanner: View {
    let message: String
    let uiScale: CGFloat
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12 * uiScale) {
            Text(message)
                .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8 * uiScale)
            SettingsActionButton(title: "DISMISS", tone: .secondary, uiScale: uiScale, action: dismiss)
        }
    }
}

/// The way from the settings to what they produced. A destination named for a feature should be
/// able to open it, rather than describing a library the reader then has to go and find.
struct RecordingLibraryCard: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        SettingsCard(title: "Library", uiScale: uiScale) {
            HStack(alignment: .center, spacing: 16 * uiScale) {
                VStack(alignment: .leading, spacing: 5 * uiScale) {
                    Text("Your recordings")
                        .font(.settingsFont(size: 15 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                    Text("Command-R starts and stops a capture during a stream. Finished recordings are browsable, and can be trimmed, cropped and exported.")
                        .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12 * uiScale)
                SettingsActionButton(title: "OPEN LIBRARY", minimumWidth: 150 * uiScale, uiScale: uiScale) {
                    viewModel.showRecordings()
                }
            }
        }
    }
}

struct CaptureSettingsGroup: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    static let sections: [SettingsSection] = CaptureSettingsPage.sections

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            CaptureSettingsPage(viewModel: viewModel, uiScale: uiScale)
            CaptureStorageCard(viewModel: viewModel, uiScale: uiScale)
                .settingsSection("storage")
            RecordingLibraryCard(viewModel: viewModel, uiScale: uiScale)
                .settingsSection("library")
        }
    }
}
