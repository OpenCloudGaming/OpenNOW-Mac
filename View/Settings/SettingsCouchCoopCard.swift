import SwiftUI

struct CouchCoopSettingsCard: View {
    let uiScale: CGFloat

    @State private var layout = OPNCouchCoopPreferences.layout()
    @ObservedObject private var presence = OPNCouchCoopPresence.shared

    var body: some View {
        SettingsCard(title: "Couch Co-Op", badge: .experimental, uiScale: uiScale) {
            LabsFlagRow(flag: OPNLabs.couchCoop, uiScale: uiScale)
            SettingsDivider(uiScale: uiScale)
            SettingsOptionRow(
                title: "Layout",
                subtitle: layout.summary,
                options: OPNCouchCoopLayout.allCases.map(\.label),
                selectedIndex: OPNCouchCoopLayout.allCases.firstIndex(of: layout) ?? 0,
                uiScale: uiScale
            ) { index in
                guard OPNCouchCoopLayout.allCases.indices.contains(index) else { return }
                layout = OPNCouchCoopLayout.allCases[index]
                OPNCouchCoopPreferences.setLayout(layout)
            }
            SettingsDivider(uiScale: uiScale)
            SettingsInfoRow(label: "Players Running", value: playersSummary, uiScale: uiScale)
        }
        .onAppear { layout = OPNCouchCoopPreferences.layout() }
    }

    private var playersSummary: String {
        guard presence.isActive else { return "Just this copy" }
        return presence.roster.instanceNumbers.map { "Player \($0)" }.joined(separator: ", ")
    }
}
