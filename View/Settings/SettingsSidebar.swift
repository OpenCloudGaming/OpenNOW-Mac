import SwiftUI

/// The desktop destination list: every tab visible at once, down the left edge, matching the rail
/// the reader just came from in the catalog. It replaces a horizontal strip that overflowed at nine
/// tabs and faded its ends, hiding the very destinations it existed to show.
struct SettingsSidebar: View {
    @Binding var selection: CatalogSettingsGroup
    let groups: [CatalogSettingsGroup]
    let uiScale: CGFloat

    /// Below this window width the labels are dropped and the rail becomes a column of glyphs, so a
    /// narrow window spends its width on the settings rather than on their names.
    static let labelMinimumWidth: CGFloat = 900

    let showsLabels: Bool
    let onSelectSearchResult: (SettingsSearchEntry) -> Void

    @State private var query = ""

    private var results: [SettingsSearchEntry] { SettingsSearchIndex.results(for: query) }

    private var isSearching: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            rail
        }
        .frame(width: (showsLabels ? 208 : 60) * uiScale)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsVendorLayout.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
        }
    }

    /// Scrolls rather than clips: seven destinations at a 2.0 interface scale are taller than the
    /// window's own minimum height, and the horizontal strip this replaced could always be scrolled
    /// to its far end.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 2 * uiScale) {
            if showsLabels {
                SettingsSearchField(query: $query, uiScale: uiScale)
                    .padding(.horizontal, 12 * uiScale)
                    .padding(.bottom, 10 * uiScale)
            }
            if isSearching {
                SettingsSearchResults(results: results, query: query, uiScale: uiScale) { entry in
                    query = ""
                    onSelectSearchResult(entry)
                }
            } else {
                ForEach(groups) { group in
                    item(group)
                }
            }
        }
        .padding(.vertical, 14 * uiScale)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func item(_ group: CatalogSettingsGroup) -> some View {
        SettingsSidebarItem(
            group: group,
            isSelected: selection == group,
            showsLabel: showsLabels,
            showsBetaTag: SettingsTabBar.betaGroups.contains(group),
            newCount: SettingsNewBadges.count(in: group),
            uiScale: uiScale
        ) {
            selection = group
        }
    }
}

struct SettingsWindowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// How many settings in a tab still wear the NEW tag, so a reader who never opens that tab still
/// learns something arrived in it.
enum SettingsNewBadges {
    static func group(for row: OpenNOWNewSettings.Row) -> CatalogSettingsGroup {
        switch row {
        case .surroundSound: .audio
        case .sessionReadyAction: .general
        }
    }

    @MainActor static func count(in group: CatalogSettingsGroup) -> Int {
        OpenNOWNewSettings.Row.allCases
            .filter { self.group(for: $0) == group && OpenNOWNewSettings.isNew($0) }
            .count
    }
}

struct SettingsSidebarItem: View {
    let group: CatalogSettingsGroup
    let isSelected: Bool
    let showsLabel: Bool
    let showsBetaTag: Bool
    let newCount: Int
    let uiScale: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10 * uiScale) {
                Image(systemName: group.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(isSelected ? OpenNOWDesign.accent : .white.opacity(isHovering ? 0.72 : 0.5))
                    .frame(width: 16 * uiScale, height: 16 * uiScale)
                if showsLabel {
                    Text(group.title)
                        .font(.settingsFont(size: 13 * uiScale, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? .white : .white.opacity(isHovering ? 0.85 : 0.6))
                        .lineLimit(1)
                    Spacer(minLength: 4 * uiScale)
                    if showsBetaTag { OpenNOWBetaTag(uiScale: uiScale * 0.85, compact: true) }
                    if newCount > 0 { OpenNOWNewTag(uiScale: uiScale * 0.85) }
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 14 * uiScale)
            .frame(height: 36 * uiScale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? OpenNOWDesign.accent : .clear)
                    .frame(width: 3 * uiScale)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showsLabel ? "" : group.title)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .accessibilityLabel(group.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected { return OpenNOWDesign.accent.opacity(0.12) }
        return isHovering ? Color.white.opacity(0.05) : .clear
    }
}
