import SwiftUI

/// Release history for Settings → System, rendered from the same parsed notes and the same pending
/// release as the update modal.
struct WhatsNewCard: View {
    let uiScale: CGFloat

    @ObservedObject private var history = OPNReleaseHistoryStore.shared
    @ObservedObject private var presentation = OPNUpdatePresentation.shared
    @State private var expandedVersionIDs: Set<String> = []
    @State private var hasExpandedNewestRelease = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsCard(title: "What's New", uiScale: uiScale) {
            VStack(alignment: .leading, spacing: 0) {
                if let release = presentation.availableRelease {
                    availableStrip(release)
                    SettingsDivider(uiScale: uiScale)
                }

                switch history.state {
                case .idle, .loading:
                    statusText("Loading release history from GitHub...")
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 10 * uiScale) {
                        statusText("Release history is unavailable: \(message)")
                        SettingsActionButton(title: "RETRY", tone: .secondary, uiScale: uiScale) {
                            history.reload()
                        }
                    }
                case .loaded(let entries):
                    if entries.isEmpty {
                        statusText("No published releases were found for this repository.")
                    } else {
                        releaseList(entries)
                    }
                }
            }
        }
        .task {
            history.loadIfNeeded()
        }
        .onChange(of: history.state) { _, state in
            guard case .loaded(let entries) = state, !hasExpandedNewestRelease, let newest = entries.first else { return }
            hasExpandedNewestRelease = true
            expandedVersionIDs.insert(newest.id)
        }
    }

    private func releaseList(_ entries: [OPNReleaseHistoryStore.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    SettingsDivider(uiScale: uiScale)
                }
                releaseRow(entry)
            }

            if let releasesURL = releasesIndexURL(from: entries) {
                SettingsDivider(uiScale: uiScale)
                SettingsActionButton(title: "OPEN RELEASES ON GITHUB", tone: .secondary, uiScale: uiScale) {
                    openURL(releasesURL)
                }
            }
        }
    }

    private func releaseRow(_ entry: OPNReleaseHistoryStore.Entry) -> some View {
        let isExpanded = expandedVersionIDs.contains(entry.id)

        return VStack(alignment: .leading, spacing: 12 * uiScale) {
            Button {
                toggle(entry.id)
            } label: {
                HStack(spacing: 10 * uiScale) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.muted)
                        .frame(width: 12 * uiScale)
                    Text(entry.version.isEmpty ? entry.summary.tagName : entry.version)
                        .font(.settingsFont(size: 14 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                    if entry.version == SettingsAppMetadata.version {
                        WhatsNewBadge(title: "INSTALLED", tone: .neutral, uiScale: uiScale)
                    }
                    if entry.summary.isPrerelease {
                        WhatsNewBadge(title: "BETA", tone: .neutral, uiScale: uiScale)
                    }
                    Spacer(minLength: 8 * uiScale)
                    if let publishedAt = entry.publishedAt {
                        Text(OPNUpdateFormat.releaseDate(publishedAt))
                            .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                            .foregroundStyle(OPNDesign.Text.muted)
                    }
                    Text("\(entry.notes.entryCount)")
                        .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.muted)
                        .frame(minWidth: 18 * uiScale, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.opnPressable)

            if isExpanded {
                OPNReleaseNotesView(notes: entry.notes, metrics: .settings, entryLimit: 5, uiScale: uiScale)
                    .padding(.leading, 22 * uiScale)
            }
        }
    }

    private func availableStrip(_ release: OPNGitHubRelease) -> some View {
        HStack(spacing: 10 * uiScale) {
            Rectangle()
                .fill(OPNDesign.accent)
                .frame(width: 4 * uiScale, height: 32 * uiScale)
            VStack(alignment: .leading, spacing: 3 * uiScale) {
                HStack(spacing: 8 * uiScale) {
                    Text(release.version)
                        .font(.settingsFont(size: 14 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                    WhatsNewBadge(title: "AVAILABLE", tone: .accent, uiScale: uiScale)
                }
                Text(availableSubtitle(release))
                    .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
            }
            Spacer(minLength: 10 * uiScale)
            SettingsActionButton(title: "VIEW UPDATE", uiScale: uiScale) {
                presentation.presentAvailableRelease()
            }
        }
        .padding(.vertical, 2 * uiScale)
    }

    private func availableSubtitle(_ release: OPNGitHubRelease) -> String {
        var parts = ["You're on \(SettingsAppMetadata.version)"]
        if release.assetByteCount > 0 {
            parts.append(OPNUpdateFormat.byteCount(release.assetByteCount))
        }
        return parts.joined(separator: " · ")
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.settingsFont(size: 12 * uiScale, weight: .medium))
            .foregroundStyle(OPNDesign.Text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ id: String) {
        guard !expandedVersionIDs.contains(id) else {
            expandedVersionIDs.remove(id)
            return
        }
        expandedVersionIDs.insert(id)
    }

    /// A release page URL is `…/releases/tag/v0.2.0`; the index is everything up to `/releases`.
    private func releasesIndexURL(from entries: [OPNReleaseHistoryStore.Entry]) -> URL? {
        for entry in entries {
            guard let range = entry.releaseURL.range(of: "/releases/") else { continue }
            return URL(string: String(entry.releaseURL[entry.releaseURL.startIndex..<range.lowerBound]) + "/releases")
        }
        return nil
    }
}

private struct WhatsNewBadge: View {
    enum Tone {
        case accent
        case neutral
    }

    let title: String
    let tone: Tone
    let uiScale: CGFloat

    var body: some View {
        Text(title)
            .font(.settingsFont(size: 9 * uiScale, weight: .bold))
            .foregroundStyle(tone == .accent ? OPNDesign.onAccent : OPNDesign.Text.secondary)
            .tracking(0.8)
            .padding(.horizontal, 7 * uiScale)
            .frame(height: 18 * uiScale)
            .background(tone == .accent ? OPNDesign.accent : OPNDesign.Stroke.subtle)
            .overlay {
                Rectangle().stroke(tone == .accent ? OPNDesign.accent : OPNDesign.Stroke.regular, lineWidth: 1)
            }
    }
}
