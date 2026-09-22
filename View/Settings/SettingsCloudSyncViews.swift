import SwiftUI

/// The iCloud destination: what is backed up, whether it is running, and how to push or pull by
/// hand. Ships behind BETA and off by default: nothing reaches iCloud until the reader enables it.
struct CloudSyncSettingsGroup: View {
    @Environment(\.opnUIScale) private var uiScale

    static let sections: [SettingsSection] = [SettingsSection("cloud-sync", "iCloud Sync")]

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            CloudSyncSettingsPage()
                .settingsSection("cloud-sync")
        }
    }
}

struct CloudSyncSettingsPage: View {
    @Environment(\.opnUIScale) private var uiScale

    private let coordinator = OPNCloudSyncCoordinator.shared
    @State private var enabledCategories = OPNCloudSyncPreferences.enabledCategories

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            if case .unavailable(let reason) = coordinator.status {
                SettingsMessageView(message: reason, systemImage: "icloud.slash", uiScale: uiScale)
            }
            if case .failed(let message) = coordinator.status {
                SettingsMessageView(message: message, systemImage: "exclamationmark.triangle.fill", uiScale: uiScale)
            }
            ForEach(coordinator.pendingConflicts) { conflict in
                conflictCard(conflict)
            }
            syncCard
            statusCard
        }
    }

    private func conflictCard(_ conflict: OPNCloudSyncConflict) -> some View {
        SettingsCard(title: "Sync Conflict — \(conflict.category.title)", uiScale: uiScale) {
            SettingsMessageView(
                message: "This Mac and \(conflict.remoteDisplayName) both changed your \(conflict.category.title.lowercased()) since the last sync. Choose which copy to keep.",
                systemImage: "exclamationmark.triangle.fill",
                uiScale: uiScale
            )
            SettingsDivider(uiScale: uiScale)
            HStack(spacing: 10 * uiScale) {
                SettingsActionButton(title: "Keep This Mac", tone: .primary, uiScale: uiScale) {
                    coordinator.resolveConflictKeepingLocal(conflict)
                }
                SettingsActionButton(title: "Use \(conflict.remoteDisplayName)", tone: .secondary, uiScale: uiScale) {
                    coordinator.resolveConflictUsingRemote(conflict)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var syncCard: some View {
        SettingsCard(title: "iCloud Sync", badge: .beta, uiScale: uiScale) {
            SettingsToggleRow(
                title: "Sync with iCloud",
                subtitle: "Back up the categories below to iCloud Drive and keep them in step across your Macs. Nothing leaves this Mac until this is on.",
                isOn: coordinator.isEnabled,
                uiScale: uiScale
            ) { coordinator.setEnabled($0) }

            ForEach(OPNCloudSyncCategory.allCases) { category in
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(
                    title: category.title,
                    subtitle: category.subtitle,
                    isOn: enabledCategories.contains(category),
                    isInert: !coordinator.isEnabled,
                    uiScale: uiScale
                ) { isOn in
                    enabledCategories = isOn
                        ? enabledCategories.union([category])
                        : enabledCategories.subtracting([category])
                    OPNCloudSyncPreferences.setCategory(category, isEnabled: isOn)
                }
            }
        }
    }

    private var statusCard: some View {
        SettingsCard(title: "Status", uiScale: uiScale) {
            SettingsInfoRow(label: "State", value: statusText, uiScale: uiScale)
            SettingsDivider(uiScale: uiScale)
            SettingsInfoRow(label: "Last Synced", value: lastSyncText, uiScale: uiScale)
            SettingsDivider(uiScale: uiScale)
            HStack(spacing: 10 * uiScale) {
                SettingsActionButton(title: "Back Up Now", tone: .primary, uiScale: uiScale) {
                    coordinator.backupNow()
                }
                .disabled(!coordinator.isEnabled || !coordinator.status.isAvailable)
                SettingsActionButton(title: "Restore from iCloud", tone: .secondary, uiScale: uiScale) {
                    coordinator.restoreNow()
                }
                .disabled(!coordinator.isEnabled || !coordinator.status.isAvailable)
                Spacer(minLength: 0)
            }
        }
    }

    private var statusText: String {
        switch coordinator.status {
        case .disabled: return "Off"
        case .unavailable: return "iCloud unavailable"
        case .syncing: return "Syncing..."
        case .idle: return "Up to date"
        case .conflict(let conflicts):
            guard let first = conflicts.first else { return "Conflicts need a choice" }
            return conflicts.count == 1 ? "Conflict with \(first.remoteDisplayName)" : "\(conflicts.count) sync conflicts"
        case .failed: return "Last attempt failed"
        }
    }

    private var lastSyncText: String {
        guard let lastSyncAt = coordinator.lastSyncAt else { return "Never" }
        return lastSyncAt.formatted(date: .abbreviated, time: .shortened)
    }
}
