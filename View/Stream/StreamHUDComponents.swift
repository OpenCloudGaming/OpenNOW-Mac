import AppKit
import Combine
import GameController
import Foundation
import SwiftUI

enum StreamHUDTheme {
    /// Same resolved colour the rest of the app paints with, so the HUD follows the user's
    /// chosen accent instead of a hardcoded green. The stream view is deliberately never
    /// invalidated while a session is live, so a mid-session accent change still waits for the
    /// next render, same as before this read became dynamic.
    static var accent: Color { OPNDesign.Fixed.accent }

    static var accentSoft: Color { OPNDesign.accentSoft }

    static let appBar = Color(red: 45 / 255, green: 45 / 255, blue: 45 / 255)
    static let surface = Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255)
    static let panel = Color(red: 23 / 255, green: 23 / 255, blue: 23 / 255)
    static let surfaceRaised = Color(red: 34 / 255, green: 34 / 255, blue: 34 / 255)
    static let divider = Color.white.opacity(0.10)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.72)
    static let textTertiary = Color.white.opacity(0.52)
    static let warning = Color.orange
    static let danger = Color.red
    /// The 0.54 dim DESIGN.md already documented in prose for stream overlays, now a symbol instead
    /// of a bare literal duplicated at every call site.
    static let scrim = Color.black.opacity(0.54)

    static func dockWidth(for width: CGFloat) -> CGFloat {
        min(344, max(268, width * 0.72))
    }
}

extension Font {
    static func streamFont(size: CGFloat, weight: OPNUIFont.Weight = .regular) -> Font {
        OPNUIFont.font(size: size, weight: weight)
    }
}

struct StreamHUDActionRow: View {
    let title: String
    let subtitle: String
    let systemName: String
    let isActive: Bool
    let isDisabled: Bool
    var isFocused = false
    /// Grid tiles fill their panel's width so a two- or three-tile row has no dead space on the
    /// right. Standalone rows (Remote Co-Op's invite buttons) keep the square 42pt footprint.
    var isWidthFlexible = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.streamFont(size: 15, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: isWidthFlexible ? nil : 42, height: 38)
                .frame(maxWidth: isWidthFlexible ? .infinity : nil)
                .background(rowBackground)
                .overlay {
                    Rectangle()
                        .stroke(strokeColor, lineWidth: isFocused ? 2 : 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.46 : 1)
        .onHover { isHovering = $0 }
        .preference(key: StreamHUDHoveredCaptionKey.self, value: isHovering ? hoverCaption : nil)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .help(subtitle.isEmpty ? title : "\(title): \(subtitle)")
    }

    private var hoverCaption: String {
        subtitle.isEmpty ? title : "\(title) · \(subtitle)"
    }

    private var strokeColor: Color {
        if isFocused { return StreamHUDTheme.accent }
        return isActive ? StreamHUDTheme.accent.opacity(0.86) : StreamHUDTheme.divider
    }

    private var rowBackground: Color {
        if isActive { return StreamHUDTheme.accent }
        return Color.white.opacity(isHovering ? 0.14 : 0.075)
    }

    private var iconColor: Color {
        isActive ? .black.opacity(0.86) : .white.opacity(isHovering ? 0.94 : 0.72)
    }
}

/// Where the pad wants focus to go. Left/right read through the controls in visual order;
/// up/down move between rows of the HUD's grids, keeping the column.
enum StreamHUDFocusDirection: Equatable {
    case left, right, up, down

    /// The ±1 a one-dimensional menu (the quit menu) reads this as.
    var linearStep: Int { self == .left || self == .up ? -1 : 1 }
}

/// What a focus entry is: a control, a section's fold header, or a dock-wide action outside any
/// section. The last two are skipped when the HUD opens so focus starts on a real control.
enum StreamHUDFocusEntryKind {
    case control
    case sectionHeader
    case globalAction
}

struct StreamHUDFocusEntry {
    /// One section as the assembler needs it: its identity, its fold action, and its controls.
    struct Section {
        let section: OPNStreamHUDSection
        let action: () -> Void
        let content: [StreamHUDFocusEntry]
    }

    let id: String
    let isDisabled: Bool
    let action: () -> Void
    /// Entries that share a group and sit next to each other in the list form one grid of
    /// `columns` tiles per row — the HUD's 4-wide icon panels. An entry with no group is a
    /// full-width row of its own (a slider, a dropdown, a participant row, a section header).
    var group = ""
    var columns = 1
    var kind: StreamHUDFocusEntryKind = .control

    init(id: String, isDisabled: Bool, group: String = "", columns: Int = 1, kind: StreamHUDFocusEntryKind = .control, action: @escaping () -> Void) {
        self.id = id
        self.isDisabled = isDisabled
        self.group = group
        self.columns = max(1, columns)
        self.kind = kind
        self.action = action
    }

