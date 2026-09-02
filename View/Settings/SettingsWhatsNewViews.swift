//
//  SettingsWhatsNewViews.swift
//  OpenNOW
//

import SwiftUI

/// Release history for Settings → About, rendered from the same parsed notes and the same pending
/// release as the update modal.
struct WhatsNewCard: View {
    let uiScale: CGFloat

    @ObservedObject private var history = OpenNOWReleaseHistoryStore.shared
    @ObservedObject private var presentation = OpenNOWUpdatePresentation.shared
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

    private func releaseList(_ entries: [OpenNOWReleaseHistoryStore.Entry]) -> some View {
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

    private func releaseRow(_ entry: OpenNOWReleaseHistoryStore.Entry) -> some View {
        let isExpanded = expandedVersionIDs.contains(entry.id)

        return VStack(alignment: .leading, spacing: 12 * uiScale) {
            Button {
                toggle(entry.id)
            } label: {
                HStack(spacing: 10 * uiScale) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.44))
                        .frame(width: 12 * uiScale)
                    Text(entry.version.isEmpty ? entry.summary.tagName : entry.version)
                        .font(.settingsNvidia(size: 14 * uiScale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.88))
                    if entry.version == SettingsAppMetadata.version {
                        WhatsNewBadge(title: "INSTALLED", tone: .neutral, uiScale: uiScale)
                    }
                    Spacer(minLength: 8 * uiScale)
                    if let publishedAt = entry.publishedAt {
                        Text(OpenNOWUpdateFormat.releaseDate(publishedAt))
                            .font(.settingsNvidia(size: 11 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.44))
                    }
                    Text("\(entry.notes.entryCount)")
                        .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.34))
                        .frame(minWidth: 18 * uiScale, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.opnPressable)

            if isExpanded {
                OpenNOWReleaseNotesView(notes: entry.notes, metrics: .settings, entryLimit: 5, uiScale: uiScale)
                    .padding(.leading, 22 * uiScale)
            }
        }
    }

    private func availableStrip(_ release: OpenNOWGitHubRelease) -> some View {
        HStack(spacing: 10 * uiScale) {
            Rectangle()
                .fill(OpenNOWDesign.accent)
                .frame(width: 4 * uiScale, height: 32 * uiScale)
            VStack(alignment: .leading, spacing: 3 * uiScale) {
                HStack(spacing: 8 * uiScale) {
                    Text(release.version)
                        .font(.settingsNvidia(size: 14 * uiScale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                    WhatsNewBadge(title: "AVAILABLE", tone: .accent, uiScale: uiScale)
                }
                Text(availableSubtitle(release))
                    .font(.settingsNvidia(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.54))
            }
            Spacer(minLength: 10 * uiScale)
            SettingsActionButton(title: "VIEW UPDATE", uiScale: uiScale) {
                presentation.presentAvailableRelease()
            }
        }
        .padding(.vertical, 2 * uiScale)
    }

    private func availableSubtitle(_ release: OpenNOWGitHubRelease) -> String {
        var parts = ["You're on \(SettingsAppMetadata.version)"]
        if release.assetByteCount > 0 {
            parts.append(OpenNOWUpdateFormat.byteCount(release.assetByteCount))
        }
        return parts.joined(separator: " · ")
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
            .foregroundStyle(.white.opacity(0.54))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ id: String) {
        if expandedVersionIDs.contains(id) {
            expandedVersionIDs.remove(id)
        } else {
            expandedVersionIDs.insert(id)
        }
    }

    /// A release page URL is `…/releases/tag/v0.2.0`; the index is everything up to `/releases`.
    private func releasesIndexURL(from entries: [OpenNOWReleaseHistoryStore.Entry]) -> URL? {
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
            .font(.settingsNvidia(size: 9 * uiScale, weight: .bold))
            .foregroundStyle(tone == .accent ? .black : .white.opacity(0.62))
            .tracking(0.8)
            .padding(.horizontal, 7 * uiScale)
            .frame(height: 18 * uiScale)
            .background(tone == .accent ? OpenNOWDesign.accent : Color.white.opacity(0.08))
            .overlay {
                Rectangle().stroke(tone == .accent ? OpenNOWDesign.accent : Color.white.opacity(0.12), lineWidth: 1)
            }
    }
}
