//  Using a retained replay window: watching the ring before deciding what to do with it, and
//  opening it in the quick editor as one prepared timeline.
//

import AVFoundation
import Foundation

@MainActor
enum RetainedReplayEditing {
    /// The ring as one timeline: one clip per segment file, in capture order, so a trim cuts across
    /// the whole window rather than only its last file.
    static func clips(for window: StreamReplayRetainedWindow) async -> [RecordingEditorSegment] {
        var clips: [RecordingEditorSegment] = []
        for ringSegment in window.segments.sorted(by: { $0.hostStart < $1.hostStart }) {
            let fileURL = window.directoryURL.appendingPathComponent(ringSegment.fileName)
            guard let seconds = await durationSeconds(of: fileURL), seconds > 0 else { continue }
            clips.append(RecordingEditorSegment(
                recording: recording(in: window, fileName: ringSegment.fileName, durationSeconds: seconds, fileSizeBytes: fileURL.fileSizeBytes),
                startSeconds: 0,
                endSeconds: seconds
            ))
        }
        return clips
    }

    /// The window as a single recording, for a header that needs a title and an encoded shape. Its
    /// file name is arbitrary: nothing plays this, the pane is handed the ring's composition.
    static func windowRecording(_ window: StreamReplayRetainedWindow) -> StreamRecording {
        recording(in: window, fileName: window.segments.first?.fileName ?? "", durationSeconds: window.durationSeconds, fileSizeBytes: window.fileSizeBytes)
    }

    /// The editor over the ring, or nil when none of its segment files can be read.
    static func makeEditor(for window: StreamReplayRetainedWindow, library: [StreamRecording]) async -> RecordingEditorViewModel? {
        let clips = await clips(for: window)
        guard !clips.isEmpty else { return nil }
        return RecordingEditorViewModel(
            primaryRecording: windowRecording(window),
            initialSegments: clips,
            library: library,
            outputTitle: "\(window.title) Clip"
        )
    }

    /// A read-only composition of the whole ring, for watching a window before deciding: the same
    /// timeline an edit would start from, with nothing to save yet.
    static func makeWatchComposition(for window: StreamReplayRetainedWindow) async throws -> StreamRecordingPreview {
        let clips = await clips(for: window)
        guard !clips.isEmpty else { throw StreamReplayClipExportError.unreadableWindow }
        let request = StreamRecordingEditRequest(
            title: window.title,
            segments: clips.map { StreamRecordingEditSegment(recording: $0.recording, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds) }
        )
        return try await StreamRecordingLibrary.previewEditedRecording(request)
    }

    /// Every clip carries the window's encoded shape, since a ring is only ever adopted by a session
    /// that still matches it. Only the file and the length differ per clip.
    private static func recording(in window: StreamReplayRetainedWindow,
                                  fileName: String,
                                  durationSeconds: Double,
                                  fileSizeBytes: Int64) -> StreamRecording {
        StreamRecording(
            id: UUID(),
            title: window.title,
            applicationID: window.applicationID,
            createdAt: window.createdAt,
            durationSeconds: durationSeconds,
            width: window.width,
            height: window.height,
            videoBitrateMbps: window.videoBitrateMbps,
            audioBitrateKbps: window.audioBitrateKbps,
            enhancedVideo: false,
            fileName: fileName,
            fileSizeBytes: fileSizeBytes,
            storageDirectoryPath: window.directoryURL.path
        )
    }

    /// The file's own length, not the manifest's host span: the editor's trim bounds and the
    /// exporter's range check are both measured against the file.
    private static func durationSeconds(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
