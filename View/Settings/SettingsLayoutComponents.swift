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
}

enum SettingsLayoutMetrics {
    /// Two 460pt cards plus the 16pt gutter between them, in unscaled points.
    static let twoColumnMinimumWidth: CGFloat = 936

    /// The page's own horizontal padding, which the measured width still carries and the cards
    /// never see. Counting it would let a page split into two columns 28pt narrower than the
    /// threshold promises.
    static let pageHorizontalPadding: CGFloat = 28

    /// A card narrower than this cannot hold a 250pt label column beside its control.
    static let narrowRowWidth: CGFloat = 600

    /// - Parameter contentWidth: the measured width of the scroll view, padding included.
    static func allowsTwoColumns(contentWidth: CGFloat, uiScale: CGFloat) -> Bool {
        guard uiScale > 0 else { return false }
        let cardWidth = contentWidth / uiScale - pageHorizontalPadding * 2
        return cardWidth >= twoColumnMinimumWidth
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

    var body: some View {
        if isWide {
            HStack(alignment: .top, spacing: 16 * uiScale) {
                column { leading() }
                column { trailing() }
            }
            // Half the page each: a row inside these columns no longer has room for its label
            // beside its control, whatever the window is doing.
            .environment(\.opnSettingsNarrowRows, true)
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

// MARK: - Section bar

struct SettingsSection: Identifiable, Equatable {
    let id: String
    let title: String

    init(_ id: String, _ title: String) {
        self.id = id
        self.title = title
    }
}

/// Where a section starts, measured in the page's coordinate space so the bar can tell which one
/// the reader is looking at.
struct SettingsSectionMark: Equatable {
    let id: String
    let minY: CGFloat
}

struct SettingsSectionMarksKey: PreferenceKey {
    static let defaultValue: [SettingsSectionMark] = []

    static func reduce(value: inout [SettingsSectionMark], nextValue: () -> [SettingsSectionMark]) {
        value.append(contentsOf: nextValue())
    }
}

let settingsPageCoordinateSpace = "opn-settings-page"

extension View {
    /// Marks a card as the start of a named section: gives it the scroll identity the bar jumps to
    /// and publishes its position so the bar can highlight it.
    func settingsSection(_ id: String) -> some View {
        self
            .id(id)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SettingsSectionMarksKey.self,
                        value: [SettingsSectionMark(id: id, minY: proxy.frame(in: .named(settingsPageCoordinateSpace)).minY)]
                    )
                }
            }
    }
}

/// The section names of the current tab, as a row of chips that jump to their card. A map for a
/// page that would otherwise be a single long scroll.
struct SettingsSectionBar: View {
    let sections: [SettingsSection]
    let activeID: String?
    let uiScale: CGFloat
    let action: (String) -> Void

    var body: some View {
        SettingsFlowLayout(spacing: 8 * uiScale) {
            ForEach(sections) { section in
                chip(section)
            }
        }
    }

    private func chip(_ section: SettingsSection) -> some View {
        let isActive = section.id == activeID
        return Button { action(section.id) } label: {
            Text(section.title)
                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(isActive ? OpenNOWDesign.accent : .white.opacity(0.58))
                .padding(.horizontal, 11 * uiScale)
                .frame(height: 26 * uiScale)
                .background(isActive ? OpenNOWDesign.accent.opacity(0.12) : Color.white.opacity(0.045))
                .overlay {
                    Rectangle().strokeBorder(isActive ? OpenNOWDesign.accent.opacity(0.34) : Color.white.opacity(0.10), lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Menu row

/// An option row whose values are too many for a chip row: the label keeps its column and the
/// value opens a dropdown. Five or more values, or values long enough to wrap the chips.
///
/// The pad never opens the dropdown - left/right step the value and confirm advances it, exactly
/// as they do on `SettingsOptionRow`, so a gamepad user needs no pointer.
struct SettingsMenuRow: View {
    @State private var focusIdentity = ControllerFocusIdentity()
    let title: String
    let subtitle: String
    let options: [String]
    let selectedIndex: Int
    var enabled: [Bool] = []
    var isLocked = false
    var isNew = false
    let uiScale: CGFloat
    let action: (Int) -> Void

    @Environment(\.opnSettingsNarrowRows) private var isNarrow

    var body: some View {
        Group {
            if isNarrow {
                VStack(alignment: .leading, spacing: 8 * uiScale) {
                    label
                    trigger
                }
            } else {
                HStack(alignment: .center, spacing: 18 * uiScale) {
                    label
                        .frame(width: 250 * uiScale, alignment: .leading)
                    trigger
                    Spacer(minLength: 0)
                }
            }
        }
        .controllerFocusable(
            focusIdentity,
            activate: { guard !isLocked else { return }; step(1) },
            adjust: { delta in guard !isLocked else { return }; step(delta) }
        )
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 5 * uiScale) {
            SettingsRowTitle(title: title, isLocked: isLocked, isNew: isNew, uiScale: uiScale)
            Text(subtitle)
                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(isLocked ? 0.38 : 0.58))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trigger: some View {
        OpenNOWDropdownMenu(items: dropdownItems, isDisabled: isLocked) {
            HStack(spacing: 8 * uiScale) {
                Text(selectedTitle)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                    .foregroundStyle(.white.opacity(isLocked ? 0.38 : 0.92))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                    .foregroundStyle(.white.opacity(isLocked ? 0.24 : 0.56))
            }
            .padding(.horizontal, 12 * uiScale)
            .frame(minWidth: 168 * uiScale, alignment: .leading)
            .frame(height: 32 * uiScale)
            .background(Color.white.opacity(isLocked ? 0.035 : 0.07))
            .overlay { Rectangle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
            .contentShape(Rectangle())
        }
    }

    private var selectedTitle: String {
        options.indices.contains(selectedIndex) ? options[selectedIndex] : "-"
    }

    private var dropdownItems: [OpenNOWDropdownItem] {
        options.indices.map { index in
            OpenNOWDropdownItem(id: "\(index)-\(options[index])", title: options[index], isSelected: index == selectedIndex) {
                guard isEnabled(index) else { return }
                action(index)
            }
        }
    }

    private func isEnabled(_ index: Int) -> Bool {
        guard !isLocked else { return false }
        return enabled.indices.contains(index) ? enabled[index] : true
    }

    /// Steps to the next selectable value, skipping any the hardware or the seat rules out.
    private func step(_ delta: Int) {
        guard !options.isEmpty else { return }
        var index = selectedIndex
        for _ in 0..<options.count {
            index = (index + delta + options.count) % options.count
            if isEnabled(index) {
                action(index)
                return
            }
        }
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
