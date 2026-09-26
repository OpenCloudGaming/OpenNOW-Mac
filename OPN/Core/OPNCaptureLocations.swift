import Foundation

/// The two media libraries OpenNOW owns, named so a caller can talk about "the screenshots folder"
/// without repeating which preference key or default that means.
public enum OPNCaptureLibrary: String, CaseIterable, Sendable {
    case screenshots
    case recordings

    /// The `UserDefaults` key the reader's own choice lives under. Deliberately outside every
    /// `OPNCloudSyncSettingsRegistry` allow-list prefix, and denied there by name anyway: a filesystem
    /// path is bound to this Mac, and syncing one to a Mac where it does not exist leaves a broken
    /// library rather than a convenience.
    public var preferenceKey: String {
        switch self {
        case .screenshots: return "OpenNOW.Capture.ScreenshotsDirectoryPath"
        case .recordings: return "OpenNOW.Capture.RecordingsDirectoryPath"
        }
    }

    /// What the settings page calls the library.
    public var displayName: String {
        switch self {
        case .screenshots: return "Screenshots"
        case .recordings: return "Recordings"
        }
    }

    /// The folder OpenNOW writes into when the reader has not chosen one. Screenshots live under
    /// Pictures and recordings under Movies because those are the media folders macOS relocates
    /// without telling anyone; `urls(for:in:)` resolves that relocation, and the home-directory path
    /// is only the fallback for when it cannot be resolved at all.
    public func defaultDirectory(fileManager: FileManager = .default, baseDirectory: URL? = nil) -> URL {
        if let baseDirectory {
            return baseDirectory.appendingPathComponent(rawValue, isDirectory: true)
        }
        if let testRoot = OPNCaptureLocations.testRootDirectory {
            return testRoot.appendingPathComponent(rawValue, isDirectory: true)
        }
        let base: URL
        switch self {
        case .screenshots:
            base = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        case .recordings:
            base = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        }
        return base.appendingPathComponent("OpenNOW", isDirectory: true)
    }
}

public enum OPNCaptureLocationError: LocalizedError, Equatable {
    case notADirectory
    case insideApplicationBundle
    case insideCloudContainer
    case notWritable(String)

    public var errorDescription: String? {
        switch self {
        case .notADirectory:
            return "Choose a folder rather than a file."
        case .insideApplicationBundle:
            return "OpenNOW's own app bundle cannot hold capture files."
        case .insideCloudContainer:
            return "iCloud Drive cannot hold the capture library. Choose a folder on this Mac."
        case .notWritable(let path):
            return "OpenNOW cannot write to \(path)."
        }
    }
}

/// What a library root resolved to, and why it is not the reader's choice when it is not.
public struct OPNCaptureLocationResolution: Equatable, Sendable {
    public let url: URL
    /// The stored override, even when it was rejected: the settings page shows what was asked for.
    public let overridePath: String?
    /// Non-nil when a stored override could not be used and the default is standing in.
    public let rejectionReason: String?

    public var usedOverride: Bool { overridePath != nil && rejectionReason == nil }
}

/// One source of truth for where OpenNOW writes the media it owns. The screenshot and recording
/// libraries forward here, so every existing consumer — the library scans, the replay buffer, iCloud
/// sync — follows a reader's choice without knowing this type exists.
public enum OPNCaptureLocations {
    public static var screenshotsDirectory: URL { directory(for: .screenshots) }
    public static var recordingsDirectory: URL { directory(for: .recordings) }

    public static func directory(for library: OPNCaptureLibrary,
                                 storage: OPNAppPreferenceStorage = .standard,
                                 fileManager: FileManager = .default,
                                 baseDirectory: URL? = nil) -> URL {
        resolve(library, storage: storage, fileManager: fileManager, baseDirectory: baseDirectory).url
    }

    /// Resolves a library root, falling back to the default when a stored override is missing,
    /// unreadable, or otherwise unusable, and saying why so the reader is not left guessing.
    public static func resolve(_ library: OPNCaptureLibrary,
                               storage: OPNAppPreferenceStorage = .standard,
                               fileManager: FileManager = .default,
                               baseDirectory: URL? = nil) -> OPNCaptureLocationResolution {
        let fallback = library.defaultDirectory(fileManager: fileManager, baseDirectory: baseDirectory)
        guard let overridePath = storedOverridePath(for: library, storage: storage) else {
            return OPNCaptureLocationResolution(url: fallback, overridePath: nil, rejectionReason: nil)
        }
        let overrideURL = URL(fileURLWithPath: overridePath, isDirectory: true)
        guard isUsable(overrideURL, fileManager: fileManager) else {
            return OPNCaptureLocationResolution(
                url: fallback,
                overridePath: overridePath,
                rejectionReason: "\(overridePath) is not available, so OpenNOW is using its default \(library.displayName.lowercased()) folder."
            )
        }
        return OPNCaptureLocationResolution(url: overrideURL, overridePath: overridePath, rejectionReason: nil)
    }

