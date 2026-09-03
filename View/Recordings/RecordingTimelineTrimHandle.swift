//  The green trim handles and the preview of what releasing one would do.
//
//  A drag does not change the clip. Applying it live meant the clip regrew to fill the track on
//  every frame, so the track rescaled under the pointer, there was no way to see what was about to
//  be cut, and dragging back out had nowhere to go. The drag moves a handle; the release makes the
//  edit, as one undo step.
//

import AppKit
import SwiftUI

extension RecordingTimelineView {
    /// Handle geometry. The bar stays slim so it does not hide the frames underneath, but the part
    /// that accepts the drag is twice as wide - a 12 pt target on a moving timeline was the whole
    /// complaint. The offset is clamped into the track so an edge handle is never half-clipped.
    var handleBarWidth: CGFloat { 10 * uiScale }
    var handleHitWidth: CGFloat { 24 * uiScale }
    var handleBarHeight: CGFloat { clipHeight + 12 * uiScale }
    var handleHitHeight: CGFloat { clipHeight + 20 * uiScale }
    /// The hit frame's top, placed so the bar inside it overhangs the clip band by 6pt each end.
    var handleTop: CGFloat { clipTop - 10 * uiScale }

    func handleOffset(edgeX: CGFloat, layout: RecordingTimelineGeometry) -> CGFloat {
        // Clamped only to the track's own bounds, which the reserved headroom keeps the handle
        // inside for the whole drag. Clamping it to the *clips* is what pinned it at the edge while
        // the pointer carried on.
        let centred = edgeX - handleHitWidth / 2
        return centred.clampedBetween(0, layout.width - handleHitWidth)
    }

    func trimHandle(item: TimelineClipFrame, layout: RecordingTimelineGeometry, isLeading: Bool) -> some View {
        ZStack {
            // Transparent, and wider than the bar: this is what the pointer actually has to hit.
            Color.white.opacity(0.001)
            Rectangle()
                .fill(OpenNOWDesign.accent)
                .frame(width: handleBarWidth, height: handleBarHeight)
                .overlay {
                    // Grip lines, so it reads as something to drag rather than as a marker.
                    VStack(spacing: 3 * uiScale) {
                        ForEach(0..<3, id: \.self) { _ in
                            Rectangle().fill(Color.black.opacity(0.38)).frame(width: 4 * uiScale, height: 1.5 * uiScale)
                        }
                    }
                }
                .overlay { Rectangle().stroke(Color.black.opacity(0.35), lineWidth: 1) }
        }
        .frame(width: handleHitWidth, height: handleHitHeight)
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(trimDrag(item: item, layout: layout, isLeading: isLeading))
    }

