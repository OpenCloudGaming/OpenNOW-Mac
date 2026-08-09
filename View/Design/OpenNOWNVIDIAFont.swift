import AppKit
@preconcurrency import CoreText
import SwiftUI

public enum OpenNOWNVIDIAFont {
    public enum Weight: Hashable, Sendable {
        case regular
        case medium
        case bold
    }

    private nonisolated(unsafe) static let descriptors: [Weight: CTFontDescriptor] = {
        var result: [Weight: CTFontDescriptor] = [:]
        result[.regular] = loadDescriptor(named: "NVIDIASans_W_Rg")
        result[.medium] = loadDescriptor(named: "NVIDIASans_W_Md")
        result[.bold] = loadDescriptor(named: "NVIDIASans_W_Bd")
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
        case .bold: return .bold
        }
    }

    private static func descriptor(weight: Weight) -> CTFontDescriptor? {
        descriptors[weight]
    }

    private static func loadDescriptor(named name: String) -> CTFontDescriptor? {
        for subdirectory in ["NVIDIA", "Resources/NVIDIA", nil] as [String?] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "woff2", subdirectory: subdirectory),
                  let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let descriptor = descriptors.first else { continue }
            return descriptor
        }
        return nil
    }
}

public extension Font {
    static func openNOWNVIDIA(size: CGFloat, weight: OpenNOWNVIDIAFont.Weight = .regular) -> Font {
        OpenNOWNVIDIAFont.font(size: size, weight: weight)
    }
}
