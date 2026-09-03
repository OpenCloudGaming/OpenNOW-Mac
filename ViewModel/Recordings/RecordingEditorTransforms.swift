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
        if let crop = preset.crop(sourceAspect: sourceAspect) {
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
            setAdjustingCrop(false)
        }
    }

    /// Keyboard-sized steps for the crop rectangle. Dropping the X/Y/W/H sliders in favour of the
    /// drag-on-video overlay took arbitrary crops away from anyone without a pointer; these put
    /// them back, and give VoiceOver something to adjust.
    static let cropNudgeStep = 0.02
    static let minimumCropSize = 0.1

    func nudgeCrop(dx: Double, dy: Double) {
        guard cropEnabled else { return }
        recordUndo()
        cropX = min(max(0, cropX + dx), max(0, 1 - cropWidth))
        cropY = min(max(0, cropY + dy), max(0, 1 - cropHeight))
    }

    func resizeCrop(dWidth: Double, dHeight: Double) {
        guard cropEnabled else { return }
        recordUndo()
        cropWidth = min(max(Self.minimumCropSize, cropWidth + dWidth), 1 - cropX)
        cropHeight = min(max(Self.minimumCropSize, cropHeight + dHeight), 1 - cropY)
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
        setAdjustingCrop(false)
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
        coalescedUndoToken = nil
        apply(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(makeSnapshot())
        coalescedUndoToken = nil
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

    /// Only an adjacent neighbour. This used to take the nearest joinable clip anywhere in the
    /// timeline, which meant two time-contiguous clips separated by others merged into one and
    /// landed at the left clip's position - reordering the timeline as a side effect of a join.
    func joinablePairContainingSelectedSegment() -> (leftIndex: Int, rightIndex: Int, selectedIndex: Int)? {
        guard let index = selectedSegmentIndex else { return nil }
        let selected = segments[index]
        let previousIndex = index - 1
        if segments.indices.contains(previousIndex), canJoin(left: segments[previousIndex], right: selected) {
            return (previousIndex, index, index)
        }
        let nextIndex = index + 1
        if segments.indices.contains(nextIndex), canJoin(left: selected, right: segments[nextIndex]) {
            return (index, nextIndex, index)
        }
        return nil
    }

    func canJoin(left: RecordingEditorSegment, right: RecordingEditorSegment) -> Bool {
        left.recording.id == right.recording.id && abs(left.endSeconds - right.startSeconds) <= Self.sectionJoinTolerance
    }

    func recordUndo() {
        undoStack.append(makeSnapshot())
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        coalescedUndoToken = nil
    }

    /// One undo step per run of edits from the same control. Without it the title field pushed a
    /// snapshot per keystroke and undo walked back through the typing instead of the edit.
    func recordCoalescedUndo(token: String) {
        guard coalescedUndoToken != token else { return }
        recordUndo()
        coalescedUndoToken = token
    }

    /// Closes a coalescing run, so returning to the same control later starts a new undo step.
    func endInteractiveEdit() {
        coalescedUndoToken = nil
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
            isAdjustingCrop: isAdjustingCrop,
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
        // Restored with the crop it edits. Left out, undoing past the point the overlay opened left
        // it on screen with `cropEnabled` false: the rectangle still dragged, still wrote cropX/Y,
        // and the export ignored all of it.
        isAdjustingCrop = snapshot.isAdjustingCrop
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