    /// The reader's stored choice, or nil when none is set. Blank counts as unset rather than as a
    /// path, so a preference written empty resolves the default instead of a relative URL.
    public static func storedOverridePath(for library: OPNCaptureLibrary,
                                          storage: OPNAppPreferenceStorage = .standard) -> String? {
        guard let value = storage.string(forKey: library.preferenceKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    public static func setOverride(_ url: URL?, for library: OPNCaptureLibrary,
                                   storage: OPNAppPreferenceStorage = .standard) {
        guard let url else {
            storage.removeObject(forKey: library.preferenceKey)
            return
        }
        storage.set(url.standardizedFileURL.path, forKey: library.preferenceKey)
    }

    public static func resetOverride(for library: OPNCaptureLibrary,
                                     storage: OPNAppPreferenceStorage = .standard) {
        setOverride(nil, for: library, storage: storage)
    }

    /// True when both libraries have been pointed at one folder. The picker warns rather than blocks:
    /// a reader may genuinely want one folder, and the write probe already keeps it usable.
    public static func librariesShareDirectory(storage: OPNAppPreferenceStorage = .standard,
                                               fileManager: FileManager = .default,
                                               baseDirectory: URL? = nil) -> Bool {
        let screenshots = directory(for: .screenshots, storage: storage, fileManager: fileManager, baseDirectory: baseDirectory)
        let recordings = directory(for: .recordings, storage: storage, fileManager: fileManager, baseDirectory: baseDirectory)
        return screenshots.standardizedFileURL.path == recordings.standardizedFileURL.path
    }

    /// The full validation a chosen folder has to pass before it is stored: a real directory, not
    /// inside OpenNOW's bundle or iCloud Drive, and writable now rather than writable in theory.
    @discardableResult
    public static func validateDirectory(_ url: URL, fileManager: FileManager = .default) throws -> URL {
        let directory = url.standardizedFileURL
        guard directory.isFileURL else { throw OPNCaptureLocationError.notADirectory }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw OPNCaptureLocationError.notADirectory
        }
        guard !isInside(directory, parentPath: Bundle.main.bundleURL.path) else {
            throw OPNCaptureLocationError.insideApplicationBundle
        }
        guard !isInside(directory, parentPath: cloudContainerRoot(fileManager: fileManager).path) else {
            throw OPNCaptureLocationError.insideCloudContainer
        }
        return try ensureWritableDirectory(at: directory, fileManager: fileManager)
    }

    /// Creates a directory and proves it writable with a probe file, the check both libraries used
    /// to carry a private copy of.
    @discardableResult
    public static func ensureWritableDirectory(at directory: URL, fileManager: FileManager = .default) throws -> URL {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw OPNCaptureLocationError.notWritable(directory.path)
        }
        let probe = directory.appendingPathComponent(".opennow-write-test", isDirectory: false)
        do {
            try Data().write(to: probe, options: .atomic)
            try? fileManager.removeItem(at: probe)
        } catch {
            throw OPNCaptureLocationError.notWritable(directory.path)
        }
        return directory
    }

    /// A cheap yes/no for the resolution path: an existing directory only has to be writable, and a
    /// missing one is created and probed once. Avoids a probe write on every library scan.
    static func isUsable(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let directory = url.standardizedFileURL
        guard !isInside(directory, parentPath: Bundle.main.bundleURL.path) else { return false }
        guard !isInside(directory, parentPath: cloudContainerRoot(fileManager: fileManager).path) else { return false }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue && fileManager.isWritableFile(atPath: directory.path)
        }
        return (try? ensureWritableDirectory(at: directory, fileManager: fileManager)) != nil
    }

    private static func cloudContainerRoot(fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
    }

    private static func isInside(_ url: URL, parentPath: String) -> Bool {
        let path = url.standardizedFileURL.path
        let parent = URL(fileURLWithPath: parentPath).standardizedFileURL.path
        guard !parent.isEmpty else { return false }
        return path == parent || path.hasPrefix(parent + "/")
    }

    /// Tests must never write into the reader's real Pictures or Movies folder. SwiftPM runs the
    /// suite inside an `.xctest` bundle, so the roots resolve under one process-wide temporary
    /// directory there. Production is untouched: this keys off how the process was launched, not off
    /// a preference a reader could set.
    static let testRootDirectory: URL? = {
        let environment = ProcessInfo.processInfo.environment
        let isTestProcess = Bundle.main.bundlePath.hasSuffix(".xctest")
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        guard isTestProcess else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenNOWTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }()
}
