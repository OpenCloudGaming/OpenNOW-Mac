import Foundation

/// Moves the pre-0.14 screenshot and recording libraries out of NVIDIA's folders and into OpenNOW's
/// own, once, on the first launch that has them.
///
/// The move does not rewrite a single sidecar. Items resolve from where their sidecar was found when
/// the stored path no longer exists (`StreamScreenshotLibrary.loadScreenshots` /
/// `StreamRecordingLibrary.loadRecordings`), so a moved library is found at its new root and a moved
/// sidecar still points at its file. That is what makes this a folder move rather than a JSON rewrite
/// across two libraries.
public enum OPNCaptureMigrationError: LocalizedError {
    case copyVerificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .copyVerificationFailed(let path):
            return "OpenNOW could not verify the copy of \(path)."
        }
    }
}

public enum OPNCaptureMigration {
    /// Written only once every library that needed moving has moved. Its presence makes a second
    /// launch a no-op.
    static let completionMarkerKey = "OpenNOW.Capture.MigrationCompleted"
    /// The one-time message the Capture page shows: the new location after a move, or why a move did
    /// not happen. Cleared when the reader dismisses it.
    static let noticeKey = "OpenNOW.Capture.MigrationNotice"

    public struct Result: Equatable, Sendable {
        public let movedLibraries: [OPNCaptureLibrary]
        public let warnings: [String]
        /// False when a completion marker already existed, or when a reader override made the run
        /// possible but not applicable.
        public let ranMigration: Bool
    }

    /// The vendor folders OpenNOW used to write into.
    public static func legacyDirectory(for library: OPNCaptureLibrary, fileManager: FileManager = .default) -> URL {
        let home = fileManager.homeDirectoryForCurrentUser
        switch library {
        case .screenshots:
            return home.appendingPathComponent("Pictures/NVIDIA/GeForce NOW", isDirectory: true)
        case .recordings:
            return home.appendingPathComponent("Movies/NVIDIA/GeForce NOW", isDirectory: true)
        }
    }

    /// Runs the migration when it has not already completed. Cheap after the first launch: a single
    /// preference read.
    @discardableResult
    public static func migrateIfNeeded(
        storage: OPNAppPreferenceStorage = .standard,
        fileManager: FileManager = .default,
        legacyRoots: (OPNCaptureLibrary) -> URL = { legacyDirectory(for: $0) },
        destinations: (OPNCaptureLibrary) -> URL = { OPNCaptureLocations.directory(for: $0) },
        moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) -> Result {
        guard !storage.bool(forKey: completionMarkerKey) else {
            return Result(movedLibraries: [], warnings: [], ranMigration: false)
        }

        var moved: [OPNCaptureLibrary] = []
        var warnings: [String] = []
        var skippedForOverride = false

        for library in OPNCaptureLibrary.allCases {
            if OPNCaptureLocations.storedOverridePath(for: library, storage: storage) != nil {
                // The reader has chosen a folder, so neither legacy nor default is in play. Not a
                // completion: clearing the override later should let a still-present legacy folder move.
                skippedForOverride = true
                continue
            }
            let legacy = legacyRoots(library)
            let destination = destinations(library)
            var isDirectory: ObjCBool = false
            let legacyExists = fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory) && isDirectory.boolValue
            guard legacyExists else { continue }
            // A new folder already exists: the reader has been here, and merging two trees silently
            // risks overwriting newer captures with older ones.
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            do {
                try moveTree(from: legacy, to: destination, fileManager: fileManager, moveItem: moveItem)
                moved.append(library)
                removeVendorFolderIfEmpty(containing: legacy, fileManager: fileManager)
            } catch {
                warnings.append("OpenNOW could not move your \(library.displayName.lowercased()) from \(legacy.path). They are still there and readable: \(error.localizedDescription)")
            }
        }

        // A failed move leaves the marker unwritten so the next launch can try again, and so the
        // legacy path stays the live library rather than an empty new page.
        if warnings.isEmpty && !skippedForOverride {
            storage.set(true, forKey: completionMarkerKey)
        }

        if !moved.isEmpty {
            storage.set(movedNotice(for: moved, destinations: destinations), forKey: noticeKey)
        }
        if !warnings.isEmpty {
            storage.set(warnings.joined(separator: " "), forKey: noticeKey)
        }

        return Result(movedLibraries: moved, warnings: warnings, ranMigration: true)
    }

    /// The message the Capture page shows once after a move.
    public static var pendingNotice: String? {
        OPNAppPreferenceStorage.standard.string(forKey: noticeKey)
    }

    public static func acknowledgeNotice(storage: OPNAppPreferenceStorage = .standard) {
        storage.removeObject(forKey: noticeKey)
    }

    /// Moves one tree. A rename within a volume, falling back to copy, verify, then delete per file
    /// when the destination is on another volume — an external drive, where `moveItem` gives up.
    static func moveTree(from source: URL,
                         to destination: URL,
                         fileManager: FileManager = .default,
                         moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try moveItem(source, destination)
        } catch {
            try copyTree(from: source, to: destination, fileManager: fileManager)
            do {
                try fileManager.removeItem(at: source)
            } catch {
                // The bytes are safely at the destination; an un-removable legacy tree is a follow-up,
                // not a data loss.
                try? fileManager.removeItem(at: destination)
                throw error
            }
        }
    }

    /// Copies files one at a time, comparing sizes as it goes, so a partial cross-volume copy is
    /// detectable rather than silently accepted.
    static func copyTree(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        // Relative subpaths rather than paths minus a prefix: on macOS the enumerator hands back
        // `/private/var/...` for a `/var/...` source, so an arithmetic strip lands mid-name.
        guard let subpaths = try? fileManager.subpathsOfDirectory(atPath: source.path) else {
            throw OPNCaptureMigrationError.copyVerificationFailed(source.path)
        }
        for relativePath in subpaths {
            let item = source.appendingPathComponent(relativePath)
            let target = destination.appendingPathComponent(relativePath)
            let attributes = try? fileManager.attributesOfItem(atPath: item.path)
            if (attributes?[.type] as? FileAttributeType) == .typeDirectory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: item, to: target)
            guard fileSize(at: item, fileManager: fileManager) == fileSize(at: target, fileManager: fileManager) else {
                throw OPNCaptureMigrationError.copyVerificationFailed(item.path)
            }
        }
    }

    private static func fileSize(at url: URL, fileManager: FileManager) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    /// Removes the vendor folder only when the move left it empty. The official client may own files
    /// under `~/Pictures/NVIDIA` or `~/Movies/NVIDIA` that are not ours.
    private static func removeVendorFolderIfEmpty(containing legacy: URL, fileManager: FileManager) {
        let vendor = legacy.deletingLastPathComponent()
        guard let contents = try? fileManager.contentsOfDirectory(atPath: vendor.path), contents.isEmpty else { return }
        try? fileManager.removeItem(at: vendor)
    }

    private static func movedNotice(for libraries: [OPNCaptureLibrary], destinations: (OPNCaptureLibrary) -> URL) -> String {
        let names = libraries.map(\.displayName).joined(separator: " and ")
        let paths = libraries.map { destinations($0).path }.joined(separator: ", ")
        return "\(names) moved into OpenNOW's own folder: \(paths)."
    }
}
