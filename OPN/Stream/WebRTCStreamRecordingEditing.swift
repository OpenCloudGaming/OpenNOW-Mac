@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

public struct WebRTCStreamRecordingEditSegment: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var recording: WebRTCStreamRecording
    public var startSeconds: Double
    public var endSeconds: Double

    public init(id: UUID = UUID(), recording: WebRTCStreamRecording, startSeconds: Double, endSeconds: Double) {
        self.id = id
        self.recording = recording
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    public var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}

public struct WebRTCStreamRecordingCrop: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let fullFrame = WebRTCStreamRecordingCrop(x: 0, y: 0, width: 1, height: 1)

    var isFullFrame: Bool {
        abs(x) <= 0.0001 && abs(y) <= 0.0001 && abs(width - 1) <= 0.0001 && abs(height - 1) <= 0.0001
    }
}

public enum WebRTCStreamRecordingRotation: Int, CaseIterable, Sendable {
    case degrees0 = 0
    case degrees90 = 90
    case degrees180 = 180
    case degrees270 = 270

    public var quarterTurns: Int { rawValue / 90 }
}

public enum WebRTCStreamRecordingExportPreset: String, CaseIterable, Sendable {
    case highestQuality
    case balanced
    case compact
}

public struct WebRTCStreamRecordingAudioEdit: Equatable, Sendable {
    public var volume: Double
    public var isMuted: Bool
    public var fadeInSeconds: Double
    public var fadeOutSeconds: Double

    public init(volume: Double = 1, isMuted: Bool = false, fadeInSeconds: Double = 0, fadeOutSeconds: Double = 0) {
        self.volume = volume
        self.isMuted = isMuted
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
    }

    public static let original = WebRTCStreamRecordingAudioEdit()
}

public struct WebRTCStreamRecordingPreview: @unchecked Sendable {
    public let asset: AVAsset
    public let audioMix: AVAudioMix?
    public let videoComposition: AVVideoComposition?
    public let durationSeconds: Double

    public init(asset: AVAsset, audioMix: AVAudioMix?, videoComposition: AVVideoComposition?, durationSeconds: Double) {
        self.asset = asset
        self.audioMix = audioMix
        self.videoComposition = videoComposition
        self.durationSeconds = durationSeconds
    }
}

public struct WebRTCStreamRecordingEditRequest: Sendable {
    public var title: String
    public var segments: [WebRTCStreamRecordingEditSegment]
    public var crop: WebRTCStreamRecordingCrop?
    public var rotation: WebRTCStreamRecordingRotation
    public var isFlippedHorizontally: Bool
    public var isFlippedVertically: Bool
    public var playbackRate: Double
    public var audio: WebRTCStreamRecordingAudioEdit
    public var exportPreset: WebRTCStreamRecordingExportPreset

    public init(title: String, segments: [WebRTCStreamRecordingEditSegment], crop: WebRTCStreamRecordingCrop? = nil, rotation: WebRTCStreamRecordingRotation = .degrees0, isFlippedHorizontally: Bool = false, isFlippedVertically: Bool = false, playbackRate: Double = 1, audio: WebRTCStreamRecordingAudioEdit = .original, exportPreset: WebRTCStreamRecordingExportPreset = .highestQuality) {
        self.title = title
        self.segments = segments
        self.crop = crop
        self.rotation = rotation
        self.isFlippedHorizontally = isFlippedHorizontally
        self.isFlippedVertically = isFlippedVertically
        self.playbackRate = playbackRate
        self.audio = audio
        self.exportPreset = exportPreset
    }
}

public enum WebRTCStreamRecordingEditorError: LocalizedError, Equatable {
    case emptyTimeline
    case missingSourceFile(String)
    case invalidTimeRange(String)
    case invalidCrop
    case invalidPlaybackRate
    case noVideoTrack(String)
    case unableToCreateCompositionTrack
    case unableToCreateExportSession
    case unsupportedExportType
    case exportCancelled
    case exportFailed(String)
    case invalidExportedFile

