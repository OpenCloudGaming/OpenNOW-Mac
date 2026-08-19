import SwiftUI

struct MacForceNowCompactButtonStyle: ButtonStyle {
    enum Role {
        case primary
        case destructive
    }

    var role: Role = .primary
    var uiScale: CGFloat = 1

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MacForceNowNVIDIAFont.font(size: 12 * uiScale, weight: .bold))
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
        case .primary: return MacForceNowDesign.accent
        case .destructive: return Color.red.opacity(0.85)
        }
    }

    private func background(isPressed: Bool) -> Color {
        switch role {
        case .primary: return isPressed ? MacForceNowDesign.accent.opacity(0.78) : MacForceNowDesign.accent
        case .destructive: return Color.black.opacity(isPressed ? 0.5 : 0.35)
        }
    }
}
