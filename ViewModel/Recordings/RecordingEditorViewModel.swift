import AVFoundation
import Combine
import Foundation

enum RecordingEditorDragPayload: Equatable {
    case recording(UUID)
    case segment(UUID)

    private static let recordingPrefix = "opennow-recording:"
    private static let segmentPrefix = "opennow-segment:"

    var stringValue: String {
        switch self {
        case .recording(let id): return Self.recordingPrefix + id.uuidString
        case .segment(let id): return Self.segmentPrefix + id.uuidString
        }
    }

    init?(stringValue: String) {
        if stringValue.hasPrefix(Self.recordingPrefix) {
            let value = String(stringValue.dropFirst(Self.recordingPrefix.count))
            guard let id = UUID(uuidString: value) else { return nil }
            self = .recording(id)
            return
        }
        if stringValue.hasPrefix(Self.segmentPrefix) {
            let value = String(stringValue.dropFirst(Self.segmentPrefix.count))
            guard let id = UUID(uuidString: value) else { return nil }
            self = .segment(id)
            return
        }
        return nil
    }
}

struct RecordingEditorSegment: Equatable, Identifiable {
    let id: UUID
    var recording: WebRTCStreamRecording
    var startSeconds: Double
    var endSeconds: Double

    init(id: UUID = UUID(), recording: WebRTCStreamRecording, startSeconds: Double, endSeconds: Double) {
        self.id = id
        self.recording = recording
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}

enum RecordingEditorCropPreset: String, CaseIterable, Identifiable {
    case full
    case square
    case wide
    case vertical
    case center

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: return "Full"
        case .square: return "1:1"
        case .wide: return "16:9"
        case .vertical: return "9:16"
        case .center: return "Center"
        }
    }

    /// The aspect ratio this preset is asking for, or nil for the ones that are not about a
    /// target shape.
    var targetAspect: Double? {
        switch self {
        case .full, .center: return nil
        case .square: return 1
        case .wide: return 16.0 / 9.0
        case .vertical: return 9.0 / 16.0
        }
    }

    /// Crop fractions are relative to the source frame, so the same numbers mean a different shape
    /// on a 16:9 capture than on the 21:9 ones this app records. They used to be hardcoded - "1:1"
    /// produced a 4:3 crop and "16:9" a 1.39:1 one - so the ratio is solved from the source instead.
    func crop(sourceAspect: Double) -> WebRTCStreamRecordingCrop? {
        let aspect = sourceAspect.isFinite && sourceAspect > 0 ? sourceAspect : 16.0 / 9.0
        switch self {
        case .full:
            return nil
        case .center:
            return WebRTCStreamRecordingCrop(x: 0.10, y: 0.10, width: 0.80, height: 0.80)
        case .square, .wide, .vertical:
            guard let target = targetAspect else { return nil }
            // width * aspect / height == target, holding whichever axis fits at full extent.
            let width = min(1, target / aspect)
            let height = min(1, aspect / target)
            return WebRTCStreamRecordingCrop(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
        }
    }
}

enum RecordingEditorExportQuality: String, CaseIterable, Identifiable {
    case highest
    case balanced
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .highest: return "Highest"
        case .balanced: return "Balanced"
        case .compact: return "Compact"
        }
    }

    var preset: WebRTCStreamRecordingExportPreset {
        switch self {
        case .highest: return .highestQuality
        case .balanced: return .balanced
        case .compact: return .compact
        }
    }
}

struct RecordingEditorSnapshot {
    var outputTitle: String
    var segments: [RecordingEditorSegment]
    var selectedSegmentID: UUID?
    var cropX: Double
    var cropY: Double
    var cropWidth: Double
    var cropHeight: Double
    var cropEnabled: Bool
    var isAdjustingCrop: Bool
    var rotation: WebRTCStreamRecordingRotation
    var isFlippedHorizontally: Bool
    var isFlippedVertically: Bool
    var playbackRate: Double
    var isMuted: Bool
    var volume: Double
    var fadeInSeconds: Double
    var fadeOutSeconds: Double
    var exportQuality: RecordingEditorExportQuality
}

@MainActor
final class RecordingEditorViewModel: ObservableObject {
    static let sectionJoinTolerance = 0.05