    public var errorDescription: String? {
        switch self {
        case .emptyTimeline:
            return "Add at least one clip segment before exporting."
        case .missingSourceFile(let fileName):
            return "The source recording file is missing: \(fileName)."
        case .invalidTimeRange(let fileName):
            return "The edit range is outside the source recording: \(fileName)."
        case .invalidCrop:
            return "The crop area must stay inside the video frame."
        case .invalidPlaybackRate:
            return "Playback speed must be between 0.25x and 4x."
        case .noVideoTrack(let fileName):
            return "The source recording has no video track: \(fileName)."
        case .unableToCreateCompositionTrack:
            return "Unable to prepare the edited video timeline."
        case .unableToCreateExportSession:
            return "Unable to start the video export session."
        case .unsupportedExportType:
            return "The selected export preset cannot create an MP4 video."
        case .exportCancelled:
            return "Video export was cancelled."
        case .exportFailed(let message):
            return message.isEmpty ? "Video export failed." : message
        case .invalidExportedFile:
            return "The exported video file could not be validated."
        }
    }
}

private struct WebRTCStreamRecordingLoadedSegment {
    let segment: WebRTCStreamRecordingEditSegment
    let asset: AVURLAsset
    let duration: CMTime
    let videoTrack: AVAssetTrack
    let audioTrack: AVAssetTrack?
    let displaySize: CGSize
    let preferredTransform: CGAffineTransform
}

private struct WebRTCStreamRecordingTimelineBuildResult {
    let composition: AVMutableComposition
    let duration: CMTime
    let firstRecording: WebRTCStreamRecording
    let renderSize: CGSize
}

private final class WebRTCStreamRecordingExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(session: AVAssetExportSession) {
        self.session = session
    }
}

public extension WebRTCStreamRecordingLibrary {
    static func previewEditedRecording(_ request: WebRTCStreamRecordingEditRequest) async throws -> WebRTCStreamRecordingPreview {
        let normalizedRequest = try validate(request)
        let loadedSegments = try await loadSegments(normalizedRequest.segments)
        let build = try buildTimeline(from: loadedSegments, request: normalizedRequest)
        let previewAudioMix = audioMix(for: build.composition, request: normalizedRequest, duration: build.duration)
        let previewVideoComposition = needsVideoComposition(normalizedRequest, loadedSegments: loadedSegments)
            ? try await videoComposition(for: build.composition, request: normalizedRequest, renderSize: build.renderSize)
            : nil
        return WebRTCStreamRecordingPreview(
            asset: build.composition,
            audioMix: previewAudioMix,
            videoComposition: previewVideoComposition,
            durationSeconds: max(0, build.duration.seconds)
        )
    }

