//  The replay ring itself: rotating segments as frames arrive, sealing them, pruning what has aged
//  out of the window, and owning the staging directory on disk.
//import AVFoundation
import CoreVideo
import Foundation
import QuartzCore

extension StreamReplayBuffer {
    // MARK: - Queue-side capture

    func appendPixelBufferOnQueue(_ pixelBuffer: CVPixelBuffer, hostTime: CFTimeInterval) {
        guard let configuration, stagingDirectory != nil, isIngressOpen else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard width > 0, height > 0 else { return }

        let gap = lastAcceptedFrameHostTime.map { hostTime - $0 } ?? 0
        let isFormatChange = activeSegment.map { $0.width != width || $0.height != height || $0.pixelFormat != pixelFormat } ?? false
        let isPeriodBreak = gap > Self.periodBreakGapSeconds
        if activeSegment == nil || isFormatChange || isPeriodBreak || (activeSegment.map { hostTime - $0.startHost >= configuration.segmentSeconds } ?? false) {
            startSegment(hostTime: hostTime, width: width, height: height, pixelFormat: pixelFormat, beginsNewPeriod: isCaptureStarted && (isFormatChange || isPeriodBreak))
        }
        guard let activeSegment else { return }
        guard activeSegment.writer.appendVideo(pixelBuffer: pixelBuffer, hostTime: hostTime) else { return }
        isCaptureStarted = true
        lastAcceptedFrameHostTime = hostTime
        // The encoded size, not the source's: the disk estimate and the free-space rule must
        // describe what the tier actually writes.
        let encoded = OPNVideoSize.capped(width: width, height: height, maxHeight: configuration.maxHeight)
        lastRecordedWidth = encoded.width
        lastRecordedHeight = encoded.height
        updateAvailableSeconds(now: hostTime)
        emitState()
    }

    func appendAudioOnQueue(data: Data, frameCount: UInt32, sampleRate: Double, channels: UInt32, hostTime: CFTimeInterval) {
        guard isIngressOpen, let activeSegment else { return }
        _ = activeSegment.writer.appendAudio(data: data, frameCount: frameCount, sampleRate: sampleRate, channels: channels, hostTime: hostTime)
    }

    func startSegment(hostTime: CFTimeInterval, width: Int, height: Int, pixelFormat: OSType, beginsNewPeriod: Bool) {
        sealActiveSegment()
        if beginsNewPeriod { currentPeriodID += 1 }
        guard let configuration, let stagingDirectory else { return }
        let id = UUID()
        let url = stagingDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("mp4")
        let writer = StreamReplaySegmentWriter(
            outputURL: url,
            configuration: configuration.recording,
            pixelTransfer: pixelTransfer,
            originHostTime: hostTime,
            maxHeight: configuration.maxHeight,
            bitrateCeilingMbps: configuration.bitrateCeilingMbps
        )
        activeSegment = ActiveSegment(id: id, periodID: currentPeriodID, startHost: hostTime, width: width, height: height, pixelFormat: pixelFormat, writer: writer)
    }

    func sealActiveSegment() {
        guard let activeSegment else { return }
        self.activeSegment = nil
        let id = activeSegment.id
        let periodID = activeSegment.periodID
        activeSegment.writer.finish { [weak self] result in
            guard let self else { return }
            self.queue.async { self.segmentDidSeal(id: id, periodID: periodID, result: result) }
        }
    }

    func segmentDidSeal(id: UUID, periodID: UInt64, result: StreamReplaySegmentFinishResult) {
        if let pendingSave, pendingSave.sealedSegmentID == id, case .failed(let message) = result {
            failPendingSave(id: pendingSave.id, message: message)
            return
        }
        guard case .sealed(let sealed) = result else {
            // The segment the save was waiting on produced no frames. Whatever sealed before it is
            // still a clip, so the save proceeds with that rather than failing outright.
            if let pendingSave, pendingSave.sealedSegmentID == id {
                startExport(for: pendingSave)
            }
            completeRetentionIfPending()
            return
        }
        if sealed.hostEnd > sealed.hostStart {
            segments.append(StreamReplaySegment(
                id: id,
                url: sealed.url,
                periodID: periodID,
                hostStart: sealed.hostStart,
                hostEnd: sealed.hostEnd,
                width: sealed.width,
                height: sealed.height
            ))
        }
        if let pendingSave, pendingSave.sealedSegmentID == id {
            startExport(for: pendingSave)
        }
        guard !completeRetentionIfPending() else { return }
        if !checkFreeSpace() {
            performStop(pauseReason: "Not enough free disk space to keep Instant Replay running.")
            return
        }
        prune(now: CACurrentMediaTime())
    }

