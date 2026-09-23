//  Turns a run of sealed replay segments into one playable clip: laid onto an `AVMutableComposition`
//  back to back and exported as a pass-through copy, since every segment opens on a keyframe.
//

import AVFoundation
import CoreMedia
import Foundation

struct StreamReplayClipExportRequest: Sendable {
    /// Sealed segments of one capture period, oldest first, all written at the same encoded shape.
    let segments: [StreamReplaySegment]
    let cutHostTime: CFTimeInterval
    /// How much of the buffer's tail this clip takes.
    let clipSeconds: Double
    let outputDirectory: URL
    let title: String
    let applicationID: String
    let videoBitrateMbps: Int
    let audioBitrateKbps: Int
}

enum StreamReplayClipExportError: LocalizedError, Equatable {
    case emptyWindow
    case unreadableWindow
    case videoTrackUnavailable(String)
    case noKeyframe(String)
    case unsupportedSourceFormat
    case writerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .emptyWindow:
            return "There was no buffered video to save."
        case .unreadableWindow:
            return "The replay's footage could not be read."
        case .videoTrackUnavailable(let file):
            return "A replay segment could not be read (\(file))."
        case .noKeyframe(let file):
            return "A replay segment had no decodable keyframe (\(file))."
        case .unsupportedSourceFormat:
            return "The replay segments did not share one video format."
        case .writerUnavailable(let message):
            return "The replay clip could not be saved: \(message)"
        }
    }
}

/// A segment with its tracks already loaded off the async API, so the export queue never touches the
/// deprecated synchronous accessors. Read-only, one queue at a time.
private struct StreamReplayLoadedSegment: @unchecked Sendable {
    let asset: AVURLAsset
    let videoTrack: AVAssetTrack
    let audioTrack: AVAssetTrack?
    let videoTimeRange: CMTimeRange
    let audioTimeRange: CMTimeRange?
}

enum StreamReplayClipExporter {
    /// How far before the requested start a keyframe is looked for. The replay writer places one
    /// every second, so this is generous.
    static let keyframeSearchWindowSeconds: Double = 5

