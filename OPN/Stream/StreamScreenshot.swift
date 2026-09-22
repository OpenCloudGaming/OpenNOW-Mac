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

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: return "OpenNOW could not encode the screenshot."
        case .metadataWriteFailed(let message): return message
        }
    }
}

public enum StreamScreenshotLibrary {
    /// Posted after any screenshot or album file is written or removed, and by iCloud sync once it
    /// copies files into the library directory. The page reads the directory once, so without this
    /// an iCloud download or an out-of-band capture leaves it showing what it scanned at launch.
    public static let didChangeNotification = Notification.Name("OPNStreamScreenshotLibraryDidChange")

    /// Beside the recordings, under the vendor's own folder, so both live in one place a reader can
    /// find from Finder and OpenNOW owns the screen capture directory.
    public static var screenshotsDirectory: URL {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        return base.appendingPathComponent("NVIDIA", isDirectory: true).appendingPathComponent("GeForce NOW", isDirectory: true)
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
                guard let screenshot = try? JSONDecoder.recordingDecoder.decode(StreamScreenshot.self, from: data) else { return nil }
                guard FileManager.default.fileExists(atPath: screenshot.imageURL.path) else { return nil }
                return screenshot
            }
            .sorted { $0.createdAt > $1.createdAt }
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

    /// Writes the PNG and its sidecar. The image is encoded before the metadata, so a failure leaves
    /// at most an orphan picture the next scan filters out rather than metadata pointing at nothing.
    @discardableResult
    public static func save(_ image: StreamScreenshotImage, title: String, applicationID: String) throws -> StreamScreenshot {
        try ensureWritableDirectory(at: screenshotsDirectory)
        let id = UUID()
        let fileName = id.uuidString + ".png"
        let imageURL = screenshotsDirectory.appendingPathComponent(fileName)
        guard let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw StreamScreenshotLibraryError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image.cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: imageURL)
            throw StreamScreenshotLibraryError.encodingFailed
        }
        let fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: imageURL.path)[.size] as? Int64) ?? 0
        let screenshot = StreamScreenshot(
            id: id,
            title: title.isEmpty ? "GeForce NOW Screenshot" : title,
            applicationID: applicationID,
            createdAt: Date(),
            width: image.width,
            height: image.height,
            fileName: fileName,
            fileSizeBytes: fileSizeBytes,
            albumIDs: [],
            storageDirectoryPath: screenshotsDirectory.path
        )
        try writeMetadata(screenshot)
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = directory.appendingPathComponent(".opennow-write-test", isDirectory: false)
        try Data().write(to: probe, options: .atomic)
        try? FileManager.default.removeItem(at: probe)
    }
}