    /// Writes the retained window's manifest once its last segment has landed, and prunes the rest.
    /// True when a retention finished, so the caller skips bookkeeping for a dead ring.
    @discardableResult
    func completeRetentionIfPending() -> Bool {
        guard let retention = pendingRetention else { return false }
        pendingRetention = nil
        isRetentionPending = false
        guard let directory = stagingDirectoryToRemove else { return true }
        stagingDirectoryToRemove = nil
        guard !segments.isEmpty else {
            segments.removeAll()
            removeStagingDirectory(directory)
            return true
        }
        let ordered = segments.sorted { $0.hostStart < $1.hostStart }
        guard let first = ordered.first, let last = ordered.last else { return true }
        let durableDirectory = (try? StreamReplayRetentionLibrary.relocateForRetention(from: directory, to: retainedRoot)) ?? directory
        let window = StreamReplayRetainedWindow(
            id: UUID(),
            title: retention.title,
            applicationID: retention.applicationID,
            createdAt: Date(),
            startHostTime: first.hostStart,
            endHostTime: last.hostEnd,
            width: first.width,
            height: first.height,
            videoBitrateMbps: retention.videoBitrateMbps,
            audioBitrateKbps: retention.audioBitrateKbps,
            segments: ordered.map(retainedSegment(for:)),
            storageDirectoryPath: durableDirectory.path
        )
        segments.removeAll()
        try? StreamReplayRetentionLibrary.write(window)
        StreamReplayRetentionLibrary.prune(in: retainedRoot, budgetBytes: retention.retainedBudgetBytes)
        return true
    }

    /// The manifest's view of one ring segment: the file it points at, and the capture-clock span
    /// it covers.
    private func retainedSegment(for segment: StreamReplaySegment) -> StreamReplayRetainedWindow.Segment {
        StreamReplayRetainedWindow.Segment(
            fileName: segment.url.lastPathComponent,
            hostStart: segment.hostStart,
            hostEnd: segment.hostEnd
        )
    }

    // MARK: - Adoption

    /// A session starting on a title the reader already played picks that title's stored ring back
    /// up, so the window rolls across play sessions instead of resetting at each one.
    func adoptRetainedRing(into directory: URL, now: CFTimeInterval) {
        guard let configuration else { return }
        let encoded = OPNVideoSize.capped(width: configuration.recording.width, height: configuration.recording.height, maxHeight: configuration.maxHeight)
        guard let adopted = StreamReplayRetentionLibrary.claimForAdoption(
            applicationID: configuration.recording.applicationID,
            encodedWidth: encoded.width,
            encodedHeight: encoded.height,
            now: now,
            in: retainedRoot,
            into: directory
        ) else { return }
        segments = adopted
        prune(now: now)
        updateAvailableSeconds(now: now)
    }

    // MARK: - Pruning

    func prune(now: CFTimeInterval) {
        guard let configuration else { return }
        // A hard window: only segments that start inside it survive, so the ring can never hold more
        // than the reader asked for. Trimming is per segment, so it may sit up to one short of it.
        let cutoff = now - configuration.windowSeconds
        segments.removeAll { segment in
            guard !segment.isPinned, segment.hostStart < cutoff else { return false }
            try? FileManager.default.removeItem(at: segment.url)
            return true
        }
        pruneByByteBudget()
    }

    func pruneByByteBudget() {
        guard let configuration else { return }
        let budget = Int64(configuration.estimatedBufferBytes(width: max(1, lastRecordedWidth), height: max(1, lastRecordedHeight)))
        var totalBytes = segments.reduce(Int64(0)) { $0 + $1.url.fileSizeBytes } + (activeSegment?.writer.outputFileSizeBytes ?? 0)
        guard totalBytes > budget else { return }
        var retainedSegments: [StreamReplaySegment] = []
        for segment in segments.reversed() {
            if totalBytes > budget, !segment.isPinned {
                let size = segment.url.fileSizeBytes
                try? FileManager.default.removeItem(at: segment.url)
                totalBytes -= size
                continue
            }
            retainedSegments.append(segment)
        }
        segments = retainedSegments.reversed()
    }