    let primaryRecording: WebRTCStreamRecording
    @Published var library: [WebRTCStreamRecording]
    @Published var outputTitle: String
    @Published var segments: [RecordingEditorSegment]
    @Published var selectedSegmentID: UUID?
    @Published var markInSeconds: Double?
    @Published var markOutSeconds: Double?
    @Published var cropX: Double = 0
    @Published var cropY: Double = 0
    @Published var cropWidth: Double = 1
    @Published var cropHeight: Double = 1
    @Published var cropEnabled = false
    @Published var rotation: WebRTCStreamRecordingRotation = .degrees0
    @Published var isFlippedHorizontally = false
    @Published var isFlippedVertically = false
    @Published var playbackRate = 1.0
    @Published var isMuted = false
    @Published var volume = 1.0
    @Published var fadeInSeconds = 0.0
    @Published var fadeOutSeconds = 0.0
    @Published var exportQuality: RecordingEditorExportQuality = .highest
    /// Owned here rather than by the view: the drawer changes how tall the editor needs to be, and
    /// the recordings page is what applies that height.
    @Published var showsAdvanced = false
    /// Which Advanced tab is open. On the view model because the drawer and the button that opens
    /// it now live in different views.
    @Published var advancedSection: RecordingAdvancedEditorSection = .arrange
    /// Set by the title field. A bare Backspace has to keep deleting characters while the name is
    /// being typed, so the Remove Selection shortcut stands down while it has focus.
    @Published var isTitleFieldFocused = false
    /// How much of the timeline the track shows: 1 is the whole thing. View state, deliberately
    /// not part of `previewSignature` - zooming does not change the video.
    @Published var timelineZoom = 1.0
    /// While true the preview shows the untouched source frame so the crop rectangle has something
    /// to be drawn against. See RecordingCropOverlay.
    @Published var isAdjustingCrop = false
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress = 0.0
    @Published var errorMessage: String?
    /// What the last structural edit did, in the terms the timeline now shows. Removing a range
    /// from the middle of a clip necessarily leaves two sections, which reads as an unwanted split
    /// unless something says otherwise.
    @Published var hint: String?

    var undoStack: [RecordingEditorSnapshot] = []
    var redoStack: [RecordingEditorSnapshot] = []
    /// Set by `recordCoalescedUndo` so a run of edits from the same control - typing a title - adds
    /// one undo step rather than one per keystroke.
    var coalescedUndoToken: String?

    init(recording: WebRTCStreamRecording, library: [WebRTCStreamRecording]) {
        primaryRecording = recording
        self.library = library
        outputTitle = recording.title + " Edit"
        let segment = RecordingEditorSegment(recording: recording, startSeconds: 0, endSeconds: max(0, recording.durationSeconds))
        segments = [segment]
        selectedSegmentID = segment.id
    }

    var selectedSegment: RecordingEditorSegment? {
        guard let selectedSegmentID else { return segments.first }
        return segments.first { $0.id == selectedSegmentID }
    }

    var selectedSegmentIndex: Int? {
        guard let selectedSegmentID else { return segments.indices.first }
        return segments.firstIndex { $0.id == selectedSegmentID }
    }

    var totalSourceDurationSeconds: Double {
        segments.reduce(0) { $0 + $1.durationSeconds }
    }

    var outputDurationSeconds: Double {
        totalSourceDurationSeconds / max(0.25, playbackRate)
    }

    /// The engine renders against the first clip's frame, so the crop presets have to solve against
    /// the same one.
    var sourceAspect: Double {
        let recording = segments.first?.recording ?? primaryRecording
        guard recording.width > 0, recording.height > 0 else { return 16.0 / 9.0 }
        return Double(recording.width) / Double(recording.height)
    }

    /// Mirrors the passthrough conditions the exporter applies, so the Export panel can say whether
    /// Highest will copy the source through or re-encode it.
    var isTrimOnlyEdit: Bool {
        guard !cropEnabled, rotation == .degrees0, !isFlippedHorizontally, !isFlippedVertically else { return false }
        guard abs(playbackRate - 1) <= 0.0001, !isMuted else { return false }
        guard abs(volume - 1) <= 0.0001, fadeInSeconds <= 0, fadeOutSeconds <= 0 else { return false }
        // Matches the exporter's passthrough rule exactly: one segment starting at the head of the
        // source. Anything else re-encodes, and claiming otherwise in the Export tab would be a lie.
        guard segments.count == 1, let only = segments.first else { return false }
        return only.startSeconds <= 0.0001
    }

