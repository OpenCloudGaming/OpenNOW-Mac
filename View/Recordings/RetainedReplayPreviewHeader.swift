//  The header over a replay window being watched: the window's facts, and the way back to the
//  library. Its Clip, Save all and Discard actions stay on the row that started the playback.
//

import SwiftUI

struct RetainedReplayPreviewHeader: View {
    let window: StreamReplayRetainedWindow
    let onStop: () -> Void
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 14 * uiScale) {
            Text("REPLAY WINDOW")
                .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(OPNDesign.accentInk)
                .fixedSize()
            VStack(alignment: .leading, spacing: 6 * uiScale) {
                Text(window.title)
                    .font(.recordingsFont(size: 13 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .lineLimit(1)
                facts
            }
            Spacer(minLength: 0)
            Button("Back to library", action: onStop)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
                .help("Stop watching this replay")
        }
        .padding(.horizontal, 22 * uiScale)
        .padding(.vertical, 12 * uiScale)
        .background(OPNDesign.Surface.deep)
        .overlay(alignment: .bottom) { Rectangle().fill(OPNDesign.Stroke.subtle).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Replay window, watching")
    }

    /// The same three facts the row that started the playback shows.
    private var facts: some View {
        HStack(spacing: 6 * uiScale) {
            RecordingPill(text: RecordingFormat.durationText(window.durationSeconds), isActive: false, uiScale: uiScale)
            RecordingPill(text: RecordingFormat.qualityText(width: window.width, height: window.height), isActive: false, uiScale: uiScale)
            RecordingPill(text: RecordingFormat.compactFileSizeText(window.fileSizeBytes), isActive: false, uiScale: uiScale)
        }
    }
}
