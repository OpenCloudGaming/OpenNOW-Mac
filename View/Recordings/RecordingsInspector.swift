//  The recording inspector, the empty states behind it and the chrome they sit on.
//

import AppKit
import AVKit
import SwiftUI

/// Everything about the selected recording, above the video: what it is, what you can do with it,
/// and its four numbers. It used to sit under the player, which put the identity a screen away from
/// the picture it described and left the actions competing with the editor for the bottom edge.
struct RecordingInspector: View {
    let recording: WebRTCStreamRecording
    let isPathCopied: Bool
    let message: String
    let uiScale: CGFloat
    let onRestart: () -> Void
    let onEdit: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            identityRow
            Rectangle().fill(OPNDesign.Stroke.subtle).frame(height: 1)
            tileRow
        }
        .background(OPNDesign.Surface.deep)
        .overlay(alignment: .bottom) { Rectangle().fill(OPNDesign.Stroke.subtle).frame(height: 1) }
    }

    /// Identity on the left, what you can do with it on the right - one row rather than a title
    /// block and a separate action bar.
    private var identityRow: some View {
        HStack(alignment: .center, spacing: 12 * uiScale) {
            Circle()
                .fill(OPNDesign.accent)
                .frame(width: 7 * uiScale, height: 7 * uiScale)
            Text("NOW PLAYING")
                .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
                .tracking(1.3)
                .foregroundStyle(OPNDesign.accentInk)
                .fixedSize()
            Text(recording.title)
                .font(.recordingsFont(size: 15 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.primary)
                .lineLimit(1)
            Text(RecordingFormat.dateText(recording.createdAt))
                .font(.recordingsFont(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .lineLimit(1)
            Spacer(minLength: 12 * uiScale)
            actionButtons
        }
        .padding(.horizontal, 22 * uiScale)
        .padding(.vertical, 14 * uiScale)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing \(recording.title)")
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button("Restart", action: onRestart)
            .buttonStyle(RecordingActionButtonStyle(tone: .primary, uiScale: uiScale))
        Button(action: onEdit) {
            HStack(spacing: 6 * uiScale) {
                Text("Edit")
                OPNBetaTag(uiScale: uiScale * 0.9)
            }
        }
        .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
        .help("Trim, arrange and export a new video. Beta.")
        Button("Open", action: onOpen)
            .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
        Button("Reveal", action: onReveal)
            .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
        Button(isPathCopied ? "Copied" : "Copy Path", action: onCopyPath)
            .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
        Button("Delete", role: .destructive, action: onDelete)
            .buttonStyle(RecordingActionButtonStyle(tone: .destructive, uiScale: uiScale))
    }

    private var tileRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10 * uiScale) {
                RecordingDetailTile(title: "QUALITY", value: RecordingFormat.qualityText(recording), detail: "\(recording.width)x\(recording.height)", uiScale: uiScale)
                RecordingDetailTile(title: "BITRATE", value: RecordingFormat.bitrateText(recording), detail: "Audio \(recording.audioBitrateKbps) Kbps", uiScale: uiScale)
                RecordingDetailTile(title: "DURATION", value: RecordingFormat.durationText(recording.durationSeconds), detail: RecordingFormat.compactFileSizeText(recording.fileSizeBytes), uiScale: uiScale)
                RecordingDetailTile(title: "ENHANCEMENT", value: recording.enhancedVideo ? "Enabled" : "Standard", detail: recording.enhancedVideo ? "Enhanced video" : "Original stream", uiScale: uiScale)
            }
            .padding(.horizontal, 22 * uiScale)
            .padding(.vertical, 14 * uiScale)

            if !message.isEmpty {
                HStack(spacing: 8 * uiScale) {
                    Image(systemName: "info.circle.fill")
                    Text(message)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.recordingsFont(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .padding(.horizontal, 22 * uiScale)
                .padding(.bottom, 14 * uiScale)
            }
        }
    }
}

struct RecordingDetailTile: View {
    let title: String
    let value: String
    let detail: String
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * uiScale) {
            Text(title)
                .font(.recordingsFont(size: 9 * uiScale, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(OPNDesign.accentInk.opacity(0.86))
            Text(value)
                .font(.recordingsFont(size: 14 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.primary)
                .lineLimit(1)
            Text(detail)
                .font(.recordingsFont(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12 * uiScale)
        .background(RecordingsLayout.card)
        .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value), \(detail)")
    }
}

struct RecordingEmptyState: View {
    enum Kind {
        case library
        case search
    }

    let kind: Kind
    let action: () -> Void
    let uiScale: CGFloat

    var body: some View {
        VStack(spacing: 16 * uiScale) {
            ZStack {
                Circle()
                    .fill(OPNDesign.accent.opacity(0.10))
                    .frame(width: 78 * uiScale, height: 78 * uiScale)
                Image(systemName: kind == .library ? "record.circle" : "line.3.horizontal.decrease.circle")
                    .font(.recordingsFont(size: 34 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.accentInk)
            }
            Text(kind == .library ? "No recordings yet" : "No matches")
                .font(.recordingsFont(size: 18 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.primary)
            Text(kind == .library ? "Start a stream, open the sidebar, and press Record to save gameplay videos here." : "Clear search or filters to show the rest of your recording library.")
                .font(.recordingsFont(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280 * uiScale)
            Button(kind == .library ? "Refresh" : "Clear Filters", action: action)
                .buttonStyle(RecordingActionButtonStyle(tone: .primary, uiScale: uiScale))
        }
        .padding(28 * uiScale)
    }
}

struct RecordingEmptyPlayer: View {
    let message: String
    let uiScale: CGFloat

    var body: some View {
        VStack(spacing: 18 * uiScale) {
            ZStack {
                Rectangle()
                    .fill(OPNDesign.Fill.neutral(0.045))
                    .frame(width: 180 * uiScale, height: 108 * uiScale)
                    .overlay { DiagonalGrid().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
                    .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
                Image(systemName: "play.rectangle.fill")
                    .font(.recordingsFont(size: 46 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.accentInk.opacity(0.88))
            }
            Text("Select a recording")
                .font(.recordingsFont(size: 24 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.primary)
            Text(message.isEmpty ? "Your saved gameplay videos appear here with playback, file actions, and capture details." : message)
                .font(.recordingsFont(size: 13 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420 * uiScale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecordingsBackdrop: View {
    var body: some View {
        ZStack {
            RecordingsLayout.surface
            RadialGradient(colors: [OPNDesign.accent.opacity(0.12), .clear], center: .topLeading, startRadius: 20, endRadius: 620)
            RadialGradient(colors: [OPNDesign.Fill.neutral(0.06), .clear], center: .bottomTrailing, startRadius: 20, endRadius: 520)
            DiagonalGrid()
                .stroke(OPNDesign.Fill.neutral(0.026), lineWidth: 1)
                .blendMode(.screen)
        }
        .ignoresSafeArea()
    }
}

struct DiagonalGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spacing: CGFloat = 42
        var x = -rect.height
        while x < rect.width + rect.height {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        x = 0
        while x < rect.width + rect.height {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x - rect.height, y: rect.maxY))
            x += spacing
        }
        return path
    }
}

struct RecordingActionButtonStyle: ButtonStyle {
    enum Tone {
        case primary
        case secondary
        case destructive
    }

    /// Shared so anything sitting in a row of these buttons can match them rather than guess.
    static let height = RecordingEditorMetrics.headerControlHeight

    let tone: Tone
    var uiScale: CGFloat = 1.0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.recordingsFont(size: 12 * uiScale, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14 * uiScale)
            .frame(height: Self.height * uiScale)
            .background(background(isPressed: configuration.isPressed))
            // `strokeBorder`, not `stroke`: a stroke is centred on the path and spills half a point
            // outside the frame. On the secondary tones that spill is invisible, but the primary
            // tone strokes in its own fill colour, so the spill painted as extra button - measurably
            // 49 px against 47 px, and it read as the primary button being taller than its row.
            .overlay { Rectangle().strokeBorder(stroke, lineWidth: 1) }
    }

    private var foreground: Color {
        switch tone {
        case .primary: return OPNDesign.onAccent.opacity(0.88)
        case .secondary: return OPNDesign.Text.primary
        case .destructive: return RecordingsLayout.danger
        }
    }

    private func background(isPressed: Bool) -> Color {
        switch tone {
        case .primary: return OPNDesign.accent.opacity(isPressed ? 0.78 : 1)
        case .secondary: return isPressed ? OPNDesign.Stroke.regular : OPNDesign.Stroke.subtle
        case .destructive: return RecordingsLayout.danger.opacity(isPressed ? 0.18 : 0.10)
        }
    }

    private var stroke: Color {
        switch tone {
        case .primary: return OPNDesign.accent
        case .secondary: return RecordingsLayout.stroke
        case .destructive: return RecordingsLayout.danger.opacity(0.36)
        }
    }
}
