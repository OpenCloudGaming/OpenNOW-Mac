import SwiftUI

struct StreamHUDMetricCard: View {
    let title: String
    let value: String
    let positive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(positive ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning).frame(width: 6, height: 6)
                Text(title.uppercased())
                    .font(.streamFont(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.46))
            }
            Text(value)
                .font(.streamFont(size: 12, weight: .bold))
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
                    .font(.streamFont(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                Text(name)
                    .font(.streamFont(size: 11, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            batteryGauge
            Text(level >= 0 ? "\(level)%" : "—")
                .font(.streamFont(size: 11, weight: .bold))
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
                    .font(.streamFont(size: 11, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                Spacer(minLength: 8)
                Text(String(value))
                    .font(.streamFont(size: 11, weight: .bold))
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
                .font(.streamFont(size: 11, weight: .medium))
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
                .font(.streamFont(size: 11, weight: .bold))
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
                .font(.streamFont(size: 10, weight: .bold))
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