    // MARK: - Teardown and staging

    func performStop(pauseReason: String?) {
        guard configuration != nil else { return }
        ingressLock.withLock {
            ingressGeneration = nil
            queuedFrameCount = 0
        }
        firstFrameTimeoutTask?.cancel()
        firstFrameTimeoutTask = nil
        let isActiveSegmentPresent = activeSegment != nil
        sealActiveSegment()
        // A session that adopted a title's ring and then produced nothing of its own would take the
        // earlier footage down with it, so the ring is kept: it was only ever earned by playing.
        let isRetaining = isRetentionPending || (!isCaptureStarted && !segments.isEmpty)
        if isRetaining, let configuration {
            pendingRetention = PendingRetention(
                title: configuration.recording.title,
                applicationID: configuration.recording.applicationID,
                videoBitrateMbps: configuration.recording.videoBitrateMbps,
                audioBitrateKbps: configuration.recording.audioBitrateKbps,
                retainedBudgetBytes: configuration.retainedBudgetBytes
            )
        }
        configuration = nil
        lastAcceptedFrameHostTime = nil
        let directory = stagingDirectory
        stagingDirectory = nil
        let keptClip = state.lastClip
        let isSaveStillRunning = pendingSave != nil
        state = StreamReplayBufferState()
        state.lastClip = keptClip
        state.pauseReason = pauseReason
        state.isSaving = isSaveStillRunning
        // A saved clip or a retained window both read the staging directory after this returns, so
        // only an ordinary stop takes it away here.
        let isDirectoryStillNeeded = isSaveStillRunning || isRetaining
        stagingDirectoryToRemove = isDirectoryStillNeeded ? directory : nil
        // Nothing was writing a segment, so no seal callback will arrive to finish the retention.
        if isRetaining, !isActiveSegmentPresent {
            completeRetentionIfPending()
        }
        if !isDirectoryStillNeeded {
            segments.removeAll()
            removeStagingDirectory(directory)
        }
        emitState(force: true)
    }

    func scheduleFirstFrameTimeout() {
        firstFrameTimeoutTask?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.configuration != nil, !self.isCaptureStarted else { return }
            self.performStop(pauseReason: "Instant Replay received no video from the stream.")
        }
        firstFrameTimeoutTask = item
        queue.asyncAfter(deadline: .now() + Self.firstFrameTimeout, execute: item)
    }

    /// The whole window plus the reserve. A ring that cannot hold its window would otherwise
    /// thrash against a full disk.
    func requiredFreeSpaceBytes() -> Int64 {
        guard let configuration else { return Self.minimumFreeBytes }
        return configuration.estimatedBufferBytes(width: max(1, lastRecordedWidth), height: max(1, lastRecordedHeight)) + Self.minimumFreeBytes
    }

    func checkFreeSpace() -> Bool {
        guard let stagingDirectory else { return true }
        let values = try? stagingDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return capacity > requiredFreeSpaceBytes()
    }

    func makeStagingDirectory() throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func writeOwnerMarker(in directory: URL) {
        let marker = directory.appendingPathComponent("owner.pid")
        try? Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: marker, options: .atomic)
    }

    /// Removes staging left by a process that is gone. A directory whose owning process is still
    /// running, or that holds a retained window, is never touched.
    func sweepOrphanedStagingDirectories() {
        let root = self.root
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        for entry in entries where !isRetainedWindow(entry) && isOrphanedStagingDirectory(entry) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// A retained window is the reader's footage until it expires, so age alone must not delete it;
    /// its manifest is what marks it protected from the sweep.
    private func isRetainedWindow(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(StreamReplayRetentionLibrary.manifestFileName).path)
    }

    private func isOrphanedStagingDirectory(_ directory: URL) -> Bool {
        let marker = directory.appendingPathComponent("owner.pid")
        guard let data = try? Data(contentsOf: marker),
              let text = String(data: data, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return modified.map { Date().timeIntervalSince($0) > 86_400 } ?? true
        }
        return kill(pid, 0) != 0
    }

    func removeStagingDirectory(_ directory: URL?) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// A stopped buffer keeps its staging until an in-flight export has finished reading it.
    func removeStagingDirectoryIfSettled() {
        guard pendingSave == nil, let directory = stagingDirectoryToRemove else { return }
        stagingDirectoryToRemove = nil
        segments.removeAll()
        removeStagingDirectory(directory)
    }
}
