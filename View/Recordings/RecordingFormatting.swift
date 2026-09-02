//
//  RecordingFormatting.swift
//  OpenNOW
//
//  How a recording's date, duration, size and quality are written in the recordings UI.
//  Namespaced rather than left as free functions: names this generic (`dateText`,
//  `durationText`) already exist elsewhere in the module with different formatting.
//

import Foundation
import SwiftUI

enum RecordingFormat {
    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func relativeDateText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func durationText(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    static func compactFileSizeText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    static func qualityText(_ recording: WebRTCStreamRecording) -> String {
        if recording.width >= 3840 || recording.height >= 2160 { return "4K" }
        if recording.width >= 2560 || recording.height >= 1440 { return "1440p" }
        if recording.width >= 1920 || recording.height >= 1080 { return "1080p" }
        if recording.height > 0 { return "\(recording.height)p" }
        return "Auto"
    }

    static func resolutionBadge(_ recording: WebRTCStreamRecording) -> String {
        recording.width > 0 && recording.height > 0 ? "\(recording.width)x\(recording.height)" : "AUTO"
    }

    static func bitrateText(_ recording: WebRTCStreamRecording) -> String {
        recording.videoBitrateMbps == 0 ? "Auto" : "\(recording.videoBitrateMbps) Mbps"
    }
}

struct RecordingRightsNotice: View {
    let onAcknowledge: () -> Void
    let uiScale: CGFloat

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16 * uiScale) {
                HStack(spacing: 12 * uiScale) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.recordingsNvidia(size: 22 * uiScale, weight: .bold))
                        .foregroundStyle(.orange)
                    Text("About Recording GeForce NOW Sessions")
                        .font(.recordingsNvidia(size: 18 * uiScale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.96))
                }
                Text("Some game publishers restrict recording or broadcasting of their titles on cloud gaming services. You are responsible for complying with the terms of service of GeForce NOW, the game publisher, and any applicable store policies when recording sessions.")
                    .font(.recordingsNvidia(size: 13 * uiScale, weight: .regular))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineSpacing(3 * uiScale)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("I Understand", action: onAcknowledge)
                        .buttonStyle(RecordingActionButtonStyle(tone: .primary, uiScale: uiScale))
                }
            }
            .padding(28 * uiScale)
            .frame(maxWidth: 460 * uiScale)
            .background {
                Rectangle().fill(RecordingsLayout.surface)
                Rectangle().fill(RecordingsLayout.card)
            }
            .overlay { Rectangle().stroke(RecordingsLayout.strongStroke, lineWidth: 1) }
            .shadow(color: .black.opacity(0.55), radius: 24 * uiScale, y: 10 * uiScale)
        }
    }
}
