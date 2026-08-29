//
//  CatalogHeroImageViews.swift
//  OpenNOW
//

import AppKit
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

struct CatalogHeroRemoteImage: View {
    let imageCache: any CatalogImageServing = CatalogImageCache.shared
    let url: URL?
    let contentMode: ContentMode
    let onScrimColorChange: (CatalogMarqueeScrimColor) -> Void

    @State private var image: NSImage?
    @State private var isLoading = false
    @State private var hasFailed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if hasFailed {
                CatalogImageFallback()
            } else {
                CatalogImageFallback()
            }
        }
        .task(id: url) { await loadImage() }
    }

    @MainActor
    private func loadImage() async {
        image = nil
        hasFailed = false
        guard let url else {
            onScrimColorChange(.black)
            return
        }

        onScrimColorChange(.black)
        isLoading = true
        // The scrim colour is read from the image's EXIF user comment, so this is the one call site
        // that needs the compressed bytes kept alongside the decoded image.
        if let cached = await imageCache.image(for: url, retainingSourceData: true) {
            guard !Task.isCancelled else { return }
            image = cached.image
            hasFailed = false
            isLoading = false
            var scrimColor = CatalogMarqueeScrimColor.black
            if let sourceData = cached.sourceData {
                scrimColor = await CatalogHeroImageMetadata.scrimColor(from: sourceData) ?? .black
            }
            guard !Task.isCancelled else { return }
            onScrimColorChange(scrimColor)
        } else {
            guard !Task.isCancelled else { return }
            image = nil
            hasFailed = true
            isLoading = false
            onScrimColorChange(.black)
        }
    }
}

struct CatalogHeroVendorBackgroundScrim: View {
    let color: CatalogMarqueeScrimColor

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: color.color.opacity(0.00), location: 0.0000),
                .init(color: color.color.opacity(0.02), location: 0.0342),
                .init(color: color.color.opacity(0.05), location: 0.0668),
                .init(color: color.color.opacity(0.12), location: 0.0955),
                .init(color: color.color.opacity(0.20), location: 0.1230),
                .init(color: color.color.opacity(0.29), location: 0.1500),
                .init(color: color.color.opacity(0.39), location: 0.1752),
                .init(color: color.color.opacity(0.50), location: 0.2000),
                .init(color: color.color.opacity(0.61), location: 0.2248),
                .init(color: color.color.opacity(0.71), location: 0.2500),
                .init(color: color.color.opacity(0.80), location: 0.2770),
                .init(color: color.color.opacity(0.88), location: 0.3045),
                .init(color: color.color.opacity(0.95), location: 0.3332),
                .init(color: color.color.opacity(0.98), location: 0.3658),
                .init(color: color.color.opacity(1.00), location: 0.4000)
            ],
            startPoint: .bottom,
            endPoint: .top
        )
    }
}

struct CatalogHeroVendorImageMask: View {
    var body: some View {
        VendorResourceImage(name: "Marquee_Hero_Image_Gradient", fileExtension: "svg")
            .scaledToFill()
    }
}

struct CatalogHeroVendorGradientOverlays: View {
    let imageLeading: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [CatalogVendorLayout.mallSurface.opacity(0.00), CatalogVendorLayout.mallSurface.opacity(0.25)],
                    startPoint: .trailing,
                    endPoint: .leading
                )
                .frame(width: imageLeading)
                .frame(maxWidth: .infinity, alignment: .leading)

                LinearGradient(
                    colors: [CatalogVendorLayout.mallSurface.opacity(0.00), CatalogVendorLayout.mallSurface],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: proxy.size.height * 0.33)
                .offset(y: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

struct CatalogMarqueeScrimColor: Equatable, Sendable {
    static let black = CatalogMarqueeScrimColor(red: 0, green: 0, blue: 0)

    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red / 255, green: green / 255, blue: blue / 255)
    }

    var preferredTextColor: Color {
        red * 0.299 + green * 0.587 + blue * 0.114 > 150 ? .black : .white
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String) {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = value.hasPrefix("#") ? String(value.dropFirst()) : value
        let expanded: String
        if sanitized.count == 3 {
            expanded = sanitized.map { String(repeating: String($0), count: 2) }.joined()
        } else {
            expanded = sanitized
        }
        guard expanded.count == 6, let number = Int(expanded, radix: 16) else { return nil }
        red = Double((number >> 16) & 0xFF)
        green = Double((number >> 8) & 0xFF)
        blue = Double(number & 0xFF)
    }
}

enum CatalogHeroImageMetadata {
    private struct Metadata: Decodable {
        let colors: Colors?
    }

    private struct Colors: Decodable {
        let left: String?
        let right: String?
        let bottom: String?
    }

    static func scrimColor(from data: Data) async -> CatalogMarqueeScrimColor? {
        await Task.detached(priority: .userInitiated) {
            scrimColorSynchronously(from: data)
        }.value
    }

    private static func scrimColorSynchronously(from data: Data) -> CatalogMarqueeScrimColor? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if let metadataColor = metadataScrimColor(from: source) {
            return metadataColor
        }
        return sampledLeftEdgeColor(from: source)
    }

    private static func metadataScrimColor(from source: CGImageSource) -> CatalogMarqueeScrimColor? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let userComment = findUserComment(in: properties),
              let jsonStart = userComment.firstIndex(of: "{") else { return nil }
        let json = String(userComment[jsonStart...])
        guard let data = json.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              let hexColor = metadata.colors?.left ?? metadata.colors?.right ?? metadata.colors?.bottom else { return nil }
        return CatalogMarqueeScrimColor(hex: hexColor)
    }

    private static func findUserComment(in value: Any) -> String? {
        if let string = value as? String, string.contains("colors") {
            return string
        }
        if let data = value as? Data, let string = String(data: data, encoding: .utf8), string.contains("colors") {
            return string
        }
        if let dictionary = value as? [String: Any] {
            if let directValue = dictionary[kCGImagePropertyExifUserComment as String] {
                return findUserComment(in: directValue)
            }
            for nestedValue in dictionary.values {
                if let match = findUserComment(in: nestedValue) {
                    return match
                }
            }
        }
        if let array = value as? [Any] {
            let scalarValues = array.compactMap { $0 as? UInt8 }
            if scalarValues.count == array.count,
               let string = String(bytes: scalarValues, encoding: .utf8),
               string.contains("colors") {
                return string
            }
            for nestedValue in array {
                if let match = findUserComment(in: nestedValue) {
                    return match
                }
            }
        }
        return nil
    }

    private static func sampledLeftEdgeColor(from source: CGImageSource) -> CatalogMarqueeScrimColor? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 48
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let drewImage = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewImage else { return nil }

        let sampleWidth = min(max(width / 8, 1), width)
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var count = 0.0
        for y in 0..<height {
            for x in 0..<sampleWidth {
                let index = (y * width + x) * 4
                red += Double(pixels[index])
                green += Double(pixels[index + 1])
                blue += Double(pixels[index + 2])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return CatalogMarqueeScrimColor(red: red / count, green: green / count, blue: blue / count)
    }
}
