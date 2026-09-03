import Foundation
import Testing
@testable import OpenNOW

// The editor view model had no coverage at all while it was gated behind an Experimental opt-in.
// These are the behaviours that gate broke silently: where the playhead sits, what a crop preset
// actually crops to, which clips a join is allowed to merge, and which edits undo knows about.

// MARK: - Playhead

private func fittedGeometry(totalDuration: Double = 30, width: CGFloat = 300, playheadSeconds: Double = 0) -> RecordingTimelineGeometry {
    RecordingTimelineGeometry(totalDuration: totalDuration, width: width, zoom: 1, playheadSeconds: playheadSeconds)
}

@Test func playheadTracksTheCumulativeTimelineNotTheSelectedClip() {
    // The regression: the playhead position is a point along the whole timeline, and the old
    // implementation clamped it into the selected clip's source range. A clip trimmed to start at
    // 30s therefore pinned the playhead to zero for its entire length.
    let layout = fittedGeometry()
    #expect(layout.x(forSeconds: 0) == 0)
    #expect(layout.x(forSeconds: 15) == 150)
    #expect(layout.x(forSeconds: 30) == 300)
}

@Test func aFittedTimelineSurvivesDegenerateInputs() {
    // An empty timeline is floored to a non-zero duration so the mapping stays finite rather than
    // dividing by zero; nothing is drawn on it either way.
    #expect(fittedGeometry(totalDuration: 0).x(forSeconds: 5).isFinite)
    #expect(fittedGeometry(totalDuration: 0).x(forSeconds: 0) == 0)
    #expect(fittedGeometry(width: 0).x(forSeconds: 30).isFinite)
    #expect(RecordingTimelineGeometry(totalDuration: 30, width: 300, zoom: .nan, playheadSeconds: .nan).zoom == 1)
}

@Test func secondsAndPixelsRoundTripBothWays() {
    let layout = fittedGeometry()
    for x in stride(from: CGFloat(0), through: 300, by: 25) {
        #expect(abs(layout.x(forSeconds: layout.seconds(forX: x)) - x) < 0.001)
    }
}

@Test func aSecondsLookupIsClampedToTheTimeline() {
    let layout = fittedGeometry()
    #expect(layout.seconds(forX: -50) == 0)
    #expect(layout.seconds(forX: 999) == 30)
}

// MARK: - Timeline zoom

@Test func zoomingCentresTheWindowOnThePlayhead() {
    let layout = RecordingTimelineGeometry(totalDuration: 120, width: 300, zoom: 4, playheadSeconds: 60)

    #expect(layout.visibleDuration == 30)
    #expect(layout.visibleStartSeconds == 45, "half a window either side of the playhead")
    #expect(layout.x(forSeconds: 60) == 150, "the playhead sits in the middle of the track")
}

@Test func theWindowStopsAtBothEndsRatherThanScrollingPastThem() {
    let atStart = RecordingTimelineGeometry(totalDuration: 120, width: 300, zoom: 4, playheadSeconds: 0)
    #expect(atStart.visibleStartSeconds == 0)
    #expect(atStart.x(forSeconds: 0) == 0)

    let atEnd = RecordingTimelineGeometry(totalDuration: 120, width: 300, zoom: 4, playheadSeconds: 120)
    #expect(atEnd.visibleStartSeconds == 90)
    #expect(atEnd.x(forSeconds: 120) == 300)
}

@Test func aClipBeforeTheWindowLaysOutAtANegativeOffset() {
    // Not clamped: the visible part of a clip that starts off-screen has to land in the right place.
    let layout = RecordingTimelineGeometry(totalDuration: 120, width: 300, zoom: 4, playheadSeconds: 60)

    #expect(layout.x(forSeconds: 0) < 0)
    #expect(layout.x(forSeconds: 120) > 300)
}

