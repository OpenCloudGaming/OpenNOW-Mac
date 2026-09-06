import AppKit
import CryptoKit
import SwiftUI

struct SettingsCard<Content: View>: View {
    let title: String
    let uiScale: CGFloat
    private let content: Content

    init(title: String, uiScale: CGFloat, @ViewBuilder content: () -> Content) {
        self.title = title
        self.uiScale = uiScale
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10 * uiScale) {
                Rectangle()
                    .fill(OpenNOWDesign.accent)
                    .frame(width: 4 * uiScale, height: 18 * uiScale)
                Text(title.uppercased())
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                    .foregroundStyle(.white.opacity(0.68))
                    .tracking(1.1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18 * uiScale)
            .padding(.top, 17 * uiScale)
            .padding(.bottom, 12 * uiScale)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 20 * uiScale)
            .padding(.bottom, 20 * uiScale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topLeading) {
                SettingsVendorLayout.card
                LinearGradient(colors: [Color.white.opacity(0.035), .clear], startPoint: .top, endPoint: .center)
                Rectangle()
                    .fill(OpenNOWDesign.accent.opacity(0.10))
                    .frame(width: 1)
            }
        )
        .overlay { Rectangle().stroke(Color.white.opacity(0.115), lineWidth: 1) }
        .shadow(color: .black.opacity(0.26), radius: 16 * uiScale, y: 8 * uiScale)
    }
}

/// A card for a setting most hosts never touch: collapsed by default, so its status is visible without
/// its full field set reading as something everyone has to configure. Callers should seed `isExpanded`
/// from whether the setting is already configured, so a host who set it up in a previous session still
/// sees it open.
struct SettingsCollapsibleCard<Content: View>: View {
    let title: String
    let statusSummary: String
    let isConfigured: Bool
    let uiScale: CGFloat
    @Binding var isExpanded: Bool
    private let content: Content

    init(title: String, statusSummary: String, isConfigured: Bool, uiScale: CGFloat, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.statusSummary = statusSummary
        self.isConfigured = isConfigured
        self.uiScale = uiScale
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 10 * uiScale) {
                    Rectangle()
                        .fill(OpenNOWDesign.accent)
                        .frame(width: 4 * uiScale, height: 18 * uiScale)
                    Text(title.uppercased())
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.68))
                        .tracking(1.1)
                    Spacer(minLength: 0)
                    Text(statusSummary)
                        .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                        .foregroundStyle(isConfigured ? OpenNOWDesign.accent : .white.opacity(0.4))
                        .fixedSize()
                    Text(isExpanded ? "\u{25BE}" : "\u{25B8}")
                        .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 18 * uiScale)
                .padding(.top, 17 * uiScale)
                .padding(.bottom, isExpanded ? 12 * uiScale : 17 * uiScale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.horizontal, 20 * uiScale)
                .padding(.bottom, 20 * uiScale)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topLeading) {
                SettingsVendorLayout.card
                LinearGradient(colors: [Color.white.opacity(0.035), .clear], startPoint: .top, endPoint: .center)
                Rectangle()
                    .fill(OpenNOWDesign.accent.opacity(0.10))
                    .frame(width: 1)
            }
        )
        .overlay { Rectangle().stroke(Color.white.opacity(0.115), lineWidth: 1) }
        .shadow(color: .black.opacity(0.26), radius: 16 * uiScale, y: 8 * uiScale)
    }
}

struct SettingsDivider: View {
    let uiScale: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.vertical, 14 * uiScale)
    }
}