    static func exportEditedRecording(_ request: WebRTCStreamRecordingEditRequest, progressHandler: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> WebRTCStreamRecording {
        let normalizedRequest = try validate(request)
        let outputID = UUID()
        let outputDirectory = try ensureDirectory(forGameTitle: normalizedRequest.title)
        let outputURL = outputDirectory.appendingPathComponent(outputID.uuidString).appendingPathExtension("mp4")
        let metadataURL = outputDirectory.appendingPathComponent(outputID.uuidString).appendingPathExtension("json")
        try removeIfExists(outputURL)
        try removeIfExists(metadataURL)
        do {
            let loadedSegments = try await loadSegments(normalizedRequest.segments)
            let build = try buildTimeline(from: loadedSegments, request: normalizedRequest)
            let presetName = await compatiblePreset(for: normalizedRequest.exportPreset, asset: build.composition)
            guard let exportSession = AVAssetExportSession(asset: build.composition, presetName: presetName) else { throw WebRTCStreamRecordingEditorError.unableToCreateExportSession }
            exportSession.outputURL = outputURL
            exportSession.outputFileType = try compatibleMP4FileType(for: exportSession)
            exportSession.shouldOptimizeForNetworkUse = false
            exportSession.timeRange = CMTimeRange(start: .zero, duration: build.duration)
            exportSession.audioMix = audioMix(for: build.composition, request: normalizedRequest, duration: build.duration)
            if needsVideoComposition(normalizedRequest, loadedSegments: loadedSegments) {
                exportSession.videoComposition = try await videoComposition(for: build.composition, request: normalizedRequest, renderSize: build.renderSize)
            }
            await progressHandler?(0)
            try await runExportSession(exportSession, progressHandler: progressHandler)
            await progressHandler?(1)
            let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard fileSize > 0 else { throw WebRTCStreamRecordingEditorError.invalidExportedFile }
            let dimensions = try await exportedVideoDimensions(at: outputURL, fallback: build.renderSize)
            let durationSeconds = try await exportedDurationSeconds(at: outputURL, fallback: build.duration.seconds)
            let recording = WebRTCStreamRecording(
                id: outputID,
                title: normalizedRequest.title,
                applicationID: build.firstRecording.applicationID,
                createdAt: Date(),
                durationSeconds: durationSeconds,
                width: dimensions.width,
                height: dimensions.height,
                videoBitrateMbps: bitrateForExportPreset(normalizedRequest.exportPreset, source: build.firstRecording),
                audioBitrateKbps: normalizedRequest.audio.isMuted ? 0 : build.firstRecording.audioBitrateKbps,
                enhancedVideo: build.firstRecording.enhancedVideo,
                fileName: outputURL.lastPathComponent,
                fileSizeBytes: fileSize,
                storageDirectoryPath: outputDirectory.path
            )
            let data = try JSONEncoder.recordingEncoder.encode(recording)
            try data.write(to: metadataURL, options: .atomic)
            return recording
        } catch {
            try? removeIfExists(outputURL)
            try? removeIfExists(metadataURL)
            throw error
        }
    }

    private static func validate(_ request: WebRTCStreamRecordingEditRequest) throws -> WebRTCStreamRecordingEditRequest {
        guard !request.segments.isEmpty else { throw WebRTCStreamRecordingEditorError.emptyTimeline }
        guard request.playbackRate.isFinite, request.playbackRate >= 0.25, request.playbackRate <= 4 else { throw WebRTCStreamRecordingEditorError.invalidPlaybackRate }
        if let crop = request.crop, !crop.isFullFrame {
            guard crop.x.isFinite, crop.y.isFinite, crop.width.isFinite, crop.height.isFinite,
                  crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0,
                  crop.x + crop.width <= 1.0001, crop.y + crop.height <= 1.0001 else { throw WebRTCStreamRecordingEditorError.invalidCrop }
        }
        let cleanedTitle = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalized = request
        normalized.title = cleanedTitle.isEmpty ? request.segments[0].recording.title + " Edit" : cleanedTitle
        normalized.playbackRate = min(max(request.playbackRate, 0.25), 4)
        normalized.audio.volume = min(max(request.audio.volume.isFinite ? request.audio.volume : 1, 0), 2)
        normalized.audio.fadeInSeconds = max(0, request.audio.fadeInSeconds.isFinite ? request.audio.fadeInSeconds : 0)
        normalized.audio.fadeOutSeconds = max(0, request.audio.fadeOutSeconds.isFinite ? request.audio.fadeOutSeconds : 0)
        return normalized
    }

    private static func loadSegments(_ segments: [WebRTCStreamRecordingEditSegment]) async throws -> [WebRTCStreamRecordingLoadedSegment] {
        var loadedSegments: [WebRTCStreamRecordingLoadedSegment] = []
        loadedSegments.reserveCapacity(segments.count)
        for segment in segments {
            let url = segment.recording.videoURL
            guard FileManager.default.fileExists(atPath: url.path) else { throw WebRTCStreamRecordingEditorError.missingSourceFile(url.lastPathComponent) }
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else { throw WebRTCStreamRecordingEditorError.noVideoTrack(url.lastPathComponent) }
            let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let displaySize = displaySize(naturalSize: naturalSize, preferredTransform: preferredTransform)
            guard segment.startSeconds.isFinite, segment.endSeconds.isFinite, segment.startSeconds >= 0, segment.endSeconds > segment.startSeconds else { throw WebRTCStreamRecordingEditorError.invalidTimeRange(url.lastPathComponent) }
            guard segment.endSeconds <= duration.seconds + 0.05 else { throw WebRTCStreamRecordingEditorError.invalidTimeRange(url.lastPathComponent) }
            loadedSegments.append(WebRTCStreamRecordingLoadedSegment(segment: segment, asset: asset, duration: duration, videoTrack: videoTrack, audioTrack: audioTrack, displaySize: displaySize, preferredTransform: preferredTransform))
        }
        return loadedSegments
    }

    private static func buildTimeline(from loadedSegments: [WebRTCStreamRecordingLoadedSegment], request: WebRTCStreamRecordingEditRequest) throws -> WebRTCStreamRecordingTimelineBuildResult {
        guard let firstSegment = loadedSegments.first else { throw WebRTCStreamRecordingEditorError.emptyTimeline }
        let composition = AVMutableComposition()
        guard let videoCompositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw WebRTCStreamRecordingEditorError.unableToCreateCompositionTrack }
        let audioCompositionTrack = loadedSegments.contains { $0.audioTrack != nil } ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        videoCompositionTrack.preferredTransform = firstSegment.preferredTransform
        var cursor = CMTime.zero
        for loadedSegment in loadedSegments {
            let sourceStart = CMTime(seconds: loadedSegment.segment.startSeconds, preferredTimescale: 600)
            let sourceEnd = CMTime(seconds: loadedSegment.segment.endSeconds, preferredTimescale: 600)
            let sourceDuration = CMTimeSubtract(sourceEnd, sourceStart)
            let sourceRange = CMTimeRange(start: sourceStart, duration: sourceDuration)
            try videoCompositionTrack.insertTimeRange(sourceRange, of: loadedSegment.videoTrack, at: cursor)
            if let audioTrack = loadedSegment.audioTrack, let audioCompositionTrack {
                try audioCompositionTrack.insertTimeRange(sourceRange, of: audioTrack, at: cursor)
            }
            let insertedRange = CMTimeRange(start: cursor, duration: sourceDuration)
            let scaledDuration = CMTimeMultiplyByFloat64(sourceDuration, multiplier: 1 / request.playbackRate)
            if abs(request.playbackRate - 1) > 0.0001 {
                videoCompositionTrack.scaleTimeRange(insertedRange, toDuration: scaledDuration)
                audioCompositionTrack?.scaleTimeRange(insertedRange, toDuration: scaledDuration)
            }
            cursor = CMTimeAdd(cursor, scaledDuration)
        }
        let renderSize = renderSize(for: firstSegment.displaySize, request: request)
        return WebRTCStreamRecordingTimelineBuildResult(composition: composition, duration: cursor, firstRecording: firstSegment.segment.recording, renderSize: renderSize)
    }

