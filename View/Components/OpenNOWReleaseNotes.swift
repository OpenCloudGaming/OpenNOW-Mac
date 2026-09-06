import SwiftUI

/// Renders parsed release notes for both update surfaces: the update modal and the What's New card
/// in Settings → About. The two differ only by `Metrics`, so the densities cannot drift apart.
struct OpenNOWReleaseNotesView: View {
    struct Metrics {
        let sectionSpacing: CGFloat
        let entrySpacing: CGFloat
        let eyebrowSize: CGFloat
        let entrySize: CGFloat
        let chipSize: CGFloat
        let showsSectionBar: Bool

        static let modal = Metrics(sectionSpacing: 14, entrySpacing: 8, eyebrowSize: 10, entrySize: 12, chipSize: 9, showsSectionBar: false)
        static let settings = Metrics(sectionSpacing: 14, entrySpacing: 7, eyebrowSize: 10, entrySize: 13, chipSize: 10, showsSectionBar: true)
    }

    let notes: OpenNOWReleaseNotes
    var metrics: Metrics = .modal
    /// Entries shown per section before an expander appears. A single release can carry a hundred
    /// bullets, which the modal scrolls through but an inline settings card must not.
    var entryLimit: Int?
    let uiScale: CGFloat

    @State private var expandedSectionIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.sectionSpacing * uiScale) {
            if notes.isEmpty {
                Text("No release notes were provided.")
                    .font(.uiSans(size: metrics.entrySize * uiScale, weight: .medium))
                    .foregroundStyle(OpenNOWDesign.Text.tertiary)
            }

            ForEach(notes.paragraphs, id: \.self) { paragraph in
                paragraphText(paragraph)
            }

            ForEach(notes.sections) { section in
                sectionView(section)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionView(_ section: OpenNOWReleaseNotes.Section) -> some View {
        VStack(alignment: .leading, spacing: metrics.entrySpacing * uiScale) {
            sectionHeader(section)

            ForEach(section.paragraphs, id: \.self) { paragraph in
                paragraphText(paragraph)
            }

            ForEach(visibleEntries(of: section)) { entry in
                entryRow(entry)
            }

            if let hiddenCount = hiddenEntryCount(of: section) {
                Button {
                    expandedSectionIDs.insert(section.id)
                } label: {
                    Text("+\(hiddenCount) MORE")
                        .font(.uiSans(size: metrics.eyebrowSize * uiScale, weight: .bold))
                        .foregroundStyle(OpenNOWDesign.accent)
                        .tracking(0.7)
                }
                .buttonStyle(.opnPressable)
                .padding(.top, 2 * uiScale)
            }
        }
    }

    private func sectionHeader(_ section: OpenNOWReleaseNotes.Section) -> some View {
        HStack(spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
            if metrics.showsSectionBar {
                Rectangle()
                    .fill(OpenNOWDesign.accent)
                    .frame(width: 3 * uiScale, height: 12 * uiScale)
            }
            Text(section.title.uppercased())
                .font(.uiSans(size: metrics.eyebrowSize * uiScale, weight: .bold))
                .foregroundStyle(OpenNOWDesign.Text.tertiary)
                .tracking(1.1)
            Spacer(minLength: OpenNOWDesign.Spacing.xSmall(scale: uiScale))
            Text("\(section.entries.count)")
                .font(.uiSans(size: metrics.eyebrowSize * uiScale, weight: .bold))
                .foregroundStyle(OpenNOWDesign.Text.muted)
        }
    }

    private func entryRow(_ entry: OpenNOWReleaseNotes.Entry) -> some View {
        HStack(alignment: .top, spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
            Rectangle()
                .fill(OpenNOWDesign.accent)
                .frame(width: 3 * uiScale, height: 3 * uiScale)
                .padding(.top, (metrics.entrySize * 0.5) * uiScale)

            Text(entry.attributedText)
                .font(.uiSans(size: metrics.entrySize * uiScale, weight: .medium))
                .foregroundStyle(OpenNOWDesign.Text.secondary)
                .tint(OpenNOWDesign.accent)
                .lineSpacing(2 * uiScale)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: OpenNOWDesign.Spacing.xSmall(scale: uiScale))

            if let author = entry.author {
                ReleaseNoteChip(label: "@\(author)", url: nil, size: metrics.chipSize, uiScale: uiScale)
            }
            if let pullRequest = entry.pullRequest {
                ReleaseNoteChip(label: "#\(pullRequest)", url: entry.pullRequestURL, size: metrics.chipSize, uiScale: uiScale)
            }
            if let commitShortSHA = entry.commitShortSHA {
                ReleaseNoteChip(label: commitShortSHA, url: entry.commitURL, size: metrics.chipSize, uiScale: uiScale)
            }
        }
    }

    private func paragraphText(_ paragraph: String) -> some View {
        Text(OpenNOWReleaseNotesFormatter.attributedText(paragraph))
            .font(.uiSans(size: metrics.entrySize * uiScale, weight: .medium))
            .foregroundStyle(OpenNOWDesign.Text.secondary)
            .tint(OpenNOWDesign.accent)
            .lineSpacing(2 * uiScale)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func visibleEntries(of section: OpenNOWReleaseNotes.Section) -> [OpenNOWReleaseNotes.Entry] {
        guard let limit = entryLimit, !expandedSectionIDs.contains(section.id), section.entries.count > limit else {
            return section.entries
        }
        return Array(section.entries.prefix(limit))
    }

    private func hiddenEntryCount(of section: OpenNOWReleaseNotes.Section) -> Int? {
        let hidden = section.entries.count - visibleEntries(of: section).count
        return hidden > 0 ? hidden : nil
    }
}

/// Commit SHA, pull request, or author tag trailing a release note entry. Clickable when it carries
/// a URL; a plain tag otherwise.
private struct ReleaseNoteChip: View {
    let label: String
    let url: URL?
    let size: CGFloat
    let uiScale: CGFloat

    @Environment(\.openURL) private var openURL
    @State private var isHovering = false

    var body: some View {
        if let url {
            Button {
                openURL(url)
            } label: {
                chipLabel
            }
            .buttonStyle(.opnPressable)
            .onHover { isHovering = $0 }
            .opnMotion(OpenNOWDesign.Motion.hover, value: isHovering)
            .help(url.absoluteString)
        } else {
            chipLabel
        }
    }

    private var chipLabel: some View {
        Text(label)
            .font(.uiSans(size: size * uiScale, weight: .bold))
            .foregroundStyle(isHovering ? OpenNOWDesign.Text.secondary : OpenNOWDesign.Text.muted)
            .tracking(0.7)
            .lineLimit(1)
            .padding(.horizontal, OpenNOWDesign.Spacing.xSmall(scale: uiScale))
            .frame(height: 18 * uiScale)
            .background(Color.white.opacity(isHovering ? 0.10 : 0.05))
            .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
    }
}
