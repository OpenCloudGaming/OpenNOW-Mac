import Foundation

public enum OPNCaptureMigrationError: LocalizedError {
    case copyVerificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .copyVerificationFailed(let path):
            return "OpenNOW could not verify the copy of \(path)."
        }
    }
}

/// Moves the pre-0.14 screenshot and recording libraries out of NVIDIA's folders into OpenNOW's own,
/// once, on the first launch that has them. No sidecar is rewritten; items heal from their sidecar.
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
        public let isMigrationRun: Bool
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

    /// Runs the migration unless a completion marker says it is done. Cheap after the first launch:
    /// a single preference read.
    @discardableResult
    public static func runMigration(
        storage: OPNAppPreferenceStorage = .standard,
        fileManager: FileManager = .default,
        legacyRoots: (OPNCaptureLibrary) -> URL = { legacyDirectory(for: $0) },
        destinations: (OPNCaptureLibrary) -> URL = { OPNCaptureLocations.directory(for: $0) },
        moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) -> Result {
        guard !storage.bool(forKey: completionMarkerKey) else {
            return Result(movedLibraries: [], warnings: [], isMigrationRun: false)
        }

        var movedLibraries: [OPNCaptureLibrary] = []
        var warnings: [String] = []
        var isOverrideSet = false

        for library in OPNCaptureLibrary.allCases {
            guard OPNCaptureLocations.storedOverridePath(for: library, storage: storage) == nil else {
                // The reader's own folder is in play, so neither legacy nor default is. Deliberately
                // not a completion: clearing the override later should let a legacy folder move.
                isOverrideSet = true
                continue
            }
            guard let outcome = migrateLibrary(library, fileManager: fileManager, legacyRoots: legacyRoots, destinations: destinations, moveItem: moveItem) else {
                continue
            }
            switch outcome {
            case .moved:
                movedLibraries.append(library)
            case .failed(let message):
                warnings.append(message)
            }
        }

        // A failure leaves the marker unwritten so the next launch can try again, and so the legacy
        // path stays the live library rather than an empty new page.
        if warnings.isEmpty && !isOverrideSet {
            storage.set(true, forKey: completionMarkerKey)
        }
        writeNotice(movedLibraries: movedLibraries, warnings: warnings, storage: storage, destinations: destinations)

        return Result(movedLibraries: movedLibraries, warnings: warnings, isMigrationRun: true)
    }

    /// The message the Capture page shows once after a move, or nil when there is nothing to report.
    public static var pendingNotice: String? {
        OPNAppPreferenceStorage.standard.string(forKey: noticeKey)
    }

    public static func acknowledgeNotice(storage: OPNAppPreferenceStorage = .standard) {
        storage.removeObject(forKey: noticeKey)
    }

    private enum LibraryOutcome {
        case moved
        case failed(String)
    }

    private static func migrateLibrary(
        _ library: OPNCaptureLibrary,
        fileManager: FileManager,
        legacyRoots: (OPNCaptureLibrary) -> URL,
        destinations: (OPNCaptureLibrary) -> URL,
        moveItem: (URL, URL) throws -> Void
    ) -> LibraryOutcome? {
        let legacy = legacyRoots(library)
        let destination = destinations(library)
        guard isDirectory(legacy, fileManager: fileManager) else { return nil }
        // A new folder already exists: the reader has been here, and merging two trees silently risks
        // overwriting newer captures with older ones.
        guard !fileManager.fileExists(atPath: destination.path) else { return nil }
        do {
            try moveTree(from: legacy, to: destination, fileManager: fileManager, moveItem: moveItem)
            removeEmptyVendorFolder(containing: legacy, fileManager: fileManager)
            return .moved
        } catch {
            return .failed("OpenNOW could not move your \(library.displayName.lowercased()) from \(legacy.path). They are still there and readable: \(error.localizedDescription)")
        }
    }

    private static func writeNotice(
        movedLibraries: [OPNCaptureLibrary],
        warnings: [String],
        storage: OPNAppPreferenceStorage,
        destinations: (OPNCaptureLibrary) -> URL
    ) {
        guard !warnings.isEmpty else {
            writeMovedNotice(movedLibraries: movedLibraries, storage: storage, destinations: destinations)
            return
        }
        storage.set(warnings.joined(separator: " "), forKey: noticeKey)
    }

    private static func writeMovedNotice(
        movedLibraries: [OPNCaptureLibrary],
        storage: OPNAppPreferenceStorage,
        destinations: (OPNCaptureLibrary) -> URL
    ) {
        guard !movedLibraries.isEmpty else { return }
        storage.set(movedNotice(for: movedLibraries, destinations: destinations), forKey: noticeKey)
    }

    /// Moves one tree. A rename within a volume, falling back to copy, verify, then delete per file
    /// when the destination is on another volume, where `moveItem` gives up.
    static func moveTree(from source: URL,
                         to destination: URL,
                         fileManager: FileManager = .default,
                         moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try moveItem(source, destination)
            return
        } catch {
            try copyTree(from: source, to: destination, fileManager: fileManager)
        }
        try fileManager.removeItem(at: source)
    }

    /// Copies files one at a time, comparing sizes as it goes, so a partial cross-volume copy is
    /// detectable rather than silently accepted.
    static func copyTree(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        // Relative subpaths rather than paths minus a prefix: macOS hands back `/private/var/...`
        // for a `/var/...` source, so an arithmetic strip lands mid-name.
        guard let subpaths = try? fileManager.subpathsOfDirectory(atPath: source.path) else {
            throw OPNCaptureMigrationError.copyVerificationFailed(source.path)
        }
        for relativePath in subpaths {
            try copyItem(relativePath: relativePath, from: source, to: destination, fileManager: fileManager)
        }
    }

    private static func copyItem(relativePath: String, from source: URL, to destination: URL, fileManager: FileManager) throws {
        let item = source.appendingPathComponent(relativePath)
        let target = destination.appendingPathComponent(relativePath)
        let attributes = try? fileManager.attributesOfItem(atPath: item.path)
        if (attributes?[.type] as? FileAttributeType) == .typeDirectory {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            return
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

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func fileSize(at url: URL, fileManager: FileManager) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    /// Removes the vendor folder only when the move left it empty. The official client may own files
    /// under `~/Pictures/NVIDIA` or `~/Movies/NVIDIA` that are not ours.
    private static func removeEmptyVendorFolder(containing legacy: URL, fileManager: FileManager) {
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
