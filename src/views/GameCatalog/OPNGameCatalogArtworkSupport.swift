import AppKit
import Foundation
import QuartzCore

@objc(OPNGameCatalogArtworkSupport)
@objcMembers
final class OPNGameCatalogArtworkSupport: NSObject {
    private static let iconQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.opennow.store-icon-loader"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    private nonisolated(unsafe) static let iconCache = NSMutableDictionary()
    private nonisolated(unsafe) static let placeholderCache = NSMutableDictionary()
    private nonisolated(unsafe) static let logoCropCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func displayLabel(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.isEmpty { return "" }
        let normalized = trimmed.replacingOccurrences(of: "-", with: "_")
        let specialLabels = [
            "FREE_TO_PLAY": "Free to Play",
            "MASSIVELY_MULTIPLAYER_ONLINE": "MMO",
            "MASSIVELY_MULTIPLAYER": "MMO",
            "KEYBOARD_MOUSE": "Keyboard + Mouse",
            "GAMEPAD_PARTIAL": "Partial Gamepad",
        ]
        if let special = specialLabels[normalized], !special.isEmpty { return special }

        let spaced = trimmed.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let acronyms: Set<String> = ["ai", "dlc", "fps", "hdr", "mmo", "moba", "pve", "pvp", "rpg", "rtx", "vr"]
        let labels = spaced.components(separatedBy: .whitespacesAndNewlines).compactMap { token -> String? in
            if token.isEmpty { return nil }
            if acronyms.contains(token) { return token.uppercased() }
            return token.prefix(1).uppercased() + token.dropFirst()
        }
        return labels.isEmpty ? trimmed : labels.joined(separator: " ")
    }

    static func iconAssetName(_ name: String?) -> String {
        let upper = (name ?? "").uppercased()
        if upper.contains("STEAM") { return "steam" }
        if upper.contains("EPIC") || upper.contains("EGS") { return "epic" }
        if upper.contains("UBISOFT") || upper.contains("UPLAY") { return "ubisoft" }
        if upper.contains("BATTLE") { return "battlenet" }
        if upper.contains("XBOX") || upper.contains("MICROSOFT") { return "xbox" }
        if upper.contains("EA") || upper.contains("ORIGIN") { return "ea" }
        if upper.contains("GOG") { return "gog" }
        return "default"
    }

    static func cachedStoreIconImage(_ name: String?) -> NSImage? {
        iconCache[iconAssetName(name)] as? NSImage
    }

    static func greyscaleIconImage(_ image: NSImage?) -> NSImage? {
        let templateImage = image?.copy() as? NSImage
        templateImage?.isTemplate = true
        return templateImage
    }

