import SwiftUI
import UniformTypeIdentifiers

struct RecordingTimelineView: View {
    let segments: [RecordingEditorSegment]
    let selectedSegmentID: UUID?
    let playheadSeconds: Double
    let markInSeconds: Double?
    let markOutSeconds: Double?
    let onSelect: (RecordingEditorSegment) -> Void
    let onSeek: (Double) -> Void
    let onRangeSelected: (Double, Double) -> Void
    let onPayloadDropped: (String, Int) -> Bool
    let onTrimBegin: (RecordingEditorSegment) -> Void
    let onSegmentTrimStart: (RecordingEditorSegment, Double) -> Void
    let onSegmentTrimEnd: (RecordingEditorSegment, Double) -> Void

    @State private var dragStartSeconds: Double?
    @State private var dragEndSeconds: Double?
    @State private var activeTrimHandleID: String?
    @State private var proposedInsertionIndex: Int?

    private var totalDuration: Double {
        max(segments.reduce(0) { $0 + $1.durationSeconds }, 0.01)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.black.opacity(0.34))
                timelineTicks(width: proxy.size.width)
                ForEach(segmentFrames(in: proxy.size.width), id: \.segment.id) { item in
                    timelineClip(item)
                    if item.segment.id == selectedSegmentID {
                        trimHandle(item: item, isLeading: true)
                            .offset(x: item.x - 6)
                        trimHandle(item: item, isLeading: false)
                            .offset(x: item.x + item.width - 6)
                    }
                }
                if let frame = activeSelectionFrame(in: proxy.size.width) {
                    selectionOverlay(frame: frame, opacity: 0.24)
                }
                if let frame = markedSelectionFrame(in: proxy.size.width) {
                    selectionOverlay(frame: frame, opacity: 0.36)
                }
                if let insertionX = insertionX(index: proposedInsertionIndex, width: proxy.size.width) {
                    insertionIndicator(x: insertionX)
                }
                playhead(width: proxy.size.width)
            }
            .contentShape(Rectangle())
            .gesture(timelineGesture(width: proxy.size.width))
            .onDrop(of: [.text], delegate: RecordingTimelineDropDelegate(
                width: proxy.size.width,
                segments: segments,
                proposedInsertionIndex: $proposedInsertionIndex,
                onPayloadDropped: onPayloadDropped
            ))
        }
        .frame(height: 86)
        .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
    }

    private func timelineClip(_ item: (segment: RecordingEditorSegment, x: CGFloat, width: CGFloat)) -> some View {
        let isSelected = item.segment.id == selectedSegmentID
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? Color.openNowGreen.opacity(0.30) : Color.white.opacity(0.10))
            Rectangle()
                .stroke(isSelected ? Color.openNowGreen : Color.white.opacity(0.18), lineWidth: isSelected ? 1.4 : 1)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.segment.recording.title)
                        .font(.recordingsNvidia(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Text("\(recordingEditorDurationText(item.segment.startSeconds)) - \(recordingEditorDurationText(item.segment.endSeconds))")
                        .font(.recordingsNvidia(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Text("KEEP")
                        .font(.recordingsNvidia(size: 8, weight: .bold))
                        .foregroundStyle(.black.opacity(0.82))
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(Color.openNowGreen)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(width: max(2, item.width), height: 58)
        .offset(x: item.x, y: 14)
        .onTapGesture { onSelect(item.segment) }
        .onDrag {
            NSItemProvider(object: RecordingEditorDragPayload.segment(item.segment.id).stringValue as NSString)
        }
    }

    private func trimHandle(item: (segment: RecordingEditorSegment, x: CGFloat, width: CGFloat), isLeading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.openNowGreen)
            .frame(width: 12, height: 72)
            .overlay(alignment: isLeading ? .leading : .trailing) {
                Rectangle().fill(Color.black.opacity(0.30)).frame(width: 2)
            }
            .shadow(color: Color.openNowGreen.opacity(0.55), radius: 6)
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let key = item.segment.id.uuidString + (isLeading ? "-leading" : "-trailing")
                    if activeTrimHandleID != key {
                        activeTrimHandleID = key
                        onTrimBegin(item.segment)
                    }
                    let handleX = item.x + (isLeading ? 0 : item.width) + value.translation.width
                    let seconds = sourceSeconds(in: item, timelineX: handleX)
                    if isLeading {
                        onSegmentTrimStart(item.segment, seconds)
                    } else {
                        onSegmentTrimEnd(item.segment, seconds)
                    }
                }
                .onEnded { _ in activeTrimHandleID = nil }
            )
    }

    private func playhead(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.94))
            .frame(width: 2, height: 94)
            .shadow(color: Color.openNowGreen.opacity(0.95), radius: 7)
            .offset(x: playheadX(in: width), y: -4)
    }

    private func selectionOverlay(frame: (x: CGFloat, width: CGFloat), opacity: Double) -> some View {
        Rectangle()
            .fill(Color.red.opacity(opacity))
            .frame(width: max(2, frame.width), height: 58)
            .overlay { Rectangle().stroke(Color.red.opacity(0.62), lineWidth: 1) }
            .offset(x: frame.x, y: 14)
    }

    private func insertionIndicator(x: CGFloat) -> some View {
        Rectangle()
            .fill(Color.openNowGreen)
            .frame(width: 3, height: 78)
            .shadow(color: Color.openNowGreen.opacity(0.80), radius: 8)
            .offset(x: x - 1.5, y: 8)
    }

    private func timelineTicks(width: CGFloat) -> some View {
        Path { path in
            let tickCount = 12
            for index in 0...tickCount {
                let x = CGFloat(index) / CGFloat(tickCount) * width
                path.move(to: CGPoint(x: x, y: 5))
                path.addLine(to: CGPoint(x: x, y: index.isMultiple(of: 3) ? 16 : 11))
            }
        }
        .stroke(Color.white.opacity(0.14), lineWidth: 1)
    }

    private func timelineGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let current = timelineSeconds(for: value.location.x, width: width)
                if dragStartSeconds == nil { dragStartSeconds = current }
                dragEndSeconds = current
            }
            .onEnded { value in
                let end = timelineSeconds(for: value.location.x, width: width)
                let start = dragStartSeconds ?? end
                defer {
                    dragStartSeconds = nil
                    dragEndSeconds = nil
                }
                if abs(value.translation.width) < 4 {
                    if let segment = segment(at: end) { onSelect(segment) }
                    onSeek(end)
                } else {
                    onRangeSelected(start, end)
                }
            }
    }

    private func segmentFrames(in width: CGFloat) -> [(segment: RecordingEditorSegment, x: CGFloat, width: CGFloat)] {
        var cursor = 0.0
        return segments.map { segment in
            let segmentWidth = CGFloat(segment.durationSeconds / totalDuration) * width
            let x = CGFloat(cursor / totalDuration) * width
            cursor += segment.durationSeconds
            return (segment, x, segmentWidth)
        }
    }

    private func insertionX(index: Int?, width: CGFloat) -> CGFloat? {
        guard let index else { return nil }
        let frames = segmentFrames(in: width)
        if index <= 0 { return 0 }
        if index >= frames.count { return width }
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

    private func timelineSeconds(for x: CGFloat, width: CGFloat) -> Double {
        totalDuration * min(max(0, Double(x / max(width, 1))), 1)
    }

    private func sourceSeconds(in item: (segment: RecordingEditorSegment, x: CGFloat, width: CGFloat), timelineX: CGFloat) -> Double {
        let ratio = min(max(0, Double((timelineX - item.x) / max(item.width, 1))), 1)
        return item.segment.startSeconds + item.segment.durationSeconds * ratio
    }

    private func playheadX(in width: CGFloat) -> CGFloat {
        guard let selected = segments.first(where: { $0.id == selectedSegmentID }) ?? segments.first else { return 0 }
        var cursor = 0.0
        for segment in segments {
            if segment.id == selected.id {
                let local = min(max(selected.startSeconds, playheadSeconds), selected.endSeconds) - selected.startSeconds
                return CGFloat((cursor + local) / totalDuration) * width
            }
            cursor += segment.durationSeconds
        }
        return 0
    }

    private func markedSelectionFrame(in width: CGFloat) -> (x: CGFloat, width: CGFloat)? {
        guard let markInSeconds, let markOutSeconds, let selected = segments.first(where: { $0.id == selectedSegmentID }) else { return nil }
        var cursor = 0.0
        for segment in segments {
            if segment.id == selected.id {
                let start = min(max(selected.startSeconds, min(markInSeconds, markOutSeconds)), selected.endSeconds) - selected.startSeconds
                let end = min(max(selected.startSeconds, max(markInSeconds, markOutSeconds)), selected.endSeconds) - selected.startSeconds
                return (CGFloat((cursor + start) / totalDuration) * width, CGFloat(max(0, end - start) / totalDuration) * width)
            }
            cursor += segment.durationSeconds
        }
        return nil
    }

    private func activeSelectionFrame(in width: CGFloat) -> (x: CGFloat, width: CGFloat)? {
        guard let dragStartSeconds, let dragEndSeconds, abs(dragStartSeconds - dragEndSeconds) > 0.03 else { return nil }
        let start = CGFloat(min(dragStartSeconds, dragEndSeconds) / totalDuration) * width
        let end = CGFloat(max(dragStartSeconds, dragEndSeconds) / totalDuration) * width
        return (start, end - start)
    }
}

func recordingEditorDurationText(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded()))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}

private struct RecordingTimelineDropDelegate: DropDelegate {
    let width: CGFloat
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
            DispatchQueue.main.async {
                _ = onPayloadDropped(payload, insertionIndex)
            }
        }
        return true
    }

    private func insertionIndex(for x: CGFloat) -> Int {
        guard !segments.isEmpty else { return 0 }
        var cursor = CGFloat.zero
        let totalDuration = max(segments.reduce(0) { $0 + $1.durationSeconds }, 0.01)
        for (index, segment) in segments.enumerated() {
            let segmentWidth = CGFloat(segment.durationSeconds / totalDuration) * width
            if x < cursor + segmentWidth / 2 { return index }
            cursor += segmentWidth
        }
        return segments.count
    }
}
