import Foundation
import Testing
@testable import OpenNOW

// The timeline's geometry and readouts: the ruler, the transport's clock, the crop rectangle's
// coordinate flip, and the grid lookup behind the filmstrip.

// MARK: - Timeline ruler and readouts

@Test func theRulerPicksAStepPeopleAlreadyReadOnAClock() {
    #expect(RecordingTimelineGeometry.rulerStepSeconds(visibleDuration: 8) == 1)
    #expect(RecordingTimelineGeometry.rulerStepSeconds(visibleDuration: 30) == 5)
    #expect(RecordingTimelineGeometry.rulerStepSeconds(visibleDuration: 90) == 15)
    #expect(RecordingTimelineGeometry.rulerStepSeconds(visibleDuration: 600) == 120)
    #expect(RecordingTimelineGeometry.rulerStepSeconds(visibleDuration: 7200) == 900, "eight quarter-hour marks, not two half-hour ones")
    #expect(RecordingTimelineGeometry.rulerStepSeconds(visibleDuration: 3) == 0.5, "a deep zoom gets a sub-second scale")
}

@Test func theRulerNeverAsksForMoreThanEightLabels() {
    for duration in stride(from: 1.0, through: 3600.0, by: 7.0) {
        let step = RecordingTimelineGeometry.rulerStepSeconds(visibleDuration: duration)
        #expect(duration / step <= 8, "\(duration)s would draw \(duration / step) labels")
    }
}

@Test func rulerTicksStayOnRoundNumbersAsTheWindowSlides() {
    let layout = RecordingTimelineGeometry(totalDuration: 600, width: 300, zoom: 8, playheadSeconds: 313)
    let ticks = layout.rulerTickSeconds()
    let step = RecordingTimelineGeometry.rulerStepSeconds(visibleDuration: layout.visibleDuration)

    #expect(!ticks.isEmpty)
    #expect(ticks.allSatisfy { $0 >= 0 }, "no labels before the start of the timeline")
    #expect(ticks.allSatisfy { abs(($0 / step).rounded() * step - $0) < 0.001 }, "every tick is a multiple of the step")
    #expect(ticks.allSatisfy { $0 <= layout.visibleEndSeconds + 0.001 })
    #expect(ticks.count <= 12)
}

@Test func theTransportReadoutShowsTenths() {
    #expect(recordingEditorPreciseTimeText(0) == "0:00.0")
    #expect(recordingEditorPreciseTimeText(9.45) == "0:09.5", "rounded, not truncated")
    #expect(recordingEditorPreciseTimeText(75.5) == "1:15.5")
    #expect(recordingEditorPreciseTimeText(3661.2) == "1:01:01.2")
    #expect(recordingEditorPreciseTimeText(-3) == "0:00.0", "a negative playhead is a bug elsewhere, not a crash here")
}

@Test @MainActor func theCropReadoutReportsThePixelSizeTheExportWillProduce() {
    let model = makeEditor(width: 5120, height: 2160)
    #expect(model.croppedOutputDescription == "5120x2160")

    model.applyCropPreset(.square)

    #expect(model.croppedOutputDescription == "2160x2160")
}

@Test @MainActor func theMarkedRangeReadoutNamesWhatRemoveSelectionWillCut() {
    let model = makeEditor(duration: 30)
    #expect(model.markedRangeDescription == nil)

    model.markIn(12)
    model.markOut(18)
    #expect(model.markedRangeDescription == "Selection 6.0s")

    model.cutMarkedRange()
    #expect(model.markedRangeDescription == nil, "the marks are consumed by the cut")
}

// MARK: - Crop overlay geometry