@Test func zoomIsClampedToTheSupportedRange() {
    #expect(RecordingTimelineGeometry(totalDuration: 30, width: 300, zoom: 0.1, playheadSeconds: 0).zoom == RecordingTimelineGeometry.minimumZoom)
    #expect(RecordingTimelineGeometry(totalDuration: 30, width: 300, zoom: 9999, playheadSeconds: 0).zoom == RecordingTimelineGeometry.maximumZoom)
}

@Test @MainActor func theZoomButtonsStepAndStopAtTheirLimits() {
    let model = makeEditor(duration: 600)
    #expect(model.canZoomTimelineOut == false, "the whole timeline already fits")
    #expect(model.timelineWindowDescription == nil)

    model.zoomTimelineIn()
    #expect(model.timelineZoom == 2)
    #expect(model.canZoomTimelineOut)
    #expect(model.timelineWindowDescription == "showing 300s of 600s")

    for _ in 0..<20 { model.zoomTimelineIn() }
    #expect(model.timelineZoom == RecordingTimelineGeometry.maximumZoom)
    #expect(model.canZoomTimelineIn == false)

    model.fitTimeline()
    #expect(model.timelineZoom == 1)
}

// MARK: - Trim snapping

@Test func aTrimHandleClicksOntoTheNearestLandmarkInsideTheThreshold() {
    #expect(RecordingTimelineGeometry.snapped(x: 148, to: [150, 40], threshold: 7) == 150)
    #expect(RecordingTimelineGeometry.snapped(x: 140, to: [150, 40], threshold: 7) == 140, "outside the threshold it is left alone")
    #expect(RecordingTimelineGeometry.snapped(x: 45, to: [40, 48], threshold: 7) == 48, "the nearest landmark wins")
    #expect(RecordingTimelineGeometry.snapped(x: 45, to: [], threshold: 7) == 45)
    #expect(RecordingTimelineGeometry.snapped(x: 45, to: [45], threshold: 0) == 45)
}

// MARK: - Crop presets

private func croppedAspect(_ crop: WebRTCStreamRecordingCrop, sourceAspect: Double) -> Double {
    crop.width * sourceAspect / crop.height
}

@Test func cropPresetsSolveTheirRatioAgainstA16By9Source() throws {
    let aspect = 16.0 / 9.0

    let square = try #require(RecordingEditorCropPreset.square.crop(sourceAspect: aspect))
    #expect(abs(croppedAspect(square, sourceAspect: aspect) - 1) < 0.001, "1:1 used to produce a 4:3 crop")

    let wide = try #require(RecordingEditorCropPreset.wide.crop(sourceAspect: aspect))
    #expect(abs(croppedAspect(wide, sourceAspect: aspect) - 16.0 / 9.0) < 0.001, "16:9 used to produce a 1.39:1 crop")

    let vertical = try #require(RecordingEditorCropPreset.vertical.crop(sourceAspect: aspect))
    #expect(abs(croppedAspect(vertical, sourceAspect: aspect) - 9.0 / 16.0) < 0.001)
}

@Test func cropPresetsSolveTheirRatioAgainstThe21By9CapturesThisAppRecords() throws {
    let aspect = 5120.0 / 2160.0

    for preset in [RecordingEditorCropPreset.square, .wide, .vertical] {
        let crop = try #require(preset.crop(sourceAspect: aspect))
        let target = try #require(preset.targetAspect)
        #expect(abs(croppedAspect(crop, sourceAspect: aspect) - target) < 0.001, "\(preset.title) on a 21:9 source")
        #expect(crop.x >= 0 && crop.y >= 0 && crop.x + crop.width <= 1.0001 && crop.y + crop.height <= 1.0001)
    }
}

@Test func cropPresetsAreCentredAndFullIsNoCrop() throws {
    let aspect = 16.0 / 9.0
    #expect(RecordingEditorCropPreset.full.crop(sourceAspect: aspect) == nil)

    let square = try #require(RecordingEditorCropPreset.square.crop(sourceAspect: aspect))
    #expect(abs(square.x - (1 - square.width) / 2) < 0.0001)
    #expect(abs(square.y - (1 - square.height) / 2) < 0.0001)
}

