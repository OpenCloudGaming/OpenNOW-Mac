import SwiftUI

struct RecordingSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            SettingsCard(title: "Recording", uiScale: uiScale) {
                SettingsSliderRow(title: "Video Bitrate", valueText: recordingVideoBitrateText, value: Double(viewModel.streamProfile.recordingVideoBitrateMbps), range: 0...200, step: 1, uiScale: uiScale, action: viewModel.setRecordingVideoBitrateMbps)
                SettingsDivider(uiScale: uiScale)
                SettingsSliderRow(title: "Audio Bitrate", valueText: "\(viewModel.streamProfile.recordingAudioBitrateKbps) Kbps", value: Double(viewModel.streamProfile.recordingAudioBitrateKbps), range: 64...320, step: 16, uiScale: uiScale, action: viewModel.setRecordingAudioBitrateKbps)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Record Enhanced Video", subtitle: "Capture the enhanced/upscaled stream frame when available, with native decoded frames as fallback.", isOn: viewModel.streamProfile.recordingEnhancedVideoEnabled, uiScale: uiScale, action: viewModel.setRecordingEnhancedVideoEnabled)
            }
            .settingsSection("recording")
        }
    }

    /// Zero is the "let the encoder pick" sentinel rather than a real bitrate, so it reads as Auto.
    private var recordingVideoBitrateText: String {
        viewModel.streamProfile.recordingVideoBitrateMbps == 0 ? "Auto" : "\(viewModel.streamProfile.recordingVideoBitrateMbps) Mbps"
    }
}

extension RecordingSettingsPage {
    static let sections: [SettingsSection] = [
        SettingsSection("recording", "Recording"),
        SettingsSection("library", "Library"),
    ]
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
                        .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Command-R starts and stops a capture during a stream. Finished recordings are browsable, and can be trimmed, cropped and exported.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
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

struct RecordingSettingsGroup: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    static let sections: [SettingsSection] = RecordingSettingsPage.sections

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            RecordingSettingsPage(viewModel: viewModel, uiScale: uiScale)
            RecordingLibraryCard(viewModel: viewModel, uiScale: uiScale)
                .settingsSection("library")
        }
    }
}