struct SettingsInfoRow: View {
    let label: String
    let value: String
    let uiScale: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16 * uiScale) {
            Text(label.uppercased())
                .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.44))
                .frame(width: 150 * uiScale, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .font(.settingsNvidia(size: 13 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

struct SettingsOptionRow: View {
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

    var body: some View {
        HStack(alignment: .top, spacing: 18 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                SettingsRowTitle(title: title, isLocked: isLocked, isNew: isNew, uiScale: uiScale)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(isLocked ? 0.38 : 0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250 * uiScale, alignment: .leading)
            SettingsFlowLayout(spacing: 8 * uiScale) {
                ForEach(options.indices, id: \.self) { index in
                    let optionEnabled = !isLocked && (enabled.indices.contains(index) ? enabled[index] : true)
                    Button { action(index) } label: {
                        Text(options[index])
                            .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                            .foregroundStyle(index == selectedIndex && !isLocked ? .black : .white.opacity(optionEnabled ? 0.82 : 0.34))
                            .padding(.horizontal, 12 * uiScale)
                            .frame(height: 32 * uiScale)
                            .background(index == selectedIndex ? OpenNOWDesign.accent.opacity(isLocked ? 0.32 : 1) : Color.white.opacity(optionEnabled ? 0.07 : 0.035))
                            .overlay { Rectangle().stroke(index == selectedIndex ? OpenNOWDesign.accent.opacity(isLocked ? 0.42 : 1) : Color.white.opacity(0.12), lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .disabled(!optionEnabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controllerFocusable(
            focusIdentity,
            activate: { guard !isLocked else { return }; cycleOption(1) },
            adjust: { delta in guard !isLocked else { return }; cycleOption(delta) }
        )
    }

    /// Walks to the next selectable option, skipping any the page has disabled.
    private func cycleOption(_ delta: Int) {
        guard !options.isEmpty else { return }
        var index = selectedIndex
        for _ in 0..<options.count {
            index = (index + delta + options.count) % options.count
            let optionEnabled = enabled.indices.contains(index) ? enabled[index] : true
            if optionEnabled {
                action(index)
                return
            }
        }
    }
}

/// Square-track switch matching the app's sharp-cornered design language, in place of the
/// native pill-shaped `Toggle(.switch)` (which no macOS API lets us square off).
struct Toggle: View {
    @Binding var isOn: Bool
    var isLocked = false
    let uiScale: CGFloat
    @State private var isHovering = false

    private var trackWidth: CGFloat { 34 * uiScale }
    private var trackHeight: CGFloat { 18 * uiScale }
    private var knobInset: CGFloat { 2 * uiScale }
    private var knobSize: CGFloat { trackHeight - knobInset * 2 }

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Rectangle()
                    .fill(isOn ? OpenNOWDesign.accent.opacity(isLocked ? 0.32 : 1) : Color.white.opacity(isHovering ? 0.12 : 0.09))
                    .overlay { Rectangle().stroke(isOn ? OpenNOWDesign.accent.opacity(isLocked ? 0.42 : 1) : Color.white.opacity(0.16), lineWidth: 1) }
                Rectangle()
                    .fill(isOn ? Color.black.opacity(isLocked ? 0.5 : 0.85) : Color.white.opacity(isLocked ? 0.35 : 0.72))
                    .frame(width: knobSize, height: knobSize)
                    .padding(knobInset)
            }
            .frame(width: trackWidth, height: trackHeight)
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .opacity(isLocked ? 0.45 : 1)
        .onHover { isHovering = $0 }
        .opnMotion(OpenNOWDesign.Motion.toggle, value: isOn)
        .opnMotion(OpenNOWDesign.Motion.hover, value: isHovering)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct SettingsToggleRow: View {
    @State private var focusIdentity = ControllerFocusIdentity()
    let title: String
    let subtitle: String
    let isOn: Bool
    var isLocked = false
    var isNew = false
    let uiScale: CGFloat
    let action: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                SettingsRowTitle(title: title, isLocked: isLocked, isNew: isNew, uiScale: uiScale)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(isLocked ? 0.38 : 0.58))
            }
            Spacer()
            Toggle(isOn: Binding(get: { isOn }, set: { action($0) }), isLocked: isLocked, uiScale: uiScale)
        }
        .controllerFocusable(
            focusIdentity,
            activate: { guard !isLocked else { return }; action(!isOn) },
            adjust: { delta in
                guard !isLocked else { return }
                let next = delta > 0
                guard next != isOn else { return }
                action(next)
            }
        )
    }
}

struct SettingsTextFieldRow: View {
    let title: String
    let subtitle: String
    let text: String
    let placeholder: String
    let uiScale: CGFloat
    let action: (String) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .center, spacing: 18 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text(title)
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250 * uiScale, alignment: .leading)
            TextField(placeholder, text: Binding(get: { draft }, set: { updateDraft($0) }))
                .textFieldStyle(.plain)
                .font(.settingsNvidia(size: 13 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12 * uiScale)
                .frame(height: 36 * uiScale)
                .background(Color.white.opacity(0.07))
                .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
                .onAppear { draft = text }
                .onChange(of: text) { _, value in
                    guard value != draft else { return }
                    draft = value
                }
        }
    }

    private func updateDraft(_ value: String) {
        draft = value
        action(value)
    }
}

struct SettingsSecureTextFieldRow: View {
    let title: String
    let subtitle: String
    @Binding var text: String
    let placeholder: String
    let uiScale: CGFloat
    let action: (String) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .center, spacing: 18 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text(title)
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250 * uiScale, alignment: .leading)
            SecureField(placeholder, text: Binding(get: { draft }, set: { updateDraft($0) }))
                .textFieldStyle(.plain)
                .font(.settingsNvidia(size: 13 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12 * uiScale)
                .frame(height: 36 * uiScale)
                .background(Color.white.opacity(0.07))
                .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
                .onAppear { draft = text }
                .onChange(of: text) { _, value in
                    guard value != draft else { return }
                    draft = value
                }
        }
    }

    private func updateDraft(_ value: String) {
        draft = value
        action(value)
    }
}

struct SettingsSliderRow: View {
    @State private var focusIdentity = ControllerFocusIdentity()
    let title: String
    let valueText: String
    let value: Double
    let range: ClosedRange<Double>
    var step = 1.0
    var isLocked = false
    var isNew = false
    let uiScale: CGFloat
    let action: @MainActor @Sendable (Double) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                SettingsRowTitle(title: title, isLocked: isLocked, isNew: isNew, uiScale: uiScale)
                Text(valueText)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                    .foregroundStyle(OpenNOWDesign.accent.opacity(isLocked ? 0.48 : 1))
            }
            .frame(width: 250 * uiScale, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { action($0) }), in: range, step: step)
                .tint(OpenNOWDesign.accent)
                .disabled(isLocked)
                .opacity(isLocked ? 0.45 : 1)
        }
        .controllerFocusable(
            focusIdentity,
            adjust: { delta in
                guard !isLocked else { return }
                // A zero or absent step would make a pad nudge do nothing, so fall back to a
                // hundredth of the range.
                let increment = step > 0 ? step : (range.upperBound - range.lowerBound) / 100
                let next = min(max(value + Double(delta) * increment, range.lowerBound), range.upperBound)
                guard next != value else { return }
                action(next)
            }
        )
    }
}

