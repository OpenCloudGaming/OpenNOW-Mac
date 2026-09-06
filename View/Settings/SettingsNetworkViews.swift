import SwiftUI

struct NetworkTransportSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        let qualityLocked = !viewModel.streamingQualityProfileAllowsCustomization
        SettingsStack(spacing: 16 * uiScale) {
            SettingsCard(title: "Transport", uiScale: uiScale) {
                SettingsToggleRow(title: "Native/NVST Transport", subtitle: "Off uses the default WebRTC session path. On requests native NVST secure RTSP transport with matching CloudMatch headers.", isOn: viewModel.streamProfile.transportMode.value == "nvst", uiScale: uiScale, action: viewModel.setNVSTTransportEnabled)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "L4S", subtitle: qualityLocked ? lockedProfileSubtitle : "Use low-latency scalable throughput when available.", isOn: viewModel.streamProfile.enableL4S, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setL4SEnabled)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Prevent Display Sleep", subtitle: "Keeps the monitor awake while a stream is active.", isOn: viewModel.streamProfile.preventDisplaySleepWhileStreaming, isCompact: true, uiScale: uiScale, action: viewModel.setPreventDisplaySleepWhileStreaming)
            }
            .settingsSection("transport")
        }
    }

    /// The quality presets own every rate-shaping knob, so a locked row explains why it is inert
    /// instead of showing help text the reader cannot act on.
    private var lockedProfileSubtitle: String {
        "Managed by the \(viewModel.streamProfile.streamingQualityProfileOption.label) quality profile. Select Custom to edit."
    }
}

extension NetworkTransportSettingsPage {
    static let sections: [SettingsSection] = [SettingsSection("transport", "Transport")]
}
