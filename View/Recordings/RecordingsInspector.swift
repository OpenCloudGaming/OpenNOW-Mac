//
//  RecordingsInspector.swift
//  OpenNOW
//
//  The recording inspector, the empty states behind it and the chrome they sit on.
//  Split out of RecordingsView.swift.
//

import AppKit
import AVKit
import SwiftUI

struct RecordingInspector: View {
    let recording: WebRTCStreamRecording
    let copiedPath: Bool
    let message: String
    let editorEarlyBetaEnabled: Bool
    let uiScale: CGFloat
    let onRestart: () -> Void
    let onEdit: () -> Void
    let onEditorLocked: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14 * uiScale) {
                VStack(alignment: .leading, spacing: 5 * uiScale) {
                    Text(recording.title)
                        .font(.recordingsNvidia(size: 18 * uiScale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(1)
                    Text("\(RecordingFormat.dateText(recording.createdAt)) · \(recording.videoURL.deletingLastPathComponent().lastPathComponent)")
                        .font(.recordingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }
                Spacer(minLength: 12 * uiScale)
                Button("Restart", action: onRestart)
                    .buttonStyle(RecordingActionButtonStyle(tone: .primary, uiScale: uiScale))
                if editorEarlyBetaEnabled {
                    Button("Edit", action: onEdit)
                        .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
                } else {
                    Button("Editor Locked", action: onEditorLocked)
                        .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
                }
                Button("Open", action: onOpen)
                    .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
                Button("Reveal", action: onReveal)
                    .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
                Button(copiedPath ? "Copied" : "Copy Path", action: onCopyPath)
                    .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(RecordingActionButtonStyle(tone: .destructive, uiScale: uiScale))
            }
            .padding(.horizontal, 22 * uiScale)
            .padding(.vertical, 16 * uiScale)

            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)

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
                .font(.recordingsNvidia(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .padding(.horizontal, 22 * uiScale)
                .padding(.bottom, 14 * uiScale)
            }
        }
        .background(Color(red: 17 / 255, green: 18 / 255, blue: 18 / 255))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1) }
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
                .font(.recordingsNvidia(size: 9 * uiScale, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(OpenNOWDesign.accent.opacity(0.86))
            Text(value)
                .font(.recordingsNvidia(size: 14 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
            Text(detail)
                .font(.recordingsNvidia(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.50))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12 * uiScale)
        .background(RecordingsLayout.card)
        .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
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
                    .fill(OpenNOWDesign.accent.opacity(0.10))
                    .frame(width: 78 * uiScale, height: 78 * uiScale)
                Image(systemName: kind == .library ? "record.circle" : "line.3.horizontal.decrease.circle")
                    .font(.recordingsNvidia(size: 34 * uiScale, weight: .bold))
                    .foregroundStyle(OpenNOWDesign.accent)
            }
            Text(kind == .library ? "No recordings yet" : "No matches")
                .font(.recordingsNvidia(size: 18 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.94))
            Text(kind == .library ? "Start a stream, open the sidebar, and press Record to save gameplay videos here." : "Clear search or filters to show the rest of your recording library.")
                .font(.recordingsNvidia(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
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
                    .fill(Color.white.opacity(0.045))
                    .frame(width: 180 * uiScale, height: 108 * uiScale)
                    .overlay { DiagonalGrid().stroke(Color.white.opacity(0.08), lineWidth: 1) }
                    .overlay { Rectangle().stroke(Color.white.opacity(0.13), lineWidth: 1) }
                Image(systemName: "play.rectangle.fill")
                    .font(.recordingsNvidia(size: 46 * uiScale, weight: .bold))
                    .foregroundStyle(OpenNOWDesign.accent.opacity(0.88))
            }
            Text("Select a recording")
                .font(.recordingsNvidia(size: 24 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
            Text(message.isEmpty ? "Your saved gameplay videos appear here with playback, file actions, and capture details." : message)
                .font(.recordingsNvidia(size: 13 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
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
            RadialGradient(colors: [OpenNOWDesign.accent.opacity(0.12), .clear], center: .topLeading, startRadius: 20, endRadius: 620)
            RadialGradient(colors: [Color.white.opacity(0.06), .clear], center: .bottomTrailing, startRadius: 20, endRadius: 520)
            DiagonalGrid()
                .stroke(Color.white.opacity(0.026), lineWidth: 1)
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

    let tone: Tone
    var uiScale: CGFloat = 1.0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.recordingsNvidia(size: 12 * uiScale, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14 * uiScale)
            .frame(height: 36 * uiScale)
            .background(background(isPressed: configuration.isPressed))
            .overlay { Rectangle().stroke(stroke, lineWidth: 1) }
    }

    private var foreground: Color {
        switch tone {
        case .primary: return .black.opacity(0.88)
        case .secondary: return .white.opacity(0.90)
        case .destructive: return RecordingsLayout.danger
        }
    }

    private func background(isPressed: Bool) -> Color {
        switch tone {
        case .primary: return OpenNOWDesign.accent.opacity(isPressed ? 0.78 : 1)
        case .secondary: return Color.white.opacity(isPressed ? 0.14 : 0.075)
        case .destructive: return RecordingsLayout.danger.opacity(isPressed ? 0.18 : 0.10)
        }
    }

    private var stroke: Color {
        switch tone {
        case .primary: return OpenNOWDesign.accent
        case .secondary: return RecordingsLayout.stroke
        case .destructive: return RecordingsLayout.danger.opacity(0.36)
        }
    }
}