struct SettingsColorRow: View {
    let title: String
    let subtitle: String
    let hex: String
    let uiScale: CGFloat
    let action: (String) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text(title)
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250 * uiScale, alignment: .leading)
            ColorPicker("", selection: Binding(get: { Color(settingsHex: hex) }, set: { action($0.settingsHexString) }), supportsOpacity: false)
                .labelsHidden()
            Text(hex)
                .font(.system(size: 11 * uiScale, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
            Spacer(minLength: 0)
        }
    }
}

struct SettingsActionButton: View {
    @State private var focusIdentity = ControllerFocusIdentity()
    enum Tone {
        case primary
        case secondary
    }

    let title: String
    var tone: Tone = .primary
    var minimumWidth: CGFloat = 0
    let uiScale: CGFloat
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(foregroundColor)
                .tracking(0.8)
                .padding(.horizontal, 14 * uiScale)
                .frame(minWidth: minimumWidth)
                .frame(height: 32 * uiScale)
                .background(backgroundColor)
                .overlay { Rectangle().stroke(strokeColor, lineWidth: 1) }
        }
        .buttonStyle(.opnPressable)
        .onHover { isHovering = $0 }
        .opnMotion(OpenNOWDesign.Motion.hover, value: isHovering)
        .controllerFocusable(focusIdentity, activate: { guard isEnabled else { return }; action() })
    }

    private var backgroundColor: Color {
        guard isEnabled else { return Color.white.opacity(0.045) }
        switch tone {
        case .primary: return OpenNOWDesign.accent.opacity(isHovering ? 0.88 : 1)
        case .secondary: return OpenNOWDesign.accent.opacity(isHovering ? 0.22 : 0.14)
        }
    }

    private var foregroundColor: Color {
        guard isEnabled else { return .white.opacity(0.32) }
        switch tone {
        case .primary: return .black
        case .secondary: return OpenNOWDesign.accent
        }
    }

    private var strokeColor: Color {
        guard isEnabled else { return Color.white.opacity(0.08) }
        return tone == .primary ? OpenNOWDesign.accent : OpenNOWDesign.accent.opacity(0.34)
    }
}