@Test func theVideoRectLetterboxesTheWayThePlayerDoes() {
    // Wider source than pane: bars top and bottom.
    let wide = RecordingCropOverlay.videoRect(in: CGSize(width: 400, height: 400), sourceAspect: 2)
    #expect(wide == CGRect(x: 0, y: 100, width: 400, height: 200))

    // Taller source than pane: bars left and right.
    let tall = RecordingCropOverlay.videoRect(in: CGSize(width: 400, height: 400), sourceAspect: 0.5)
    #expect(tall == CGRect(x: 100, y: 0, width: 200, height: 400))

    // Exact fit, and a degenerate aspect falls back to the whole pane rather than vanishing.
    #expect(RecordingCropOverlay.videoRect(in: CGSize(width: 400, height: 200), sourceAspect: 2) == CGRect(x: 0, y: 0, width: 400, height: 200))
    #expect(RecordingCropOverlay.videoRect(in: CGSize(width: 400, height: 200), sourceAspect: 0) == CGRect(x: 0, y: 0, width: 400, height: 200))
}

@Test func theCropRectangleFlipsFromCoreImagesBottomOriginToTheViewsTop() {
    let video = CGRect(x: 0, y: 0, width: 200, height: 100)

    // A crop pinned to the bottom of the frame draws at the bottom of the view.
    let bottom = RecordingCropOverlay.cropRect(in: video, x: 0, y: 0, width: 1, height: 0.5)
    #expect(bottom == CGRect(x: 0, y: 50, width: 200, height: 50))

    // ...and one pinned to the top draws at the top.
    let top = RecordingCropOverlay.cropRect(in: video, x: 0, y: 0.5, width: 1, height: 0.5)
    #expect(top == CGRect(x: 0, y: 0, width: 200, height: 50))

    // A full-frame crop covers the video exactly, offset included.
    let offsetVideo = CGRect(x: 30, y: 10, width: 200, height: 100)
    #expect(RecordingCropOverlay.cropRect(in: offsetVideo, x: 0, y: 0, width: 1, height: 1) == offsetVideo)
}

@Test @MainActor func adjustingTheCropShowsTheOriginalFrameWithoutChangingTheExport() {
    let model = makeEditor()
    model.applyCropPreset(.square)
    model.rotateRight()

    #expect(model.previewRequest().crop != nil)
    #expect(model.previewRequest().rotation == .degrees90)

    model.setAdjustingCrop(true)

    #expect(model.previewRequest().crop == nil, "the rectangle needs the untouched frame under it")
    #expect(model.previewRequest().rotation == .degrees0)
    #expect(model.request().crop != nil, "the export is unaffected")
    #expect(model.request().rotation == .degrees90)
    #expect(model.frameSignature.contains("adjusting"), "so the preview actually refreshes")

    model.setAdjustingCrop(false)
    #expect(model.previewRequest().crop != nil)
}

@Test @MainActor func adjustingTheCropTurnsTheCropOnAndTurningItOffPutsTheRectangleAway() {
    let model = makeEditor()
    #expect(model.cropEnabled == false)

    model.setAdjustingCrop(true)
    #expect(model.cropEnabled, "there is nothing to drag otherwise")
    #expect(model.isAdjustingCrop)

    model.applyCropPreset(.full)
    #expect(model.cropEnabled == false)
    #expect(model.isAdjustingCrop == false, "the rectangle cannot outlive the crop it edits")
}

// MARK: - Preview refresh routing

@Test @MainActor func eachGroupOfControlsMovesOnlyItsOwnSignature() {
    // The three groups cost wildly different amounts to apply, so a change must not look like a
    // change to the others. A volume slider that moved the timeline signature rebuilt the whole
    // composition, reloaded every source asset and restarted playback.
    let model = makeEditor(duration: 30)
    let timeline = model.timelineSignature
    let frame = model.frameSignature
    let audio = model.audioSignature

    model.volume = 0.4
    #expect(model.timelineSignature == timeline)
    #expect(model.frameSignature == frame)
    #expect(model.audioSignature != audio)

    model.applyCropPreset(.square)
    #expect(model.timelineSignature == timeline)
    #expect(model.frameSignature != frame)

    model.splitAtPlayhead(15)
    #expect(model.timelineSignature != timeline)
}

