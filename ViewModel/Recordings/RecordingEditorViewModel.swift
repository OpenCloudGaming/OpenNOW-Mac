import AVFoundation
import Combine
import Foundation

enum RecordingEditorDragPayload: Equatable {
    case recording(UUID)
    case segment(UUID)

    private static let recordingPrefix = "macforce-now-recording:"
    private static let segmentPrefix = "macforce-now-segment:"

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

    var crop: WebRTCStreamRecordingCrop? {
        switch self {
        case .full:
            return nil
        case .square:
            return WebRTCStreamRecordingCrop(x: 0.125, y: 0, width: 0.75, height: 1)
        case .wide:
            return WebRTCStreamRecordingCrop(x: 0, y: 0.1094, width: 1, height: 0.7812)
        case .vertical:
            return WebRTCStreamRecordingCrop(x: 0.3418, y: 0, width: 0.3164, height: 1)
        case .center:
            return WebRTCStreamRecordingCrop(x: 0.10, y: 0.10, width: 0.80, height: 0.80)
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

private struct RecordingEditorSnapshot {
    var outputTitle: String
    var segments: [RecordingEditorSegment]
    var selectedSegmentID: UUID?
    var cropX: Double
    var cropY: Double
    var cropWidth: Double
    var cropHeight: Double
    var cropEnabled: Bool
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
    private static let sectionJoinTolerance = 0.05

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
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress = 0.0
    @Published var errorMessage: String?

    private var undoStack: [RecordingEditorSnapshot] = []
    private var redoStack: [RecordingEditorSnapshot] = []

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

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var canExport: Bool { !isExporting && !segments.isEmpty && outputDurationSeconds > 0.05 }
    var canJoinSelectedSection: Bool { joinablePairContainingSelectedSegment() != nil }
    var previewSignature: String {
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
        let cropSignature = [
            cropEnabled ? "1" : "0",
            String(format: "%.4f", cropX),
            String(format: "%.4f", cropY),
            String(format: "%.4f", cropWidth),
            String(format: "%.4f", cropHeight),
        ].joined(separator: ":")
        let transformSignature = [String(rotation.rawValue), isFlippedHorizontally ? "1" : "0", isFlippedVertically ? "1" : "0"].joined(separator: ":")
        let audioSignature = [
            String(format: "%.4f", playbackRate),
            isMuted ? "1" : "0",
            String(format: "%.4f", volume),
            String(format: "%.4f", fadeInSeconds),
            String(format: "%.4f", fadeOutSeconds),
        ].joined(separator: ":")
        return [segmentSignature, cropSignature, transformSignature, audioSignature].joined(separator: "#")
    }

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
        cutRange(startSeconds: min(markInSeconds, markOutSeconds), endSeconds: max(markInSeconds, markOutSeconds))
        self.markInSeconds = nil
        self.markOutSeconds = nil
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
        let insertionIndex = pair.selectedIndex - [pair.leftIndex, pair.rightIndex].filter { $0 < pair.selectedIndex }.count
        recordUndo()
        let joined = RecordingEditorSegment(id: selectedID, recording: left.recording, startSeconds: left.startSeconds, endSeconds: right.endSeconds)
        for index in [pair.leftIndex, pair.rightIndex].sorted(by: >) {
            segments.remove(at: index)
        }
        segments.insert(joined, at: min(max(0, insertionIndex), segments.count))
        selectedSegmentID = joined.id
        markInSeconds = nil
        markOutSeconds = nil
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

    func applyCropPreset(_ preset: RecordingEditorCropPreset) {
        recordUndo()
        if let crop = preset.crop {
            cropEnabled = true
            cropX = crop.x
            cropY = crop.y
            cropWidth = crop.width
            cropHeight = crop.height
        } else {
            cropEnabled = false
            cropX = 0
            cropY = 0
            cropWidth = 1
            cropHeight = 1
        }
    }

    func rotateLeft() {
        recordUndo()
        rotation = WebRTCStreamRecordingRotation(rawValue: (rotation.rawValue + 270) % 360) ?? .degrees0
    }

    func rotateRight() {
        recordUndo()
        rotation = WebRTCStreamRecordingRotation(rawValue: (rotation.rawValue + 90) % 360) ?? .degrees0
    }

    func toggleHorizontalFlip() {
        recordUndo()
        isFlippedHorizontally.toggle()
    }

    func toggleVerticalFlip() {
        recordUndo()
        isFlippedVertically.toggle()
    }

    func resetEdits() {
        recordUndo()
        let segment = RecordingEditorSegment(recording: primaryRecording, startSeconds: 0, endSeconds: primaryRecording.durationSeconds)
        outputTitle = primaryRecording.title + " Edit"
        segments = [segment]
        selectedSegmentID = segment.id
        markInSeconds = nil
        markOutSeconds = nil
        cropEnabled = false
        cropX = 0
        cropY = 0
        cropWidth = 1
        cropHeight = 1
        rotation = .degrees0
        isFlippedHorizontally = false
        isFlippedVertically = false
        playbackRate = 1
        isMuted = false
        volume = 1
        fadeInSeconds = 0
        fadeOutSeconds = 0
        exportQuality = .highest
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(makeSnapshot())
        apply(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(makeSnapshot())
        apply(snapshot)
    }

    func request() -> WebRTCStreamRecordingEditRequest {
        WebRTCStreamRecordingEditRequest(
            title: outputTitle,
            segments: segments.map { WebRTCStreamRecordingEditSegment(recording: $0.recording, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds) },
            crop: cropEnabled ? WebRTCStreamRecordingCrop(x: cropX, y: cropY, width: cropWidth, height: cropHeight) : nil,
            rotation: rotation,
            isFlippedHorizontally: isFlippedHorizontally,
            isFlippedVertically: isFlippedVertically,
            playbackRate: playbackRate,
            audio: WebRTCStreamRecordingAudioEdit(volume: volume, isMuted: isMuted, fadeInSeconds: fadeInSeconds, fadeOutSeconds: fadeOutSeconds),
            exportPreset: exportQuality.preset
        )
    }

    func export() async throws -> WebRTCStreamRecording {
        guard !isExporting else { throw WebRTCStreamRecordingEditorError.exportFailed("An export is already running.") }
        isExporting = true
        exportProgress = 0
        errorMessage = nil
        do {
            let request = request()
            let recording = try await WebRTCStreamRecordingLibrary.exportEditedRecording(request) { [weak self] progress in
                self?.exportProgress = progress
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

    private func clampedPlayhead(_ playheadSeconds: Double) -> Double {
        guard let segment = selectedSegment else { return 0 }
        return min(max(segment.startSeconds, playheadSeconds), segment.endSeconds)
    }

    private func joinablePairContainingSelectedSegment() -> (leftIndex: Int, rightIndex: Int, selectedIndex: Int)? {
        guard let index = selectedSegmentIndex else { return nil }
        let selected = segments[index]
        if let previousSourceIndex = nearestJoinableIndex(to: index, matching: { canJoin(left: segments[$0], right: selected) }) {
            return (previousSourceIndex, index, index)
        }
        if let nextSourceIndex = nearestJoinableIndex(to: index, matching: { canJoin(left: selected, right: segments[$0]) }) {
            return (index, nextSourceIndex, index)
        }
        return nil
    }

    private func nearestJoinableIndex(to selectedIndex: Int, matching isJoinable: (Int) -> Bool) -> Int? {
        segments.indices
            .filter { $0 != selectedIndex && isJoinable($0) }
            .min { abs($0 - selectedIndex) < abs($1 - selectedIndex) }
    }

    private func canJoin(left: RecordingEditorSegment, right: RecordingEditorSegment) -> Bool {
        left.recording.id == right.recording.id && abs(left.endSeconds - right.startSeconds) <= Self.sectionJoinTolerance
    }

    private func recordUndo() {
        undoStack.append(makeSnapshot())
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func makeSnapshot() -> RecordingEditorSnapshot {
        RecordingEditorSnapshot(
            outputTitle: outputTitle,
            segments: segments,
            selectedSegmentID: selectedSegmentID,
            cropX: cropX,
            cropY: cropY,
            cropWidth: cropWidth,
            cropHeight: cropHeight,
            cropEnabled: cropEnabled,
            rotation: rotation,
            isFlippedHorizontally: isFlippedHorizontally,
            isFlippedVertically: isFlippedVertically,
            playbackRate: playbackRate,
            isMuted: isMuted,
            volume: volume,
            fadeInSeconds: fadeInSeconds,
            fadeOutSeconds: fadeOutSeconds,
            exportQuality: exportQuality
        )
    }

    private func apply(_ snapshot: RecordingEditorSnapshot) {
        outputTitle = snapshot.outputTitle
        segments = snapshot.segments
        selectedSegmentID = snapshot.selectedSegmentID
        cropX = snapshot.cropX
        cropY = snapshot.cropY
        cropWidth = snapshot.cropWidth
        cropHeight = snapshot.cropHeight
        cropEnabled = snapshot.cropEnabled
        rotation = snapshot.rotation
        isFlippedHorizontally = snapshot.isFlippedHorizontally
        isFlippedVertically = snapshot.isFlippedVertically
        playbackRate = snapshot.playbackRate
        isMuted = snapshot.isMuted
        volume = snapshot.volume
        fadeInSeconds = snapshot.fadeInSeconds
        fadeOutSeconds = snapshot.fadeOutSeconds
        exportQuality = snapshot.exportQuality
    }
}
