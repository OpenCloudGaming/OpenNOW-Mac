//
//  RecordingEditorTransforms.swift
//  OpenNOW
//
//  Frame transforms (crop, rotate, flip), undo/redo, and turning the edit into an export
//  request. Split out of RecordingEditorViewModel.swift.
//

import AVFoundation
import Combine
import Foundation

extension RecordingEditorViewModel {
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


    func clampedPlayhead(_ playheadSeconds: Double) -> Double {
        guard let segment = selectedSegment else { return 0 }
        return min(max(segment.startSeconds, playheadSeconds), segment.endSeconds)
    }

    func joinablePairContainingSelectedSegment() -> (leftIndex: Int, rightIndex: Int, selectedIndex: Int)? {
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

    func nearestJoinableIndex(to selectedIndex: Int, matching isJoinable: (Int) -> Bool) -> Int? {
        segments.indices
            .filter { $0 != selectedIndex && isJoinable($0) }
            .min { abs($0 - selectedIndex) < abs($1 - selectedIndex) }
    }

    func canJoin(left: RecordingEditorSegment, right: RecordingEditorSegment) -> Bool {
        left.recording.id == right.recording.id && abs(left.endSeconds - right.startSeconds) <= Self.sectionJoinTolerance
    }

    func recordUndo() {
        undoStack.append(makeSnapshot())
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func makeSnapshot() -> RecordingEditorSnapshot {
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

    func apply(_ snapshot: RecordingEditorSnapshot) {
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