    /// What the marked range covers, so Remove Selection says what it is about to remove.
    var markedRangeDescription: String? {
        guard hasMarkedRange, let markInSeconds, let markOutSeconds else { return nil }
        return String(format: "Selection %.1fs", abs(markOutSeconds - markInSeconds))
    }

    /// The pixel size the current crop produces, which is what a crop is really being chosen by.
    var croppedOutputDescription: String {
        let recording = segments.first?.recording ?? primaryRecording
        guard cropEnabled, recording.width > 0, recording.height > 0 else {
            return "\(recording.width)x\(recording.height)"
        }
        let width = max(2, Int((Double(recording.width) * cropWidth).rounded()))
        let height = max(2, Int((Double(recording.height) * cropHeight).rounded()))
        return "\(width)x\(height)"
    }

    var hasMarkedRange: Bool {
        guard let markInSeconds, let markOutSeconds else { return false }
        return abs(markOutSeconds - markInSeconds) > 0.05
    }

    var canRemoveSelectedSegment: Bool { segments.count > 1 && selectedSegmentIndex != nil }

    func canMoveSelectedSegment(offset: Int) -> Bool {
        guard let index = selectedSegmentIndex else { return false }
        return segments.indices.contains(index + offset)
    }

    /// Whether the current crop is the one this preset produces, so the row can show it selected.
    func isCropPresetActive(_ preset: RecordingEditorCropPreset) -> Bool {
        guard let crop = preset.crop(sourceAspect: sourceAspect) else { return !cropEnabled }
        guard cropEnabled else { return false }
        return abs(crop.x - cropX) < 0.005 && abs(crop.y - cropY) < 0.005
            && abs(crop.width - cropWidth) < 0.005 && abs(crop.height - cropHeight) < 0.005
    }

    func setAdjustingCrop(_ isAdjusting: Bool) {
        if isAdjusting, !cropEnabled {
            recordUndo()
            cropEnabled = true
        }
        isAdjustingCrop = isAdjusting
    }

    /// What the preview should show, which is not always what the export will produce: while the
    /// crop rectangle is up, the preview drops the crop and the orientation so the rectangle can be
    /// drawn over the original frame.
    func previewRequest() -> WebRTCStreamRecordingEditRequest {
        var previewRequest = request()
        guard isAdjustingCrop else { return previewRequest }
        previewRequest.crop = nil
        previewRequest.rotation = .degrees0
        previewRequest.isFlippedHorizontally = false
        previewRequest.isFlippedVertically = false
        return previewRequest
    }

    var canZoomTimelineIn: Bool { timelineZoom < RecordingTimelineGeometry.maximumZoom - 0.0001 }

    var canZoomTimelineOut: Bool { timelineZoom > RecordingTimelineGeometry.minimumZoom + 0.0001 }

    func zoomTimelineIn() {
        timelineZoom = min(RecordingTimelineGeometry.maximumZoom, timelineZoom * 2)
    }

    func zoomTimelineOut() {
        timelineZoom = max(RecordingTimelineGeometry.minimumZoom, timelineZoom / 2)
    }

    /// Continuous, for the scroll wheel. The buttons step in whole doublings; a wheel should not.
    func zoomTimeline(byFactor factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        timelineZoom = min(RecordingTimelineGeometry.maximumZoom, max(RecordingTimelineGeometry.minimumZoom, timelineZoom * factor))
    }

    func fitTimeline() {
        timelineZoom = RecordingTimelineGeometry.minimumZoom
    }

