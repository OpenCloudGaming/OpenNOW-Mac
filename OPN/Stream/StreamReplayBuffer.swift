//  Instant replay: a rolling window of the last few minutes of a stream, kept as short finalized
//  files on disk and copied out to one clip on demand.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
@preconcurrency import WebRTC

/// What the replay ring is asked to keep: the encoder settings it shares with a manual recording,
/// how much of the past it retains, and how much of that one save writes.
public struct StreamReplayBufferConfiguration: Equatable, Sendable {
    public static let minimumWindowSeconds: Double = 30
    /// Two hours, matching Steam's background-recording duration. What this costs is the disk
    /// estimate the settings page shows, not a fixed allocation.
    public static let maximumWindowSeconds: Double = 7_200
    public static let defaultWindowSeconds: Double = 1_800
    public static let minimumClipSeconds: Double = 10
    public static let maximumClipSeconds: Double = 600
    public static let defaultClipSeconds: Double = 60

    public let recording: StreamRecordingConfiguration
    /// How much of the past is kept on disk.
    public let windowSeconds: Double
    /// How much of that window one save writes: the window is a ring, a clip is a slice of it.
    public let clipSeconds: Double
    /// How much footage one file holds. Longer files mean fewer encoder restarts at the cost of a
    /// coarser prune and a larger in-flight file.
    public let segmentSeconds: Double
    /// 0 keeps the stream's own height. Anything else scales frames down before they are encoded,
    /// which is what makes a smaller replay tier actually smaller.
    public let maxHeight: Int
    /// 0 lets the recording bitrate setting decide.
    public let bitrateCeilingMbps: Int
    /// The ceiling on the whole retained store, across every title. The window bounds one ring; this
    /// bounds all of them, the way Steam bounds its background recordings by disk.
    public let retainedBudgetBytes: Int64

    public init(recording: StreamRecordingConfiguration,
                windowSeconds: Double = StreamReplayBufferConfiguration.defaultWindowSeconds,
                clipSeconds: Double = StreamReplayBufferConfiguration.defaultClipSeconds,
                segmentSeconds: Double = 300,
                maxHeight: Int = 0,
                bitrateCeilingMbps: Int = 0,
                retainedBudgetBytes: Int64 = StreamReplayRetentionLibrary.bytes(forGigabytes: StreamReplayRetentionLibrary.defaultBudgetGigabytes)) {
        // The 30–7200 s range is the settings surface's; the buffer itself only needs a positive
        // window, which keeps it unit-testable at seconds rather than minutes.
        self.recording = recording
        let window = min(max(windowSeconds, 1), Self.maximumWindowSeconds)
        self.windowSeconds = window
        self.clipSeconds = min(max(clipSeconds, 0.5), window)
        self.segmentSeconds = min(max(segmentSeconds, 0.5), 600)
        self.maxHeight = max(0, maxHeight)
        self.bitrateCeilingMbps = max(0, bitrateCeilingMbps)
        self.retainedBudgetBytes = max(0, retainedBudgetBytes)
    }

    /// Bytes per second the encoder is expected to produce, using the same automatic-bitrate rule
    /// the writer applies and the same ceiling the quality tier puts on it.
    public static func estimatedBytesPerSecond(recording: StreamRecordingConfiguration, width: Int, height: Int, bitrateCeilingMbps: Int = 0) -> Double {
        let videoBitsPerSecond = WebRTCStreamRecorder.videoBitrate(configuration: recording, width: max(1, width), height: max(1, height))
        let cappedVideoBitsPerSecond = bitrateCeilingMbps > 0 ? min(videoBitsPerSecond, bitrateCeilingMbps * 1_000_000) : videoBitsPerSecond
        let audioBitsPerSecond = Double(recording.audioBitrateKbps * 1_000)
        return (Double(cappedVideoBitsPerSecond) + audioBitsPerSecond) / 8
    }

    /// `width` and `height` are the source frame's; the tier's cap is applied here so callers cannot
    /// forget it.
    public func estimatedBufferBytes(width: Int, height: Int) -> Int64 {
        let size = OPNVideoSize.capped(width: width, height: height, maxHeight: maxHeight)
        let retainedSeconds = windowSeconds + segmentSeconds
        return Int64(Self.estimatedBytesPerSecond(
            recording: recording,
            width: size.width,
            height: size.height,
            bitrateCeilingMbps: bitrateCeilingMbps
        ) * retainedSeconds)
    }
}

