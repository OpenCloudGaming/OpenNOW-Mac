//  Frame previews behind the editor's timeline clips. Without them a clip is a green rectangle
//  with a filename on it, and finding the moment to cut at means scrubbing the player and watching
//  the playhead rather than reading the timeline.
//

import AppKit
import AVFoundation
import SwiftUI

/// Decodes a batch of frames, spread across a few generators running at once.
///
/// One generator decoding ninety-six frames of a 5K source takes about two seconds; four of them
/// take four hundred milliseconds, and the machine has cores to spare. Each generator is driven by
/// exactly one task, so none of them is shared.
///
/// There is no generator cache and no actor guarding one. Both existed because opening the asset
/// was assumed to be expensive; measured, it is five to eight milliseconds - nothing against the
/// decode - and caching them cost a reentrancy hazard, a serialisation chain, and a lifetime to
/// get wrong.
private enum RecordingFilmstripDecoder {
    /// Enough to use the machine without thrashing it.
    private static var workerCount: Int {
        min(6, max(2, ProcessInfo.processInfo.activeProcessorCount / 3))
    }

    /// The recorder's keyframe interval. Frames closer together than this share a group of
    /// pictures, and how the work is split turns on that.
    private static let keyframeIntervalSeconds = 2.0

    /// Contiguous blocks when the frames are packed tighter than a keyframe interval, interleaved
    /// when they are not.
    ///
    /// Measured on a 5K capture: a zoomed window of thirty-two frames across eighteen seconds took
    /// 1492ms interleaved and 716ms contiguous, because interleaving makes every worker decode
    /// forward through the same groups of pictures. The whole-recording grid, six seconds apart, is
    /// the other way round - no group is shared, so interleaving only balances the load better.
    private static func split(_ times: [Double], workers: Int) -> [[Double]] {
        let sorted = times.sorted()
        guard workers > 1, sorted.count > 1 else { return [sorted] }
        let spacing = ((sorted.last ?? 0) - (sorted.first ?? 0)) / Double(sorted.count - 1)
        guard spacing < keyframeIntervalSeconds else {
            return (0..<workers).map { worker in
                sorted.enumerated().filter { $0.offset % workers == worker }.map(\.element)
            }
        }
        let perWorker = Int((Double(sorted.count) / Double(workers)).rounded(.up))
        return stride(from: 0, to: sorted.count, by: perWorker).map {
            Array(sorted[$0..<Swift.min($0 + perWorker, sorted.count)])
        }
    }

    static func images(
        url: URL,
        times: [Double],
        maximumSize: CGSize,
        toleranceSeconds: Double
    ) async -> [Double: NSImage] {
        guard !times.isEmpty else { return [:] }
        let groups = split(times, workers: min(workerCount, times.count))
        return await withTaskGroup(of: [Double: NSImage].self) { group in
            for slice in groups where !slice.isEmpty {
                group.addTask {
                    await decode(url: url, times: slice, maximumSize: maximumSize, toleranceSeconds: toleranceSeconds)
                }
            }
            var merged: [Double: NSImage] = [:]
            for await images in group { merged.merge(images) { current, _ in current } }
            return merged
        }
    }

