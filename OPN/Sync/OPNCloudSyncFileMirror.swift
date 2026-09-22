import Foundation

/// Copies a flat directory of small files between this Mac and the iCloud container — the screenshot
/// library and the collection icon images. The copy is additive and newer-file-wins in both
/// directions, so a reader's files cannot be destroyed by a sync that runs before another Mac has
/// uploaded.
enum OPNCloudSyncFileMirror {
    struct MirrorResult: Sendable, Equatable {
        var copied = 0
        var skipped = 0
    }

    /// - Parameters:
    ///   - source: the library to read from.
    ///   - destination: the library to write into; created if absent.
    @discardableResult
    static func mirror(from source: URL, to destination: URL) throws -> MirrorResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return MirrorResult() }
        let entries = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var result = MirrorResult()
        for entry in entries where isMirrored(entry) {
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let target = destination.appendingPathComponent(entry.lastPathComponent, isDirectory: false)
            let sourceDate = values?.contentModificationDate ?? .distantPast
            let sourceSize = values?.fileSize ?? 0
            guard !isDestinationCurrent(target: target, sourceDate: sourceDate, sourceSize: sourceSize) else {
                result.skipped += 1
                continue
            }
            try replaceItemIfPresent(at: target, with: entry, fileManager: fileManager)
            result.copied += 1
        }
        return result
    }

    /// A destination is current when it exists and is at least as new and the same size as the source.
    private static func isDestinationCurrent(target: URL, sourceDate: Date, sourceSize: Int) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: target.path) else { return false }
        let targetValues = try? target.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let targetDate = targetValues?.contentModificationDate ?? .distantPast
        let targetSize = targetValues?.fileSize ?? 0
        return targetDate >= sourceDate && targetSize == sourceSize
    }

    private static func replaceItemIfPresent(at target: URL, with source: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.copyItem(at: source, to: target)
    }

    /// Only the picture and its metadata sidecar travel. `albums.json` is a `.json` beside them, so
    /// it is carried by the same rule without a special case.
    private static func isMirrored(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "png" || ext == "json"
    }
}