    /// Lays the sections out as one list: each header row followed by its controls, or the header
    /// alone when folded, so a pad can still reach it to reopen the section.
    static func sectioned(_ sections: [Section], collapsed: Set<OPNStreamHUDSection>) -> [StreamHUDFocusEntry] {
        sections.flatMap { section -> [StreamHUDFocusEntry] in
            let header = StreamHUDFocusEntry(id: section.section.focusID, isDisabled: false, kind: .sectionHeader, action: section.action)
            guard !collapsed.contains(section.section) else { return [header] }
            return [header] + section.content
        }
    }

    /// Focus only ever lands on enabled rows, so both navigation and activation
    /// filter the disabled ones out — a row that goes disabled while focused
    /// must not fire when the pad's activate button is pressed.
    static func focusID(after current: String?, in entries: [StreamHUDFocusEntry], step: Int) -> String? {
        let enabled = entries.filter { !$0.isDisabled }
        guard !enabled.isEmpty else { return nil }
        guard let currentIndex = enabled.firstIndex(where: { $0.id == current }) else { return enabled.first?.id }
        return enabled[(currentIndex + step + enabled.count) % enabled.count].id
    }

    /// The rows the entries lay out as: grouped entries chunked `columns` at a time, everything
    /// else one per row. Indices into `entries`.
    static func rows(of entries: [StreamHUDFocusEntry]) -> [[Int]] {
        var rows: [[Int]] = []
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            guard !entry.group.isEmpty else {
                rows.append([index])
                index += 1
                continue
            }
            var row: [Int] = []
            while index < entries.count, entries[index].group == entry.group, row.count < entry.columns {
                row.append(index)
                index += 1
            }
            rows.append(row)
        }
        return rows
    }

    /// Two-dimensional focus movement. Left and right walk the enabled controls in visual order
    /// (wrapping), so a grid still reads like a list when scanned. Up and down go to the previous
    /// or next row that has an enabled control, landing on the one nearest the current column — a
    /// press of "down" on the microphone tile reaches the pointer tile beneath it, not the tile to
    /// its right, which is what the flat ±1 walk did.
    static func focusID(from current: String?, direction: StreamHUDFocusDirection, in entries: [StreamHUDFocusEntry]) -> String? {
        switch direction {
        case .left, .right:
            return focusID(after: current, in: entries, step: direction.linearStep)
        case .up, .down:
            let rows = rows(of: entries)
            guard !rows.isEmpty else { return nil }
            guard let currentIndex = entries.firstIndex(where: { $0.id == current }),
                  let rowIndex = rows.firstIndex(where: { $0.contains(currentIndex) }),
                  let column = rows[rowIndex].firstIndex(of: currentIndex) else {
                return entries.first(where: { !$0.isDisabled })?.id
            }
            let step = direction.linearStep
            for offset in 1..<max(2, rows.count) {
                let row = rows[(rowIndex + step * offset + rows.count * offset) % rows.count]
                let candidates = row.enumerated().filter { !entries[$0.element].isDisabled }
                guard !candidates.isEmpty else { continue }
                let nearest = candidates.min { abs($0.offset - column) < abs($1.offset - column) }
                return nearest.map { entries[$0.element].id }
            }
            return nil
        }
    }

    static func activatable(_ current: String?, in entries: [StreamHUDFocusEntry]) -> StreamHUDFocusEntry? {
        let enabled = entries.filter { !$0.isDisabled }
        return enabled.first(where: { $0.id == current }) ?? enabled.first
    }
}

struct StreamQuitMenuButton: View {
    let title: String
    let isPrimary: Bool
    let isFocused: Bool
    let isDisabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.streamFont(size: 12, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(backgroundColor)
                .overlay {
                    Rectangle()
                        .stroke(strokeColor, lineWidth: isFocused ? 2 : 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.46 : 1)
        .onHover { isHovering = $0 }
    }

    private var strokeColor: Color {
        if isFocused { return StreamHUDTheme.accent }
        return isPrimary ? StreamHUDTheme.accent : StreamHUDTheme.divider
    }

    private var backgroundColor: Color {
        if isPrimary { return StreamHUDTheme.accent.opacity(isHovering ? 0.82 : 1) }
        return Color.white.opacity(isHovering ? 0.14 : 0.075)
    }

    private var foregroundColor: Color {
        if isPrimary { return .black.opacity(0.86) }
        return .white.opacity(isHovering ? 0.94 : 0.82)
    }
}

/// Square design-system dropdown for stream HUD panels. Replaces native
/// `.pickerStyle(.menu)`, which renders rounded system chrome the stream
/// design forbids (DESIGN.md "Overflow Menu" / "Don't" sections).
/// Set by a dropdown while its panel is open, read by the section around it. `zIndex` only orders
/// views within one container, so a panel that spills past its own section was painted over by the
/// next section's translucent background and read as transparent. The section lifts itself in the
/// sidebar's stack instead.
struct StreamHUDExpandedPanelKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// The caption of the tile the pointer is over, lifted from the tile to its section so the same line
/// that explains a gamepad focus also explains a hover. Nil when no tile is hovered.
struct StreamHUDHoveredCaptionKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        value = value ?? nextValue()
    }
}