/// One encoded file in the ring.
struct StreamReplaySegment: Sendable {
    let id: UUID
    let url: URL
    let periodID: UInt64
    let hostStart: CFTimeInterval
    let hostEnd: CFTimeInterval
    let width: Int
    let height: Int
    var isPinned = false
}

/// What the HUD shows. Buffering and saving are separate facts: a save in flight must not hide the
/// fact that capture is still running.
public struct StreamReplayBufferState: Equatable, Sendable {
    public var isBuffering = false
    public var availableSeconds: Double = 0
    public var isSaving = false
    public var lastClip: StreamRecording?
    public var failureMessage: String?
    public var pauseReason: String?

    /// The window's ready footage as `M:SS`, for a one-line HUD status.
    public var availableText: String {
        let whole = max(0, Int(availableSeconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// The one-glance value a HUD metric card shows. Buffered footage is the whole story while the
    /// window is running; anything else is a state the reader needs to notice.
    public var shortStatusText: String {
        if pauseReason?.isEmpty == false { return "Paused" }
        if isSaving { return "Saving" }
        guard isBuffering else { return "Off" }
        guard availableSeconds >= 1 else { return "…" }
        return availableText
    }

    public init() {}
}

/// The rolling buffer. All mutable state lives on `queue`; the decode and audio threads only take
/// the ingress gate's lock and enqueue.
public final class StreamReplayBuffer: @unchecked Sendable {
    public typealias StateHandler = @MainActor @Sendable (StreamReplayBufferState) -> Void

    static let maximumQueuedFrames = 4
    static let minimumFreeBytes: Int64 = 1_500_000_000
    static let periodBreakGapSeconds: Double = 10
    static let firstFrameTimeout: DispatchTimeInterval = .seconds(15)

    let queue = DispatchQueue(label: "io.opencg.opennow.replay.buffer")
    let conversionQueue = DispatchQueue(label: "io.opencg.opennow.replay.conversion", qos: .userInitiated)

    let ingressLock = NSLock()
    var ingressGeneration: UInt64?
    var queuedFrameCount = 0

    let pixelTransfer = OPNPixelBufferTransfer()
    let i420BGRAConverter = WebRTCI420BGRAConverter()
    var bgraPool: CVPixelBufferPool?
    var bgraPoolWidth = 0
    var bgraPoolHeight = 0

    var configuration: StreamReplayBufferConfiguration?
    var stagingDirectory: URL?
    var segments: [StreamReplaySegment] = []
    var activeSegment: ActiveSegment?
    var currentPeriodID: UInt64 = 1
    var isCaptureStarted = false
    var lastAcceptedFrameHostTime: CFTimeInterval?
    var lastRecordedWidth = 0
    var lastRecordedHeight = 0
    var pendingSave: PendingSave?
    var pendingRetention: PendingRetention?
    var isRetentionPending = false
    var stagingDirectoryToRemove: URL?
    var firstFrameTimeoutTask: DispatchWorkItem?
    var state = StreamReplayBufferState()
    private var lastStateEmitHostTime: CFTimeInterval = 0

    private let stateHandlerLock = NSLock()
    private var storedStateHandler: StateHandler?
    private var stateDeliveryTask: Task<Void, Never>?

    public init(root: URL = StreamReplayRetentionLibrary.bufferRoot, retainedRoot: URL = StreamReplayRetentionLibrary.retainedWindowsDirectory) {
        self.root = root
        self.retainedRoot = retainedRoot
    }

    /// Where this buffer's live segments live, and where a finished ring is kept. Both are injected so
    /// a test works in its own directories rather than the reader's.
    let root: URL
    let retainedRoot: URL

    public var onStateChanged: StateHandler? {
        get { stateHandlerLock.withLock { storedStateHandler } }
        set { stateHandlerLock.withLock { storedStateHandler = newValue } }
    }

    // MARK: - Lifecycle

    public func start(configuration: StreamReplayBufferConfiguration) {
        queue.async {
            guard self.configuration == nil else { return }
            do {
                let directory = try self.makeStagingDirectory()
                self.stagingDirectory = directory
                self.writeOwnerMarker(in: directory)
            } catch {
                self.state = StreamReplayBufferState()
                self.state.failureMessage = "Instant Replay could not create its buffer: \(error.localizedDescription)"
                self.emitState(force: true)
                return
            }
            self.configuration = configuration
            self.lastRecordedWidth = configuration.recording.width
            self.lastRecordedHeight = configuration.recording.height
            // Refused up front rather than five minutes in, when the first segment seals: a window
            // the disk cannot hold is a choice to make before the stream starts, not after.
            guard self.checkFreeSpace() else {
                let needed = ByteCountFormatter.string(fromByteCount: self.requiredFreeSpaceBytes(), countStyle: .file)
                let minutes = Int(configuration.windowSeconds / 60)
                self.removeStagingDirectory(self.stagingDirectory)
                self.stagingDirectory = nil
                self.configuration = nil
                self.state = StreamReplayBufferState()
                self.state.failureMessage = "Instant Replay needs about \(needed) free to keep \(minutes) minutes of footage."
                self.emitState(force: true)
                return
            }
            self.segments = []
            self.activeSegment = nil
            self.isCaptureStarted = false
            self.currentPeriodID = 1
            self.lastAcceptedFrameHostTime = nil
            self.pendingSave = nil
            self.pendingRetention = nil
            self.isRetentionPending = false
            self.stagingDirectoryToRemove = nil
            self.state = StreamReplayBufferState()
            self.state.isBuffering = true
            if let directory = self.stagingDirectory {
                self.adoptRetainedRing(into: directory, now: CACurrentMediaTime())
            }
            self.ingressLock.withLock {
                self.ingressGeneration = 1
                self.queuedFrameCount = 0
            }
            self.scheduleFirstFrameTimeout()
            self.sweepOrphanedStagingDirectories()
            self.emitState(force: true)
        }
    }

    public func stop() {
        queue.async { self.performStop(pauseReason: nil) }
    }

    /// Ends the buffer but keeps its ring on disk as a retained window, so the footage can still be
    /// saved after the stream is gone. A no-op when nothing was buffered.
    public func retain() {
        queue.async {
            guard self.configuration != nil else { return }
            self.isRetentionPending = true
            self.performStop(pauseReason: nil)
        }
    }

    public func saveClip() {
        queue.async { self.beginSave() }
    }

    // MARK: - Saving

    private func beginSave() {
        guard configuration != nil, isIngressOpen else { return }
        guard pendingSave == nil else {
            state.failureMessage = "A replay clip is already being saved."
            emitState(force: true)
            return
        }
        guard let activeSegment, let configuration else {
            state.failureMessage = "Instant Replay has not buffered any video yet."
            emitState(force: true)
            return
        }
        let outputDirectory: URL
        do {
            outputDirectory = try StreamRecordingLibrary.ensureDirectory(forGameTitle: configuration.recording.title)
        } catch {
            state.failureMessage = "The recordings folder is not writable: \(error.localizedDescription)"
            emitState(force: true)
            return
        }
        let cutHostTime = CACurrentMediaTime()
        let existing = segments.filter { $0.periodID == currentPeriodID }
        pendingSave = PendingSave(
            id: UUID(),
            cutHostTime: cutHostTime,
            clipSeconds: configuration.clipSeconds,
            existingSegments: existing,
            sealedSegmentID: activeSegment.id,
            outputDirectory: outputDirectory,
            title: configuration.recording.title,
            applicationID: configuration.recording.applicationID,
            videoBitrateMbps: configuration.recording.videoBitrateMbps,
            audioBitrateKbps: configuration.recording.audioBitrateKbps
        )
        state.isSaving = true
        state.failureMessage = nil
        emitState(force: true)
        sealActiveSegment()
    }

    func startExport(for pending: PendingSave) {
        var clipSegments = pending.existingSegments
        if let sealed = segments.first(where: { $0.id == pending.sealedSegmentID }) {
            clipSegments.append(sealed)
        }
        clipSegments.sort { $0.hostStart < $1.hostStart }
        guard !clipSegments.isEmpty else {
            failPendingSave(id: pending.id, message: "There was no buffered video to save.")
            return
        }
        let pinnedIDs = Set(clipSegments.map(\.id))
        for index in segments.indices where pinnedIDs.contains(segments[index].id) {
            segments[index].isPinned = true
        }
        let request = StreamReplayClipExportRequest(
            segments: clipSegments,
            cutHostTime: pending.cutHostTime,
            clipSeconds: pending.clipSeconds,
            outputDirectory: pending.outputDirectory,
            title: pending.title,
            applicationID: pending.applicationID,
            videoBitrateMbps: pending.videoBitrateMbps,
            audioBitrateKbps: pending.audioBitrateKbps
        )
        let saveID = pending.id
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let recording = try await StreamReplayClipExporter.export(request)
                self.queue.async { self.completeSave(id: saveID, recording: recording) }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.queue.async { self.failPendingSave(id: saveID, message: message.isEmpty ? "The replay clip could not be saved." : message) }
            }
        }
    }

    private func completeSave(id: UUID, recording: StreamRecording) {
        guard pendingSave?.id == id else { return }
        pendingSave = nil
        state.isSaving = false
        state.lastClip = recording
        state.failureMessage = nil
        unpinAll()
        prune(now: CACurrentMediaTime())
        removeStagingDirectoryIfSettled()
        emitState(force: true)
    }

    func failPendingSave(id: UUID, message: String) {
        guard pendingSave?.id == id else { return }
        pendingSave = nil
        state.isSaving = false
        state.failureMessage = message
        unpinAll()
        prune(now: CACurrentMediaTime())
        removeStagingDirectoryIfSettled()
        emitState(force: true)
    }

    private func unpinAll() {
        for index in segments.indices { segments[index].isPinned = false }
    }

    func updateAvailableSeconds(now: CFTimeInterval) {
        guard let configuration else { return }
        let periodStart = segments.first(where: { $0.periodID == currentPeriodID })?.hostStart ?? activeSegment?.startHost
        guard let periodStart else {
            state.availableSeconds = 0
            return
        }
        state.availableSeconds = min(configuration.windowSeconds, max(0, now - periodStart))
    }

    // MARK: - Ingress gate

    func beginIngress() -> UInt64? {
        ingressLock.withLock {
            guard let generation = ingressGeneration, queuedFrameCount < Self.maximumQueuedFrames else { return nil }
            queuedFrameCount += 1
            return generation
        }
    }

    func finishIngress() {
        ingressLock.withLock {
            queuedFrameCount = max(0, queuedFrameCount - 1)
        }
    }

    func isGenerationActive(_ generation: UInt64) -> Bool {
        ingressLock.withLock { ingressGeneration == generation }
    }

    var isIngressOpen: Bool {
        ingressLock.withLock { ingressGeneration != nil }
    }

    // MARK: - State

    func emitState(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastStateEmitHostTime >= 0.5 else { return }
        lastStateEmitHostTime = now
        let snapshot = state
        let handler = stateHandlerLock.withLock { storedStateHandler }
        let previous = stateDeliveryTask
        stateDeliveryTask = Task { @MainActor in
            await previous?.value
            handler?(snapshot)
        }
    }

    struct ActiveSegment {
        let id: UUID
        let periodID: UInt64
        let startHost: CFTimeInterval
        let width: Int
        let height: Int
        let pixelFormat: OSType
        let writer: StreamReplaySegmentWriter
    }

    struct PendingSave {
        let id: UUID
        let cutHostTime: CFTimeInterval
        let clipSeconds: Double
        let existingSegments: [StreamReplaySegment]
        let sealedSegmentID: UUID
        let outputDirectory: URL
        let title: String
        let applicationID: String
        let videoBitrateMbps: Int
        let audioBitrateKbps: Int
    }

    /// The metadata a retained window needs, captured before the stop clears the configuration.
    struct PendingRetention {
        let title: String
        let applicationID: String
        let videoBitrateMbps: Int
        let audioBitrateKbps: Int
        let retainedBudgetBytes: Int64
    }
}
