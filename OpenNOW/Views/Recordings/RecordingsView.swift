import AVKit
import SwiftUI
import WebRTCMedia

struct RecordingsView: View {
    @State private var recordings: [WebRTCStreamRecording] = []
    @State private var selectedRecording: WebRTCStreamRecording?
    @State private var player: AVPlayer?
    @State private var message = ""
    @State private var pendingDelete: WebRTCStreamRecording?

    var body: some View {
        HSplitView {
            recordingsList
                .frame(minWidth: 360, idealWidth: 430, maxWidth: 520)
            playerPane
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.gfnBackgroundGreen)
        .onAppear { reload() }
        .confirmationDialog("Delete recording?", isPresented: deleteDialogPresented) {
            Button("Delete", role: .destructive) { deletePendingRecording() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This permanently removes the video file and metadata from OpenNOW recordings.")
        }
    }

    private var recordingsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RECORDINGS")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(Color.openNowGreen)
                    Text("Saved Videos")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.96))
                }
                Spacer()
                Button(action: reload) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(22)

            if recordings.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(recordings) { recording in
                            RecordingRow(recording: recording, isSelected: selectedRecording?.id == recording.id) {
                                select(recording)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 18)
                }
            }
        }
        .background(Color(red: 22 / 255, green: 23 / 255, blue: 22 / 255))
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.10)).frame(width: 1) }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "record.circle")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(Color.openNowGreen.opacity(0.9))
            Text("No recordings yet")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))
            Text("Start a stream, open the sidebar, and press Record to save gameplay videos here.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(28)
    }

    private var playerPane: some View {
        VStack(spacing: 0) {
            if let selectedRecording, let player {
                VideoPlayer(player: player)
                    .background(Color.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { player.play() }
                RecordingDetailBar(recording: selectedRecording, onReveal: { reveal(selectedRecording) }, onDelete: { pendingDelete = selectedRecording })
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 54, weight: .medium))
                        .foregroundStyle(.white.opacity(0.28))
                    Text("Select a recording")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.86))
                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black.opacity(0.72))
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func reload() {
        recordings = WebRTCStreamRecordingLibrary.loadRecordings()
        if let selectedRecording, let refreshed = recordings.first(where: { $0.id == selectedRecording.id }) {
            self.selectedRecording = refreshed
        } else {
            select(recordings.first)
        }
    }

    private func select(_ recording: WebRTCStreamRecording?) {
        selectedRecording = recording
        guard let recording else {
            player?.pause()
            player = nil
            return
        }
        player?.pause()
        player = AVPlayer(url: recording.videoURL)
    }

    private func reveal(_ recording: WebRTCStreamRecording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.videoURL])
    }

    private func deletePendingRecording() {
        guard let recording = pendingDelete else { return }
        do {
            try WebRTCStreamRecordingLibrary.delete(recording)
            pendingDelete = nil
            reload()
        } catch {
            message = error.localizedDescription
            pendingDelete = nil
        }
    }
}

private struct RecordingRow: View {
    let recording: WebRTCStreamRecording
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Rectangle().fill(isSelected ? Color.openNowGreen : Color.white.opacity(isHovering ? 0.15 : 0.08))
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(isSelected ? .black.opacity(0.86) : .white.opacity(0.82))
                }
                .frame(width: 52, height: 42)

                VStack(alignment: .leading, spacing: 5) {
                    Text(recording.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)
                    Text("\(dateText(recording.createdAt)) · \(durationText(recording.durationSeconds)) · \(fileSizeText(recording.fileSizeBytes))")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.56))
                        .lineLimit(1)
                    Text("\(recording.width)x\(recording.height) · \(recording.videoBitrateMbps == 0 ? "Auto" : "\(recording.videoBitrateMbps) Mbps")")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.openNowGreen.opacity(0.82))
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(isSelected ? Color.white.opacity(0.10) : Color.white.opacity(isHovering ? 0.06 : 0.035))
            .overlay { Rectangle().stroke(isSelected ? Color.openNowGreen.opacity(0.46) : Color.white.opacity(0.08), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct RecordingDetailBar: View {
    let recording: WebRTCStreamRecording
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                Text("\(dateText(recording.createdAt)) · \(durationText(recording.durationSeconds)) · \(recording.width)x\(recording.height)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer()
            Button("Reveal", action: onReveal)
                .buttonStyle(RecordingActionButtonStyle())
            Button("Delete", role: .destructive, action: onDelete)
                .buttonStyle(RecordingActionButtonStyle(destructive: true))
        }
        .padding(.horizontal, 18)
        .frame(height: 72)
        .background(Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.10)).frame(height: 1) }
    }
}

private struct RecordingActionButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(destructive ? Color.red.opacity(0.92) : .white.opacity(0.9))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(.white.opacity(configuration.isPressed ? 0.15 : 0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

private func dateText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func durationText(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded()))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}

private func fileSizeText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