@Test @MainActor func playbackRateCountsAsATimelineChange() {
    // It is applied with scaleTimeRange on the composition's own tracks, not at render time, so it
    // cannot be handled in place.
    let model = makeEditor(duration: 30)
    let timeline = model.timelineSignature
    let audio = model.audioSignature

    model.playbackRate = 2

    #expect(model.timelineSignature != timeline)
    #expect(model.audioSignature == audio)
}

@Test @MainActor func zoomingTheTimelineIsNotAPreviewChange() {
    let model = makeEditor(duration: 30)
    let signature = model.previewSignature

    model.zoomTimelineIn()

    #expect(model.previewSignature == signature, "zoom is view state; it does not change the video")
}

// MARK: - Guarding an edit in progress

@MainActor
private func makeLibraryModel() -> (RecordingsViewModel, WebRTCStreamRecording, WebRTCStreamRecording) {
    let first = makeRecording(title: "First", duration: 30)
    let second = makeRecording(title: "Second", duration: 30)
    let model = RecordingsViewModel()
    model.recordings = [first, second]
    model.select(first, autoplay: false)
    return (model, first, second)
}

@Test @MainActor func switchingRecordingsWithNoEditsJustSwitches() {
    let (model, first, second) = makeLibraryModel()
    defer { model.removePlayerTimeObserver() }
    model.editorViewModel = RecordingEditorViewModel(recording: first, library: model.recordings)

    model.requestSelect(second, autoplay: false)

    #expect(model.pendingEditorDiscardSelection == nil)
    #expect(model.selectedRecording?.id == second.id)
}

@Test @MainActor func switchingRecordingsMidEditAsksFirst() {
    // This used to happen silently, and not only from clicking another row: typing in the search
    // field moved the selection through reconcileSelection and took the edit with it.
    let (model, first, second) = makeLibraryModel()
    defer { model.removePlayerTimeObserver() }
    let editor = RecordingEditorViewModel(recording: first, library: model.recordings)
    editor.splitAtPlayhead(10)
    model.editorViewModel = editor

    model.requestSelect(second, autoplay: false)

    #expect(model.pendingEditorDiscardSelection?.id == second.id)
    #expect(model.selectedRecording?.id == first.id, "nothing moves until the question is answered")
    #expect(model.editorViewModel != nil)

    model.confirmPendingEditorDiscard()

    #expect(model.pendingEditorDiscardSelection == nil)
    #expect(model.selectedRecording?.id == second.id)
    #expect(model.editorViewModel == nil)
}

@Test @MainActor func keepingTheEditLeavesEverythingWhereItWas() {
    let (model, first, second) = makeLibraryModel()
    defer { model.removePlayerTimeObserver() }
    let editor = RecordingEditorViewModel(recording: first, library: model.recordings)
    editor.splitAtPlayhead(10)
    model.editorViewModel = editor

    model.requestSelect(second, autoplay: false)
    model.cancelPendingEditorDiscard()

    #expect(model.pendingEditorDiscardSelection == nil)
    #expect(model.selectedRecording?.id == first.id)
    #expect(model.editorViewModel === editor)
}

@Test @MainActor func closingTheEditorAsksOnlyWhenThereIsSomethingToLose() {
    let (model, first, _) = makeLibraryModel()
    defer { model.removePlayerTimeObserver() }
    model.editorViewModel = RecordingEditorViewModel(recording: first, library: model.recordings)

    model.requestCloseEditor()
    #expect(model.isPendingEditorClose == false)
    #expect(model.editorViewModel == nil, "an untouched editor just closes")

    let editor = RecordingEditorViewModel(recording: first, library: model.recordings)
    editor.splitAtPlayhead(10)
    model.editorViewModel = editor

    model.requestCloseEditor()
    #expect(model.isPendingEditorClose)
    #expect(model.editorViewModel === editor)

    model.confirmPendingEditorDiscard()
    #expect(model.isPendingEditorClose == false)
    #expect(model.editorViewModel == nil)
}

