import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One captured frame on disk. Mirrors `StreamRecording`: a PNG beside a JSON sidecar, so the
/// library is a directory scan rather than a database, and the picture is readable outside OpenNOW.
public struct StreamScreenshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public let applicationID: String
    public let createdAt: Date
    public let width: Int
    public let height: Int
    public let fileName: String
    public let fileSizeBytes: Int64
    /// Albums this shot belongs to. Empty means unfiled; an album the reader deleted is pruned when
    /// the screenshot is next saved rather than rewritten eagerly.
    public var albumIDs: [UUID]
    public let storageDirectoryPath: String?

    /// A copy of this shot pointing at where it was actually found, used when a stored path has gone
    /// stale and the sidecar's own directory is the truth.
    func replacingStorageDirectoryPath(_ path: String) -> StreamScreenshot {
        StreamScreenshot(
            id: id,
            title: title,
            applicationID: applicationID,
            createdAt: createdAt,
            width: width,
            height: height,
            fileName: fileName,
            fileSizeBytes: fileSizeBytes,
            albumIDs: albumIDs,
            storageDirectoryPath: path
        )
    }

    public var imageURL: URL { storageDirectory.appendingPathComponent(fileName) }
    public var metadataURL: URL { storageDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("json") }

    private var storageDirectory: URL {
        guard let storageDirectoryPath, !storageDirectoryPath.isEmpty else {
            return StreamScreenshotLibrary.screenshotsDirectory
        }
        return URL(fileURLWithPath: storageDirectoryPath, isDirectory: true)
    }
}

/// A local album. Nothing about it lives on NVIDIA's service: it is a name and a set of screenshot
/// ids kept in a single JSON file beside the images.
public struct ScreenshotAlbum: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
}

public enum StreamScreenshotLibraryError: LocalizedError {
    case encodingFailed
    case metadataWriteFailed(String)
    case imageReadFailed
    case invalidCrop

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: return "OpenNOW could not encode the screenshot."
        case .metadataWriteFailed(let message): return message
        case .imageReadFailed: return "OpenNOW could not read this screenshot. The image may be missing or damaged."
        case .invalidCrop: return "Select an area inside the screenshot before cropping."
        }
    }
}

public enum StreamScreenshotLibrary {
    /// Posted after any screenshot or album file is written or removed, and by iCloud sync once it
    /// copies files into the library directory. The page reads the directory once, so without this
    /// an iCloud download or an out-of-band capture leaves it showing what it scanned at launch.
    public static let didChangeNotification = Notification.Name("OPNStreamScreenshotLibraryDidChange")

    /// Where the reader's screenshots live. A thin forwarder: `OPNCaptureLocations` owns the default,
    /// the reader's override, and its validation, so every consumer here follows a folder change
    /// without knowing about it.
    public static var screenshotsDirectory: URL {
        OPNCaptureLocations.screenshotsDirectory
    }

    static let albumsFileName = "albums.json"

    @discardableResult
    public static func ensureDirectory() throws -> URL {
        try ensureWritableDirectory(at: screenshotsDirectory)
        return screenshotsDirectory
    }

    public static func loadScreenshots() -> [StreamScreenshot] {
        screenshotMetadataURLs()
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard let decoded = try? JSONDecoder.recordingDecoder.decode(StreamScreenshot.self, from: data) else { return nil }
                // A stored path that no longer exists — the folder moved, in Finder or by us — falls
                // back to the sidecar's own directory. Out-of-root items keep their path.
                let screenshot = decoded.replacingStorageDirectoryPath(healedStoragePath(
                    stored: decoded.storageDirectoryPath,
                    sidecarDirectory: url.deletingLastPathComponent()
                ))
                guard FileManager.default.fileExists(atPath: screenshot.imageURL.path) else { return nil }
                return screenshot
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The rule behind folder moves being non-destructive: honour a stored path while it exists,
    /// otherwise resolve beside the sidecar that named the item.
    static func healedStoragePath(stored: String?,
                                  sidecarDirectory: URL,
                                  fileManager: FileManager = .default) -> String {
        guard let stored, !stored.isEmpty, fileManager.fileExists(atPath: stored) else {
            return sidecarDirectory.path
        }
        return stored
    }

    public static func loadAlbums() -> [ScreenshotAlbum] {
        let url = screenshotsDirectory.appendingPathComponent(albumsFileName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let albums = (try? JSONDecoder.recordingDecoder.decode([ScreenshotAlbum].self, from: data)) ?? []
        return albums.sorted { $0.createdAt < $1.createdAt }
    }

    public static func saveAlbums(_ albums: [ScreenshotAlbum]) throws {
        try ensureWritableDirectory(at: screenshotsDirectory)
        let url = screenshotsDirectory.appendingPathComponent(albumsFileName)
        let data = try JSONEncoder.recordingEncoder.encode(albums)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw StreamScreenshotLibraryError.metadataWriteFailed(error.localizedDescription)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    @discardableResult
    public static func save(
        _ image: StreamScreenshotImage,
        title: String,
        applicationID: String,
        albumIDs: [UUID] = [],
        directory: URL = screenshotsDirectory
    ) throws -> StreamScreenshot {
        try Task.checkCancellation()
        try ensureWritableDirectory(at: directory)
        let id = UUID()
        let fileName = id.uuidString + ".png"
        let imageURL = directory.appendingPathComponent(fileName)
        var isComplete = false
        defer {
            if !isComplete { try? FileManager.default.removeItem(at: imageURL) }
        }
        guard let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw StreamScreenshotLibraryError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image.cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw StreamScreenshotLibraryError.encodingFailed
        }
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: imageURL.path)
        let fileSizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let screenshot = StreamScreenshot(
            id: id,
            title: title.isEmpty ? "GeForce NOW Screenshot" : title,
            applicationID: applicationID,
            createdAt: Date(),
            width: image.width,
            height: image.height,
            fileName: fileName,
            fileSizeBytes: fileSizeBytes,
            albumIDs: albumIDs,
            storageDirectoryPath: directory.path
        )
        try writeMetadata(screenshot)
        isComplete = true
        return screenshot
    }

    public static func update(_ screenshot: StreamScreenshot) throws {
        try writeMetadata(screenshot)
    }

    public static func delete(_ screenshot: StreamScreenshot) throws {
        if FileManager.default.fileExists(atPath: screenshot.imageURL.path) {
            try FileManager.default.removeItem(at: screenshot.imageURL)
        }
        if FileManager.default.fileExists(atPath: screenshot.metadataURL.path) {
            try FileManager.default.removeItem(at: screenshot.metadataURL)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private static func writeMetadata(_ screenshot: StreamScreenshot) throws {
        let data = try JSONEncoder.recordingEncoder.encode(screenshot)
        do {
            try data.write(to: screenshot.metadataURL, options: .atomic)
        } catch {
            throw StreamScreenshotLibraryError.metadataWriteFailed(error.localizedDescription)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private static func screenshotMetadataURLs() -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: screenshotsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents.filter { url in
            guard url.pathExtension.caseInsensitiveCompare("json") == .orderedSame else { return false }
            guard url.lastPathComponent.caseInsensitiveCompare(albumsFileName) != .orderedSame else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile != false
        }
    }

    private static func ensureWritableDirectory(at directory: URL) throws {
        try OPNCaptureLocations.ensureWritableDirectory(at: directory)
    }
}
