//  The replay window after its stream has ended: the ring is kept on disk, described by a manifest,
//  so it can still be saved once the game is closed, and picked back up by the next session.
//

import Foundation

/// A ring left behind by a finished stream, as the recordings screen and the next session need it.
/// The segments are the bytes and their capture-clock ranges; this is the index.
public struct StreamReplayRetainedWindow: Codable, Equatable, Identifiable, Sendable {
    /// One finalized file and the capture-clock span it covers. The span is absolute, not an offset
    /// into the window, because a clip and the ring's own prune both work in capture-clock time.
    public struct Segment: Codable, Equatable, Sendable {
        public let fileName: String
        public let hostStart: CFTimeInterval
        public let hostEnd: CFTimeInterval

        public init(fileName: String, hostStart: CFTimeInterval, hostEnd: CFTimeInterval) {
            self.fileName = fileName
            self.hostStart = hostStart
            self.hostEnd = hostEnd
        }

        public var durationSeconds: Double { max(0, hostEnd - hostStart) }
    }

    public let id: UUID
    public let title: String
    public let applicationID: String
    /// When the session that wrote it ended. It orders this window against every other title's.
    public let createdAt: Date
    public let startHostTime: CFTimeInterval
    public let endHostTime: CFTimeInterval
    /// The encoded shape every segment in the window shares, and the shape a later session must
    /// match before it can roll this ring forward.
    public let width: Int
    public let height: Int
    public let videoBitrateMbps: Int
    public let audioBitrateKbps: Int
    public let segments: [Segment]
    public let storageDirectoryPath: String?

    public init(id: UUID,
                title: String,
                applicationID: String,
                createdAt: Date,
                startHostTime: CFTimeInterval,
                endHostTime: CFTimeInterval,
                width: Int,
                height: Int,
                videoBitrateMbps: Int,
                audioBitrateKbps: Int,
                segments: [Segment],
                storageDirectoryPath: String?) {
        self.id = id
        self.title = title
        self.applicationID = applicationID
        self.createdAt = createdAt
        self.startHostTime = startHostTime
        self.endHostTime = endHostTime
        self.width = width
        self.height = height
        self.videoBitrateMbps = videoBitrateMbps
        self.audioBitrateKbps = audioBitrateKbps
        self.segments = segments
        self.storageDirectoryPath = storageDirectoryPath
    }

    public var durationSeconds: Double { max(0, endHostTime - startHostTime) }

    public var directoryURL: URL {
        guard let storageDirectoryPath, !storageDirectoryPath.isEmpty else { return StreamReplayRetentionLibrary.retainedWindowsDirectory }
        return URL(fileURLWithPath: storageDirectoryPath, isDirectory: true)
    }

    public var manifestURL: URL { directoryURL.appendingPathComponent(StreamReplayRetentionLibrary.manifestFileName) }

    public var segmentFileNames: [String] { segments.map(\.fileName) }

    public var segmentURLs: [URL] { segmentFileNames.map { directoryURL.appendingPathComponent($0) } }

    public var fileSizeBytes: Int64 {
        segmentURLs.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
    }