@Test @MainActor func theFilterCannotMoveTheSelectionOutFromUnderAnOpenEditor() {
    let (model, first, _) = makeLibraryModel()
    defer { model.removePlayerTimeObserver() }
    model.editorViewModel = RecordingEditorViewModel(recording: first, library: model.recordings)

    // Exactly what typing in the search field does: the edited recording stops being visible.
    model.searchText = "Second"
    model.reconcileSelection(withVisibleIDs: model.visibleRecordings.map(\.id))

    #expect(model.selectedRecording?.id == first.id)
    #expect(model.editorViewModel != nil)
}

@Test @MainActor func theSelectionIsStillReconciledWithNoEditorOpen() {
    let (model, _, second) = makeLibraryModel()
    defer { model.removePlayerTimeObserver() }

    model.searchText = "Second"
    model.reconcileSelection(withVisibleIDs: model.visibleRecordings.map(\.id))

    #expect(model.selectedRecording?.id == second.id)
}

// MARK: - Controller focus

@Test @MainActor func theEditorTakesControllerFocusAndBackReturnsIt() {
    let (model, first, _) = makeLibraryModel()
    defer { model.removePlayerTimeObserver() }
    #expect(model.controllerFocus == .library)

    model.startEditing(first)
    #expect(model.controllerFocus == .editor)

    model.applyControllerCommand(.back, in: model.recordings)
    #expect(model.controllerFocus == .library)

    model.applyControllerCommand(.actions, in: model.recordings)
    #expect(model.controllerFocus == .editor)

    model.closeEditor()
    #expect(model.controllerFocus == .library)
}

@Test @MainActor func theEditorSwallowsPadInputThatWouldOtherwiseWalkTheLibrary() {
    let (model, first, _) = makeLibraryModel()
    defer { model.removePlayerTimeObserver() }
    model.startEditing(first)
    let editor = try? #require(model.editorViewModel)
    editor?.splitAtPlayhead(10)
    editor?.selectedSegmentID = editor?.segments.first?.id

    model.applyControllerCommand(.move(.down), in: model.recordings)

    #expect(model.selectedRecording?.id == first.id, "the list did not move")
    #expect(editor?.selectedSegmentID == editor?.segments.last?.id, "the clip selection did")
}

@Test @MainActor func theShoulderButtonsTrimToWhereThePreviewIsParked() {
    let (model, first, _) = makeLibraryModel()
    defer { model.removePlayerTimeObserver() }
    model.startEditing(first)
    guard let editor = model.editorViewModel else { return }
    model.playerTimeSeconds = 12

    model.applyControllerCommand(.pageLeft, in: model.recordings)

    #expect(abs((editor.segments.first?.startSeconds ?? 0) - 12) < 0.001)
}

@Test @MainActor func editingAnotherRecordingMidEditAsksBeforeThrowingTheEditAway() {
    let (model, first, second) = makeLibraryModel()
    defer { model.removePlayerTimeObserver() }
    let editor = RecordingEditorViewModel(recording: first, library: model.recordings)
    editor.splitAtPlayhead(10)
    model.editorViewModel = editor

    // The context menu's Edit reaches any row, not just the selected one.
    model.startEditing(second)

    #expect(model.pendingEditorDiscardSelection?.id == second.id)
    #expect(model.editorViewModel === editor)
}

@Test func aDrawnSpanNeverExceedsTheTrackPlusOneScreenOfOverscan() {
    // Geometry stays unclamped so off-window content lands in the right place, but a view frame
    // cannot: at 32x zoom a full-length clip asked for ~28,800 pt, past what a layer's backing
    // store can take.
    let layout = RecordingTimelineGeometry(totalDuration: 600, width: 900, zoom: 32, playheadSeconds: 300)
    let wholeTimeline = layout.displayFrame(x: layout.x(forSeconds: 0), width: layout.x(forSeconds: 600) - layout.x(forSeconds: 0))

    #expect(wholeTimeline.width <= 900 * 3)
    #expect(wholeTimeline.x >= -900)
}

