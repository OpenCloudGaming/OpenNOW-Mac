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
    static let sections: [SettingsSection] = [SettingsSection("recording", "Recording")]
}
