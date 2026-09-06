import SwiftUI

/// The destination for features on trial. It exists only while something is in flight: the tab this
/// replaces stood empty for long enough that people learned to skip it, and a destination that is
/// usually nothing teaches exactly that.
struct LabsSettingsPage: View {
    let uiScale: CGFloat

    static let sections: [SettingsSection] = [SettingsSection("labs", "Labs")]

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            SettingsCard(title: "In Flight", badge: .experimental, uiScale: uiScale) {
                Text("Each of these is off by default and may change, misbehave or disappear. Turning one on is a request to be surprised.")
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(OpenNOWLabs.flags) { flag in
                    SettingsDivider(uiScale: uiScale)
                    LabsFlagRow(flag: flag, uiScale: uiScale)
                }
            }
            .settingsSection("labs")
        }
    }
}

struct LabsFlagRow: View {
    let flag: OpenNOWLabsFlag
    let uiScale: CGFloat

    @State private var isEnabled = false

    var body: some View {
        SettingsToggleRow(
            title: flag.title,
            subtitle: "\(flag.summary) On trial since \(flag.since).",
            isOn: isEnabled,
            uiScale: uiScale
        ) { enabled in
            isEnabled = enabled
            OpenNOWLabs.setEnabled(flag, enabled)
        }
        .onAppear { isEnabled = OpenNOWLabs.isEnabled(flag) }
    }
}