@Test func aDrawnSpanKeepsItsPositionWhileItIsOnScreen() {
    let layout = RecordingTimelineGeometry(totalDuration: 30, width: 300, zoom: 1, playheadSeconds: 0)
    let frame = layout.displayFrame(x: 60, width: 90)

    #expect(frame.x == 60)
    #expect(frame.width == 90)
}

@Test func aSpanEntirelyOffTheTrackCollapsesInsteadOfDrawingBackwards() {
    let layout = RecordingTimelineGeometry(totalDuration: 30, width: 300, zoom: 1, playheadSeconds: 0)

    let farLeft = layout.displayFrame(x: -5000, width: 10)
    #expect(farLeft.width == 0, "a negative width would be an invalid rect, not a small one")

    let farRight = layout.displayFrame(x: 5000, width: 10)
    #expect(farRight.width == 0)
}

// MARK: - Explaining what an edit did

@Test @MainActor func removingARangeFromTheMiddleSaysWhyThereAreNowTwoSections() {
    // The report was "why does removing selection split the video?" - it does, necessarily, and the
    // export has no gap. Nothing said so.
    let model = makeEditor(duration: 30)
    model.markIn(10)
    model.markOut(16)

    model.cutMarkedRange()

    #expect(model.segments.count == 2)
    let hint = model.hint ?? ""
    #expect(hint.contains("6.0s"))
    #expect(hint.contains("back to back"))
    #expect(hint.contains("no gap"))
}

@Test @MainActor func removingFromAnEndDoesNotClaimToHaveLeftTwoSections() {
    let model = makeEditor(duration: 30)
    model.markIn(0)
    model.markOut(10)

    model.cutMarkedRange()

    #expect(model.segments.count == 1)
    #expect(model.hint?.contains("back to back") == false)
}

@Test @MainActor func splitAndJoinSayWhatTheyDid() {
    let model = makeEditor(duration: 30)

    model.splitAtPlayhead(15)
    #expect(model.hint?.contains("Split") == true)

    model.joinSelectedSection()
    #expect(model.hint?.contains("Merged") == true)
}

@Test @MainActor func aTrimmedClipCanStillBeDraggedBackOutToTheFullRecording() {
    // "once you trim with the green bars we cant recover anymore?" - the clip regrows to fill the
    // track after a trim, so the handle had nowhere left to drag. The bound is the source
    // recording, not the current trim.
    let model = makeEditor(duration: 30)

    model.updateSelectedEnd(5)
    #expect(model.segments[0].endSeconds == 5)

    model.updateSelectedEnd(30)
    #expect(model.segments[0].endSeconds == 30, "the full source is still reachable")

    model.updateSelectedStart(20)
    model.updateSelectedStart(0)
    #expect(model.segments[0].startSeconds == 0)
}

@Test @MainActor func aTrimStaysInsideTheSourceRecording() {
    let model = makeEditor(duration: 30)

    model.updateSelectedEnd(9999)
    #expect(model.segments[0].endSeconds == 30)

    model.updateSelectedStart(-9999)
    #expect(model.segments[0].startSeconds == 0)
}

// MARK: - Filmstrip grid lookup

@Test func theNearestGridFrameIsFoundByBinarySearch() {
    // Runs once per tile per redraw, and the timeline redraws several times a second while the
    // preview plays, so a linear scan of a 96-entry grid was 4,600 comparisons a frame. Asserted
    // against the shared helper itself rather than a copy of it.
    let grid = (0..<96).map { Double($0) * 6.1 }

    for target in stride(from: -10.0, through: 620.0, by: 3.7) {
        let index = recordingNearestIndex(in: grid, to: target) { $0 }
        let expected = grid.min { abs($0 - target) < abs($1 - target) }
        #expect(index.map { grid[$0] } == expected, "target \(target)")
    }
}

