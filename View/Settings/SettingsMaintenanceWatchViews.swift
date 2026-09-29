import SwiftUI

/// The maintenance watches this Mac is running, and where the reader ends one. The page says plainly
/// that the list is local and that monitoring stops when OpenNOW quits.
struct MaintenanceWatchSettingsPage: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    static let sections: [SettingsSection] = [
        SettingsSection("maintenance-watch", "Maintenance Watch"),
    ]

    private var limitLine: String {
        let count = viewModel.watchedTitleCount
        let maximum = CatalogMaintenanceWatchStore.maximumCount
        return "\(count) of \(maximum) watched on this Mac. The cap keeps one poll from growing without bound: every watched title is one more game each cycle has to check."
    }

    var body: some View {
        SettingsCard(title: "Maintenance Watch", isNew: OPNNewSettings.isNew(.maintenanceWatch), uiScale: uiScale) {
            if !viewModel.maintenanceWatches.isEmpty { watchList }
            if viewModel.maintenanceWatches.isEmpty { emptyState }
            footer
        }
        .settingsSection("maintenance-watch")
    }

    private var watchList: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.maintenanceWatches) { watch in
                watchRow(watch)
                SettingsDivider(uiScale: uiScale)
            }
            HStack {
                SettingsActionButton(title: "STOP WATCHING ALL", tone: .secondary, uiScale: uiScale) {
                    OPNNewSettings.acknowledge(.maintenanceWatch)
                    viewModel.clearMaintenanceWatches()
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 14 * uiScale)
        }
    }

    private var emptyState: some View {
        Text("Nothing is being watched. Open a game's offline notice and choose Watch to be told when maintenance finishes.")
            .font(.settingsFont(size: 13 * uiScale, weight: .medium))
            .foregroundStyle(OPNDesign.Text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5 * uiScale) {
            Text("OpenNOW checks watched games on the same 30-60 second poll it uses for patching, and brings you back the moment one is playable again.")
                .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("A watch ends on its own once the title is ready to play, or when you remove it here. Watching runs only while OpenNOW is running, window hidden included. Quitting OpenNOW ends it, and the watch list stays on this Mac — it is not synced to iCloud.")
                .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text(limitLine)
                .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.muted)
                .tracking(0.4)
                .padding(.top, 2 * uiScale)
        }
        .padding(.top, 14 * uiScale)
    }

    private func watchRow(_ watch: CatalogMaintenanceWatch) -> some View {
        HStack(alignment: .center, spacing: 18 * uiScale) {
            VStack(alignment: .leading, spacing: 4 * uiScale) {
                Text(watch.title.isEmpty ? "Watched game" : watch.title)
                    .font(.settingsFont(size: 13 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .lineLimit(1)
                Text("Watching since \(watch.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
            }
            Spacer(minLength: 0)
            SettingsActionButton(title: "REMOVE", tone: .secondary, uiScale: uiScale) {
                OPNNewSettings.acknowledge(.maintenanceWatch)
                viewModel.removeMaintenanceWatch(identity: watch.identity)
            }
        }
        .padding(.vertical, 11 * uiScale)
    }
}
