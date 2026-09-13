import SwiftUI

struct ThemeSettingsPage: View {
    let uiScale: CGFloat
    @AppStorage(OpenNOWHomeLayout.modeKey) private var homeLayoutRawValue = OpenNOWHomeLayout.Mode.classic.rawValue

    private var selectedHomeLayoutIndex: Int {
        let mode = OpenNOWHomeLayout.Mode(rawValue: homeLayoutRawValue) ?? .classic
        return OpenNOWHomeLayout.Mode.allCases.firstIndex(of: mode) ?? 0
    }

    static let sections: [SettingsSection] = [
        SettingsSection("home-layout", "Home Layout"),
    ]

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
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