struct SettingsStatusPill: View {
    let title: String
    let value: String
    let positive: Bool
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 3 * uiScale) {
            Text(title.uppercased())
                .font(.settingsNvidia(size: 9 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
                .tracking(0.8)
            Text(value.isEmpty ? "-" : value)
                .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(positive ? OpenNOWDesign.accent : .white.opacity(0.66))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 10 * uiScale)
        .frame(minWidth: 94 * uiScale, alignment: .trailing)
        .frame(height: 40 * uiScale)
        .background(Color.white.opacity(positive ? 0.055 : 0.035))
        .overlay { Rectangle().stroke(positive ? OpenNOWDesign.accent.opacity(0.24) : Color.white.opacity(0.08), lineWidth: 1) }
    }
}

struct SettingsMessageView: View {
    let message: String
    let systemImage: String
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 10 * uiScale) {
            Image(systemName: systemImage)
                .foregroundStyle(OpenNOWDesign.accent)
            Text(message)
                .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.78))
            Spacer()
        }
        .padding(12 * uiScale)
        .background(Color.white.opacity(0.07))
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }
}

struct SettingsFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Must never return a non-finite size (see FlowLayout in CatalogView.swift):
        // an .infinity proposal would otherwise propagate NaN into the layout graph
        // and livelock the main thread.
        let proposedWidth = proposal.width
        let width: CGFloat = (proposedWidth?.isFinite == true && proposedWidth! > 0) ? proposedWidth! : 320
        var size = CGSize(width: width, height: 0)
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if lineWidth + subviewSize.width > width, lineWidth > 0 {
                size.height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += subviewSize.width + spacing
            lineHeight = max(lineHeight, subviewSize.height)
        }
        size.height += lineHeight
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if x + subviewSize.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(subviewSize))
            x += subviewSize.width + spacing
            lineHeight = max(lineHeight, subviewSize.height)
        }
    }
}

/// A small "BETA" tag, for surfaces that are shipped but still settling.
///
/// One component rather than three inline `Text`s: it appears on the Settings tab, in the stream
/// HUD and on the Home entry point, and three copies would drift in colour and casing the way the
/// relay rows already did.
/// A row title with its optional NEW tag riding alongside, so every row kind renders the tag the
/// same way.
struct SettingsRowTitle: View {
    let title: String
    let isLocked: Bool
    let isNew: Bool
    let uiScale: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8 * uiScale) {
            Text(title)
                .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(isLocked ? 0.58 : 1))
            if isNew { OpenNOWNewTag(uiScale: uiScale) }
        }
    }
}

/// Marks a setting added in the current release. Solid accent so it reads at a glance next to
/// the quieter tinted BETA tag; it disappears once the setting is used or the next release ships.
struct OpenNOWNewTag: View {
    let uiScale: CGFloat

    var body: some View {
        Text("NEW")
            .font(.settingsNvidia(size: 8 * uiScale, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(.black)
            .padding(.horizontal, 4 * uiScale)
            .padding(.vertical, 2 * uiScale)
            .background(OpenNOWDesign.accent)
            .accessibilityLabel("New setting")
    }
}

struct OpenNOWBetaTag: View {
    let uiScale: CGFloat
    /// The HUD and the top bar sit on a dark stream surface where the accent reads as interactive;
    /// Settings wants the quieter treatment.
    var prominent = false
    /// Rides along inside another control - a tab, a row title - where the tag is an annotation on
    /// something else and must not outweigh it.
    var compact = false

    var body: some View {
        Text("BETA")
            .font(.settingsNvidia(size: (compact ? 8 : 9) * uiScale, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(foreground)
            .padding(.horizontal, (compact ? 4 : 5) * uiScale)
            .padding(.vertical, 2 * uiScale)
            .background(background)
            .accessibilityLabel("Beta")
    }

    private var foreground: Color {
        if prominent { return .black }
        return compact ? OpenNOWDesign.accent.opacity(0.72) : OpenNOWDesign.accent
    }

    private var background: Color {
        if prominent { return OpenNOWDesign.accent }
        return OpenNOWDesign.accent.opacity(compact ? 0.12 : 0.16)
    }
}
