import AppKit
import Combine
import GameController
import Foundation
import SwiftUI

enum WebRTCMediaStreamTheme {
    static let accent = Color(red: 0.46, green: 0.90, blue: 0.10)
    static let accentSoft = Color(red: 0.67, green: 1.0, blue: 0.36)
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

    static func dockWidth(for width: CGFloat) -> CGFloat {
        min(344, max(268, width * 0.72))
    }
}

extension Font {
    static func streamNvidia(size: CGFloat, weight: OpenNOWNVIDIAFont.Weight = .regular) -> Font {
        OpenNOWNVIDIAFont.font(size: size, weight: weight)
    }
}

struct StreamHUDActionRow: View {
    let title: String
    let subtitle: String
    let systemName: String
    let isActive: Bool
    let isDisabled: Bool
    var isFocused = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.streamNvidia(size: 15, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: 42, height: 38)
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
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .help(subtitle.isEmpty ? title : "\(title): \(subtitle)")
    }

    private var strokeColor: Color {
        if isFocused { return WebRTCMediaStreamTheme.accent }
        return isActive ? WebRTCMediaStreamTheme.accent.opacity(0.86) : WebRTCMediaStreamTheme.divider
    }

    private var rowBackground: Color {
        if isActive { return WebRTCMediaStreamTheme.accent }
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

struct StreamHUDFocusEntry {
    let id: String
    let isDisabled: Bool
    let action: () -> Void
    /// Entries that share a group and sit next to each other in the list form one grid of
    /// `columns` tiles per row — the HUD's 4-wide icon panels. An entry with no group is a
    /// full-width row of its own (a slider, a dropdown, a participant row).
    var group = ""
    var columns = 1

    init(id: String, isDisabled: Bool, group: String = "", columns: Int = 1, action: @escaping () -> Void) {
        self.id = id
        self.isDisabled = isDisabled
        self.group = group
        self.columns = max(1, columns)
        self.action = action
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
                .font(.streamNvidia(size: 12, weight: .bold))
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
        if isFocused { return WebRTCMediaStreamTheme.accent }
        return isPrimary ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.divider
    }

    private var backgroundColor: Color {
        if isPrimary { return WebRTCMediaStreamTheme.accent.opacity(isHovering ? 0.82 : 1) }
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
                .font(.streamNvidia(size: 11, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            Spacer(minLength: 8)
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Text(selectedTitle)
                        .font(.streamNvidia(size: 12, weight: .bold))
                        .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Color.white.opacity(isHovering ? 0.14 : 0.075))
                .overlay {
                    Rectangle()
                        .stroke((isExpanded || isFocused) ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.divider, lineWidth: isFocused ? 2 : 1)
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
        .background(WebRTCMediaStreamTheme.surfaceRaised)
        .background(WebRTCMediaStreamTheme.panel)
        .overlay {
            Rectangle()
                .stroke(WebRTCMediaStreamTheme.divider, lineWidth: 1)
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
                    .font(.streamNvidia(size: 12, weight: .bold))
                    .foregroundStyle(isSelected ? WebRTCMediaStreamTheme.accent : (isHovering ? WebRTCMediaStreamTheme.textPrimary : WebRTCMediaStreamTheme.textSecondary))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(WebRTCMediaStreamTheme.accent)
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

struct StreamUnifiedSidebar<Content: View>: View {
    let title: String
    let closeAction: () -> Void
    let content: Content

    init(title: String, closeAction: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.closeAction = closeAction
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.streamNvidia(size: 12, weight: .bold))
                        .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button(action: closeAction) {
                        Image(systemName: "xmark")
                            .font(.streamNvidia(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.82))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.08))
                            .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close stream HUD")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(WebRTCMediaStreamTheme.appBar)
                Rectangle().fill(WebRTCMediaStreamTheme.divider).frame(height: 1)
                ScrollView(.vertical, showsIndicators: false) {
                    content
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                }
                Rectangle().fill(WebRTCMediaStreamTheme.divider).frame(height: 1)
                Text(WebRTCMediaStreamCommand.shortcutGuide)
                    .font(.streamNvidia(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
            }
            .frame(width: WebRTCMediaStreamTheme.dockWidth(for: proxy.size.width), height: proxy.size.height, alignment: .topLeading)
            .background(WebRTCMediaStreamTheme.panel.opacity(0.985))
            .overlay(alignment: .trailing) { Rectangle().fill(WebRTCMediaStreamTheme.divider).frame(width: 1) }
            .overlay(alignment: .top) { Rectangle().fill(WebRTCMediaStreamTheme.accent).frame(height: 2) }
            .shadow(color: .black.opacity(0.58), radius: 28, x: 14, y: 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
    }
}

struct StreamHUDSection<Content: View>: View {
    let label: String
    let spacing: CGFloat
    /// Marks a section as still settling. Sits beside the label rather than in the content so it
    /// reads as a property of the feature, not of one control inside it.
    let showsBetaTag: Bool
    /// What the focused control in this section does, for a pad user reading icon-only tiles.
    /// Drawn in the accent colour under the content; nil hides the line.
    let caption: String?
    let content: Content

    @State private var hasExpandedPanel = false

    init(label: String, spacing: CGFloat = 10, showsBetaTag: Bool = false, caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.spacing = spacing
        self.showsBetaTag = showsBetaTag
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.streamNvidia(size: 10, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                if showsBetaTag { OpenNOWBetaTag(uiScale: 1, prominent: true) }
                Spacer(minLength: 0)
            }
            content
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.streamNvidia(size: 10, weight: .bold))
                    .foregroundStyle(WebRTCMediaStreamTheme.accentSoft)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityHidden(true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.055))
        .overlay { Rectangle().stroke(WebRTCMediaStreamTheme.divider, lineWidth: 1) }
        .onPreferenceChange(StreamHUDExpandedPanelKey.self) { hasExpandedPanel = $0 }
        // Above every sibling section while one of this section's dropdowns is open, so the panel
        // is not tinted by the next section's background painting over it.
        .zIndex(hasExpandedPanel ? 50 : 0)
    }
}

/// Wraps HUD cards and action buttons onto extra rows instead of overflowing
/// the dock. An `HStack` cannot compress children past their intrinsic width,
/// so rows spilled over the dock's trailing edge once the controller battery
/// cards joined the status row.
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

struct StreamHUDMetricCard: View {
    let title: String
    let value: String
    let positive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(positive ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning).frame(width: 6, height: 6)
                Text(title.uppercased())
                    .font(.streamNvidia(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.46))
            }
            Text(value)
                .font(.streamNvidia(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(Color.white.opacity(0.055))
        .overlay { Rectangle().stroke(WebRTCMediaStreamTheme.divider, lineWidth: 1) }
    }
}

/// One connected controller: which slot it is, what it is, and its battery as a gauge with the
/// number beside it. Replaces the per-device "battery square" cards, which read as anonymous
/// metrics and multiplied whenever a receiver lit up another slot. Square geometry and theme
/// tokens throughout, per DESIGN.md: the gauge is three `Rectangle`s, not a rounded battery glyph.
struct StreamHUDControllerRow: View {
    let label: String
    let name: String
    let level: Int
    let charging: Bool

    private var isLow: Bool { level >= 0 && level <= 20 }
    private var isCritical: Bool { level >= 0 && level <= 5 }
    /// Charging reads as a positive state (accent soft); low and critical use the same warning and
    /// danger tokens the rest of the HUD uses for those conditions.
    private var gaugeColor: Color {
        if charging { return WebRTCMediaStreamTheme.accentSoft }
        if isCritical { return WebRTCMediaStreamTheme.danger }
        if isLow { return WebRTCMediaStreamTheme.warning }
        return WebRTCMediaStreamTheme.accent
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(gaugeColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.streamNvidia(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                Text(name)
                    .font(.streamNvidia(size: 11, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            batteryGauge
            Text(level >= 0 ? "\(level)%" : "—")
                .font(.streamNvidia(size: 11, weight: .bold))
                .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.055))
        .overlay { Rectangle().stroke(WebRTCMediaStreamTheme.divider, lineWidth: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(name), battery \(level >= 0 ? "\(level) percent" : "unknown")\(charging ? ", charging" : "")")
    }

    /// Battery outline with proportional fill and a terminal nub, all square-cornered; the bolt sits
    /// over the fill while charging.
    private var batteryGauge: some View {
        let fill = level >= 0 ? CGFloat(min(max(level, 0), 100)) / 100 : 0
        return HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                Rectangle()
                    .stroke(WebRTCMediaStreamTheme.textTertiary, lineWidth: 1)
                    .frame(width: 26, height: 11)
                Rectangle()
                    .fill(gaugeColor)
                    .frame(width: max(0, 22 * fill), height: 7)
                    .padding(.leading, 2)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(WebRTCMediaStreamTheme.panel)
                        .frame(width: 26, height: 11)
                }
            }
            Rectangle()
                .fill(WebRTCMediaStreamTheme.textTertiary)
                .frame(width: 2, height: 5)
        }
    }
}

extension View {
    /// Focus indicator for HUD controls with no built-in `isFocused` styling of their own (a
    /// segmented `Picker`, a `Slider` row) — matches the accent-stroke language `StreamHUDActionRow`
    /// and `StreamHUDDropdown` already use for gamepad focus.
    func hudFocusRing(_ isFocused: Bool) -> some View {
        padding(4)
            .overlay {
                if isFocused {
                    Rectangle().stroke(WebRTCMediaStreamTheme.accent, lineWidth: 2)
                }
            }
    }
}

/// Shared label/value/slider row for HUD panels - used by both the WebRTC and native NVST stream
/// HUDs (Clarity, Noise Reduction, Fill Dim), which previously each re-typed this same layout.
struct StreamHUDSliderRow: View {
    let label: String
    let value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    let isDisabled: Bool
    var isFocused = false
    let action: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(label)
                    .font(.streamNvidia(size: 11, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                Spacer(minLength: 8)
                Text(String(value))
                    .font(.streamNvidia(size: 11, weight: .bold))
                    .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                    .frame(minWidth: 28, alignment: .trailing)
            }
            Slider(
                value: Binding(get: { Double(value) }, set: { action(Int($0.rounded())) }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
            .tint(WebRTCMediaStreamTheme.accent)
            .disabled(isDisabled)
        }
        .hudFocusRing(isFocused)
        .opacity(isDisabled ? 0.46 : 1)
    }
}

/// Squared segmented control for the stream HUD, replacing `.pickerStyle(.segmented)`.
///
/// The stock style draws AppKit's rounded capsule with its own tint handling, which is the one
/// piece of system chrome left in a HUD built entirely from square panels, 1px strokes and the
/// NVIDIA type ramp. This is the same chip row Settings uses for its option rows, sized for the
/// HUD: label on the left like `StreamHUDDropdown`, chips trailing, selected chip filled with the
/// accent and set in black so it reads at HUD contrast.
struct StreamHUDSegmentedRow<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String)]
    let selection: Value
    let isDisabled: Bool
    var isFocused = false
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.streamNvidia(size: 11, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                ForEach(options, id: \.value) { option in
                    StreamHUDSegmentedChip(
                        title: option.title,
                        isSelected: option.value == selection,
                        isDisabled: isDisabled
                    ) {
                        onSelect(option.value)
                    }
                }
            }
        }
        .hudFocusRing(isFocused)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.46 : 1)
    }
}