    /// Whether the manifest is still true on disk: every segment it names is present.
    public var hasAllSegments: Bool {
        !segments.isEmpty && segmentURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Where retained windows live and how much of them there is: one window per title, each rolling
/// across that title's sessions, until the budget or the reader clears them.
public enum StreamReplayRetentionLibrary {
    public static let manifestFileName = "manifest.json"
    public static let didChangeNotification = Notification.Name("OPNStreamReplayRetentionDidChange")

    /// The retained store's ceiling, as the settings surface bounds it.
    public static let minimumBudgetGigabytes = 5
    public static let maximumBudgetGigabytes = 200
    public static let defaultBudgetGigabytes = 20

    /// Decimal gigabytes, the same unit `ByteCountFormatter` reports, so the number the settings
    /// page shows is the number the store is held to.
    public static func bytes(forGigabytes gigabytes: Int) -> Int64 {
        Int64(max(0, gigabytes)) * 1_000_000_000
    }

    /// The budget the settings page has stored, in bytes. Read here rather than from inside
    /// `StreamReplayBufferConfiguration`, so building a policy value never opens a side channel.
    public static var configuredBudgetBytes: Int64 {
        bytes(forGigabytes: OPNStreamPreferences.loadRecordingReplayStorageBudgetGB())
    }

    /// The reader's own cache, where a live session's ring is written. Disposable by design: losing
    /// a ring that is still rolling costs nothing, because the session is still on screen.
    public static var bufferRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OpenNOW", isDirectory: true).appendingPathComponent("InstantReplay", isDirectory: true)
    }

    /// Where a finished stream's window goes. Deliberately not the cache: macOS may purge that at any
    /// time, and a retained window is footage the reader has not decided about yet.
    public static var retainedWindowsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("OpenNOW", isDirectory: true).appendingPathComponent("RetainedReplays", isDirectory: true)
    }

