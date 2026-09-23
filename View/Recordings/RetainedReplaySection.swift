import SwiftUI

/// Replay windows whose stream has ended and whose ring is still on disk, above the library because
/// they are the footage from the sessions just played. One window per title, rolling per title.
struct RetainedReplaySection: View {
    let windows: [StreamReplayRetainedWindow]
    let keepingWindowID: UUID?
    let watchedWindowID: UUID?
    let message: String
    let usageText: String
    let uiScale: CGFloat
    let onWatch: (StreamReplayRetainedWindow) -> Void
    let onClip: (StreamReplayRetainedWindow) -> Void
    let onKeep: (StreamReplayRetainedWindow) -> Void
    let onDiscard: (StreamReplayRetainedWindow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            header
            ForEach(windows) { window in
                RetainedReplayRow(
                    window: window,
                    isWatching: watchedWindowID == window.id,
                    isKeeping: keepingWindowID == window.id,
                    isBusy: keepingWindowID != nil,
                    uiScale: uiScale,
                    onWatch: { onWatch(window) },
                    onClip: { onClip(window) },
                    onKeep: { onKeep(window) },
                    onDiscard: { onDiscard(window) }
                )
            }
            if !message.isEmpty {
                Text(message)
                    .font(.recordingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14 * uiScale)
        .padding(.top, 16 * uiScale)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8 * uiScale) {
            Text("RECENT REPLAYS")
                .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(OPNDesign.Text.muted)
            Spacer(minLength: 0)
            Text(usageText)
                .font(.recordingsFont(size: 10 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.muted)
                .lineLimit(1)
        }
    }
}

private struct RetainedReplayRow: View {
    let window: StreamReplayRetainedWindow
    let isWatching: Bool
    let isKeeping: Bool
    let isBusy: Bool
    let uiScale: CGFloat
    let onWatch: () -> Void
    let onClip: () -> Void
    let onKeep: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * uiScale) {
            watchButton
            HStack(spacing: 8 * uiScale) {
                actionButton("Clip", isPrimary: true, isDisabled: isBusy, action: onClip)
                actionButton("Save all", isPrimary: false, isDisabled: isBusy, action: onKeep)
                actionButton("Discard", isPrimary: false, isDisabled: isBusy, action: onDiscard)
                Spacer(minLength: 0)
                if isKeeping {
                    Text("Saving…")
                        .font(.recordingsFont(size: 11 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.accentInk)
                }
            }
        }
        .padding(12 * uiScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RecordingsLayout.raised)
        .overlay { Rectangle().strokeBorder(isWatching ? OPNDesign.accent : RecordingsLayout.stroke, lineWidth: 1) }
    }

    /// The facts block is the play control, not a fourth button: the card is what the reader aims
    /// at, and the glyph says the footage can be watched before any of the actions are chosen.
    private var watchButton: some View {
        Button(action: onWatch) {
            HStack(spacing: 9 * uiScale) {
                Image(systemName: isWatching ? "pause.circle.fill" : "play.circle")
                    .font(.recordingsFont(size: 16 * uiScale, weight: .bold))
                    .foregroundStyle(isWatching ? OPNDesign.accent : OPNDesign.Text.secondary)
                VStack(alignment: .leading, spacing: 6 * uiScale) {
                    Text(window.title)
                        .font(.recordingsFont(size: 13 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                        .lineLimit(1)
                    facts
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.46 : 1)
        .help(isWatching ? "Stop watching this replay" : "Watch this replay")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.title)
        .accessibilityValue(factsText)
        .accessibilityHint(isWatching ? "Stops the playback" : "Plays this replay in the player pane")
    }

    /// The same three facts the library rows show, in the same order.
    private var facts: some View {
        HStack(spacing: 6 * uiScale) {
            RecordingPill(text: RecordingFormat.durationText(window.durationSeconds), isActive: false, uiScale: uiScale)
            RecordingPill(text: RecordingFormat.qualityText(width: window.width, height: window.height), isActive: false, uiScale: uiScale)
            RecordingPill(text: RecordingFormat.compactFileSizeText(window.fileSizeBytes), isActive: false, uiScale: uiScale)
        }
    }

    private var factsText: String {
        [RecordingFormat.durationText(window.durationSeconds),
         RecordingFormat.qualityText(width: window.width, height: window.height),
         RecordingFormat.compactFileSizeText(window.fileSizeBytes)].joined(separator: ", ")
    }

    private func actionButton(_ title: String, isPrimary: Bool, isDisabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(isPrimary ? OPNDesign.onAccent : OPNDesign.Text.secondary)
                .padding(.horizontal, 12 * uiScale)
                .frame(height: 26 * uiScale)
                .background(isPrimary ? OPNDesign.accent : OPNDesign.Fill.neutral(0.075))
                .overlay { Rectangle().strokeBorder(isPrimary ? OPNDesign.accent : RecordingsLayout.strongStroke, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.46 : 1)
    }
}