@Test func theNearestLookupHandlesAnEmptyGrid() {
    #expect(recordingNearestIndex(in: [Double](), to: 5) { $0 } == nil)
    #expect(recordingNearestIndex(in: [7.0], to: -99) { $0 } == 0)
}

// MARK: - Shared interest counting

@Test func interestCountingStartsOnceAndStopsOnTheLastRelease() {
    // Both the filmstrip's grids and the waveform's peaks are shared by every clip of a recording
    // and thrown away when the editor closes. They each had their own copy of this.
    var counter = RecordingInterestCounter()
    let recording = UUID()

    // Called outside the macro: `#expect` captures its operand immutably.
    let first = counter.retain(recording)
    let second = counter.retain(recording)
    let firstRelease = counter.release(recording)
    let lastRelease = counter.release(recording)

    #expect(first, "the first interest starts the build")
    #expect(second == false, "a second clip joins the one already running")
    #expect(firstRelease == false, "one clip leaving is not the last")
    #expect(lastRelease, "the last one discards")
}

@Test func interestCountingTreatsAnUnknownReleaseAsTheLast() {
    var counter = RecordingInterestCounter()
    let released = counter.release(UUID())
    #expect(released, "releasing something never retained still cleans up")
}

@Test func clampingIsSafeWhenTheUpperBoundFallsBelowTheLower() {
    // `1 - cropWidth` goes negative once a crop fills the frame, and a ClosedRange traps on that.
    #expect(0.5.clampedBetween(0, 1) == 0.5)
    #expect((-2.0).clampedBetween(0, 1) == 0)
    #expect(9.0.clampedBetween(0, 1) == 1)
    #expect(0.5.clampedBetween(0, -0.3) == 0, "an inverted range collapses to its lower bound")
}

// MARK: - Visible source range (filmstrip window)

/// Mirrors `RecordingTimelineView.visibleSourceRange`, which is private to the view.
private func visibleSourceRange(clipX: CGFloat, clipWidth: CGFloat, trackWidth: CGFloat,
                                start: Double, duration: Double) -> ClosedRange<Double>? {
    guard clipWidth > 1 else { return nil }
    let leading = min(max(0, -clipX / clipWidth), 1)
    let trailing = min(max(0, (trackWidth - clipX) / clipWidth), 1)
    guard trailing > leading else { return nil }
    let lower = start + duration * Double(leading)
    let upper = start + duration * Double(trailing)
    guard upper > lower else { return nil }
    return lower...upper
}

@Test func aClipFullyOnScreenAsksForItsWholeSourceRange() {
    let range = visibleSourceRange(clipX: 0, clipWidth: 300, trackWidth: 300, start: 10, duration: 30)
    #expect(range == 10...40)
}

@Test func aClipRunningOffBothEdgesAsksOnlyForWhatIsShowing() {
    // Zoomed in: the clip is three track-widths wide and starts one width off to the left, so the
    // middle third of it is on screen.
    let range = visibleSourceRange(clipX: -300, clipWidth: 900, trackWidth: 300, start: 0, duration: 90)
    let bounds = try? #require(range)
    #expect(bounds?.lowerBound == 30)
    #expect(bounds?.upperBound == 60)
}

@Test func aClipEntirelyOffScreenAsksForNothing() {
    #expect(visibleSourceRange(clipX: -5000, clipWidth: 100, trackWidth: 300, start: 0, duration: 30) == nil)
    #expect(visibleSourceRange(clipX: 5000, clipWidth: 100, trackWidth: 300, start: 0, duration: 30) == nil)
    #expect(visibleSourceRange(clipX: 0, clipWidth: 0, trackWidth: 300, start: 0, duration: 30) == nil)
}

@Test func aSubSecondRulerStepGetsSubSecondLabels() {
    // At a deep zoom the step drops to half a second, and whole-second labels then repeat
    // themselves - "0:11 0:11 0:12 0:12" - at exactly the zoom where the sub-second detail is the
    // reason to be there.
    let step = RecordingTimelineGeometry.rulerStepSeconds(visibleDuration: 3)
    #expect(step == 0.5)

    let ticks = [10.0, 10.5, 11.0, 11.5]
    let whole = ticks.map(recordingEditorDurationText)
    let precise = ticks.map(recordingEditorPreciseTimeText)

    #expect(Set(whole).count < ticks.count, "whole seconds cannot label a half-second step")
    #expect(Set(precise).count == ticks.count)
}