    /// Moves a finished ring out of the purgeable cache. A rename within the same volume.
    public static func relocateForRetention(from directory: URL, to root: URL = retainedWindowsDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: directory, to: destination)
        return destination
    }

    /// The windows on disk, newest first, as the recordings screen lists them.
    public static func loadRetainedWindows(in root: URL = retainedWindowsDirectory) -> [StreamReplayRetainedWindow] {
        retainedWindows(in: root)
            .filter { $0.hasAllSegments }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The stored ring for one title, which is what a starting session looks for.
    public static func window(forApplicationID applicationID: String, in root: URL = retainedWindowsDirectory) -> StreamReplayRetainedWindow? {
        loadRetainedWindows(in: root).first { $0.applicationID == applicationID }
    }

    public static func write(_ window: StreamReplayRetainedWindow) throws {
        try save(window)
        postChange()
    }

    public static func discard(_ window: StreamReplayRetainedWindow) {
        try? FileManager.default.removeItem(at: window.directoryURL)
        postChange()
    }

    /// Hands one title's window back to a session starting on it: its segment files move into the
    /// live staging directory and the caller gets them as ring segments to keep rolling.
    @discardableResult
    static func claimForAdoption(applicationID: String,
                                 encodedWidth: Int,
                                 encodedHeight: Int,
                                 now: CFTimeInterval,
                                 in root: URL = retainedWindowsDirectory,
                                 into directory: URL) -> [StreamReplaySegment]? {
        guard let window = window(forApplicationID: applicationID, in: root) else { return nil }
        guard window.width == encodedWidth, window.height == encodedHeight else { return nil }
        guard window.endHostTime <= now else { return nil }
        var claimed: [StreamReplaySegment] = []
        for segment in window.segments.sorted(by: { $0.hostStart < $1.hostStart }) {
            let destination = directory.appendingPathComponent(segment.fileName)
            guard (try? FileManager.default.moveItem(at: window.directoryURL.appendingPathComponent(segment.fileName), to: destination)) != nil else { continue }
            claimed.append(StreamReplaySegment(
                id: UUID(),
                url: destination,
                periodID: 1,
                hostStart: segment.hostStart,
                hostEnd: segment.hostEnd,
                width: window.width,
                height: window.height
            ))
        }
        try? FileManager.default.removeItem(at: window.directoryURL)
        postChange()
        return claimed.isEmpty ? nil : claimed
    }

    /// Collapses the store to one window per title, drops any whose segments have gone, and holds
    /// what is left under `budgetBytes`. Called at each retention, never at startup.
    @discardableResult
    public static func prune(in root: URL = retainedWindowsDirectory, budgetBytes: Int64) -> Bool {
        let didRemoveUnusable = removeUnusableWindows(in: root)
        let didRemoveDuplicates = removeDuplicateWindows(in: root)
        let didTrim = enforceBudget(budgetBytes, in: root)
        guard didRemoveUnusable || didRemoveDuplicates || didTrim else { return false }
        postChange()
        return true
    }

    /// Holds the store under `budgetBytes`: whole windows go first, least recently written, and only
    /// a single window larger than the budget has its own oldest footage cut.
    @discardableResult
    public static func enforceBudget(_ budgetBytes: Int64, in root: URL = retainedWindowsDirectory) -> Bool {
        var kept = loadRetainedWindows(in: root).sorted { $0.createdAt > $1.createdAt }
        guard !kept.isEmpty else { return false }
        var totalBytes = kept.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        var didPrune = false
        while totalBytes > budgetBytes, kept.count > 1 {
            let oldest = kept.removeLast()
            totalBytes -= oldest.fileSizeBytes
            try? FileManager.default.removeItem(at: oldest.directoryURL)
            didPrune = true
        }
        if totalBytes > budgetBytes, let newest = kept.first {
            didPrune = trimOldestSegments(of: newest, overflowBytes: totalBytes - budgetBytes) || didPrune
        }
        guard didPrune else { return false }
        postChange()
        return true
    }

    private static func postChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Persist without notifying, so a trim can rewrite a manifest inside a prune that will notify
    /// once for the whole operation.
    private static func save(_ window: StreamReplayRetainedWindow) throws {
        let data = try JSONEncoder.recordingEncoder.encode(window)
        try data.write(to: window.manifestURL, options: .atomic)
    }

    private static func trimOldestSegments(of window: StreamReplayRetainedWindow, overflowBytes: Int64) -> Bool {
        var ordered = window.segments.sorted { $0.hostStart < $1.hostStart }
        var freedBytes = Int64(0)
        while freedBytes < overflowBytes, ordered.count > 1, let oldest = ordered.first {
            let url = window.directoryURL.appendingPathComponent(oldest.fileName)
            freedBytes += url.fileSizeBytes
            try? FileManager.default.removeItem(at: url)
            ordered.removeFirst()
        }
        guard freedBytes > 0 else { return false }
        let trimmed = StreamReplayRetainedWindow(
            id: window.id,
            title: window.title,
            applicationID: window.applicationID,
            createdAt: window.createdAt,
            startHostTime: ordered.first?.hostStart ?? window.startHostTime,
            endHostTime: ordered.last?.hostEnd ?? window.endHostTime,
            width: window.width,
            height: window.height,
            videoBitrateMbps: window.videoBitrateMbps,
            audioBitrateKbps: window.audioBitrateKbps,
            segments: ordered,
            storageDirectoryPath: window.storageDirectoryPath
        )
        try? save(trimmed)
        return true
    }

    private static func removeUnusableWindows(in root: URL) -> Bool {
        var didRemove = false
        for directory in retainedWindowDirectories(in: root) where decodeWindow(at: directory)?.hasAllSegments != true {
            try? FileManager.default.removeItem(at: directory)
            didRemove = true
        }
        return didRemove
    }

    /// One window per title: the newest is kept and its older siblings go.
    private static func removeDuplicateWindows(in root: URL) -> Bool {
        var didRemove = false
        var seenApplicationIDs = Set<String>()
        let windows = retainedWindows(in: root).sorted { $0.createdAt > $1.createdAt }
        for window in windows where !seenApplicationIDs.insert(window.applicationID).inserted {
            try? FileManager.default.removeItem(at: window.directoryURL)
            didRemove = true
        }
        return didRemove
    }

    private static func retainedWindowDirectories(in root: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(manifestFileName).path) }
    }

    private static func decodeWindow(at directory: URL) -> StreamReplayRetainedWindow? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(manifestFileName)) else { return nil }
        return try? JSONDecoder.recordingDecoder.decode(StreamReplayRetainedWindow.self, from: data)
    }

    private static func retainedWindows(in root: URL) -> [StreamReplayRetainedWindow] {
        retainedWindowDirectories(in: root).compactMap(decodeWindow(at:))
    }
}