    static func export(_ request: StreamReplayClipExportRequest) async throws -> StreamRecording {
        let requestedStart = request.cutHostTime - request.clipSeconds
        let selected = request.segments.filter { $0.hostEnd > requestedStart }
        guard let firstSegment = selected.first else { throw StreamReplayClipExportError.emptyWindow }

        let loaded = try await loadSegments(selected.map(\.url))
        guard let firstLoaded = loaded.first else { throw StreamReplayClipExportError.emptyWindow }

        let firstOffset = max(0, requestedStart - firstSegment.hostStart)
        let alignment = try firstKeyframe(in: firstLoaded, atOrBefore: firstOffset)
        let clipOriginHost = firstSegment.hostStart + alignment.time.seconds
        guard alignment.time.seconds.isFinite, clipOriginHost < request.cutHostTime else {
            throw StreamReplayClipExportError.emptyWindow
        }
        let clipDurationSeconds = request.cutHostTime - clipOriginHost

        let outputURL = request.outputDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: outputURL)
        let composition = try buildComposition(loaded: loaded, firstAlignment: alignment.time)
        let exportedSeconds = try await exportComposition(composition, requestedDuration: clipDurationSeconds, to: outputURL)
        return try writeRecording(
            title: request.title,
            applicationID: request.applicationID,
            createdAt: Date(),
            durationSeconds: exportedSeconds,
            width: firstSegment.width,
            height: firstSegment.height,
            videoBitrateMbps: request.videoBitrateMbps,
            audioBitrateKbps: request.audioBitrateKbps,
            outputURL: outputURL
        )
    }

    /// Saves a whole retained window, for the recordings screen's Keep. Nothing is trimmed: the
    /// reader kept the window precisely to decide afterwards.
    static func exportRetainedWindow(_ window: StreamReplayRetainedWindow) async throws -> StreamRecording {
        let urls = window.segmentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { throw StreamReplayClipExportError.emptyWindow }
        let loaded = try await loadSegments(urls)

        let outputDirectory: URL
        do {
            outputDirectory = try StreamRecordingLibrary.ensureDirectory(forGameTitle: window.title)
        } catch {
            throw StreamReplayClipExportError.writerUnavailable(error.localizedDescription)
        }
        let outputURL = outputDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: outputURL)
        let composition = try buildComposition(loaded: loaded, firstAlignment: .zero)
        let exportedSeconds = try await exportComposition(composition, requestedDuration: composition.duration.seconds, to: outputURL)
        return try writeRecording(
            title: window.title,
            applicationID: window.applicationID,
            createdAt: Date(),
            durationSeconds: exportedSeconds,
            width: window.width,
            height: window.height,
            videoBitrateMbps: window.videoBitrateMbps,
            audioBitrateKbps: window.audioBitrateKbps,
            outputURL: outputURL
        )
    }

    /// The file and its sidecar. The metadata goes down second, so a failure leaves an orphan the
    /// next library scan filters out rather than metadata pointing at nothing.
    private static func writeRecording(title: String,
                                       applicationID: String,
                                       createdAt: Date,
                                       durationSeconds: Double,
                                       width: Int,
                                       height: Int,
                                       videoBitrateMbps: Int,
                                       audioBitrateKbps: Int,
                                       outputURL: URL) throws -> StreamRecording {
        let fileSize = outputURL.fileSizeBytes
        let recording = StreamRecording(
            id: UUID(),
            title: title.isEmpty ? "GeForce NOW Replay" : title,
            applicationID: applicationID,
            createdAt: createdAt,
            durationSeconds: durationSeconds,
            width: width,
            height: height,
            videoBitrateMbps: videoBitrateMbps,
            audioBitrateKbps: audioBitrateKbps,
            enhancedVideo: false,
            fileName: outputURL.lastPathComponent,
            fileSizeBytes: fileSize,
            storageDirectoryPath: outputURL.deletingLastPathComponent().path
        )
        do {
            let data = try JSONEncoder.recordingEncoder.encode(recording)
            try data.write(to: recording.metadataURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw StreamReplayClipExportError.writerUnavailable(error.localizedDescription)
        }
        return recording
    }

    // MARK: - Loading

    private static func loadSegments(_ urls: [URL]) async throws -> [StreamReplayLoadedSegment] {
        var loaded: [StreamReplayLoadedSegment] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            do {
                guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                    throw StreamReplayClipExportError.videoTrackUnavailable(url.lastPathComponent)
                }
                let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
                loaded.append(StreamReplayLoadedSegment(
                    asset: asset,
                    videoTrack: videoTrack,
                    audioTrack: audioTrack,
                    videoTimeRange: try await videoTrack.load(.timeRange),
                    audioTimeRange: try await audioTrack?.load(.timeRange)
                ))
            } catch let error as StreamReplayClipExportError {
                throw error
            } catch {
                throw StreamReplayClipExportError.videoTrackUnavailable(url.lastPathComponent)
            }
        }
        return loaded
    }

    /// The keyframe that opens the clip: the last sync sample at or before the requested start, or
    /// the first one after it when the request lands before the first keyframe.
    private static func firstKeyframe(in loadedSegment: StreamReplayLoadedSegment, atOrBefore target: Double) throws -> (time: CMTime, format: CMFormatDescription?) {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: loadedSegment.asset)
        } catch {
            throw StreamReplayClipExportError.videoTrackUnavailable(loadedSegment.asset.url.lastPathComponent)
        }
        let output = AVAssetReaderTrackOutput(track: loadedSegment.videoTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw StreamReplayClipExportError.videoTrackUnavailable(loadedSegment.asset.url.lastPathComponent) }
        reader.add(output)
        let searchStart = max(0, target - keyframeSearchWindowSeconds)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: searchStart, preferredTimescale: 600),
                                       duration: CMTime(seconds: keyframeSearchWindowSeconds * 2, preferredTimescale: 600))
        guard reader.startReading() else {
            throw StreamReplayClipExportError.videoTrackUnavailable(loadedSegment.asset.url.lastPathComponent)
        }

        var lastKeyframeAtOrBefore: CMTime?
        var firstKeyframeAfter: CMTime?
        var firstFormat: CMFormatDescription?
        while let sample = output.copyNextSampleBuffer() {
            if firstFormat == nil { firstFormat = CMSampleBufferGetFormatDescription(sample) }
            guard isSyncSample(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if time.seconds <= target + 0.0005 {
                lastKeyframeAtOrBefore = time
                continue
            }
            if firstKeyframeAfter == nil { firstKeyframeAfter = time }
        }
        guard let time = lastKeyframeAtOrBefore ?? firstKeyframeAfter else {
            throw StreamReplayClipExportError.noKeyframe(loadedSegment.asset.url.lastPathComponent)
        }
        return (time, firstFormat)
    }

    private static func isSyncSample(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]] else { return true }
        guard let attachment = attachments.first else { return true }
        return !(attachment[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    // MARK: - Composition

    /// Lays the segments back to back on one video and one audio track. The clip's clock is the
    /// capture clock, so anything the buffer's own timeline dropped stays dropped.
    private static func buildComposition(loaded: [StreamReplayLoadedSegment], firstAlignment: CMTime) throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StreamReplayClipExportError.unsupportedSourceFormat
        }
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero

        for (index, loadedSegment) in loaded.enumerated() {
            let requestedStart = index == 0 ? firstAlignment : .zero
            guard let videoRange = clampedRange(start: requestedStart, timeRange: loadedSegment.videoTimeRange) else { continue }
            do {
                try videoTrack.insertTimeRange(videoRange, of: loadedSegment.videoTrack, at: cursor)
            } catch {
                throw StreamReplayClipExportError.writerUnavailable(error.localizedDescription)
            }
            if let sourceAudio = loadedSegment.audioTrack,
               let audioCompositionTrack = audioTrack,
               let audioRange = audioRange(forVideoRange: videoRange, requestedStart: requestedStart, audioTimeRange: loadedSegment.audioTimeRange) {
                try? audioCompositionTrack.insertTimeRange(audioRange, of: sourceAudio, at: cursor)
            }
            cursor = CMTimeAdd(cursor, videoRange.duration)
        }
        return composition
    }

    private static func clampedRange(start: CMTime, timeRange: CMTimeRange) -> CMTimeRange? {
        let clampedStart = max(start, timeRange.start)
        let end = timeRange.end
        guard end > clampedStart else { return nil }
        return CMTimeRange(start: clampedStart, duration: CMTimeSubtract(end, clampedStart))
    }

    /// The audio that belongs beside a video range: the overlap of the two, or nothing when they do
    /// not meet.
    private static func audioRange(forVideoRange videoRange: CMTimeRange, requestedStart: CMTime, audioTimeRange: CMTimeRange?) -> CMTimeRange? {
        guard let audioTimeRange else { return nil }
        let audioStart = max(requestedStart, audioTimeRange.start)
        let audioEnd = min(requestedStart + videoRange.duration, audioTimeRange.end)
        guard audioEnd > audioStart else { return nil }
        return CMTimeRange(start: audioStart, duration: audioEnd - audioStart)
    }

    /// Exports the composed timeline, trimming its tail to the requested window. Pass-through keeps
    /// the encoded samples; a source the container refuses is re-encoded rather than failing.
    private static func exportComposition(_ composition: AVMutableComposition, requestedDuration: Double, to outputURL: URL) async throws -> Double {
        let composedSeconds = composition.duration.seconds
        let exportSeconds = max(0, min(composedSeconds, requestedDuration))
        guard exportSeconds > 0 else { throw StreamReplayClipExportError.emptyWindow }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
            ?? AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw StreamReplayClipExportError.writerUnavailable("No export session was available for the clip.")
        }
        guard let fileType = session.supportedFileTypes.contains(.mp4) ? AVFileType.mp4 : session.supportedFileTypes.first else {
            throw StreamReplayClipExportError.writerUnavailable("The clip's container was not supported.")
        }
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: exportSeconds, preferredTimescale: 600))
        session.shouldOptimizeForNetworkUse = false
        do {
            try await session.export(to: outputURL, as: fileType)
        } catch {
            throw StreamReplayClipExportError.writerUnavailable(message(for: error))
        }
        return exportSeconds
    }

    private static func message(for error: Error?) -> String {
        guard let error else { return "no further detail" }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }
}
