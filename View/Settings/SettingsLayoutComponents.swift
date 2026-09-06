import SwiftUI

/// Layout machinery the restructured Settings pages share: the two-column container, the section
/// bar that gives a long page a map, the menu row for long option lists, and the collapsed card.

// MARK: - Wide layout

private struct SettingsWideLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SettingsNarrowRowsKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SettingsCardWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// True when the page has room for two card columns and nothing else forbids it. Published by
    /// `SettingsContent`, which owns the only measurement of the page's width.
    var opnSettingsWideLayout: Bool {
        get { self[SettingsWideLayoutKey.self] }
        set { self[SettingsWideLayoutKey.self] = newValue }
    }

    /// True inside a container too narrow for a row's label column to sit beside its control, so
    /// rows stack the control under the label instead of wrapping it.
    var opnSettingsNarrowRows: Bool {
        get { self[SettingsNarrowRowsKey.self] }
        set { self[SettingsNarrowRowsKey.self] = newValue }
    }

    /// The width a full-page card gets, padding already removed. `SettingsColumns` halves it to
    /// decide whether its own cards are narrow.
    var opnSettingsCardWidth: CGFloat {
        get { self[SettingsCardWidthKey.self] }
        set { self[SettingsCardWidthKey.self] = newValue }
    }
}

enum SettingsLayoutMetrics {
    /// Wide enough that each column can still hold a row's label beside its control. Splitting
    /// below this produced two columns whose every row stacked anyway - the same layout as one
    /// column, at half the measure.
    static var twoColumnMinimumWidth: CGFloat { narrowRowWidth * 2 + columnGutter }

    /// A card narrower than this cannot hold a 250pt label column beside its control.
    static let narrowRowWidth: CGFloat = 600

    /// The gutter between the two columns.
    static let columnGutter: CGFloat = 16

    /// - Parameter cardWidth: the measured width a full-page card gets, in points.
    static func allowsTwoColumns(cardWidth: CGFloat, uiScale: CGFloat) -> Bool {
        guard uiScale > 0 else { return false }
        return cardWidth / uiScale >= twoColumnMinimumWidth
    }

    /// Whether a container this wide has to stack a row's control under its label.
    static func usesNarrowRows(cardWidth: CGFloat, uiScale: CGFloat) -> Bool {
        guard cardWidth > 0, uiScale > 0 else { return false }
        return cardWidth / uiScale < narrowRowWidth
    }

    /// What each column gets once the page is split.
    static func columnWidth(cardWidth: CGFloat) -> CGFloat {
        max(0, (cardWidth - columnGutter) / 2)
    }
}

/// Two independent card columns side by side, or one column when the page is narrow or a gamepad
/// is driving it.
///
/// Independent columns rather than a grid of paired rows: a grid row is as tall as its taller card,
/// so any pair of unequal cards leaves a hole. Here each column packs its own cards and the two
/// simply end at different heights, which is what the card order per page is chosen to minimise.
///
/// Under pad focus the layout collapses to one column on purpose. Focus order is computed from each
/// row's `minY` alone (`ControllerSettingsFocusModel.setOrder`), so two columns would interleave
/// into one list and up/down would jump between them.
struct SettingsColumns<Leading: View, Trailing: View>: View {
    let uiScale: CGFloat
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    @Environment(\.opnSettingsWideLayout) private var isWide
    @Environment(\.opnSettingsCardWidth) private var cardWidth

    /// Each column is half a page, so a row inside one can need its control stacked while the
    /// full-width cards on the same page keep theirs beside the label. Measured rather than
    /// assumed: above roughly a 1216pt page the columns are as wide as a page that would not stack.
    private var columnUsesNarrowRows: Bool {
        SettingsLayoutMetrics.usesNarrowRows(
            cardWidth: SettingsLayoutMetrics.columnWidth(cardWidth: cardWidth),
            uiScale: uiScale
        )
    }

    var body: some View {
        if isWide {
            HStack(alignment: .top, spacing: SettingsLayoutMetrics.columnGutter * uiScale) {
                column { leading() }
                column { trailing() }
            }
            .environment(\.opnSettingsNarrowRows, columnUsesNarrowRows)
            .environment(\.opnSettingsCardWidth, SettingsLayoutMetrics.columnWidth(cardWidth: cardWidth))
        } else {
            VStack(alignment: .leading, spacing: 16 * uiScale) {
                leading()
                trailing()
            }
        }
    }

    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Card anchors

/// A card a search result can name and scroll to. Nothing draws these; the title is what a result
/// shows as its location, and the id is what the page scrolls to.
struct SettingsSection: Identifiable, Equatable {
    let id: String
    let title: String

    init(_ id: String, _ title: String) {
        self.id = id
        self.title = title
    }
}

extension View {
    /// Marks a card as the start of a named section: gives it the scroll identity a search result
    /// jumps to. Nothing draws a section; the names exist so a result can say which card it lives
    /// in, and the identity exists so it can be scrolled to.
    func settingsSection(_ identifier: String) -> some View {
        self.id(identifier)
    }
}

// MARK: - Subheading

/// Names a block inside a card, where a second `SettingsCard` would read as a separate object and
/// spend a header's worth of height saying so. Quieter than a card title by design.
struct SettingsSubheading: View {
    let title: String
    let uiScale: CGFloat

    var body: some View {
        Text(title.uppercased())
            .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
            .tracking(1.0)
            .foregroundStyle(.white.opacity(0.44))
    }
}

// MARK: - Label column

private struct SettingsLabelColumn: ViewModifier {
    let uiScale: CGFloat
    @Environment(\.opnSettingsNarrowRows) private var isNarrow

    func body(content: Content) -> some View {
        if isNarrow {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content.frame(width: 250 * uiScale, alignment: .leading)
        }
    }
}

extension View {
    /// A row's label column: a fixed 250 beside its control, or the full width when the container
    /// is too narrow to hold both. Rows whose control cannot stack - a text field, a level meter -
    /// still read better full-width than squeezed into what is left of 250.
    func settingsLabelColumn(uiScale: CGFloat) -> some View {
        modifier(SettingsLabelColumn(uiScale: uiScale))
    }
}

// MARK: - Disclosure card

/// A card whose body is folded away until asked for: the advanced block, a diagnostics dump, a
/// statistics panel. Rare enough that it should not spend a screen of height by default, and its
/// open state is remembered per card so a reader who lives in it is not refolding it every visit.
struct SettingsDisclosureCard<Content: View>: View {
    let title: String
    let summary: String
    let uiScale: CGFloat
    private let storageKey: String
    private let content: Content

    @AppStorage private var isExpanded: Bool

    init(title: String, summary: String, storageKey: String, uiScale: CGFloat, @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self.uiScale = uiScale
        self.storageKey = storageKey
        self.content = content()
        _isExpanded = AppStorage(wrappedValue: false, "OpenNOW.Settings.Expanded.\(storageKey)")
    }

    var body: some View {
        SettingsCollapsibleCard(
            title: title,
            statusSummary: summary,
            isConfigured: false,
            uiScale: uiScale,
            isExpanded: $isExpanded
        ) {
            content
        }
    }
}
