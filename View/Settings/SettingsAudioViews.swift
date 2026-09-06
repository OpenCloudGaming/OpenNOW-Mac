import SwiftUI

struct AudioSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            SettingsColumns(uiScale: uiScale) {
                outputCard
            } trailing: {
                microphoneCard
            }
        }
    }

    private var outputCard: some View {
        SettingsCard(title: "Output", uiScale: uiScale) {
            SettingsSliderRow(title: "Game Volume", valueText: percentText(viewModel.streamProfile.gameVolume), value: viewModel.streamProfile.gameVolume, range: 0...1, step: 0.01, uiScale: uiScale, action: viewModel.setGameVolume)
            SettingsDivider(uiScale: uiScale)
            SettingsOptionRow(title: "Surround Sound", subtitle: viewModel.surroundModeSubtitle, options: OPNStreamPreferences.surroundModeOptions.map(\.label), selectedIndex: viewModel.streamProfile.surroundModeIndex, isNew: OpenNOWNewSettings.isNew(.surroundSound), uiScale: uiScale) { index in
                OpenNOWNewSettings.acknowledge(.surroundSound)
                viewModel.setSurroundModeIndex(index)
            }
            if viewModel.showsHeadphoneSurroundRow {
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(
                    title: "Headphone Surround",
                    subtitle: "Decode the full surround mix here and render it to two channels, instead of asking the server for a stereo mix. For headphones - on speakers it will sound wrong.",
                    isOn: viewModel.streamProfile.enableHeadphoneSurround,
                    isNew: OpenNOWNewSettings.isNew(.headphoneSurround),
                    uiScale: uiScale
                ) { newValue in
                    OpenNOWNewSettings.acknowledge(.headphoneSurround)
                    viewModel.setHeadphoneSurroundEnabled(newValue)
                }
            }
        }
        .settingsSection("output")
    }

    private var microphoneCard: some View {
        SettingsCard(title: "Microphone", uiScale: uiScale) {
            SettingsOptionRow(title: "Microphone Mode", subtitle: "Controls how voice input is sent to the stream.", options: OPNStreamPreferences.microphoneModeOptions.map(\.label), selectedIndex: selectedMicrophoneModeIndex, uiScale: uiScale, action: { viewModel.setMicrophoneMode(OPNStreamPreferences.microphoneModeOptions[$0].value) })
            SettingsDivider(uiScale: uiScale)
            SettingsOptionRow(title: "Microphone Device", subtitle: "Current input device for OpenNOW streams.", options: viewModel.microphoneDeviceOptions.map(\.label), selectedIndex: selectedMicrophoneDeviceIndex, uiScale: uiScale, action: { viewModel.setMicrophoneDeviceId(viewModel.microphoneDeviceOptions[$0].uniqueId) })
            SettingsDivider(uiScale: uiScale)
            SettingsSliderRow(title: "Microphone Volume", valueText: percentText(viewModel.streamProfile.microphoneVolume), value: viewModel.streamProfile.microphoneVolume, range: 0...1, step: 0.01, uiScale: uiScale, action: viewModel.setMicrophoneVolume)
            SettingsDivider(uiScale: uiScale)
            SettingsMicrophoneTestRow(active: viewModel.microphoneTestActive, level: viewModel.microphoneTestLevel, message: viewModel.microphoneTestMessage, uiScale: uiScale, action: viewModel.toggleMicrophoneTest)
        }
        .settingsSection("microphone")
    }

    private var selectedMicrophoneModeIndex: Int {
        OPNStreamPreferences.microphoneModeOptions.firstIndex { $0.value == viewModel.streamProfile.microphoneMode } ?? 0
    }

    private var selectedMicrophoneDeviceIndex: Int {
        viewModel.microphoneDeviceOptions.firstIndex { $0.uniqueId == viewModel.streamProfile.microphoneDeviceId } ?? 0
    }

    private func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

extension AudioSettingsPage {
    static let sections: [SettingsSection] = [
        SettingsSection("output", "Output"),
        SettingsSection("microphone", "Microphone")
    ]
}