    private static func decode(
        url: URL,
        times: [Double],
        maximumSize: CGSize,
        toleranceSeconds: Double
    ) async -> [Double: NSImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        // The recorder writes a keyframe every two seconds. A tolerance under that makes the
        // generator decode forward through a 5K group of pictures to reach the exact frame -
        // measured at 125ms each, against 22ms when it may serve the keyframe it lands on.
        let tolerance = CMTime(seconds: max(0, toleranceSeconds), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let sorted = times.sorted()
        var decoded: [Double: NSImage] = [:]
        guard !Task.isCancelled else { return [:] }
        for await result in generator.images(for: sorted.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
            // `for await` parks until the generator hands over the next image, so the loop also
            // tells it to stop rather than waiting out work nobody wants.
            if Task.isCancelled {
                generator.cancelAllCGImageGeneration()
                break
            }
            guard case .success(let requestedTime, let image, _) = result else { continue }
            let seconds = requestedTime.seconds
            // Map back to the value the caller asked for: the generator round-trips through a
            // timescale and need not hand back the identical Double.
            guard let match = sorted.min(by: { abs($0 - seconds) < abs($1 - seconds) }) else { continue }
            decoded[match] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        return decoded
    }
}

/// The strip's frame store: a coarse grid of the whole recording, plus a fine grid of whatever the
/// timeline is currently showing.
///
/// Built when the editor opens and kept until it closes. Everything a user does afterwards - trim,
/// split, remove, reorder - only changes *which* of these frames a clip shows, never which frames
/// have to exist, so those operations cost nothing. Zoom is the one thing that needs frames the
/// coarse grid does not have, and it gets a bounded window pass rather than a rebuild.
///
/// Two tiers because one is not affordable: a grid dense enough for maximum zoom across a
/// ten-minute recording is over two thousand frames, and decoded at a usable size that is more
/// than a gigabyte of images.
@MainActor
enum RecordingFilmstripLoader {
    /// Whole-recording grid. 512 frames at 128px tall is ~79MB and about a second of coverage per
    /// frame on a ten-minute clip.
    /// Sized for zoom 1 and nothing more. At zoom 1 a tile spans about fifty seconds of a
    /// ten-minute recording, so 512 frames was forty-six times what could be seen - six seconds of
    /// decoding before the strip stopped filling in, which is what read as "slow, keeps partially
    /// loading". The window pass covers the zoomed case, the only place finer frames are visible.
    private static let baseFrameLimit = 96
    private static let baseMinimumSpacing = 4.0
    private static let baseFrameHeight: CGFloat = 128
    /// Visible-window grid, decoded at the size a tile actually draws at.
    private static let windowFrameCount = 32
    private static let windowFrameHeight: CGFloat = 256
    /// The recorder writes a keyframe every two seconds, and a tolerance under that forces the
    /// generator to decode forward through a 5K GOP to reach the exact frame - measured at 125ms
    /// each against 22ms when it may serve the keyframe it lands on. The coarse grid is six seconds
    /// apart, so a second either way is invisible in it and not worth six times the wait.
    private static let baseToleranceSeconds = 2.0

    private static var base: [UUID: [RecordingFilmstripGridFrame]] = [:]
    /// Keyed by clip, not by recording: a split makes several clips of one source, and keyed by
    /// recording they cancelled each other's window pass in a loop and neither ever got fine frames.
    private static var window: [UUID: (range: ClosedRange<Double>, frames: [RecordingFilmstripGridFrame])] = [:]
    private static var baseBuilders: [UUID: Task<Void, Never>] = [:]
    private static var windowBuilders: [UUID: Task<Void, Never>] = [:]
    private static var interest = RecordingInterestCounter()

    // MARK: - Reading

    fileprivate static func baseGrid(for recordingID: UUID) -> [RecordingFilmstripGridFrame] {
        base[recordingID] ?? []
    }

    fileprivate static func windowGrid(forClip clipID: UUID) -> (range: ClosedRange<Double>, frames: [RecordingFilmstripGridFrame])? {
        window[clipID]
    }

    static func isBaseComplete(_ recordingID: UUID) -> Bool {
        baseBuilders[recordingID] == nil && base[recordingID] != nil
    }

    // MARK: - Lifetime

    /// Reference counted: several clips can share one recording, and the frames outlive any one of
    /// them but not the editor.
    static func retain(_ recording: WebRTCStreamRecording) {
        _ = interest.retain(recording.id)
        startBase(recording)
    }

    static func release(_ recordingID: UUID) {
        guard interest.release(recordingID) else { return }
        baseBuilders[recordingID]?.cancel()
        baseBuilders[recordingID] = nil
        windowBuilders[recordingID]?.cancel()
        windowBuilders[recordingID] = nil
        base[recordingID] = nil
        window[recordingID] = nil
    }

    // MARK: - Building

    private static func startBase(_ recording: WebRTCStreamRecording) {
        guard base[recording.id] == nil, baseBuilders[recording.id] == nil else { return }
        let id = recording.id
        let url = recording.videoURL
        let duration = max(recording.durationSeconds, 0.1)
        let size = decodeSize(for: recording, height: baseFrameHeight)
        let times = gridTimes(duration: duration, limit: baseFrameLimit, minimumSpacing: baseMinimumSpacing)
        base[id] = []
        baseBuilders[id] = Task {
            // In batches, so the strip fills in from the start of the recording rather than staying
            // empty until every frame is decoded.
            var collected: [RecordingFilmstripGridFrame] = []
            // Big enough that all four workers have something to do, small enough that the strip
            // still fills in visibly rather than appearing at the end.
            for batch in times.chunked(into: 32) {
                guard !Task.isCancelled else { return }
                let decoded = await RecordingFilmstripDecoder.images(
                    url: url, times: batch, maximumSize: size, toleranceSeconds: baseToleranceSeconds
                )
                guard !Task.isCancelled else { return }
                collected.append(contentsOf: decoded.map { RecordingFilmstripGridFrame(seconds: $0.key, image: $0.value) })
                collected.sort { $0.seconds < $1.seconds }
                base[id] = collected
            }
            baseBuilders[id] = nil
        }
    }

    /// Frames for exactly what the timeline is showing. Bounded and debounced by the caller, and
    /// re-run only when the visible range actually moves.
    static func refreshWindow(for recording: WebRTCStreamRecording, clipID: UUID, range: ClosedRange<Double>) {
        let id = clipID
        if let existing = window[id], existing.range == range { return }
        windowBuilders[id]?.cancel()
        let url = recording.videoURL
        let size = decodeSize(for: recording, height: windowFrameHeight)
        let span = max(0.01, range.upperBound - range.lowerBound)
        let times = (0..<windowFrameCount).map { range.lowerBound + (Double($0) + 0.5) * span / Double(windowFrameCount) }
        // Only as precise as the tiles can show. A shallow zoom spaces them seconds apart, where a
        // keyframe is as good as an exact frame and six times quicker to get; a deep zoom spaces
        // them tenths apart and has to pay for the forward decode.
        let tolerance = max(0.1, span / Double(windowFrameCount) / 2)
        windowBuilders[id] = Task {
            var collected: [RecordingFilmstripGridFrame] = []
            for batch in times.chunked(into: 32) {
                guard !Task.isCancelled else { return }
                let decoded = await RecordingFilmstripDecoder.images(
                    url: url, times: batch, maximumSize: size, toleranceSeconds: tolerance
                )
                guard !Task.isCancelled else { return }
                collected.append(contentsOf: decoded.map { RecordingFilmstripGridFrame(seconds: $0.key, image: $0.value) })
                collected.sort { $0.seconds < $1.seconds }
                window[id] = (range, collected)
            }
            windowBuilders[id] = nil
        }
    }

    static func clearWindow(forClip clipID: UUID) {
        windowBuilders[clipID]?.cancel()
        windowBuilders[clipID] = nil
        window[clipID] = nil
    }

    // MARK: - Helpers

    private static func decodeSize(for recording: WebRTCStreamRecording, height: CGFloat) -> CGSize {
        let aspect = recording.width > 0 && recording.height > 0
            ? CGFloat(recording.width) / CGFloat(recording.height)
            : 16.0 / 9.0
        return CGSize(width: (height * aspect).rounded(), height: height)
    }

    private static func gridTimes(duration: Double, limit: Int, minimumSpacing: Double) -> [Double] {
        let count = min(limit, max(8, Int(duration / minimumSpacing)))
        return (0..<count).map { (Double($0) + 0.5) * duration / Double(count) }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// One decoded frame of the whole-recording grid.
fileprivate struct RecordingFilmstripGridFrame {
    let seconds: Double
    let image: NSImage
}

struct RecordingFilmstripView: View {
    let recording: WebRTCStreamRecording
    /// The clip this strip belongs to. Two clips of one recording need their own window passes.
    let clipID: UUID
    let startSeconds: Double
    let endSeconds: Double
    let size: CGSize
    /// The clip's own share of the timeline. Only the visible part of a zoomed clip is worth fine
    /// frames, and this is how the strip knows what that is.
    var visibleRange: ClosedRange<Double>?

    /// How long the visible range has to hold still before decoding fine frames for it.
    private static let windowSettleDelay = Duration.milliseconds(300)

    @State private var baseFrames: [RecordingFilmstripGridFrame] = []
    @State private var windowFrames: [RecordingFilmstripGridFrame] = []

    private var sourceAspect: CGFloat {
        guard recording.width > 0, recording.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(recording.width) / CGFloat(recording.height)
    }

    private var naturalFrameWidth: CGFloat {
        min(max(size.height * sourceAspect, 24), 160)
    }

    private var frameCount: Int {
        min(max(Int((size.width / max(naturalFrameWidth, 1)).rounded(.up)), 1), 48)
    }

    /// Divided out of the container rather than taken from the source shape, so the tiles always
    /// span the clip however far it is zoomed.
    private var frameWidth: CGFloat {
        max(size.width / CGFloat(frameCount), 1)
    }

    private var frameTimes: [Double] {
        let span = max(0, endSeconds - startSeconds)
        guard span > 0 else { return [startSeconds] }
        return (0..<frameCount).map { startSeconds + (Double($0) + 0.5) * span / Double(frameCount) }
    }

    /// The fine window when it covers the tile, the coarse grid otherwise. Both are already
    /// decoded, so this is a lookup - which is what makes trimming, splitting and reordering free.
    private var tiles: [NSImage?] {
        frameTimes.map { target in
            nearest(in: windowFrames, to: target) ?? nearest(in: baseFrames, to: target)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, frame in
                Group {
                    if let frame {
                        Image(nsImage: frame)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: frameWidth, height: size.height)
                .clipped()
            }
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height, alignment: .leading)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: recording.id) { await followBaseGrid() }
        .task(id: windowKey) { await followWindowGrid() }
    }

    /// Bucketed to a tenth of a second so a drag does not restart the window pass on every frame.
    private var windowKey: String {
        guard let visibleRange else { return "none" }
        return "\(clipID.uuidString)|\(Int(visibleRange.lowerBound * 10))|\(Int(visibleRange.upperBound * 10))"
    }

    private func followBaseGrid() async {
        RecordingFilmstripLoader.retain(recording)
        defer { RecordingFilmstripLoader.release(recording.id) }
        await recordingPollUntilComplete(
            snapshot: { RecordingFilmstripLoader.baseGrid(for: recording.id) },
            isComplete: { RecordingFilmstripLoader.isBaseComplete(recording.id) },
            apply: { baseFrames = $0 }
        )
    }

    private func followWindowGrid() async {
        guard let visibleRange, visibleRange.upperBound > visibleRange.lowerBound else {
            windowFrames = []
            RecordingFilmstripLoader.clearWindow(forClip: clipID)
            return
        }
        try? await Task.sleep(for: Self.windowSettleDelay)
        guard !Task.isCancelled else { return }
        RecordingFilmstripLoader.refreshWindow(for: recording, clipID: clipID, range: visibleRange)
        await recordingPollUntilComplete(
            snapshot: { RecordingFilmstripLoader.windowGrid(forClip: clipID) },
            // The window pass has no completion flag: it is superseded by the next range rather
            // than finishing, and this task is cancelled when that happens.
            isComplete: { false },
            apply: { current in
                // Keep the frames already shown until the new range's arrive, rather than dropping
                // to the coarse grid the moment the range moves.
                if current?.range == visibleRange { windowFrames = current?.frames ?? [] }
            }
        )
    }

    private func nearest(in frames: [RecordingFilmstripGridFrame], to target: Double) -> NSImage? {
        recordingNearestIndex(in: frames, to: target, key: \.seconds).map { frames[$0].image }
    }
}
