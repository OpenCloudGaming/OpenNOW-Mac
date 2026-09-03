//  Shared chrome for the two Steam Controller sheets (tester, mapping editor). Both used to
//  hand-roll rounded buttons, rounded panels, native pickers and their own opacity ramp; these
//  pieces put them on the documented modal spec — 2px accent top bar, App Bar header, 1px
//  Stroke Subtle rules, square everything — and make them honour interface scale.
//

import AppKit
import SwiftUI

/// Sheet sizing. The content scales with the interface scale, so the window has to grow with it —
/// but a scaled minimum alone pins the sheet larger than the display at 150 % and above, and a
/// window forced under its own `minWidth` clips at the right edge instead of resizing. Clamp to
/// what the screen can actually show.
enum SteamControllerSheetMetrics {
    static func size(width: CGFloat, height: CGFloat, uiScale: CGFloat) -> CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let margin: CGFloat = 80
        return CGSize(
            width: min(width * uiScale, max(width * 0.6, visible.width - margin)),
            height: min(height * uiScale, max(height * 0.6, visible.height - margin))
        )
    }
}

/// 2px accent bar along the top edge of a modal surface.
struct SteamControllerModalTopBar: View {
    var body: some View {
        Rectangle()
            .fill(OpenNOWDesign.accent)
            .frame(height: 2)
            .frame(maxWidth: .infinity)
    }
}

/// 1px Stroke Subtle rule. Never scaled: a hairline stays a hairline at every interface scale.
struct SteamControllerModalRule: View {
    var body: some View {
        Rectangle()
            .fill(OpenNOWDesign.Stroke.subtle)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

/// App Bar header block: accent eyebrow over a 20pt title, with the standard square close control.
struct SteamControllerModalHeader: View {
    let eyebrow: String
    let title: String
    let uiScale: CGFloat
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
            VStack(alignment: .leading, spacing: 6 * uiScale) {
                Text(eyebrow)
                    .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(OpenNOWDesign.accent)
                Text(title)
                    .font(.settingsNvidia(size: 20 * uiScale, weight: .bold))
                    .foregroundStyle(OpenNOWDesign.Text.primary)
            }
            Spacer(minLength: OpenNOWDesign.Spacing.xSmall(scale: uiScale))
            OpenNOWModalCloseButton(uiScale: uiScale, action: onClose)
        }
        .padding(.horizontal, OpenNOWDesign.Spacing.card(scale: uiScale))
        .padding(.vertical, OpenNOWDesign.Spacing.medium(scale: uiScale))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenNOWDesign.Surface.appBar)
    }
}

/// Eyebrow section label: 10pt bold, tracking 1.1, Text Tertiary.
struct SteamControllerEyebrow: View {
    let text: String
    let uiScale: CGFloat

    var body: some View {
        Text(text)
            .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(OpenNOWDesign.Text.tertiary)
    }
}

/// Square selectable chip — the one control shape the two sheets need for chords, option pickers,
/// mouse buttons and the selected-control badge. Row Fill resting, 0.14 on hover, accent selected.
struct SteamControllerChip: View {
    let label: String
    let isSelected: Bool
    var systemImage: String?
    var height: CGFloat = 28
    var fontSize: CGFloat = 11
    var fillsWidth = true
    var alignment: Alignment = .center
    let uiScale: CGFloat
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6 * uiScale) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.settingsNvidia(size: (fontSize - 1) * uiScale, weight: .bold))
                }
                Text(label)
                    .font(.settingsNvidia(size: fontSize * uiScale, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, OpenNOWDesign.Spacing.controlRow(scale: uiScale))
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: alignment)
            .frame(height: height * uiScale)
            .background(background)
            .overlay { Rectangle().stroke(stroke, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.opnPressable)
        .onHover { isHovering = $0 }
        .opnMotion(OpenNOWDesign.Motion.hover, value: isHovering)
        .opacity(isEnabled ? 1 : 0.46)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var foreground: Color {
        if isSelected { return .black }
        return isHovering ? OpenNOWDesign.Text.primary : OpenNOWDesign.Text.secondary
    }

    private var background: Color {
        if isSelected { return OpenNOWDesign.accent }
        return Color.white.opacity(isHovering ? 0.14 : 0.075)
    }

    private var stroke: Color {
        isSelected ? OpenNOWDesign.accent : OpenNOWDesign.Stroke.subtle
    }
}

/// Square replacement for `.pickerStyle(.segmented)` / `.pickerStyle(.menu)`, which both render
/// rounded system chrome. Same chip row Settings pages already use for their option rows.
struct SteamControllerOptionPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    let selection: Value
    var height: CGFloat = 28
    var fontSize: CGFloat = 11
    let uiScale: CGFloat
    let onSelect: (Value) -> Void

    var body: some View {
        SettingsFlowLayout(spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                SteamControllerChip(
                    label: option.label,
                    isSelected: option.value == selection,
                    height: height,
                    fontSize: fontSize,
                    fillsWidth: false,
                    uiScale: uiScale
                ) {
                    onSelect(option.value)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Square axis/level bar. Signed bars grow from a centre tick, unsigned ones from the leading edge.
struct SteamControllerValueBar: View {
    let value: Float
    var signed = true
    let uiScale: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let clamped = CGFloat(max(-1, min(1, value)))
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.075))
                if signed {
                    Rectangle()
                        .fill(OpenNOWDesign.Stroke.regular)
                        .frame(width: 1)
                        .offset(x: width / 2)
                    Rectangle()
                        .fill(OpenNOWDesign.accent)
                        .frame(width: width * abs(clamped) / 2)
                        .offset(x: clamped >= 0 ? width / 2 : width / 2 - width * abs(clamped) / 2)
                } else {
                    Rectangle()
                        .fill(OpenNOWDesign.accent)
                        .frame(width: width * max(0, clamped))
                }
            }
        }
        .frame(height: 8 * uiScale)
    }
}

/// Square status indicator. The circular status dot is a stream-surface exception; app-shell
/// surfaces use the square.
struct SteamControllerStatusMarker: View {
    let color: Color
    let uiScale: CGFloat

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 8 * uiScale, height: 8 * uiScale)
    }
}

/// Square badge — Section Fill, 1px Stroke Subtle, for the battery readout and similar chips.
struct SteamControllerBadge<Content: View>: View {
    let uiScale: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, OpenNOWDesign.Spacing.xSmall(scale: uiScale))
            .frame(height: 20 * uiScale)
            .background(Color.white.opacity(0.055))
            .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
    }
}

/// Section container: Section Fill, 1px Stroke Subtle, square, eyebrow header.
struct SteamControllerSection<Content: View>: View {
    let title: String
    let uiScale: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.contentVertical(scale: uiScale)) {
            SteamControllerEyebrow(text: title, uiScale: uiScale)
            content
        }
        .padding(OpenNOWDesign.Spacing.card(scale: uiScale))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.055))
        .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
    }
}
