import SwiftUI

struct NetworkTransportSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            SettingsCard(title: "Transport", uiScale: uiScale) {
                SettingsToggleRow(title: "Native/NVST Transport", subtitle: "Off uses the default WebRTC session path. On requests native NVST secure RTSP transport with matching CloudMatch headers.", isOn: viewModel.streamProfile.transportMode.value == "nvst", uiScale: uiScale, action: viewModel.setNVSTTransportEnabled)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "L4S", subtitle: "Use low-latency scalable throughput when available.", isOn: viewModel.streamProfile.enableL4S, uiScale: uiScale, action: viewModel.setL4SEnabled)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Prevent Display Sleep", subtitle: "Keeps the monitor awake while a stream is active.", isOn: viewModel.streamProfile.preventDisplaySleepWhileStreaming, isCompact: true, uiScale: uiScale, action: viewModel.setPreventDisplaySleepWhileStreaming)
            }
            .settingsSection("transport")
        }
    }
}

extension NetworkTransportSettingsPage {
    static let sections: [SettingsSection] = [SettingsSection("transport", "Transport")]
}