private struct StreamHUDSegmentedChip: View {
    let title: String
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.streamNvidia(size: 11, weight: .bold))
                .foregroundStyle(isSelected ? .black : WebRTCMediaStreamTheme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(chipBackground)
                .overlay {
                    Rectangle()
                        .stroke(isSelected ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.divider, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 && !isDisabled }
    }

    private var chipBackground: Color {
        if isSelected { return WebRTCMediaStreamTheme.accent }
        return Color.white.opacity(isHovering ? 0.14 : 0.075)
    }
}

/// The approve / remove control on a Remote Co-Op participant row.
///
/// Shared when both stream HUDs hosted Remote Co-Op; only the native HUD does now and the row has to look identical in each:
/// it was a private helper on the WebRTC HUD until the native NVST transport grew the same panel.
struct StreamHUDParticipantIconButton: View {
    let systemName: String
    let label: String
    let color: Color
    /// Drawn with the same ring the rest of the HUD uses, so a controller can find these rows.
    /// Approving a guest happens mid-game, when reaching for the trackpad is worst.
    var isFocused = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.streamNvidia(size: 10, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(isFocused ? 0.16 : 0.07))
                .overlay {
                    Rectangle().stroke(isFocused ? color : color.opacity(0.32), lineWidth: isFocused ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}