    static func iconPlaceholderImage(_ name: String?) -> NSImage {
        let assetName = iconAssetName(name)
        if let cached = placeholderCache[assetName] as? NSImage { return cached }
        let labels = ["steam": "ST", "epic": "EP", "ubisoft": "UB", "battlenet": "BN", "xbox": "XB", "ea": "EA", "gog": "GOG", "default": "CL"]
        let fills: [String: NSColor] = [
            "steam": NSColor(red: 0x1B / 255, green: 0x28 / 255, blue: 0x38 / 255, alpha: 1),
            "epic": NSColor(red: 0x20 / 255, green: 0x20 / 255, blue: 0x20 / 255, alpha: 1),
            "ubisoft": NSColor(red: 0x3D / 255, green: 0x61 / 255, blue: 1, alpha: 1),
            "battlenet": NSColor(red: 0x14 / 255, green: 0x9B / 255, blue: 1, alpha: 1),
            "xbox": NSColor(red: 0x10 / 255, green: 0x7C / 255, blue: 0x10 / 255, alpha: 1),
            "ea": NSColor(red: 1, green: 0x47 / 255, blue: 0x47 / 255, alpha: 1),
            "gog": NSColor(red: 0x6D / 255, green: 0x3D / 255, blue: 0xF5 / 255, alpha: 1),
            "default": NSColor(red: 0x76 / 255, green: 0xB9 / 255, blue: 0x00 / 255, alpha: 1),
        ]
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        let bounds = NSRect(origin: .zero, size: size)
        (fills[assetName] ?? fills["default"] ?? .systemGreen).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        let label = labels[assetName] ?? labels["default"] ?? "CL"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: label.count > 2 ? 18 : 23, weight: .black),
            .foregroundColor: NSColor.white,
        ]
        let labelSize = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: floor((size.width - labelSize.width) * 0.5), y: floor((size.height - labelSize.height) * 0.5) - 1), withAttributes: attributes)
        image.unlockFocus()
        placeholderCache[assetName] = image
        return image
    }

    static func loadStoreIconImage(_ name: String?, completion: (@Sendable (NSImage?) -> Void)?) {
        let assetName = iconAssetName(name)
        if let cached = cachedStoreIconImage(name) {
            DispatchQueue.main.async { completion?(cached) }
            return
        }
        let paths = iconCandidatePaths(assetName)
        iconQueue.addOperation {
            loadIconData(from: paths, index: 0) { data in
                let image = data.flatMap(NSImage.init(data:))
                if let image {
                    image.isTemplate = false
                    DispatchQueue.main.async {
                        iconCache[assetName] = image
                        completion?(image)
                    }
                    return
                }
                if assetName != "default" {
                    loadIconData(from: iconCandidatePaths("default"), index: 0) { defaultData in
                        let defaultImage = defaultData.flatMap(NSImage.init(data:))
                        defaultImage?.isTemplate = false
                        DispatchQueue.main.async {
                            if let defaultImage { iconCache[assetName] = defaultImage }
                            completion?(defaultImage)
                        }
                    }
                    return
                }
                DispatchQueue.main.async { completion?(nil) }
            }
        }
    }

    static func fallbackArtworkImage() -> NSImage {
        OPNUIHelpers.fallbackHeroArtworkImage()
    }

    static func visibleLogoImage(_ image: NSImage?) -> NSImage? {
        guard let image, image.size.width > 0, image.size.height > 0 else { return image }
        let cacheKey = NSString(string: "\(Unmanaged.passUnretained(image).toOpaque()):\(Int(image.size.width))x\(Int(image.size.height))")
        if let cached = logoCropCache.object(forKey: cacheKey) { return cached }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else { return image }
        let width = source.width
        let height = source.height
        if width <= 0 || height <= 0 { return image }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return image }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                if pixels[offset + 3] <= 10 { continue }
                minX = Swift.min(minX, x)
                minY = Swift.min(minY, y)
                maxX = Swift.max(maxX, x)
                maxY = Swift.max(maxY, y)
            }
        }
        if maxX < minX || maxY < minY { return image }
        let padding = Swift.max(8, Int(ceil(Double(Swift.max(maxX - minX + 1, maxY - minY + 1)) * 0.04)))
        minX = Swift.max(0, minX - padding)
        minY = Swift.max(0, minY - padding)
        maxX = Swift.min(width - 1, maxX + padding)
        maxY = Swift.min(height - 1, maxY + padding)
        let cropWidth = maxX - minX + 1
        let cropHeight = maxY - minY + 1
        if cropWidth <= 0 || cropHeight <= 0 { return image }
        if Double(cropWidth) >= Double(width) * 0.92 && Double(cropHeight) >= Double(height) * 0.92 { return image }
        guard let cropped = source.cropping(to: CGRect(x: minX, y: minY, width: cropWidth, height: cropHeight)) else { return image }
        let result = NSImage(cgImage: cropped, size: NSSize(width: cropWidth, height: cropHeight))
        logoCropCache.setObject(result, forKey: cacheKey, cost: Swift.max(1, cropWidth * cropHeight * 4))
        return result
    }

    static func heroVisibleArtworkRect(for image: NSImage?, bounds: NSRect) -> NSRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return bounds }
        return bounds
    }

    static func heroLogoFrame(for image: NSImage?, bounds: NSRect, artworkImage: NSImage?) -> NSRect {
        let artworkRect = heroVisibleArtworkRect(for: artworkImage, bounds: bounds)
        let horizontalInset = min(OPNGameCatalogLayoutSupport.heroContentInset(forWidth: bounds.width), max(24, artworkRect.width * 0.08))
        let maxWidth = min(OPNGameCatalogLayoutSupport.storeHeroLogoMaxWidth, max(120, artworkRect.width - horizontalInset * 2))
        let maxHeight = min(OPNGameCatalogLayoutSupport.storeHeroLogoMaxHeight, artworkRect.height * 0.44)
        var width = maxWidth
        var height = maxHeight
        if let image, image.size.width > 0, image.size.height > 0 {
            let aspect = image.size.width / image.size.height
            if maxWidth / max(1, maxHeight) > aspect {
                height = maxHeight
                width = floor(height * aspect)
            } else {
                width = maxWidth
                height = floor(width / aspect)
            }
        }
        return NSRect(x: artworkRect.minX + horizontalInset, y: artworkRect.minY + floor((artworkRect.height - height) * 0.5), width: width, height: height)
    }

    static func heroLogoFallbackFrame(_ bounds: NSRect, artworkImage: NSImage?) -> NSRect {
        let artworkRect = heroVisibleArtworkRect(for: artworkImage, bounds: bounds)
        let horizontalInset = min(OPNGameCatalogLayoutSupport.heroContentInset(forWidth: bounds.width), max(24, artworkRect.width * 0.08))
        let width = min(OPNGameCatalogLayoutSupport.storeHeroLogoMaxWidth, max(160, artworkRect.width - horizontalInset * 2))
        let height = min(108, max(56, artworkRect.height * 0.22))
        return NSRect(x: artworkRect.minX + horizontalInset, y: artworkRect.minY + floor((artworkRect.height - height) * 0.5), width: width, height: height)
    }

    static func bringHeroLogoToFront(container: NSView?, titleFallback: NSTextField?, logoView: NSImageView?) {
        MainActor.assumeIsolated {
            guard let container else { return }
            if titleFallback?.superview === container, let titleFallback { container.addSubview(titleFallback, positioned: .above, relativeTo: nil) }
            if logoView?.superview === container, let logoView { container.addSubview(logoView, positioned: .above, relativeTo: nil) }
        }
    }

    static func configureHeroLogoImageView(_ logoView: NSImageView?, zPosition: CGFloat) {
        MainActor.assumeIsolated {
            guard let logoView else { return }
            logoView.imageScaling = .scaleProportionallyDown
            logoView.imageAlignment = .alignLeft
            logoView.wantsLayer = true
            logoView.layer?.zPosition = zPosition
            logoView.layer?.shadowColor = NSColor.black.withAlphaComponent(0.9).cgColor
            logoView.layer?.shadowOpacity = 1
            logoView.layer?.shadowRadius = 18
            logoView.layer?.shadowOffset = CGSize(width: 0, height: -2)
        }
    }

    static func heroImageHasVisibleContent(_ image: NSImage?) -> Bool {
        guard let image, image.size.width >= 900, image.size.height >= 300, image.size.width / max(1, image.size.height) >= 1.65 else { return false }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else { return true }
        let sampleWidth = 24
        let sampleHeight = 24
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: sampleWidth, height: sampleHeight, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return true }
        context.draw(source, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        var visiblePixels = 0
        var opaquePixels = 0
        for offset in stride(from: 0, to: pixels.count - 3, by: bytesPerPixel) {
            let alpha = pixels[offset + 3]
            if alpha > 24 { visiblePixels += 1 }
            if alpha > 180 { opaquePixels += 1 }
        }
        let totalPixels = sampleWidth * sampleHeight
        return visiblePixels >= totalPixels / 3 && opaquePixels >= totalPixels / 5
    }

    private static func iconCandidatePaths(_ assetName: String) -> [String] {
        let safeAssetName = assetName.isEmpty ? "default" : assetName
        var paths: [String] = []
        if let bundlePath = Bundle.main.path(forResource: safeAssetName, ofType: "svg", inDirectory: "store-icons"), !bundlePath.isEmpty { paths.append(bundlePath) }
        let relativePath = "assets/store-icons/\(safeAssetName).svg"
        paths.append(FileManager.default.currentDirectoryPath.appending("/").appending(relativePath))
        paths.append("/Volumes/Projects/OpenNOW-Mac/" + relativePath)
        return paths
    }

    private static func loadIconData(from paths: [String], index: Int, completion: @escaping @Sendable (Data?) -> Void) {
        if index >= paths.count {
            completion(nil)
            return
        }
        let path = paths[index]
        DispatchQueue.global(qos: .utility).async {
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            if let data, !data.isEmpty {
                completion(data)
                return
            }
            loadIconData(from: paths, index: index + 1, completion: completion)
        }
    }
}
