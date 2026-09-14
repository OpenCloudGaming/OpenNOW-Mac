import SwiftUI

extension Font {
    static func uiSans(size: CGFloat, weight: OPNUIFont.Weight = .regular) -> Font {
        OPNUIFont.font(size: size, weight: weight)
    }
}

struct LoginTextFieldStyle: TextFieldStyle {
    let isFocused: Bool
    var uiScale: CGFloat = 1

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.uiSans(size: 14 * uiScale, weight: .regular))
            .foregroundStyle(OPNDesign.Text.primary)
            .tint(OPNDesign.accent)
            .padding(.horizontal, 16 * uiScale)
            .padding(.vertical, 14 * uiScale)
            .background(OPNDesign.Fill.neutral(0.08))
            .overlay {
                Rectangle()
                    .stroke(isFocused ? OPNDesign.accent : OPNDesign.Stroke.regular, lineWidth: isFocused ? 2 : 1)
            }
    }
}

struct PrimaryLoginButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.uiSans(size: 14, weight: .bold))
            .foregroundStyle(OPNDesign.onAccent)
            .tracking(0.4)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(configuration.isPressed ? OPNDesign.accent.opacity(0.76) : OPNDesign.accent)
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

struct VendorGetInButtonStyle: ButtonStyle {
    enum Size {
        case regular
        case large

        var height: CGFloat { self == .regular ? 36 : 40 }
        var fontSize: CGFloat { self == .regular ? 14 : 15 }
    }

    var size: Size = .regular
    var uiScale: CGFloat = 1
    var minimumWidth: CGFloat?
    /// The sign-in wall stays dark in every appearance, so a button on it keeps the bright accent
    /// and the black label that reads on it.
    var isOnFixedDarkSurface = false

    private var fill: Color { isOnFixedDarkSurface ? OPNDesign.Fixed.accent : OPNDesign.accent }

    private var label: Color { isOnFixedDarkSurface ? .black : OPNDesign.onAccent }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.uiSans(size: size.fontSize * uiScale, weight: .bold))
            .foregroundStyle(label)
            .tracking(0.3)
            .padding(.horizontal, OPNDesign.Spacing.medium(scale: uiScale))
            .frame(minWidth: minimumWidth.map { $0 * uiScale })
            .frame(height: size.height * uiScale)
            .background(configuration.isPressed ? fill.opacity(0.78) : fill)
            .opacity(configuration.isPressed ? 0.92 : 1)
    }
}

struct SecondaryLoginButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.uiSans(size: compact ? 13 : 14, weight: .bold))
            .foregroundStyle(OPNDesign.Text.primary)
            .tracking(0.3)
            .padding(.horizontal, compact ? 14 : 16)
            .padding(.vertical, compact ? 8 : 12)
            .background(configuration.isPressed ? OPNDesign.Stroke.regular : OPNDesign.Stroke.subtle)
            .overlay {
                Rectangle()
                    .stroke(OPNDesign.Stroke.regular, lineWidth: 1)
            }
    }
}