@Test func aDegenerateSourceAspectFallsBackRatherThanProducingAnInvalidCrop() throws {
    let crop = try #require(RecordingEditorCropPreset.square.crop(sourceAspect: 0))
    #expect(crop.width > 0 && crop.height > 0)
    #expect(crop.x + crop.width <= 1.0001)
}

@Test @MainActor func applyingACropPresetUsesTheRecordingsOwnAspect() {
    let model = makeEditor(width: 5120, height: 2160)

    model.applyCropPreset(.square)

    #expect(model.cropEnabled)
    #expect(abs(model.cropWidth * model.sourceAspect / model.cropHeight - 1) < 0.001)
}

@Test @MainActor func theFullPresetClearsTheCrop() {
    let model = makeEditor()
    model.applyCropPreset(.vertical)

    model.applyCropPreset(.full)

    #expect(model.cropEnabled == false)
    #expect(model.cropX == 0 && model.cropY == 0 && model.cropWidth == 1 && model.cropHeight == 1)
}

// MARK: - Join

@Test @MainActor func joinMergesAnAdjacentContiguousNeighbour() {
    let model = makeThreeClipEditor()
    model.selectedSegmentID = model.segments[1].id

    #expect(model.canJoinSelectedSection)
    model.joinSelectedSection()

    #expect(model.segments.count == 2)
    #expect(model.segments[0].startSeconds == 0)
    #expect(model.segments[0].endSeconds == 20)
    #expect(model.segments[1].startSeconds == 20)
}

@Test @MainActor func joinRefusesAClipThatIsContiguousButNotAdjacent() {
    // 0-10, 10-20, 20-30 reordered to 0-10, 20-30, 10-20. The tail is time-contiguous with the head
    // but two positions away; joining them used to merge both and move the result to the front,
    // silently reordering the timeline.
    let model = makeThreeClipEditor()
    let middle = model.segments[1]
    model.moveSegment(id: middle.id, to: model.segments.count)
    model.selectedSegmentID = model.segments[2].id

    #expect(model.segments.map(\.startSeconds) == [0, 20, 10])
    #expect(model.canJoinSelectedSection == false)
}

@Test @MainActor func splitThenJoinReturnsTheOriginalClip() {
    let model = makeEditor(duration: 30)

    model.splitAtPlayhead(12)
    model.joinSelectedSection()

    #expect(model.segments.count == 1)
    #expect(model.segments[0].startSeconds == 0)
    #expect(model.segments[0].endSeconds == 30)
}

// MARK: - Cut, move, drag

@Test @MainActor func cuttingAMarkedRangeLeavesTheHeadAndTail() {
    let model = makeEditor(duration: 30)

    model.markIn(10)
    model.markOut(20)
    #expect(model.hasMarkedRange)
    model.cutMarkedRange()

    #expect(model.segments.map(\.startSeconds) == [0, 20])
    #expect(model.segments.map(\.endSeconds) == [10, 30])
    #expect(model.hasMarkedRange == false, "the marks are consumed by the cut")
}

@Test @MainActor func markOutBeforeMarkInDropsTheStaleMark() {
    let model = makeEditor(duration: 30)

    model.markIn(20)
    model.markOut(10)

    #expect(model.markInSeconds == nil)
    #expect(model.hasMarkedRange == false)
}

@Test @MainActor func aTimelinePositionResolvesToTheRightClipAndSourceTime() throws {
    let model = makeEditor(duration: 30)
    model.markIn(10)
    model.markOut(20)
    model.cutMarkedRange()

    let target = try #require(model.sourceTime(forTimelineSeconds: 15))

    #expect(target.segment.id == model.segments[1].id)
    #expect(abs(target.seconds - 25) < 0.0001, "5s into a clip that starts at 20s")
}

@Test @MainActor func dropPayloadsRoundTripThroughTheirStringForm() throws {
    let model = makeThreeClipEditor()
    let moved = model.segments[0]

    let payload = try #require(RecordingEditorDragPayload(stringValue: RecordingEditorDragPayload.segment(moved.id).stringValue))
    #expect(payload == .segment(moved.id))
    #expect(model.handleDropPayload(payload.stringValue, at: 3))
    #expect(model.segments.last?.id == moved.id)

    #expect(RecordingEditorDragPayload(stringValue: "not-a-payload") == nil)
}