@Test @MainActor func leavingThePageLeavesThePlayerWithNothingWatchingIt() {
    // The state `reload` has to recognise. Leaving the page removes the time observer and the
    // playback-status sink but leaves the player behind, so a gate on `player == nil` skipped
    // re-selecting: the playhead froze at its last value while the preview played on, and every
    // playhead-relative edit - Split, Trim Start, Set In - cut at a stale time and exported it.
    //
    // `reload` itself reads the real recordings folder, so the gate is asserted here as the
    // condition rather than by driving a method whose result depends on what is on this disk.
    let (model, _, _) = makeLibraryModel()
    defer { model.removePlayerTimeObserver() }
    #expect(model.playerTimeObserver != nil)

    model.removePlayerTimeObserver()

    #expect(model.player != nil, "the player outlives the observers, which is what made this silent")
    #expect(model.playerTimeObserver == nil)
}

@Test @MainActor func selectingReinstallsTheObservers() {
    let (model, first, _) = makeLibraryModel()
    defer { model.removePlayerTimeObserver() }

    model.removePlayerTimeObserver()
    model.select(first, autoplay: false)

    #expect(model.playerTimeObserver != nil)
}

// MARK: - Deferred trim

/// Mirrors `RecordingTimelineView.boundedTrimSeconds`, which is private to the view.
private func boundedTrim(_ seconds: Double, start: Double, end: Double, sourceDuration: Double, isLeading: Bool) -> Double {
    if isLeading { return min(max(0, seconds), max(0, end - 0.05)) }
    return max(min(sourceDuration, seconds), start + 0.05)
}

@Test func aPendingTrimStopsWhereTheFootageDoes() {
    // The drag no longer mutates the segment, so the view has to bound the preview itself or the
    // ghost strip would run off the end of the recording.
    #expect(boundedTrim(-5, start: 10, end: 20, sourceDuration: 30, isLeading: true) == 0)
    #expect(boundedTrim(99, start: 10, end: 20, sourceDuration: 30, isLeading: false) == 30)
}

@Test func aPendingTrimKeepsTheClipLongerThanNothing() {
    #expect(boundedTrim(25, start: 10, end: 20, sourceDuration: 30, isLeading: true) == 19.95)
    #expect(boundedTrim(5, start: 10, end: 20, sourceDuration: 30, isLeading: false) == 10.05)
}

@Test func aPendingTrimOutwardIsAllowedPastTheCommittedEdge() {
    // Dragging back out is the case the preview exists for: the bound is the source recording, not
    // the clip's current trim.
    #expect(boundedTrim(2, start: 10, end: 20, sourceDuration: 30, isLeading: true) == 2)
    #expect(boundedTrim(28, start: 10, end: 20, sourceDuration: 30, isLeading: false) == 28)
}

// MARK: - Trim headroom

@Test func headroomIsReservedOnlyOnTheSideBeingDragged() {
    // The track fits its clips exactly, so a clip that fills it has nowhere to grow. Reserving the
    // room on one side is what keeps the handle under the pointer instead of pinned at the edge.
    let leading = RecordingTrimHeadroom.forDrag(
        isLeading: true, segmentStart: 20, segmentEnd: 40, sourceDuration: 100, committedDuration: 20
    )
    #expect(leading.leading == 20)
    #expect(leading.trailing == 0)

    let trailing = RecordingTrimHeadroom.forDrag(
        isLeading: false, segmentStart: 20, segmentEnd: 40, sourceDuration: 100, committedDuration: 20
    )
    #expect(trailing.leading == 0)
    #expect(trailing.trailing == 20, "capped at the timeline's own length, not the 60s available")
}

