//  Audio peaks under the editor's timeline clips. Most cuts are made to a sound - a shot, a line,
//  the moment a car lands - and without a waveform the only way to find one is to scrub and listen.
//

import AVFoundation
import SwiftUI

/// Peaks for a whole recording, computed once and sliced per clip. Reading is done at 8 kHz mono:
/// this drives a few hundred pixels of bar chart, and decoding 48 kHz stereo to draw it would cost
/// six times as much for no visible difference.
/// Peaks for a whole recording, read once and shared. Reading is done at 8 kHz mono: this drives a
/// few hundred pixels of bar chart, and decoding 48 kHz stereo to draw it would cost six times as
/// much for no visible difference.
///
/// Partial results are published as the read progresses. Decoding ten minutes of audio out of a
/// multi-gigabyte file takes seconds, and waiting for all of it before drawing anything looked like
/// the waveform was simply not there.
@MainActor
enum RecordingWaveformLoader {
    /// Buckets across the whole recording. A clip showing ten seconds of a ten-minute source still
    /// gets ~33 of them, which is enough to see where the loud part is.
    static let bucketCount = 2000

    private static var completed: [UUID: [Float]] = [:]
    private static var partial: [UUID: [Float]] = [:]
    private static var readers: [UUID: Task<Void, Never>] = [:]
    private static var interest = RecordingInterestCounter()

    /// Whatever has been read so far, complete or not.
    static func snapshot(for recordingID: UUID) -> [Float] {
        completed[recordingID] ?? partial[recordingID] ?? []
    }

    static func isComplete(_ recordingID: UUID) -> Bool {
        completed[recordingID] != nil
    }

    /// Reference counted like the filmstrip's store, for the same reasons: the read outlives any
    /// one clip but not the editor. Without this the `AVAssetReader` kept decoding a forty-minute
    /// audio track after the editor had closed, and the peaks stayed resident for every recording
    /// opened in the life of the process.
    static func retain(_ recording: WebRTCStreamRecording) {
        _ = interest.retain(recording.id)
        startLoading(recording)
    }

    static func release(_ recordingID: UUID) {
        guard interest.release(recordingID) else { return }
        readers[recordingID]?.cancel()
        readers[recordingID] = nil
        completed[recordingID] = nil
        partial[recordingID] = nil
    }

    /// Idempotent: several clips of one recording share a single read.
    private static func startLoading(_ recording: WebRTCStreamRecording) {
        guard completed[recording.id] == nil, readers[recording.id] == nil else { return }
        let id = recording.id
        let url = recording.videoURL
        readers[id] = Task {
            let peaks = await readPeaks(url: url, bucketCount: bucketCount) { progressPeaks in
                Task { @MainActor in partial[id] = progressPeaks }
            }
            completed[id] = peaks
            partial[id] = nil
            readers[id] = nil
        }
    }

    nonisolated private static func readPeaks(
        url: URL,
        bucketCount: Int,
        onProgress: @escaping @Sendable ([Float]) -> Void
    ) async -> [Float] {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                  let reader = try? AVAssetReader(asset: asset) else { return [] }
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 8000,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return [] }
            reader.add(output)
            guard reader.startReading() else { return [] }

            let duration = (try? await asset.load(.duration).seconds) ?? 0
            guard duration > 0 else { return [] }
            let samplesPerBucket = max(1, Int((8000 * duration / Double(bucketCount)).rounded()))

            var peaks: [Float] = []
            peaks.reserveCapacity(bucketCount)
            var bucketPeak: Float = 0
            var bucketSamples = 0
            var lastPublished = 0

            while let sampleBuffer = output.copyNextSampleBuffer() {
                if Task.isCancelled { reader.cancelReading(); return peaks }
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                var lengthAtOffset = 0
                var totalLength = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
                      let dataPointer else { continue }
                dataPointer.withMemoryRebound(to: Float.self, capacity: totalLength / MemoryLayout<Float>.size) { samples in
                    for index in 0..<(totalLength / MemoryLayout<Float>.size) {
                        bucketPeak = max(bucketPeak, abs(samples[index]))
                        bucketSamples += 1
                        if bucketSamples >= samplesPerBucket {
                            peaks.append(bucketPeak)
                            bucketPeak = 0
                            bucketSamples = 0
                        }
                    }
                }
                // Roughly every twentieth of the strip, so the bars grow visibly rather than
                // appearing all at once when the whole file has been decoded.
                if peaks.count - lastPublished >= bucketCount / 20 {
                    lastPublished = peaks.count
                    onProgress(peaks)
                }
            }
            if bucketSamples > 0 { peaks.append(bucketPeak) }
            return peaks
        }.value
    }
}

struct RecordingWaveformView: View {
    let recording: WebRTCStreamRecording
    let startSeconds: Double
    let endSeconds: Double
    let size: CGSize

    @State private var peaks: [Float] = []

    var body: some View {
        Canvas { context, canvasSize in
            let bars = visiblePeaks(width: canvasSize.width)
            guard !bars.isEmpty else { return }
            let barWidth = canvasSize.width / CGFloat(bars.count)
            let midY = canvasSize.height / 2
            var path = Path()
            for (index, peak) in bars.enumerated() {
                let height = max(1, CGFloat(peak) * canvasSize.height)
                let x = CGFloat(index) * barWidth
                path.addRect(CGRect(x: x, y: midY - height / 2, width: max(0.5, barWidth - 0.5), height: height))
            }
            context.fill(path, with: .color(OpenNOWDesign.accent.opacity(0.55)))
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: recording.id) {
            RecordingWaveformLoader.retain(recording)
            defer { RecordingWaveformLoader.release(recording.id) }
            await recordingPollUntilComplete(
                snapshot: { RecordingWaveformLoader.snapshot(for: recording.id) },
                isComplete: { RecordingWaveformLoader.isComplete(recording.id) },
                apply: { peaks = $0 }
            )
        }
    }

    /// The clip's slice of the whole-recording peaks, resampled to roughly one bar every two
    /// points. Slicing rather than re-reading is what makes trimming free.
    private func visiblePeaks(width: CGFloat) -> [Float] {
        guard !peaks.isEmpty, recording.durationSeconds > 0, width > 1 else { return [] }
        let total = Double(RecordingWaveformLoader.bucketCount)
        let first = Int((startSeconds / recording.durationSeconds * total).rounded(.down))
        let last = Int((endSeconds / recording.durationSeconds * total).rounded(.up))
        let lower = min(max(0, first), peaks.count - 1)
        let upper = min(max(lower + 1, last), peaks.count)
        let slice = Array(peaks[lower..<upper])
        let barCount = min(max(Int(width / 2), 1), slice.count)
        let resampled: [Float]
        if barCount < slice.count {
            resampled = (0..<barCount).map { index in
                let start = index * slice.count / barCount
                let end = max(start + 1, (index + 1) * slice.count / barCount)
                return slice[start..<end].max() ?? 0
            }
        } else {
            resampled = slice
        }
        return scaled(resampled)
    }

    /// Scaled against this clip's own loud-but-not-peak level rather than the file's single
    /// loudest sample. Gameplay capture has occasional transients an order of magnitude above the
    /// rest, and dividing by those drew every other bar as a flat line.
    private func scaled(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return values }
        let sorted = values.sorted()
        let reference = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        guard reference > 0.0001 else { return values.map { _ in 0 } }
        // A gentle curve, because loudness is not linear and a strictly linear bar chart of game
        // audio is mostly empty space.
        return values.map { min(1, powf($0 / reference, 0.7)) }
    }
}
