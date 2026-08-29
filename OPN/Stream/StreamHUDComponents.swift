//
//  StreamHUDComponents.swift
//  OpenNOW
//

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

struct StreamHUDFocusEntry {
    let id: String
    let isDisabled: Bool
    let action: () -> Void

    /// Focus only ever lands on enabled rows, so both navigation and activation
    /// filter the disabled ones out — a row that goes disabled while focused
    /// must not fire when the pad's activate button is pressed.
    static func focusID(after current: String?, in entries: [StreamHUDFocusEntry], step: Int) -> String? {
        let enabled = entries.filter { !$0.isDisabled }
        guard !enabled.isEmpty else { return nil }
        guard let currentIndex = enabled.firstIndex(where: { $0.id == current }) else { return enabled.first?.id }
        return enabled[(currentIndex + step + enabled.count) % enabled.count].id
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
struct StreamHUDDropdown: View {
    let label: String
    let options: [(value: Int, title: String)]
    let selection: Int
    let isDisabled: Bool
    let onSelect: (Int) -> Void
    var isFocused = false
    @State private var isExpanded = false
    @State private var isHovering = false

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
            .overlay(alignment: .topTrailing) {
                if isExpanded {
                    dropdownPanel
                        .offset(y: 30)
                }
            }
            .onExitCommand { isExpanded = false }
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.46 : 1)
        .zIndex(isExpanded ? 10 : 0)
        .onChange(of: isDisabled) { _, disabled in
            if disabled { isExpanded = false }
        }
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
        .background(WebRTCMediaStreamTheme.surfaceRaised)
        .overlay {
            Rectangle()
                .stroke(WebRTCMediaStreamTheme.divider, lineWidth: 1)
        }
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

/// Per-device gamepad edge tracking for HUD navigation. A plain class on
/// purpose: mutating it from input callbacks must not invalidate the view.
@MainActor
final class StreamHUDGamepadTracker {
    enum NavigationStep {
        case move(Int)
        case activate
        case back
    }

    var lastButtons: [InputDeviceID: GamepadButtons] = [:]
    var lastStickStep: [InputDeviceID: Int] = [:]

    func reset() {
        lastButtons.removeAll()
        lastStickStep.removeAll()
    }

    func navigationStep(_ state: GamepadState) -> NavigationStep? {
        let previousButtons = lastButtons[state.deviceID] ?? state.buttons
        let pressed = state.buttons.subtracting(previousButtons)
        lastButtons[state.deviceID] = state.buttons

        let horizontal = abs(state.leftStickX) >= abs(state.leftStickY) ? state.leftStickX : 0
        let vertical = abs(state.leftStickY) > abs(state.leftStickX) ? state.leftStickY : 0
        let stickStep: Int = horizontal > 0.6 || vertical < -0.6 ? 1 : (horizontal < -0.6 || vertical > 0.6 ? -1 : 0)
        let previousStickStep = lastStickStep[state.deviceID] ?? 0
        lastStickStep[state.deviceID] = stickStep

        if pressed.contains(.south) { return .activate }
        if pressed.contains(.east) { return .back }
        if pressed.contains(.dpadRight) || pressed.contains(.dpadDown) { return .move(1) }
        if pressed.contains(.dpadLeft) || pressed.contains(.dpadUp) { return .move(-1) }
        if stickStep != 0, stickStep != previousStickStep { return .move(stickStep) }
        return nil
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
    let content: Content

    init(label: String, spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.label = label
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(label)
                .font(.streamNvidia(size: 10, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.055))
        .overlay { Rectangle().stroke(WebRTCMediaStreamTheme.divider, lineWidth: 1) }
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

struct StreamHUDBatteryCard: View {
    let label: String
    let level: Int
    let charging: Bool

    var body: some View {
        let displayValue = level >= 0 ? "\(level)%" : "—"
        let isLow = level >= 0 && level <= 20
        let iconName = charging ? "bolt.fill" : Self.batteryIconName(for: level)
        let iconColor = charging ? .yellow : (isLow ? WebRTCMediaStreamTheme.warning : WebRTCMediaStreamTheme.accent)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(iconColor)
                Text(label.uppercased())
                    .font(.streamNvidia(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.46))
            }
            Text(displayValue)
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

    private static func batteryIconName(for level: Int) -> String {
        switch level {
        case 90...: return "battery.100percent"
        case 60..<90: return "battery.75percent"
        case 30..<60: return "battery.50percent"
        case 15..<30: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

struct StreamSessionSidebarLimit: Equatable {
    let startedAt: Date
    let durationSeconds: Int

    init?(session: StreamSessionDescriptor, fallbackStartedAt: Date = Date()) {
        guard let duration = Int(session.metadata["sessionLimitSeconds"] ?? ""), duration > 0 else { return nil }
        let startedAtEpoch = Double(session.metadata["startedAtEpochSeconds"] ?? "")
        let startedAt = startedAtEpoch.map { Date(timeIntervalSince1970: $0) } ?? fallbackStartedAt
        self.startedAt = startedAt
        self.durationSeconds = duration
    }

    init?(update: StreamSessionLimitUpdate, receivedAt: Date = Date()) {
        let durationSeconds = max(3600, update.remainingSeconds)
        self.startedAt = receivedAt.addingTimeInterval(-Double(durationSeconds - update.remainingSeconds))
        self.durationSeconds = durationSeconds
    }

    func remainingSeconds(at now: Date) -> Int {
        max(0, durationSeconds - Int(now.timeIntervalSince(startedAt)))
    }
}

private struct WebRTCMediaSessionLimit: Equatable {
    let startedAt: Date
    let durationSeconds: Int

    init?(session: StreamSessionDescriptor, fallbackStartedAt: Date = Date()) {
        guard let duration = Int(session.metadata["sessionLimitSeconds"] ?? ""), duration > 0 else { return nil }
        let startedAtEpoch = Double(session.metadata["startedAtEpochSeconds"] ?? "")
        let startedAt = startedAtEpoch.map { Date(timeIntervalSince1970: $0) } ?? fallbackStartedAt
        self.startedAt = startedAt
        self.durationSeconds = duration
    }

    init?(update: StreamSessionLimitUpdate, receivedAt: Date = Date()) {
        let durationSeconds = max(3600, update.remainingSeconds)
        self.startedAt = receivedAt.addingTimeInterval(-Double(durationSeconds - update.remainingSeconds))
        self.durationSeconds = durationSeconds
    }

    func remainingSeconds(at now: Date) -> Int {
        max(0, durationSeconds - Int(now.timeIntervalSince(startedAt)))
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
