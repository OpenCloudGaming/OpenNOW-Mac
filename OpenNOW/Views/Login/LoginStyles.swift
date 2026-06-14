//
//  LoginStyles.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import SwiftUI

struct LoginTextFieldStyle: TextFieldStyle {
    let isFocused: Bool

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.white)
            .tint(Color.openNowGreen)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.08))
            .overlay {
                Rectangle()
                    .stroke(isFocused ? Color.openNowGreen : Color.gfnStroke, lineWidth: isFocused ? 2 : 1)
            }
    }
}

struct PrimaryLoginButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.black)
            .tracking(0.4)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(configuration.isPressed ? Color.openNowGreen.opacity(0.76) : Color.openNowGreen)
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

struct SecondaryLoginButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 13 : 14, weight: .bold))
            .foregroundStyle(.white)
            .tracking(0.3)
            .padding(.horizontal, compact ? 14 : 16)
            .padding(.vertical, compact ? 8 : 12)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08))
            .overlay {
                Rectangle()
                    .stroke(Color.gfnStroke, lineWidth: 1)
            }
    }
}

extension Color {
    static let openNowGreen = Color(red: 0.46, green: 0.90, blue: 0.10)
    static let gfnAuthPanel = Color(red: 0.110, green: 0.110, blue: 0.110)
    static let gfnPanel = Color(red: 0.224, green: 0.224, blue: 0.224)
    static let gfnCharcoal = Color(red: 0.098, green: 0.098, blue: 0.098)
    static let gfnStroke = Color.white.opacity(0.14)
    static let gfnTextSecondary = Color.white.opacity(0.72)
    static let gfnTextTertiary = Color.white.opacity(0.48)
}
