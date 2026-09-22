//  Local storage for a collection's reader-supplied image icon. A collection stores only the asset
//  id; the normalized PNG lives here, under Application Support, and is mirrored into the iCloud
//  container on its own so a small image never bloats catalog.json.

import AppKit

/// Reads and writes the custom image icons behind the collection icon picker. Every image is
/// normalized down to a bounded square-ish PNG, so one huge import cannot fill the disk, the iCloud
/// container or the picker's grid.
enum OPNCollectionIconStore {
    static let maximumPixelSize: CGFloat = 256
    static let maximumByteCount = 512 * 1024
    static let fileExtension = "png"

    /// Posted after an icon image is written or removed, and by iCloud sync once it copies icon files
    /// into the local directory. Every glyph reads the store directly, so without this an icon that
    /// arrives on its own — after the catalog that names it has already synced — never appears.
    static let didChangeNotification = Notification.Name("OPNCollectionIconStoreDidChange")
    /// The `userInfo` key naming the asset whose file changed, so an observer can ignore another
    /// collection's write. `removeOrphans` posts without one: it clears many assets at once.
    static let assetIdentifierKey = "assetIdentifier"

    /// The directory the local icons live in, beside the app's other Application Support data.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("OpenNOW", isDirectory: true).appendingPathComponent("CollectionIcons", isDirectory: true)
    }

    static func url(for assetIdentifier: String) -> URL {
        directory.appendingPathComponent(assetIdentifier, isDirectory: false).appendingPathExtension(fileExtension)
    }

    static func image(for assetIdentifier: String) -> NSImage? {
        NSImage(contentsOf: url(for: assetIdentifier))
    }

    /// Imports an image from anywhere on disk, normalized and written under `assetIdentifier`.
    @discardableResult
    static func storeImage(from source: URL, assetIdentifier: String) -> Bool {
        guard let image = NSImage(contentsOf: source) else { return false }
        return storeImage(image, assetIdentifier: assetIdentifier)
    }

    @discardableResult
    static func storeImage(_ image: NSImage, assetIdentifier: String) -> Bool {
        guard let data = normalizedPNGData(from: image), data.count <= maximumByteCount else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(for: assetIdentifier), options: .atomic)
            NotificationCenter.default.post(name: didChangeNotification, object: nil, userInfo: [assetIdentifierKey: assetIdentifier])
            return true
        } catch {
            return false
        }
    }

    static func remove(assetIdentifier: String) {
        guard FileManager.default.fileExists(atPath: url(for: assetIdentifier).path) else { return }
        try? FileManager.default.removeItem(at: url(for: assetIdentifier))
        NotificationCenter.default.post(name: didChangeNotification, object: nil, userInfo: [assetIdentifierKey: assetIdentifier])
    }

    /// Deletes every stored icon no live collection names, so a removed collection leaves no image
    /// behind. The iCloud copy is additive and is pruned by the next full backup once the local one
    /// is gone.
    static func removeOrphans(keeping assetIdentifiers: Set<String>) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        var removedAny = false
        for file in contents where !assetIdentifiers.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
            removedAny = true
        }
        guard removedAny else { return }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private static func normalizedPNGData(from image: NSImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maximumPixelSize / max(size.width, size.height))
        let pixelSize = NSSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        representation.size = pixelSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: pixelSize), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return representation.representation(using: .png, properties: [:])
    }
}
