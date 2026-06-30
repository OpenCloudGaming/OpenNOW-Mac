import SwiftUI
import WebRTCMedia

struct RecordingTimelineView: View {
    let segments: [RecordingEditorSegment]
    let selectedSegmentID: UUID?
    let playheadSeconds: Double
    let markInSeconds: Double?
    let markOutSeconds: Double?
    let onSelect: (RecordingEditorSegment) -> Void
    let onSeek: (Double) -> Void

    private var totalDuration: Double {
        max(segments.reduce(0) { $0 + $1.durationSeconds }, 0.01)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.black.opacity(0.34))
                ForEach(segmentFrames(in: proxy.size.width), id: \.segment.id) { item in
                    Button { onSelect(item.segment) } label: {
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(item.segment.id == selectedSegmentID ? Color.openNowGreen.opacity(0.35) : Color.white.opacity(0.11))
                            Rectangle()
                                .stroke(item.segment.id == selectedSegmentID ? Color.openNowGreen : Color.white.opacity(0.18), lineWidth: 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.segment.recording.title)
                                    .font(.recordingsNvidia(size: 10, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                                Text("\(recordingEditorDurationText(item.segment.startSeconds)) - \(recordingEditorDurationText(item.segment.endSeconds))")
                                    .font(.recordingsNvidia(size: 9, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.52))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: max(2, item.width), height: proxy.size.height)
                    .offset(x: item.x)
                }
                if let markFrame = markFrame(in: proxy.size.width) {
                    Rectangle()
                        .fill(Color.red.opacity(0.34))
                        .frame(width: max(2, markFrame.width), height: proxy.size.height)
                        .offset(x: markFrame.x)
                }
                Rectangle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 2, height: proxy.size.height + 8)
                    .shadow(color: Color.openNowGreen.opacity(0.95), radius: 7)
                    .offset(x: playheadX(in: proxy.size.width))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                onSeek(totalDuration * min(max(0, value.location.x / max(proxy.size.width, 1)), 1))
            })
        }
        .frame(height: 64)
        .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
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

    private func markFrame(in width: CGFloat) -> (x: CGFloat, width: CGFloat)? {
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
}

func recordingEditorDurationText(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded()))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}
