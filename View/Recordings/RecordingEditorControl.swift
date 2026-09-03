//
//  RecordingEditorControl.swift
//  OpenNOW
//
//  The one button the editor is built from.
//
//  There were five: `zoomButton`, `transportButton`, `transportStepButton`, `quickButton` and
//  `RecordingEditorSmallButton`, each repeating the same chain - font, foreground, frame, fill,
//  inset border, disabled-while-exporting, help, accessibility - and each drifting from the others
//  a little. The differences that matter are a tone, a height and what is on the label.
//

import SwiftUI

struct RecordingEditorControl<Label: View>: View {
    enum Tone {
        /// The default: a faint fill inside a faint border.
        case standard
        /// Carries the accent. Play/pause, and the selected option in a row of them.
        case prominent
        /// No fill and no border, for controls that sit on top of the timeline.
        case borderless
    }

    var tone: Tone = .standard
    var height: CGFloat = RecordingEditorMetrics.controlHeight
    /// Set for the square icon buttons; otherwise the label plus padding decides.
    var width: CGFloat?
    var horizontalPadding: CGFloat = 10
    var fontSize: CGFloat = 11
    let help: String
    /// Defaults to `help`, which is the right label for an icon-only control. Text controls pass
    /// their own title and let `help` become the hint.
    var accessibilityTitle: String?
    var isDisabled = false
    var shortcut: KeyEquivalent?
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        Button(action: action) {
            label()
                .font(.recordingsNvidia(size: fontSize * uiScale, weight: .bold))
                .foregroundStyle(foreground)
                .padding(.horizontal, width == nil ? horizontalPadding * uiScale : 0)
                .frame(width: width.map { $0 * uiScale }, height: height * uiScale)
                .background(background)
                // `strokeBorder`, not `stroke`: a centred stroke spills half a point outside the
                // frame, and a tone that strokes in its own fill colour then measures taller than
                // its neighbours. See DESIGN.md, Borders on Filled Controls.
                .overlay { Rectangle().strokeBorder(border, lineWidth: tone == .borderless ? 0 : 1) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
        .accessibilityLabel(accessibilityTitle ?? help)
        .accessibilityHint(accessibilityTitle == nil ? "" : help)
        .accessibilityAddTraits(tone == .prominent ? .isSelected : [])
        .modifier(RecordingEditorShortcut(key: shortcut))
    }

    private var foreground: Color {
        switch tone {
        case .standard: return .white.opacity(0.88)
        case .prominent: return .black.opacity(0.86)
        case .borderless: return .white.opacity(isDisabled ? 0.24 : 0.66)
        }
    }

    private var background: Color {
        switch tone {
        case .standard: return .white.opacity(0.065)
        case .prominent: return OpenNOWDesign.accent
        case .borderless: return .clear
        }
    }

    private var border: Color {
        switch tone {
        case .standard: return .white.opacity(0.12)
        case .prominent: return OpenNOWDesign.accent
        case .borderless: return .clear
        }
    }
}

extension RecordingEditorControl where Label == Text {
    /// Text-only, the commonest shape.
    init(
        _ title: String,
        tone: Tone = .standard,
        height: CGFloat = RecordingEditorMetrics.controlHeight,
        horizontalPadding: CGFloat = 10,
        fontSize: CGFloat = 11,
        help: String,
        isDisabled: Bool = false,
        shortcut: KeyEquivalent? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            tone: tone, height: height, width: nil, horizontalPadding: horizontalPadding,
            fontSize: fontSize, help: help, accessibilityTitle: title, isDisabled: isDisabled,
            shortcut: shortcut, action: action, label: { Text(title) }
        )
    }
}

extension RecordingEditorControl where Label == Image {
    /// Icon-only. `help` is the accessible name, because the glyph is not one.
    init(
        systemImage: String,
        tone: Tone = .standard,
        height: CGFloat = RecordingEditorMetrics.controlHeight,
        width: CGFloat,
        fontSize: CGFloat = 12,
        help: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(
            tone: tone, height: height, width: width, horizontalPadding: 0,
            fontSize: fontSize, help: help, accessibilityTitle: nil, isDisabled: isDisabled,
            shortcut: nil, action: action, label: { Image(systemName: systemImage) }
        )
    }
}

/// `keyboardShortcut` has no "no shortcut" value, and applying it unconditionally would bind keys
/// the control does not want.
struct RecordingEditorShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}
