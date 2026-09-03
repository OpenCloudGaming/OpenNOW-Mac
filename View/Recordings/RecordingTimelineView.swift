import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RecordingTimelineView: View {
    let segments: [RecordingEditorSegment]
    let selectedSegmentID: UUID?
    let playheadSeconds: Double
    let markInSeconds: Double?
    let markOutSeconds: Double?
    let zoom: Double
    let uiScale: CGFloat
    let onSelect: (RecordingEditorSegment) -> Void
    let onSeek: (Double) -> Void
    let onRangeSelected: (Double, Double) -> Void
    let onPayloadDropped: (String, Int) -> Bool
    let onTrimBegin: (RecordingEditorSegment) -> Void
    let onSegmentTrimStart: (RecordingEditorSegment, Double) -> Void
    let onSegmentTrimEnd: (RecordingEditorSegment, Double) -> Void

    @State private var dragStartSeconds: Double?
    @State private var dragEndSeconds: Double?
    @State var activeTrimHandleID: String?
    /// The edge's source time when the drag started. Read live it would feed back on itself, since
    /// the segment it comes from is being edited by the drag.
    @State var trimBaseSeconds: Double?
    @State var trimSecondsPerPoint: Double = 0
    /// Where the handle currently is, before the trim is committed. Applying it live meant the clip
    /// regrew to fill the track on every frame of the drag, so the track rescaled under the pointer
    /// and there was no way to see what was about to be cut - or what a drag outward would restore.
    @State var pendingTrim: PendingTrim?
    /// Room reserved at one end of the track while a handle is dragged outward.
    ///
    /// The timeline fits its clips exactly, so a clip that fills the track has nowhere to grow: the
    /// handle hit the edge and stopped while the pointer kept going, which is what felt like losing
    /// the cursor. Reserving the space once, at drag start, gives the extension somewhere to be
    /// drawn and keeps the handle under the pointer for the whole drag.
    @State var trimHeadroom = RecordingTrimHeadroom.none

    struct PendingTrim: Equatable {
        let segmentID: UUID
        let isLeading: Bool
        /// The committed edge, so the preview knows which way and how far this has moved.
        let committedSeconds: Double
        var seconds: Double
    }
    @State private var proposedInsertionIndex: Int?

    /// The track's vertical layout, in one place. These were eight literals scattered through the
    /// file and they drifted: the trim handles were centred on the track while the clips were
    /// centred three points lower, which is exactly what it looked like.
    var trackHeight: CGFloat { 170 * uiScale }
    var rulerHeight: CGFloat { 18 * uiScale }
    var clipHeight: CGFloat { trackHeight - rulerHeight - 12 * uiScale }
    var clipTop: CGFloat { rulerHeight }
    var committedDuration: Double {
        max(segments.reduce(0) { $0 + $1.durationSeconds }, 0.01)
    }

    var totalDuration: Double {
        committedDuration + trimHeadroom.leading + trimHeadroom.trailing
    }

    private func geometry(width: CGFloat) -> RecordingTimelineGeometry {
        RecordingTimelineGeometry(totalDuration: totalDuration, width: width, zoom: zoom, playheadSeconds: playheadSeconds)
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = geometry(width: proxy.size.width)
            // `.topLeading`, not `.leading`: a `ZStack` centres its children vertically, so every
            // `offset(y:)` below was a delta from the middle of the track rather than a position in
            // it. That put the clips 15pt lower than intended - past the bottom edge, where they
            // were clipped - and the trim handles 25pt above them.
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.black.opacity(0.34))
                timelineRuler(layout: layout)
                ForEach(segmentFrames(layout: layout), id: \.segment.id) { item in
                    timelineClip(item, layout: layout)
                    if item.segment.id == selectedSegmentID {
                        trimHandle(item: item, layout: layout, isLeading: true)
                            .offset(x: handleOffset(edgeX: handleEdgeX(item: item, isLeading: true), layout: layout), y: handleTop)
                        trimHandle(item: item, layout: layout, isLeading: false)
                            .offset(x: handleOffset(edgeX: handleEdgeX(item: item, isLeading: false), layout: layout), y: handleTop)
                    }
                }
                if let item = segmentFrames(layout: layout).first(where: { $0.segment.id == pendingTrim?.segmentID }) {
                    trimPreview(item: item, layout: layout)
                }
                if let frame = activeSelectionFrame(layout: layout) {
                    selectionOverlay(frame: frame, opacity: 0.24)
                }
                if let frame = markedSelectionFrame(layout: layout) {
                    selectionOverlay(frame: frame, opacity: 0.36)
                }
                ForEach(cutBoundaries(layout: layout), id: \.x) { boundary in
                    cutMarker(x: boundary.x, isRemovedRange: boundary.isRemovedRange)
                }
                if let insertionX = insertionX(index: proposedInsertionIndex, layout: layout) {
                    insertionIndicator(x: insertionX)
                }
                playhead(layout: layout)
            }
            // Zoomed clips run past both edges of the track.
            .clipped()
            .contentShape(Rectangle())
            .gesture(timelineGesture(layout: layout))
            .onDrop(of: [.text], delegate: RecordingTimelineDropDelegate(
                layout: layout,
                segments: segments,
                proposedInsertionIndex: $proposedInsertionIndex,
                onPayloadDropped: onPayloadDropped
            ))
        }
        .frame(height: trackHeight)
        .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Editor timeline")
        .accessibilityValue(accessibilityValueText)
    }

    /// The timeline is a drag surface with no discrete controls in it, so it announces its state
    /// rather than pretending to be a list of buttons.
    private var accessibilityValueText: String {
        let clips = "\(segments.count) clip\(segments.count == 1 ? "" : "s")"
        let position = "playhead at \(recordingEditorPreciseTimeText(playheadSeconds)) of \(recordingEditorPreciseTimeText(totalDuration))"
        guard let markInSeconds, let markOutSeconds else { return "\(clips), \(position)" }
        return "\(clips), \(position), selection \(String(format: "%.1f", abs(markOutSeconds - markInSeconds))) seconds"
    }

    // MARK: - Clips

    private func timelineClip(_ item: TimelineClipFrame, layout: RecordingTimelineGeometry) -> some View {
        let isSelected = item.segment.id == selectedSegmentID
        let drawn = layout.displayFrame(x: item.x, width: item.width)
        // The source range the drawn rect actually covers. `displayFrame` clamps a zoomed clip to
        // the track, so the rect is a *window* onto the clip - handing the strip the clip's whole
        // start...end spread it across that window and drew frames from the wrong moments, by up to
        // the zoom factor.
        let drawnRange = drawnSourceRange(of: item, drawn: drawn)
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.black.opacity(0.30))
            if drawn.width > 24 {
                RecordingFilmstripView(
                    recording: item.segment.recording,
                    clipID: item.segment.id,
                    startSeconds: drawnRange.lowerBound,
                    endSeconds: drawnRange.upperBound,
                    size: CGSize(width: drawn.width, height: clipHeight),
                    visibleRange: visibleSourceRange(of: item, layout: layout)
                )
            }
            // Only behind the label. Across the whole clip this washed out every frame to the
            // right of it as well, for no reason.
            LinearGradient(colors: [.black.opacity(0.80), .black.opacity(0.00)], startPoint: .leading, endPoint: .trailing)
                .frame(width: min(drawn.width, 210 * uiScale))
                .frame(maxWidth: .infinity, alignment: .leading)
            if drawn.width > 24 {
                waveform(for: item, range: drawnRange, width: drawn.width)
            }
            // Selection reads from the border; a heavy fill on top of the frames only greened them.
            Rectangle()
                .fill(isSelected ? OpenNOWDesign.accent.opacity(0.07) : Color.clear)
            Rectangle()
                .stroke(isSelected ? OpenNOWDesign.accent : Color.white.opacity(0.18), lineWidth: isSelected ? 1.4 : 1)
            HStack(spacing: 8 * uiScale) {
                VStack(alignment: .leading, spacing: 2 * uiScale) {
                    Text(item.segment.recording.title)
                        .font(.recordingsNvidia(size: 11 * uiScale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Text("\(recordingEditorDurationText(item.segment.startSeconds)) - \(recordingEditorDurationText(item.segment.endSeconds))")
                        .font(.recordingsNvidia(size: 9 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Text("KEEP")
                        .font(.recordingsNvidia(size: 8 * uiScale, weight: .bold))
                        .foregroundStyle(.black.opacity(0.82))
                        .padding(.horizontal, 5 * uiScale)
                        .frame(height: 15 * uiScale)
                        .background(OpenNOWDesign.accent)
                }
            }
            .padding(.horizontal, 10 * uiScale)
        }
        .frame(width: max(2, drawn.width), height: clipHeight)
        .offset(x: drawn.x, y: clipTop)
        .onTapGesture { onSelect(item.segment) }
        .onDrag {
            NSItemProvider(object: RecordingEditorDragPayload.segment(item.segment.id).stringValue as NSString)
        }
    }

    /// The clip's source range that the drawn rect covers, which is the whole clip only while it
    /// fits on the track.
    private func waveform(for item: TimelineClipFrame, range: ClosedRange<Double>, width: CGFloat) -> some View {
        RecordingWaveformView(
            recording: item.segment.recording,
            startSeconds: range.lowerBound,
            endSeconds: range.upperBound,
            size: CGSize(width: width, height: 34 * uiScale)
        )
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func drawnSourceRange(of item: TimelineClipFrame, drawn: (x: CGFloat, width: CGFloat)) -> ClosedRange<Double> {
        let span = item.segment.durationSeconds
        guard item.width > 1, span > 0 else { return item.segment.startSeconds...item.segment.endSeconds }
        let leading = min(max(0, Double((drawn.x - item.x) / item.width)), 1)
        let trailing = min(max(leading, Double((drawn.x + drawn.width - item.x) / item.width)), 1)
        let lower = item.segment.startSeconds + span * leading
        let upper = item.segment.startSeconds + span * trailing
        return lower...max(lower + 0.0001, upper)
    }

    /// The part of the clip's source that is actually on screen, so the strip can decode fine
    /// frames for it. At zoom 1 that is the whole clip and the coarse grid is enough; zoomed in it
    /// is a few seconds, which is worth sixty-four frames of its own.
    private func visibleSourceRange(of item: TimelineClipFrame, layout: RecordingTimelineGeometry) -> ClosedRange<Double>? {
        guard layout.isZoomed, item.width > 1 else { return nil }
        let leadingFraction = min(max(0, -item.x / item.width), 1)
        let trailingFraction = min(max(0, (layout.width - item.x) / item.width), 1)
        guard trailingFraction > leadingFraction else { return nil }
        let span = item.segment.durationSeconds
        let lower = item.segment.startSeconds + span * Double(leadingFraction)
        let upper = item.segment.startSeconds + span * Double(trailingFraction)
        guard upper > lower else { return nil }
        return lower...upper
    }

    // MARK: - Overlays

    private func playhead(layout: RecordingTimelineGeometry) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.94))
            .frame(width: 2, height: trackHeight + 8 * uiScale)
            .shadow(color: OpenNOWDesign.accent.opacity(0.95), radius: 7)
            .offset(x: layout.x(forSeconds: playheadSeconds + trimHeadroom.leading), y: -4 * uiScale)
    }

    private func selectionOverlay(frame: (x: CGFloat, width: CGFloat), opacity: Double) -> some View {
        Rectangle()
            .fill(Color.red.opacity(opacity))
            .frame(width: max(2, frame.width), height: clipHeight)
            .overlay { Rectangle().strokeBorder(Color.red.opacity(0.62), lineWidth: 1) }
            .offset(x: frame.x, y: clipTop)
    }

    /// Where one section of a recording meets the next. Two sections of the same source read as
    /// two unrelated clips otherwise, which is what made a Remove Selection look like it had split
    /// the video by mistake.
    private func cutBoundaries(layout: RecordingTimelineGeometry) -> [(x: CGFloat, isRemovedRange: Bool)] {
        let frames = segmentFrames(layout: layout)
        return zip(frames, frames.dropFirst()).compactMap { left, right in
            guard left.segment.recording.id == right.segment.recording.id else { return nil }
            let x = right.x
            guard x >= 0, x <= layout.width else { return nil }
            // Contiguous in the source means a plain split; a jump means footage was removed here.
            let isRemovedRange = abs(left.segment.endSeconds - right.segment.startSeconds) > RecordingEditorViewModel.sectionJoinTolerance
            return (x, isRemovedRange)
        }
    }

    private func cutMarker(x: CGFloat, isRemovedRange: Bool) -> some View {
        VStack(spacing: 1 * uiScale) {
            Image(systemName: isRemovedRange ? "scissors" : "arrow.left.and.right")
                .font(.recordingsNvidia(size: 8 * uiScale, weight: .bold))
                .foregroundStyle(.black.opacity(0.86))
                .frame(width: 14 * uiScale, height: 12 * uiScale)
                .background(isRemovedRange ? RecordingsLayout.danger : OpenNOWDesign.accent)
            Rectangle()
                .fill(isRemovedRange ? RecordingsLayout.danger : OpenNOWDesign.accent)
                .frame(width: 2, height: clipHeight - 14 * uiScale)
        }
        .offset(x: x - 7 * uiScale, y: clipTop - 2 * uiScale)
        .allowsHitTesting(false)
        .help(isRemovedRange ? "Footage was removed here. The sections play back to back." : "Split point. Join merges them back.")
    }

    private func insertionIndicator(x: CGFloat) -> some View {
        Rectangle()
            .fill(OpenNOWDesign.accent)
            .frame(width: 3, height: clipHeight + 8 * uiScale)
            .shadow(color: OpenNOWDesign.accent.opacity(0.80), radius: 8)
            .offset(x: x - 1.5, y: clipTop - 4 * uiScale)
    }

    private func timelineRuler(layout: RecordingTimelineGeometry) -> some View {
        let ticks = layout.rulerTickSeconds()
        let step = RecordingTimelineGeometry.rulerStepSeconds(visibleDuration: layout.visibleDuration)
        return ZStack(alignment: .topLeading) {
            Path { path in
                for seconds in ticks {
                    let x = layout.x(forSeconds: seconds)
                    path.move(to: CGPoint(x: x, y: rulerHeight - 7 * uiScale))
                    path.addLine(to: CGPoint(x: x, y: rulerHeight))
                }
            }
            .stroke(Color.white.opacity(0.20), lineWidth: 1)
            ForEach(ticks, id: \.self) { seconds in
                let x = layout.x(forSeconds: seconds)
                // The last label would otherwise hang off the right edge of the track.
                if x >= 0, x < layout.width - 26 * uiScale {
                    // Tenths once the step is sub-second: whole-second labels repeat themselves
                    // ("0:11 0:11 0:12 0:12") at exactly the zoom where the sub-second detail is
                    // the reason to be there.
                    Text(step < 1 ? recordingEditorPreciseTimeText(seconds) : recordingEditorDurationText(seconds))
                        .font(.recordingsNvidia(size: 8 * uiScale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.42))
                        .fixedSize()
                        .offset(x: x + 3 * uiScale, y: 0)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Gestures

    private func timelineGesture(layout: RecordingTimelineGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let current = layout.seconds(forX: value.location.x) - trimHeadroom.leading
                if dragStartSeconds == nil { dragStartSeconds = current }
                dragEndSeconds = current
            }
            .onEnded { value in
                let end = layout.seconds(forX: value.location.x) - trimHeadroom.leading
                let start = dragStartSeconds ?? end
                defer {
                    dragStartSeconds = nil
                    dragEndSeconds = nil
                }
                if abs(value.translation.width) < 4 {
                    // Shift-click marks from the playhead to where you clicked, the same range a
                    // drag would have produced. Read from the current modifier state because a
                    // SwiftUI drag gesture does not carry the flags that were held during it.
                    if NSEvent.modifierFlags.contains(.shift) {
                        onRangeSelected(playheadSeconds, end)
                    } else {
                        if let segment = segment(at: end) { onSelect(segment) }
                        onSeek(end)
                    }
                } else {
                    onRangeSelected(start, end)
                }
            }
    }

    // MARK: - Layout

    func segmentFrames(layout: RecordingTimelineGeometry) -> [TimelineClipFrame] {
        var cursor = trimHeadroom.leading
        return segments.map { segment in
            let x = layout.x(forSeconds: cursor)
            let end = layout.x(forSeconds: cursor + segment.durationSeconds)
            cursor += segment.durationSeconds
            return TimelineClipFrame(segment: segment, x: x, width: end - x)
        }
    }

    private func insertionX(index: Int?, layout: RecordingTimelineGeometry) -> CGFloat? {
        guard let index else { return nil }
        let frames = segmentFrames(layout: layout)
        if index <= 0 { return layout.x(forSeconds: 0) }
        if index >= frames.count { return layout.x(forSeconds: totalDuration) }
        return frames[index].x
    }

    private func segment(at timelineSeconds: Double) -> RecordingEditorSegment? {
        var cursor = 0.0
        for segment in segments {
            let next = cursor + segment.durationSeconds
            if timelineSeconds <= next || segment.id == segments.last?.id { return segment }
            cursor = next
        }
        return nil
    }

    private func sourceSeconds(in item: TimelineClipFrame, timelineX: CGFloat) -> Double {
        let ratio = min(max(0, Double((timelineX - item.x) / max(item.width, 1))), 1)
        return item.segment.startSeconds + item.segment.durationSeconds * ratio
    }

    private func markedSelectionFrame(layout: RecordingTimelineGeometry) -> (x: CGFloat, width: CGFloat)? {
        guard let markInSeconds, let markOutSeconds, let selected = segments.first(where: { $0.id == selectedSegmentID }) else { return nil }
        var cursor = trimHeadroom.leading
        for segment in segments {
            if segment.id == selected.id {
                // The marks are source times inside the selected clip; the track is cumulative.
                let start = min(max(selected.startSeconds, min(markInSeconds, markOutSeconds)), selected.endSeconds) - selected.startSeconds
                let end = min(max(selected.startSeconds, max(markInSeconds, markOutSeconds)), selected.endSeconds) - selected.startSeconds
                let startX = layout.x(forSeconds: cursor + start)
                let endX = layout.x(forSeconds: cursor + end)
                return layout.displayFrame(x: startX, width: endX - startX)
            }
            cursor += segment.durationSeconds
        }
        return nil
    }

    private func activeSelectionFrame(layout: RecordingTimelineGeometry) -> (x: CGFloat, width: CGFloat)? {
        guard let dragStartSeconds, let dragEndSeconds, abs(dragStartSeconds - dragEndSeconds) > 0.03 else { return nil }
        let start = layout.x(forSeconds: min(dragStartSeconds, dragEndSeconds))
        let end = layout.x(forSeconds: max(dragStartSeconds, dragEndSeconds))
        return layout.displayFrame(x: start, width: end - start)
    }
}

struct TimelineClipFrame {
    let segment: RecordingEditorSegment
    let x: CGFloat
    let width: CGFloat
}

/// Tenths, because trimming is done against a readout and whole seconds hide the frame you are
/// actually parked on.
func recordingEditorPreciseTimeText(_ seconds: Double) -> String {
    let value = max(0, seconds.isFinite ? seconds : 0)
    // Rounded off the total tenths rather than truncating the remainder: 3661.2 lands at
    // 3661.19999... in binary, and truncating printed it as .1.
    let totalTenths = Int((value * 10).rounded())
    let whole = totalTenths / 10
    let tenths = totalTenths % 10
    if whole >= 3600 { return String(format: "%d:%02d:%02d.%d", whole / 3600, (whole / 60) % 60, whole % 60, tenths) }
    return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenths)
}

func recordingEditorDurationText(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded()))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}

private struct RecordingTimelineDropDelegate: DropDelegate {
    let layout: RecordingTimelineGeometry
    let segments: [RecordingEditorSegment]
    @Binding var proposedInsertionIndex: Int?
    let onPayloadDropped: (String, Int) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        proposedInsertionIndex = insertionIndex(for: info.location.x)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        proposedInsertionIndex = insertionIndex(for: info.location.x)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        proposedInsertionIndex = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let insertionIndex = proposedInsertionIndex ?? insertionIndex(for: info.location.x)
        proposedInsertionIndex = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String else { return }
            Task { @MainActor in
                _ = onPayloadDropped(payload, insertionIndex)
            }
        }
        return true
    }

    /// Which gap the drop lands in, decided in timeline seconds so it stays right when zoomed.
    private func insertionIndex(for x: CGFloat) -> Int {
        guard !segments.isEmpty else { return 0 }
        let dropSeconds = layout.seconds(forX: x)
        var cursor = 0.0
        for (index, segment) in segments.enumerated() {
            if dropSeconds < cursor + segment.durationSeconds / 2 { return index }
            cursor += segment.durationSeconds
        }
        return segments.count
    }
}
