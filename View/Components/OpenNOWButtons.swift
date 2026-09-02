import SwiftUI

/// `.plain` with a press response. Plain buttons draw no chrome *and* give no feedback, so every
/// tile, menu row and icon in the app used to swallow the click silently until the action's own
/// side effect showed up. Drops the transform under Reduce Motion and keeps the dim.
struct OpenNOWPressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97
    var pressedOpacity: Double = 0.92
    var anchor: UnitPoint = .center

    func makeBody(configuration: Configuration) -> some View {
        // `@Environment` read from a nested View: a ButtonStyle is not part of the view graph, so
        // an environment property on the style itself never updates.
        PressableBody(configuration: configuration, pressedScale: pressedScale, pressedOpacity: pressedOpacity, anchor: anchor)
    }

    private struct PressableBody: View {
        let configuration: Configuration
        let pressedScale: CGFloat
        let pressedOpacity: Double
        let anchor: UnitPoint

        var body: some View {
            configuration.label
                .opnHoverScale(configuration.isPressed, factor: pressedScale, anchor: anchor)
                .opacity(configuration.isPressed ? pressedOpacity : 1)
                .opnMotion(OpenNOWDesign.Motion.press, value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == OpenNOWPressableButtonStyle {
    static var opnPressable: OpenNOWPressableButtonStyle { .init() }

    static func opnPressable(scale: CGFloat, opacity: Double = 0.92, anchor: UnitPoint = .center) -> OpenNOWPressableButtonStyle {
        .init(pressedScale: scale, pressedOpacity: opacity, anchor: anchor)
    }
}

/// Secondary action inside a modal footer, sized to sit beside `VendorGetInButtonStyle(.regular)`.
/// `SecondaryLoginButtonStyle` is the same design but predates interface scale and hardcodes its
/// metrics, so it cannot be used on scaled chrome.
struct OpenNOWModalSecondaryButtonStyle: ButtonStyle {
    var uiScale: CGFloat = 1

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OpenNOWNVIDIAFont.font(size: 13 * uiScale, weight: .bold))
            .foregroundStyle(OpenNOWDesign.Text.primary)
            .tracking(0.3)
            .padding(.horizontal, OpenNOWDesign.Spacing.medium(scale: uiScale))
            .frame(height: 36 * uiScale)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08))
            .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
    }
}

struct OpenNOWCompactButtonStyle: ButtonStyle {
    enum Role {
        case primary
        case destructive
    }

    var role: Role = .primary
    var uiScale: CGFloat = 1

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OpenNOWNVIDIAFont.font(size: 12 * uiScale, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14 * uiScale)
            .frame(height: 28 * uiScale)
            .background(background(isPressed: configuration.isPressed))
            .overlay { Rectangle().stroke(stroke, lineWidth: 1) }
    }

    private var foreground: Color {
        switch role {
        case .primary: return .black
        case .destructive: return .white
        }
    }

    private var stroke: Color {
        switch role {
        case .primary: return OpenNOWDesign.accent
        case .destructive: return Color.red.opacity(0.85)
        }
    }

    private func background(isPressed: Bool) -> Color {
        switch role {
        case .primary: return isPressed ? OpenNOWDesign.accent.opacity(0.78) : OpenNOWDesign.accent
        case .destructive: return Color.black.opacity(isPressed ? 0.5 : 0.35)
        }
    }
}
