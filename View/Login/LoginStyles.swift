//
//  LoginStyles.swift
//  MacForceNow
//
//  Created by Jayian on 6/14/26.
//

import SwiftUI

extension Font {
    static func nvidiaSans(size: CGFloat, weight: MacForceNowNVIDIAFont.Weight = .regular) -> Font {
        MacForceNowNVIDIAFont.font(size: size, weight: weight)
    }
}

struct LoginTextFieldStyle: TextFieldStyle {
    let isFocused: Bool
    var uiScale: CGFloat = 1

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.nvidiaSans(size: 14 * uiScale, weight: .regular))
            .foregroundStyle(.white)
            .tint(MacForceNowDesign.accent)
            .padding(.horizontal, 16 * uiScale)
            .padding(.vertical, 14 * uiScale)
            .background(Color.white.opacity(0.08))
            .overlay {
                Rectangle()
                    .stroke(isFocused ? MacForceNowDesign.accent : MacForceNowDesign.Stroke.regular, lineWidth: isFocused ? 2 : 1)
            }
    }
}

struct PrimaryLoginButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.nvidiaSans(size: 14, weight: .bold))
            .foregroundStyle(.black)
            .tracking(0.4)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(configuration.isPressed ? MacForceNowDesign.accent.opacity(0.76) : MacForceNowDesign.accent)
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.nvidiaSans(size: size.fontSize * uiScale, weight: .bold))
            .foregroundStyle(.black)
            .tracking(0.3)
            .padding(.horizontal, MacForceNowDesign.Spacing.medium(scale: uiScale))
            .frame(minWidth: minimumWidth.map { $0 * uiScale })
            .frame(height: size.height * uiScale)
            .background(configuration.isPressed ? MacForceNowDesign.accent.opacity(0.78) : MacForceNowDesign.accent)
            .opacity(configuration.isPressed ? 0.92 : 1)
    }
}

struct SecondaryLoginButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.nvidiaSans(size: compact ? 13 : 14, weight: .bold))
            .foregroundStyle(.white)
            .tracking(0.3)
            .padding(.horizontal, compact ? 14 : 16)
            .padding(.vertical, compact ? 8 : 12)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08))
            .overlay {
                Rectangle()
                    .stroke(MacForceNowDesign.Stroke.regular, lineWidth: 1)
            }
    }
}
