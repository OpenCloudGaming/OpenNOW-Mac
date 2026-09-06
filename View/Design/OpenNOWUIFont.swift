import AppKit
@preconcurrency import CoreText
import SwiftUI

public enum OpenNOWUIFont {
    public enum Weight: Hashable, Sendable {
        case regular
        case medium
        case semibold
        case bold
        case black
    }

    private nonisolated(unsafe) static let descriptors: [Weight: CTFontDescriptor] = {
        var result: [Weight: CTFontDescriptor] = [:]
        result[.regular] = loadDescriptor(named: "HankenGrotesk-Regular")
        result[.medium] = loadDescriptor(named: "HankenGrotesk-Medium")
        result[.bold] = loadDescriptor(named: "HankenGrotesk-Bold")
        result[.semibold] = loadDescriptor(named: "HankenGrotesk-Medium")
        result[.black] = loadDescriptor(named: "HankenGrotesk-Bold")
        return result
    }()

    public static func font(size: CGFloat, weight: Weight = .regular) -> Font {
        Font(nsFont(size: size, weight: weight))
    }

    public static func prepare() {
        _ = descriptors
    }

    public static func nsFont(size: CGFloat, weight: Weight = .regular) -> NSFont {
        if let descriptor = descriptor(weight: weight) {
            return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
        }
        return NSFont.systemFont(ofSize: size, weight: fallbackWeight(weight))
    }

    private static func fallbackWeight(_ weight: Weight) -> NSFont.Weight {
        switch weight {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .black: return .black
        }
    }

    private static func descriptor(weight: Weight) -> CTFontDescriptor? {
        descriptors[weight]
    }

    private static func loadDescriptor(named name: String) -> CTFontDescriptor? {
        for subdirectory in ["Fonts", "Resources/Fonts", nil] as [String?] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "woff2", subdirectory: subdirectory),
                  let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let descriptor = descriptors.first else { continue }
            return descriptor
        }
        return nil
    }
}

public extension Font {
    static func openNOWUI(size: CGFloat, weight: OpenNOWUIFont.Weight = .regular) -> Font {
        OpenNOWUIFont.font(size: size, weight: weight)
    }
}