@Test @MainActor func droppingALibraryRecordingInsertsItAtThatPosition() {
    let model = makeEditor(duration: 30)
    let other = makeRecording(title: "Second", duration: 12)
    model.library = [model.primaryRecording, other]

    #expect(model.handleDropPayload(RecordingEditorDragPayload.recording(other.id).stringValue, at: 0))

    #expect(model.segments.count == 2)
    #expect(model.segments[0].recording.id == other.id)
}

// MARK: - Button gating

@Test @MainActor func theActionsThatCannotDoAnythingReportThemselvesDisabled() {
    let model = makeEditor(duration: 30)

    #expect(model.hasMarkedRange == false, "Remove Selection with no marks")
    #expect(model.canRemoveSelectedSegment == false, "Remove with a single clip")
    #expect(model.canMoveSelectedSegment(offset: -1) == false)
    #expect(model.canMoveSelectedSegment(offset: 1) == false)

    model.splitAtPlayhead(15)

    #expect(model.canRemoveSelectedSegment)
    #expect(model.canMoveSelectedSegment(offset: -1), "the split selects the right-hand clip")
    #expect(model.canMoveSelectedSegment(offset: 1) == false)
}

@Test @MainActor func aTrimOnlyEditIsReportedAsNeedingNoReEncode() {
    let model = makeEditor(duration: 30)
    #expect(model.isTrimOnlyEdit)

    model.updateSelectedEnd(20)
    #expect(model.isTrimOnlyEdit, "trimming the tail is still a copy")

    model.updateSelectedStart(5)
    #expect(model.isTrimOnlyEdit == false, "a head trim cannot start on a keyframe, so it re-encodes")

    model.updateSelectedStart(0)
    model.splitAtPlayhead(15)
    #expect(model.isTrimOnlyEdit == false, "two sections cannot be copied through")

    model.joinSelectedSection()
    model.applyCropPreset(.square)
    #expect(model.isTrimOnlyEdit == false)

    model.applyCropPreset(.full)
    model.playbackRate = 1.5
    #expect(model.isTrimOnlyEdit == false)

    model.playbackRate = 1
    model.appendRecording(makeRecording(title: "Second", duration: 12))
    #expect(model.isTrimOnlyEdit == false, "a second source has to be re-encoded into one track")
}

// MARK: - Undo

@Test @MainActor func undoCoversTheControlsThatWriteStraightToTheModel() {
    // Sliders, checkboxes and pickers bind to the properties directly. Undo used to skip every one
    // of them, so undoing a trim also restored whatever the crop happened to be at the time.
    let model = makeEditor(duration: 30)

    model.recordUndo()
    model.isMuted = true
    model.recordUndo()
    model.volume = 0.25

    model.undo()
    #expect(model.volume == 1)
    #expect(model.isMuted)

    model.undo()
    #expect(model.isMuted == false)
    #expect(model.canUndo == false)
}

@Test @MainActor func redoReplaysWhatUndoTookBack() {
    let model = makeEditor(duration: 30)
    model.recordUndo()
    model.cropEnabled = true

    model.undo()
    #expect(model.cropEnabled == false)
    #expect(model.canRedo)

    model.redo()
    #expect(model.cropEnabled)
}

@Test @MainActor func aRunOfTypingIsOneUndoStep() {
    let model = makeEditor(duration: 30)
    let original = model.outputTitle

    for title in ["A", "Ab", "Abc"] {
        model.recordCoalescedUndo(token: "outputTitle")
        model.outputTitle = title
    }

    #expect(model.undoStack.count == 1)
    model.undo()
    #expect(model.outputTitle == original)
}