    /// The drag itself: move now, commit on release.
    private func trimDrag(item: TimelineClipFrame, layout: RecordingTimelineGeometry, isLeading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                    let key = item.segment.id.uuidString + (isLeading ? "-leading" : "-trailing")
                    if activeTrimHandleID != key {
                        activeTrimHandleID = key
                        let base = isLeading ? item.segment.startSeconds : item.segment.endSeconds
                        trimBaseSeconds = base
                        // Frozen with the base value, and now genuinely constant: the segments are
                        // untouched until release, so the track does not rescale mid-drag.
                        // Reserved before the scale is read, so the scale already accounts for the
                        // room the drag may need. Both stay fixed for the whole gesture.
                        trimHeadroom = RecordingTrimHeadroom.forDrag(
                            isLeading: isLeading,
                            segmentStart: item.segment.startSeconds,
                            segmentEnd: item.segment.endSeconds,
                            sourceDuration: item.segment.recording.durationSeconds,
                            committedDuration: committedDuration
                        )
                        trimSecondsPerPoint = totalDuration / Double(max(layout.width, 1))
                        pendingTrim = PendingTrim(segmentID: item.segment.id, isLeading: isLeading, committedSeconds: base, seconds: base)
                    }
                    guard let base = trimBaseSeconds else { return }
                    let edgeX = item.x + (isLeading ? 0 : item.width)
                    let snappedX = RecordingTimelineGeometry.snapped(
                        x: edgeX + value.translation.width,
                        to: snapTargets(layout: layout, excluding: item.segment.id),
                        threshold: 7 * uiScale
                    )
                    let seconds = base + Double(snappedX - edgeX) * trimSecondsPerPoint
                    pendingTrim?.seconds = boundedTrimSeconds(seconds, for: item.segment, isLeading: isLeading)
                }
                .onEnded { _ in
                    // The edit lands here, as one undo step. Nothing was mutated during the drag.
                    if let pending = pendingTrim, pending.seconds != pending.committedSeconds {
                        onTrimBegin(item.segment)
                        if pending.isLeading {
                            onSegmentTrimStart(item.segment, pending.seconds)
                        } else {
                            onSegmentTrimEnd(item.segment, pending.seconds)
                        }
                    }
                    activeTrimHandleID = nil
                    trimBaseSeconds = nil
                    trimSecondsPerPoint = 0
                    pendingTrim = nil
                    trimHeadroom = .none
                }
    }

    /// The x a handle should sit at: the pending edge while it is being dragged, the committed one
    /// otherwise.
    func handleEdgeX(item: TimelineClipFrame, isLeading: Bool) -> CGFloat {
        let committed = item.x + (isLeading ? 0 : item.width)
        guard let pending = pendingTrim,
              pending.segmentID == item.segment.id,
              pending.isLeading == isLeading,
              trimSecondsPerPoint > 0 else { return committed }
        return committed + CGFloat((pending.seconds - pending.committedSeconds) / trimSecondsPerPoint)
    }

    /// The source recording's real limits, so a drag outward stops where the footage does and the
    /// clip keeps a usable length.
    /// The source's real limits, narrowed to the room reserved for this drag. Without the second
    /// bound the handle would run past the end of the track again, which is the thing the headroom
    /// exists to prevent.
    private func boundedTrimSeconds(_ seconds: Double, for segment: RecordingEditorSegment, isLeading: Bool) -> Double {
        if isLeading {
            let earliest = max(0, segment.startSeconds - trimHeadroom.leading)
            return seconds.clampedBetween(earliest, segment.endSeconds - 0.05)
        }
        let latest = min(segment.recording.durationSeconds, segment.endSeconds + trimHeadroom.trailing)
        return seconds.clampedBetween(segment.startSeconds + 0.05, latest)
    }

    /// What the release will do, drawn before it happens.
    ///
    /// Dragging inward shades the part about to be cut. Dragging outward paints the footage that
    /// would come back - real frames, taken from the base grid that is already decoded, so the
    /// decision is made against the picture rather than against a timecode.
    @ViewBuilder
    func trimPreview(item: TimelineClipFrame, layout: RecordingTimelineGeometry) -> some View {
        if let pending = pendingTrim, trimSecondsPerPoint > 0 {
            let committedX = item.x + (pending.isLeading ? 0 : item.width)
            let pendingX = committedX + CGFloat((pending.seconds - pending.committedSeconds) / trimSecondsPerPoint)
            let lowerX = min(committedX, pendingX)
            let width = abs(pendingX - committedX)
            let isRestoring = pending.isLeading
                ? pending.seconds < pending.committedSeconds
                : pending.seconds > pending.committedSeconds
            if width > 1 {
                Group {
                    if isRestoring {
                        RecordingFilmstripView(
                            recording: item.segment.recording,
                            clipID: item.segment.id,
                            startSeconds: min(pending.seconds, pending.committedSeconds),
                            endSeconds: max(pending.seconds, pending.committedSeconds),
                            size: CGSize(width: width, height: clipHeight),
                            // Base grid only: these frames are already decoded, so the preview is
                            // immediate and a drag never queues decode work it will throw away.
                            visibleRange: nil
                        )
                        .overlay { Rectangle().fill(OpenNOWDesign.accent.opacity(0.16)) }
                        .overlay { Rectangle().strokeBorder(OpenNOWDesign.accent, lineWidth: 1) }
                    } else {
                        Rectangle()
                            .fill(Color.black.opacity(0.62))
                            .overlay { Rectangle().fill(RecordingsLayout.danger.opacity(0.22)) }
                            .overlay { Rectangle().strokeBorder(RecordingsLayout.danger.opacity(0.75), lineWidth: 1) }
                    }
                }
                .frame(width: width, height: clipHeight)
                .offset(x: lowerX, y: clipTop)
                .allowsHitTesting(false)
            }
        }
    }

    /// Where a trim handle is allowed to click into place: the playhead, the other clips' edges,
    /// and both ends of the timeline.
    private func snapTargets(layout: RecordingTimelineGeometry, excluding segmentID: UUID) -> [CGFloat] {
        var targets: [CGFloat] = [layout.x(forSeconds: playheadSeconds), layout.x(forSeconds: 0), layout.x(forSeconds: totalDuration)]
        for frame in segmentFrames(layout: layout) where frame.segment.id != segmentID {
            targets.append(frame.x)
            targets.append(frame.x + frame.width)
        }
        return targets
    }
}