struct StreamHUDDropdown: View {
    let label: String
    let options: [(value: Int, title: String)]
    let selection: Int
    let isDisabled: Bool
    let onSelect: (Int) -> Void
    var isFocused = false
    @State private var isExpanded = false
    @State private var isHovering = false
    /// Where the button sits in the window, so the panel can open upward when there is no room
    /// below it. The sidebar's list scrolls and its footer does not, so a panel opening downward
    /// from a control near the bottom was cut off by the scroll view's edge.
    @State private var buttonMaxY: CGFloat = 0
    @State private var windowHeight: CGFloat = 0

    private var selectedTitle: String {
        options.first(where: { $0.value == selection })?.title ?? options.first?.title ?? ""
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.streamFont(size: 11, weight: .medium))
                .foregroundStyle(StreamHUDTheme.textTertiary)
            Spacer(minLength: 8)
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Text(selectedTitle)
                        .font(.streamFont(size: 12, weight: .bold))
                        .foregroundStyle(StreamHUDTheme.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(StreamHUDTheme.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Color.white.opacity(isHovering ? 0.14 : 0.075))
                .overlay {
                    Rectangle()
                        .stroke((isExpanded || isFocused) ? StreamHUDTheme.accent : StreamHUDTheme.divider, lineWidth: isFocused ? 2 : 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .overlay {
                if isExpanded {
                    // Invisible full-screen catcher so any outside click dismisses.
                    Color.black.opacity(0.001)
                        .frame(width: 6000, height: 6000)
                        .contentShape(Rectangle())
                        .onTapGesture { isExpanded = false }
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            buttonMaxY = proxy.frame(in: .global).maxY
                            // The window, not the screen: the HUD lives in a stream window that is
                            // often, but not always, fullscreen.
                            windowHeight = NSApp.keyWindow?.frame.height ?? NSApp.mainWindow?.frame.height ?? NSScreen.main?.frame.height ?? 0
                        }
                        .onChange(of: proxy.frame(in: .global).maxY) { _, value in buttonMaxY = value }
                }
            )
            .overlay(alignment: opensUpward ? .bottomTrailing : .topTrailing) {
                if isExpanded {
                    dropdownPanel
                        .offset(y: opensUpward ? -30 : 30)
                }
            }
            .onExitCommand { isExpanded = false }
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.46 : 1)
        .zIndex(isExpanded ? 10 : 0)
        .preference(key: StreamHUDExpandedPanelKey.self, value: isExpanded)
        .onChange(of: isDisabled) { _, disabled in
            if disabled { isExpanded = false }
        }
    }

    /// Panel height is `rows * 30 + 8`; open upward when that would not fit under the button.
    private var opensUpward: Bool {
        guard windowHeight > 0, buttonMaxY > 0 else { return false }
        let panelHeight = CGFloat(options.count) * 30 + 8
        return buttonMaxY + panelHeight + 40 > windowHeight
    }

    private var dropdownPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(options, id: \.value) { option in
                StreamHUDDropdownRow(
                    title: option.title,
                    isSelected: option.value == selection
                ) {
                    isExpanded = false
                    onSelect(option.value)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 208)
        // Two fills: the sidebar itself is slightly translucent over the video, and a single
        // near-black fill over it still let the picture read through the panel.
        .background(StreamHUDTheme.surfaceRaised)
        .background(StreamHUDTheme.panel)
        .overlay {
            Rectangle()
                .stroke(StreamHUDTheme.divider, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.55), radius: 14, x: 0, y: 8)
    }
}

private struct StreamHUDDropdownRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.streamFont(size: 12, weight: .bold))
                    .foregroundStyle(isSelected ? StreamHUDTheme.accent : (isHovering ? StreamHUDTheme.textPrimary : StreamHUDTheme.textSecondary))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(StreamHUDTheme.accent)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color.white.opacity(isHovering ? 0.08 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Wraps HUD metric cards onto extra rows instead of overflowing the dock.
/// An `HStack` cannot compress children past their intrinsic width, so a row
/// spilled over the dock's trailing edge once it held more cards than fit.
struct StreamHUDWrappingRow<Content: View>: View {
    private let columns: [GridItem]
    private let spacing: CGFloat
    private let content: Content

    /// - Parameter fixedItemWidth: pass the item's exact width for controls that
    ///   must not stretch (the 42-wide action buttons); leave nil so cards share
    ///   the row width equally.
    init(minimumItemWidth: CGFloat, fixedItemWidth: CGFloat? = nil, spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.columns = [GridItem(.adaptive(minimum: minimumItemWidth, maximum: fixedItemWidth ?? .infinity), spacing: spacing)]
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
            content
        }
    }
}