@Test @MainActor func aDiscreteEditClosesTheCoalescingRun() {
    let model = makeEditor(duration: 30)

    model.recordCoalescedUndo(token: "outputTitle")
    model.outputTitle = "A"
    model.splitAtPlayhead(15)
    model.recordCoalescedUndo(token: "outputTitle")
    model.outputTitle = "B"

    #expect(model.undoStack.count == 3, "typing, the split, then typing again")
}

@Test @MainActor func endingAnInteractiveEditStartsAFreshUndoStep() {
    let model = makeEditor(duration: 30)

    model.recordCoalescedUndo(token: "outputTitle")
    model.outputTitle = "A"
    model.endInteractiveEdit()
    model.recordCoalescedUndo(token: "outputTitle")
    model.outputTitle = "B"

    #expect(model.undoStack.count == 2)
}

@Test @MainActor func theUndoStackIsBounded() {
    let model = makeEditor(duration: 30)

    for _ in 0..<80 { model.recordUndo() }

    #expect(model.undoStack.count == 50)
}

@Test @MainActor func undoingPastTheCropOverlayPutsItAway() {
    // The overlay is only meaningful while there is a crop to edit. Left out of the snapshot, undo
    // restored `cropEnabled == false` while `isAdjustingCrop` stayed true: the rectangle kept
    // dragging and writing cropX/Y, and the export ignored every bit of it.
    let model = makeEditor()

    model.setAdjustingCrop(true)
    #expect(model.cropEnabled)
    #expect(model.isAdjustingCrop)

    model.undo()

    #expect(model.cropEnabled == false)
    #expect(model.isAdjustingCrop == false, "the rectangle cannot outlive the crop it edits")
    #expect(model.previewRequest().crop == nil)
}

@Test @MainActor func redoBringsTheCropOverlayBackWithItsCrop() {
    let model = makeEditor()
    model.setAdjustingCrop(true)
    model.undo()

    model.redo()

    #expect(model.cropEnabled)
    #expect(model.isAdjustingCrop)
}

// MARK: - Crop without a pointer

@Test @MainActor func theCropRectangleCanBeMovedAndResizedFromTheKeyboard() {
    // Dropping the X/Y/W/H sliders for the drag-on-video overlay took arbitrary crops away from
    // anyone without a pointer. These are what put them back.
    let model = makeEditor()
    model.applyCropPreset(.square)
    let width = model.cropWidth
    let originalX = model.cropX

    model.nudgeCrop(dx: RecordingEditorViewModel.cropNudgeStep, dy: 0)
    #expect(abs(model.cropX - (originalX + RecordingEditorViewModel.cropNudgeStep)) < 0.0001)
    #expect(model.cropWidth == width, "moving does not resize")

    model.resizeCrop(dWidth: -0.1, dHeight: -0.1)
    #expect(model.cropWidth < width)
}

@Test @MainActor func keyboardCropStaysInsideTheFrameAndAboveTheMinimumSize() {
    let model = makeEditor()
    model.applyCropPreset(.center)

    for _ in 0..<200 { model.nudgeCrop(dx: 1, dy: 1) }
    #expect(model.cropX + model.cropWidth <= 1.0001)
    #expect(model.cropY + model.cropHeight <= 1.0001)

    for _ in 0..<200 { model.nudgeCrop(dx: -1, dy: -1) }
    #expect(model.cropX >= 0)
    #expect(model.cropY >= 0)

    for _ in 0..<200 { model.resizeCrop(dWidth: -1, dHeight: -1) }
    #expect(model.cropWidth >= RecordingEditorViewModel.minimumCropSize - 0.0001)
    #expect(model.cropHeight >= RecordingEditorViewModel.minimumCropSize - 0.0001)
}

@Test @MainActor func keyboardCropDoesNothingWhenThereIsNoCrop() {
    let model = makeEditor()
    #expect(model.cropEnabled == false)

    model.nudgeCrop(dx: 0.1, dy: 0.1)
    model.resizeCrop(dWidth: 0.1, dHeight: 0.1)

    #expect(model.cropX == 0)
    #expect(model.cropWidth == 1)
    #expect(model.canUndo == false, "a no-op does not land on the undo stack")
}
