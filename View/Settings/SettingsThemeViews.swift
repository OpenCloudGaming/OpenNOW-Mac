import SwiftUI

struct ThemeSettingsPage: View {
    let uiScale: CGFloat
    @AppStorage(OpenNOWInterfacePreferences.uiScaleKey) private var uiScaleStorage = OpenNOWInterfacePreferences.defaultUIScale
    @AppStorage(OpenNOWHomeLayout.modeKey) private var homeLayoutRawValue = OpenNOWHomeLayout.Mode.classic.rawValue

    private var selectedHomeLayoutIndex: Int {
        let mode = OpenNOWHomeLayout.Mode(rawValue: homeLayoutRawValue) ?? .classic
        return OpenNOWHomeLayout.Mode.allCases.firstIndex(of: mode) ?? 0
    }

    static let sections: [SettingsSection] = [
        SettingsSection("interface", "Interface"),
        SettingsSection("home-layout", "Home Layout"),
    ]

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            SettingsCard(title: "Interface", uiScale: uiScale) {
                SettingsSliderRow(title: "Interface Scale", valueText: "\(Int((uiScaleStorage * 100).rounded()))%", value: uiScaleStorage, range: OpenNOWInterfacePreferences.uiScaleRange, step: 0.05, uiScale: uiScale) { scale in
                    uiScaleStorage = scale
                }
                SettingsDivider(uiScale: uiScale)
                Text("Scales the catalog, settings, and in-stream HUD. Increase it on high-resolution displays (for example 5K) when the interface feels too small.")
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsSection("interface")

            SettingsCard(title: "Home Layout", uiScale: uiScale) {
                SettingsOptionRow(title: "Home Layout", subtitle: "How the keyboard-and-mouse home page is laid out. Classic keeps today's featured banner and wide landscape tiles. Poster switches to rows of tall, portrait box-art tiles. Controller mode is unaffected.", options: OpenNOWHomeLayout.Mode.allCases.map(\.label), selectedIndex: selectedHomeLayoutIndex, isNew: OpenNOWNewSettings.isNew(.homeLayout), uiScale: uiScale) { index in
                    OpenNOWNewSettings.acknowledge(.homeLayout)
                    homeLayoutRawValue = OpenNOWHomeLayout.Mode.allCases[index].rawValue
                }
            }
            .settingsSection("home-layout")
        }
    }
}