    private static func videoComposition(for composition: AVMutableComposition, request: WebRTCStreamRecordingEditRequest, renderSize: CGSize) async throws -> AVMutableVideoComposition {
        let videoComposition = try await AVMutableVideoComposition.videoComposition(
            with: composition,
            applyingCIFiltersWithHandler: { filterRequest in
                let sourceExtent = filterRequest.sourceImage.extent
                let crop = request.crop ?? .fullFrame
                let cropRect = cropRect(for: sourceExtent, crop: crop)
                var image = filterRequest.sourceImage.cropped(to: cropRect).transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
                let croppedExtent = CGRect(origin: .zero, size: cropRect.size)
                if request.isFlippedHorizontally {
                    image = image.transformed(by: CGAffineTransform(translationX: croppedExtent.width, y: 0).scaledBy(x: -1, y: 1))
                }
                if request.isFlippedVertically {
                    image = image.transformed(by: CGAffineTransform(translationX: 0, y: croppedExtent.height).scaledBy(x: 1, y: -1))
                }
                image = rotatedImage(image, rotation: request.rotation, sourceSize: croppedExtent.size)
                let rotatedExtent = CGRect(origin: .zero, size: rotatedSize(croppedExtent.size, rotation: request.rotation))
                let scale = min(renderSize.width / max(rotatedExtent.width, 1), renderSize.height / max(rotatedExtent.height, 1))
                let scaledWidth = rotatedExtent.width * scale
                let scaledHeight = rotatedExtent.height * scale
                let x = (renderSize.width - scaledWidth) / 2
                let y = (renderSize.height - scaledHeight) / 2
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: x / max(scale, 0.0001), y: y / max(scale, 0.0001)))
                filterRequest.finish(with: image.cropped(to: CGRect(origin: .zero, size: renderSize)), context: nil)
            }
        )
        videoComposition.renderSize = normalizedRenderSize(renderSize)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        return videoComposition
    }

    private static func audioMix(for composition: AVMutableComposition, request: WebRTCStreamRecordingEditRequest, duration: CMTime) -> AVAudioMix? {
        guard let audioTrack = composition.tracks(withMediaType: .audio).first else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
        let volume = Float(request.audio.isMuted ? 0 : request.audio.volume)
        parameters.setVolume(volume, at: .zero)
        if !request.audio.isMuted, request.audio.fadeInSeconds > 0 {
            let fadeDuration = CMTime(seconds: min(request.audio.fadeInSeconds, max(0, duration.seconds)), preferredTimescale: 600)
            parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume, timeRange: CMTimeRange(start: .zero, duration: fadeDuration))
        }
        if !request.audio.isMuted, request.audio.fadeOutSeconds > 0 {
            let fadeDurationSeconds = min(request.audio.fadeOutSeconds, max(0, duration.seconds))
            let fadeDuration = CMTime(seconds: fadeDurationSeconds, preferredTimescale: 600)
            let start = CMTimeMaximum(.zero, CMTimeSubtract(duration, fadeDuration))
            parameters.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0, timeRange: CMTimeRange(start: start, duration: fadeDuration))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    private static func runExportSession(_ exportSession: AVAssetExportSession, progressHandler: (@MainActor @Sendable (Double) -> Void)?) async throws {
        let box = WebRTCStreamRecordingExportSessionBox(session: exportSession)
        let progressTask = Task.detached(priority: .utility) {
            for await state in box.session.states(updateInterval: 0.15) {
                switch state {
                case .waiting, .exporting:
                    await progressHandler?(Double(box.session.progress))
                default:
                    break
                }
            }
        }
        defer { progressTask.cancel() }
        try await withTaskCancellationHandler {
            guard let outputURL = box.session.outputURL, let outputFileType = box.session.outputFileType else {
                throw WebRTCStreamRecordingEditorError.unableToCreateExportSession
            }
            do {
                try await box.session.export(to: outputURL, as: outputFileType)
            } catch {
                if Task.isCancelled {
                    throw WebRTCStreamRecordingEditorError.exportCancelled
                }
                throw WebRTCStreamRecordingEditorError.exportFailed(error.localizedDescription)
            }
        } onCancel: {
            box.session.cancelExport()
        }
    }

    private static func needsVideoComposition(_ request: WebRTCStreamRecordingEditRequest, loadedSegments: [WebRTCStreamRecordingLoadedSegment]) -> Bool {
        if let crop = request.crop, !crop.isFullFrame { return true }
        if request.rotation != .degrees0 || request.isFlippedHorizontally || request.isFlippedVertically { return true }
        let firstSize = loadedSegments.first?.displaySize ?? .zero
        return loadedSegments.contains { abs($0.displaySize.width - firstSize.width) > 1 || abs($0.displaySize.height - firstSize.height) > 1 }
    }

    private static func compatiblePreset(for exportPreset: WebRTCStreamRecordingExportPreset, asset: AVAsset) async -> String {
        let preferred: [String]
        switch exportPreset {
        case .highestQuality:
            preferred = [AVAssetExportPresetHighestQuality, AVAssetExportPresetHEVCHighestQuality, AVAssetExportPreset1920x1080]
        case .balanced:
            preferred = [AVAssetExportPreset1920x1080, AVAssetExportPresetMediumQuality, AVAssetExportPresetHighestQuality]
        case .compact:
            preferred = [AVAssetExportPreset1280x720, AVAssetExportPreset960x540, AVAssetExportPresetLowQuality, AVAssetExportPresetMediumQuality]
        }
        for preset in preferred {
            if await isPresetCompatible(preset, asset: asset) { return preset }
        }
        return AVAssetExportPresetHighestQuality
    }

    private static func isPresetCompatible(_ preset: String, asset: AVAsset) async -> Bool {
        await withCheckedContinuation { continuation in
            AVAssetExportSession.determineCompatibility(ofExportPreset: preset, with: asset, outputFileType: .mp4) { compatible in
                continuation.resume(returning: compatible)
            }
        }
    }

    private static func compatibleMP4FileType(for exportSession: AVAssetExportSession) throws -> AVFileType {
        if exportSession.supportedFileTypes.contains(.mp4) { return .mp4 }
        if let fileType = exportSession.supportedFileTypes.first { return fileType }
        throw WebRTCStreamRecordingEditorError.unsupportedExportType
    }

    private static func exportedVideoDimensions(at url: URL, fallback: CGSize) async throws -> (width: Int, height: Int) {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { return (max(1, Int(fallback.width.rounded())), max(1, Int(fallback.height.rounded()))) }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let size = displaySize(naturalSize: naturalSize, preferredTransform: preferredTransform)
        return (max(1, Int(size.width.rounded())), max(1, Int(size.height.rounded())))
    }

    private static func exportedDurationSeconds(at url: URL, fallback: Double) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return duration.seconds.isFinite && duration.seconds > 0 ? duration.seconds : fallback
    }

    private static func displaySize(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let width = abs(transformed.width)
        let height = abs(transformed.height)
        return CGSize(width: max(1, width), height: max(1, height))
    }

    private static func renderSize(for sourceSize: CGSize, request: WebRTCStreamRecordingEditRequest) -> CGSize {
        let crop = request.crop ?? .fullFrame
        let croppedSize = CGSize(width: sourceSize.width * max(0.01, crop.width), height: sourceSize.height * max(0.01, crop.height))
        return normalizedRenderSize(rotatedSize(croppedSize, rotation: request.rotation))
    }

    private static func normalizedRenderSize(_ size: CGSize) -> CGSize {
        let width = max(16, Int(size.width.rounded(.toNearestOrAwayFromZero)))
        let height = max(16, Int(size.height.rounded(.toNearestOrAwayFromZero)))
        return CGSize(width: width + width % 2, height: height + height % 2)
    }

    private static func cropRect(for extent: CGRect, crop: WebRTCStreamRecordingCrop) -> CGRect {
        guard !crop.isFullFrame else { return extent }
        return CGRect(
            x: extent.minX + extent.width * crop.x,
            y: extent.minY + extent.height * crop.y,
            width: extent.width * crop.width,
            height: extent.height * crop.height
        )
    }

    private static func rotatedSize(_ size: CGSize, rotation: WebRTCStreamRecordingRotation) -> CGSize {
        rotation == .degrees90 || rotation == .degrees270 ? CGSize(width: size.height, height: size.width) : size
    }

    private static func rotatedImage(_ image: CIImage, rotation: WebRTCStreamRecordingRotation, sourceSize: CGSize) -> CIImage {
        switch rotation {
        case .degrees0:
            return image
        case .degrees90:
            return image.transformed(by: CGAffineTransform(translationX: sourceSize.height, y: 0).rotated(by: .pi / 2))
        case .degrees180:
            return image.transformed(by: CGAffineTransform(translationX: sourceSize.width, y: sourceSize.height).rotated(by: .pi))
        case .degrees270:
            return image.transformed(by: CGAffineTransform(translationX: 0, y: sourceSize.width).rotated(by: -.pi / 2))
        }
    }

    private static func bitrateForExportPreset(_ preset: WebRTCStreamRecordingExportPreset, source: WebRTCStreamRecording) -> Int {
        switch preset {
        case .highestQuality:
            return source.videoBitrateMbps
        case .balanced:
            return source.videoBitrateMbps == 0 ? 0 : max(4, min(source.videoBitrateMbps, 18))
        case .compact:
            return source.videoBitrateMbps == 0 ? 0 : max(2, min(source.videoBitrateMbps, 8))
        }
    }

    private static func removeIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