@Test func headroomNeverExceedsWhatTheSourceHolds() {
    let atHead = RecordingTrimHeadroom.forDrag(
        isLeading: true, segmentStart: 0, segmentEnd: 30, sourceDuration: 30, committedDuration: 30
    )
    #expect(atHead.leading == 0, "a clip already at the head has nothing to restore")

    let atTail = RecordingTrimHeadroom.forDrag(
        isLeading: false, segmentStart: 0, segmentEnd: 30, sourceDuration: 30, committedDuration: 30
    )
    #expect(atTail.trailing == 0)
}

@Test func headroomIsCappedSoTheClipsAreNeverSqueezedPastHalfTheTrack() {
    // A one-second clip with ten minutes of source behind it would otherwise reserve ten minutes
    // and compress the timeline to nothing.
    let headroom = RecordingTrimHeadroom.forDrag(
        isLeading: true, segmentStart: 600, segmentEnd: 601, sourceDuration: 900, committedDuration: 1
    )
    #expect(headroom.leading == 5, "the floor, since half of a one-second timeline is not usable room")

    let longer = RecordingTrimHeadroom.forDrag(
        isLeading: true, segmentStart: 600, segmentEnd: 700, sourceDuration: 900, committedDuration: 100
    )
    #expect(longer.leading == 100, "at most the timeline's own length")
}

// MARK: - Filmstrip work splitting

/// Mirrors `RecordingFilmstripDecoder.split`, which is private to its file.
private func splitFrameTimes(_ times: [Double], workers: Int, keyframeInterval: Double = 2) -> [[Double]] {
    let sorted = times.sorted()
    guard workers > 1, sorted.count > 1 else { return [sorted] }
    let spacing = ((sorted.last ?? 0) - (sorted.first ?? 0)) / Double(sorted.count - 1)
    guard spacing < keyframeInterval else {
        return (0..<workers).map { worker in
            sorted.enumerated().filter { $0.offset % workers == worker }.map(\.element)
        }
    }
    let perWorker = Int((Double(sorted.count) / Double(workers)).rounded(.up))
    return stride(from: 0, to: sorted.count, by: perWorker).map {
        Array(sorted[$0..<Swift.min($0 + perWorker, sorted.count)])
    }
}

@Test func denselyPackedFramesAreSplitIntoContiguousBlocks() {
    // Frames inside one group of pictures: interleaving makes every worker decode forward through
    // the same group. Measured at 1492ms interleaved against 716ms contiguous on a 5K capture.
    let times = (0..<32).map { 120 + Double($0) * 0.5 }
    let groups = splitFrameTimes(times, workers: 4)

    #expect(groups.count == 4)
    for group in groups {
        let spans = zip(group, group.dropFirst()).map { $1 - $0 }
        #expect(spans.allSatisfy { abs($0 - 0.5) < 0.001 }, "each worker gets a run, not every fourth frame")
    }
    #expect(groups.flatMap { $0 }.sorted() == times, "every frame is asked for exactly once")
}

@Test func sparselySpacedFramesAreInterleaved() {
    // A frame every six seconds shares no group of pictures with its neighbours, so there is
    // nothing to reuse and interleaving balances the load instead.
    let times = (0..<24).map { Double($0) * 6 }
    let groups = splitFrameTimes(times, workers: 4)

    #expect(groups.count == 4)
    for group in groups {
        let spans = zip(group, group.dropFirst()).map { $1 - $0 }
        #expect(spans.allSatisfy { abs($0 - 24) < 0.001 }, "every fourth frame")
    }
    #expect(groups.flatMap { $0 }.sorted() == times)
}

@Test func splittingHandlesFewerFramesThanWorkers() {
    #expect(splitFrameTimes([5], workers: 4) == [[5]])
    #expect(splitFrameTimes([], workers: 4) == [[]])
    #expect(splitFrameTimes([1, 2, 3], workers: 1) == [[1, 2, 3]])
}