    /// What the track is showing, for the header. Says nothing at all when the whole timeline fits,
    /// because then the ruler already says it.
    var timelineWindowDescription: String? {
        guard timelineZoom > RecordingTimelineGeometry.minimumZoom + 0.0001 else { return nil }
        let visible = totalSourceDurationSeconds / timelineZoom
        return "showing \(String(format: "%.0f", visible))s of \(String(format: "%.0f", totalSourceDurationSeconds))s"
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var canExport: Bool { !isExporting && !segments.isEmpty && outputDurationSeconds > 0.05 }
    var canJoinSelectedSection: Bool { joinablePairContainingSelectedSegment() != nil }
    /// Three signatures, not one, because they cost wildly different amounts to apply. Only a
    /// timeline change needs the composition rebuilt; the other two are a property on the player
    /// item. Rebuilding for a volume slider reloaded every source asset and restarted playback.
    ///
    /// Playback rate lives in the timeline group: it is applied with `scaleTimeRange` on the
    /// composition's own tracks, not at render time.
    var timelineSignature: String {
        let segmentSignature = segments
            .map { segment in
                [
                    segment.id.uuidString,
                    segment.recording.id.uuidString,
                    String(format: "%.4f", segment.startSeconds),
                    String(format: "%.4f", segment.endSeconds),
                ].joined(separator: ":")
            }
            .joined(separator: "|")
        return [segmentSignature, String(format: "%.4f", playbackRate)].joined(separator: "@")
    }

    var frameSignature: String {
        [
            isAdjustingCrop ? "adjusting" : "applied",
            cropEnabled ? "1" : "0",
            String(format: "%.4f", cropX),
            String(format: "%.4f", cropY),
            String(format: "%.4f", cropWidth),
            String(format: "%.4f", cropHeight),
            String(rotation.rawValue),
            isFlippedHorizontally ? "1" : "0",
            isFlippedVertically ? "1" : "0",
        ].joined(separator: ":")
    }

    var audioSignature: String {
        [
            isMuted ? "1" : "0",
            String(format: "%.4f", volume),
            String(format: "%.4f", fadeInSeconds),
            String(format: "%.4f", fadeOutSeconds),
        ].joined(separator: ":")
    }

    var previewSignature: String {
        [timelineSignature, frameSignature, audioSignature].joined(separator: "#")
    }

    /// Anything worth warning about before the edit is thrown away. Every mutating path records an
    /// undo step, so an empty stack means nothing has been changed yet.
    var hasUnsavedEdits: Bool { !undoStack.isEmpty }

    func sourceTime(forTimelineSeconds timelineSeconds: Double) -> (segment: RecordingEditorSegment, seconds: Double)? {
        var cursor = 0.0
        let target = min(max(0, timelineSeconds), totalSourceDurationSeconds)
        for segment in segments {
            let nextCursor = cursor + segment.durationSeconds
            if target <= nextCursor || segment.id == segments.last?.id {
                return (segment, min(max(segment.startSeconds, segment.startSeconds + target - cursor), segment.endSeconds))
            }
            cursor = nextCursor
        }
        return nil
    }

    func selectSegment(_ segment: RecordingEditorSegment) {
        selectedSegmentID = segment.id
        markInSeconds = nil
        markOutSeconds = nil
    }

    /// Walks the timeline a clip at a time, for the pad: there is no cursor to click a clip with.
    func selectAdjacentSegment(offset: Int) {
        guard let index = selectedSegmentIndex else { return }
        let next = min(max(0, index + offset), max(0, segments.count - 1))
        guard next != index, segments.indices.contains(next) else { return }
        selectedSegmentID = segments[next].id
        markInSeconds = nil
        markOutSeconds = nil
    }

    func selectPreviewSegment(_ segment: RecordingEditorSegment) {
        if selectedSegmentID != segment.id { selectedSegmentID = segment.id }
    }

    func updateSelectedStart(_ value: Double) {
        guard let index = selectedSegmentIndex else { return }
        let segment = segments[index]
        let next = min(max(0, value), max(0, segment.endSeconds - 0.05))
        segments[index].startSeconds = next
    }

    func updateSelectedEnd(_ value: Double) {
        guard let index = selectedSegmentIndex else { return }
        let segment = segments[index]
        let next = max(min(segment.recording.durationSeconds, value), segment.startSeconds + 0.05)
        segments[index].endSeconds = next
    }

    func updateSegmentStart(_ segment: RecordingEditorSegment, seconds: Double) {
        selectedSegmentID = segment.id
        updateSelectedStart(seconds)
    }

    func updateSegmentEnd(_ segment: RecordingEditorSegment, seconds: Double) {
        selectedSegmentID = segment.id
        updateSelectedEnd(seconds)
    }

    func beginInteractiveEdit() {
        recordUndo()
    }

    func trimStartToPlayhead(_ playheadSeconds: Double) {
        guard let index = selectedSegmentIndex else { return }
        recordUndo()
        let segment = segments[index]
        segments[index].startSeconds = min(max(0, playheadSeconds), max(0, segment.endSeconds - 0.05))
    }

    func trimEndToPlayhead(_ playheadSeconds: Double) {
        guard let index = selectedSegmentIndex else { return }
        recordUndo()
        let segment = segments[index]
        segments[index].endSeconds = max(min(segment.recording.durationSeconds, playheadSeconds), segment.startSeconds + 0.05)
    }

    func markIn(_ playheadSeconds: Double) {
        markInSeconds = clampedPlayhead(playheadSeconds)
        if let markOutSeconds, let markInSeconds, markOutSeconds < markInSeconds {
            self.markOutSeconds = nil
        }
    }

    func markOut(_ playheadSeconds: Double) {
        markOutSeconds = clampedPlayhead(playheadSeconds)
        if let markInSeconds, let markOutSeconds, markInSeconds > markOutSeconds {
            self.markInSeconds = nil
        }
    }

    func cutMarkedRange() {
        guard let markInSeconds, let markOutSeconds else { return }
        let removed = abs(markOutSeconds - markInSeconds)
        let sectionsBefore = segments.count
        cutRange(startSeconds: min(markInSeconds, markOutSeconds), endSeconds: max(markInSeconds, markOutSeconds))
        self.markInSeconds = nil
        self.markOutSeconds = nil
        hint = segments.count > sectionsBefore
            ? String(format: "Removed %.1fs from the middle. The two sections play back to back - the export has no gap.", removed)
            : String(format: "Removed %.1fs.", removed)
    }

    func splitAtPlayhead(_ playheadSeconds: Double) {
        guard let index = selectedSegmentIndex else { return }
        let segment = segments[index]
        let split = min(max(segment.startSeconds + 0.05, playheadSeconds), segment.endSeconds - 0.05)
        guard split > segment.startSeconds, split < segment.endSeconds else { return }
        recordUndo()
        let left = RecordingEditorSegment(recording: segment.recording, startSeconds: segment.startSeconds, endSeconds: split)
        let right = RecordingEditorSegment(recording: segment.recording, startSeconds: split, endSeconds: segment.endSeconds)
        segments.replaceSubrange(index...index, with: [left, right])
        selectedSegmentID = right.id
        hint = "Split into two sections. Join puts them back together."
    }

    func cutRange(startSeconds: Double, endSeconds: Double) {
        guard let index = selectedSegmentIndex else { return }
        let segment = segments[index]
        let start = min(max(segment.startSeconds, startSeconds), segment.endSeconds)
        let end = max(min(segment.endSeconds, endSeconds), segment.startSeconds)
        guard end - start > 0.05 else { return }
        recordUndo()
        var replacements: [RecordingEditorSegment] = []
        if start - segment.startSeconds > 0.05 {
            replacements.append(RecordingEditorSegment(recording: segment.recording, startSeconds: segment.startSeconds, endSeconds: start))
        }
        if segment.endSeconds - end > 0.05 {
            replacements.append(RecordingEditorSegment(recording: segment.recording, startSeconds: end, endSeconds: segment.endSeconds))
        }
        segments.replaceSubrange(index...index, with: replacements)
        if let replacement = replacements.last {
            selectedSegmentID = replacement.id
        } else if segments.indices.contains(index) {
            selectedSegmentID = segments[index].id
        } else {
            selectedSegmentID = segments.first?.id
        }
    }

    func appendRecording(_ recording: WebRTCStreamRecording) {
        guard recording.durationSeconds > 0 else { return }
        recordUndo()
        let segment = RecordingEditorSegment(recording: recording, startSeconds: 0, endSeconds: recording.durationSeconds)
        segments.append(segment)
        selectedSegmentID = segment.id
    }

    func appendRecording(_ recording: WebRTCStreamRecording, at insertionIndex: Int) {
        guard recording.durationSeconds > 0 else { return }
        recordUndo()
        let segment = RecordingEditorSegment(recording: recording, startSeconds: 0, endSeconds: recording.durationSeconds)
        segments.insert(segment, at: min(max(0, insertionIndex), segments.count))
        selectedSegmentID = segment.id
    }

    func handleDropPayload(_ payload: String, at insertionIndex: Int) -> Bool {
        guard let payload = RecordingEditorDragPayload(stringValue: payload) else { return false }
        switch payload {
        case .recording(let id):
            guard let recording = library.first(where: { $0.id == id }) else { return false }
            appendRecording(recording, at: insertionIndex)
            return true
        case .segment(let id):
            return moveSegment(id: id, to: insertionIndex)
        }
    }

    @discardableResult
    func moveSegment(id: UUID, to insertionIndex: Int) -> Bool {
        guard let currentIndex = segments.firstIndex(where: { $0.id == id }) else { return false }
        let boundedIndex = min(max(0, insertionIndex), segments.count)
        var adjustedIndex = boundedIndex
        if currentIndex < boundedIndex { adjustedIndex -= 1 }
        guard currentIndex != adjustedIndex, currentIndex + 1 != boundedIndex else { return false }
        recordUndo()
        let segment = segments.remove(at: currentIndex)
        segments.insert(segment, at: min(max(0, adjustedIndex), segments.count))
        selectedSegmentID = segment.id
        return true
    }

    func joinSelectedSection() {
        guard let pair = joinablePairContainingSelectedSegment() else { return }
        let left = segments[pair.leftIndex]
        let right = segments[pair.rightIndex]
        let selectedID = segments[pair.selectedIndex].id
        let insertionIndex = pair.leftIndex
        recordUndo()
        let joined = RecordingEditorSegment(id: selectedID, recording: left.recording, startSeconds: left.startSeconds, endSeconds: right.endSeconds)
        for index in [pair.leftIndex, pair.rightIndex].sorted(by: >) {
            segments.remove(at: index)
        }
        segments.insert(joined, at: min(max(0, insertionIndex), segments.count))
        selectedSegmentID = joined.id
        markInSeconds = nil
        markOutSeconds = nil
        hint = "Merged back into one section."
    }

    func duplicateSelectedSegment() {
        guard let index = selectedSegmentIndex else { return }
        recordUndo()
        let segment = segments[index]
        let duplicate = RecordingEditorSegment(recording: segment.recording, startSeconds: segment.startSeconds, endSeconds: segment.endSeconds)
        segments.insert(duplicate, at: segments.index(after: index))
        selectedSegmentID = duplicate.id
    }

    func removeSelectedSegment() {
        guard let index = selectedSegmentIndex, segments.count > 1 else { return }
        recordUndo()
        segments.remove(at: index)
        selectedSegmentID = segments.indices.contains(index) ? segments[index].id : segments.last?.id
    }

    func moveSelectedSegment(offset: Int) {
        guard let index = selectedSegmentIndex else { return }
        let nextIndex = index + offset
        guard segments.indices.contains(nextIndex) else { return }
        recordUndo()
        segments.swapAt(index, nextIndex)
    }

    func export() async throws -> WebRTCStreamRecording {
        guard !isExporting else { throw WebRTCStreamRecordingEditorError.exportFailed("An export is already running.") }
        isExporting = true
        exportProgress = 0
        errorMessage = nil
        do {
            let request = request()
            let recording = try await WebRTCStreamRecordingLibrary.exportEditedRecording(request) { [weak self] progress in
                // Published only when the number on screen would actually change. Every publish
                // re-evaluates the editor's whole body - timeline, filmstrips, waveform canvas - and
                // at the raw update rate that competed with the encoder for the machine.
                guard let self else { return }
                guard Int(progress * 100) != Int(self.exportProgress * 100) else { return }
                self.exportProgress = progress
            }
            isExporting = false
            exportProgress = 1
            return recording
        } catch {
            isExporting = false
            errorMessage = error.localizedDescription
            throw error
        }
    }
}
