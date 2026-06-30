import SwiftUI
import WebRTCMedia

struct RecordingEditorView: View {
    @ObservedObject var viewModel: RecordingEditorViewModel
    let playheadSeconds: Double
    let onSeek: (Double) -> Void
    let onCancel: () -> Void
    let onSaved: (WebRTCStreamRecording) -> Void
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 12) {
            header
            RecordingTimelineView(
                segments: viewModel.segments,
                selectedSegmentID: viewModel.selectedSegmentID,
                playheadSeconds: playheadSeconds,
                markInSeconds: viewModel.markInSeconds,
                markOutSeconds: viewModel.markOutSeconds,
                onSelect: viewModel.selectSegment,
                onSeek: { timelineSeconds in
                    guard let target = viewModel.sourceTime(forTimelineSeconds: timelineSeconds) else { return }
                    viewModel.selectSegment(target.segment)
                    onSeek(target.seconds)
                }
            )
            controls
            transformAndAudio
            exportBar
        }
        .padding(14)
        .background(Color(red: 14 / 255, green: 15 / 255, blue: 15 / 255))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CLIP EDITOR")
                    .font(.recordingsNvidia(size: 10, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Color.openNowGreen)
                Text("\(recordingEditorDurationText(viewModel.outputDurationSeconds)) output · \(viewModel.segments.count) segment\(viewModel.segments.count == 1 ? "" : "s")")
                    .font(.recordingsNvidia(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            TextField("New clip title", text: $viewModel.outputTitle)
                .textFieldStyle(.plain)
                .font(.recordingsNvidia(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Color.white.opacity(0.065))
                .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
            Button("Undo") { viewModel.undo() }
                .disabled(!viewModel.canUndo || viewModel.isExporting)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
            Button("Redo") { viewModel.redo() }
                .disabled(!viewModel.canRedo || viewModel.isExporting)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
            Button("Reset") { viewModel.resetEdits() }
                .disabled(viewModel.isExporting)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
            Button("Cancel", action: onCancel)
                .disabled(viewModel.isExporting)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
        }
    }

    private var controls: some View {
        HStack(alignment: .top, spacing: 10) {
            editorPanel(title: "TIMING") {
                if let selected = viewModel.selectedSegment {
                    timelineSlider(title: "Start", value: Binding(get: { selected.startSeconds }, set: viewModel.updateSelectedStart), range: 0...max(selected.endSeconds - 0.05, 0.05))
                    timelineSlider(title: "End", value: Binding(get: { selected.endSeconds }, set: viewModel.updateSelectedEnd), range: min(selected.startSeconds + 0.05, selected.recording.durationSeconds)...max(selected.recording.durationSeconds, selected.startSeconds + 0.05))
                    HStack(spacing: 7) {
                        smallButton("Trim In") { viewModel.trimStartToPlayhead(playheadSeconds) }
                        smallButton("Trim Out") { viewModel.trimEndToPlayhead(playheadSeconds) }
                        smallButton("Split") { viewModel.splitAtPlayhead(playheadSeconds) }
                    }
                    HStack(spacing: 7) {
                        smallButton("Mark In") { viewModel.markIn(playheadSeconds) }
                        smallButton("Mark Out") { viewModel.markOut(playheadSeconds) }
                        smallButton("Cut") { viewModel.cutMarkedRange() }
                    }
                }
            }
            editorPanel(title: "SEQUENCING") {
                HStack(spacing: 7) {
                    smallButton("Duplicate") { viewModel.duplicateSelectedSegment() }
                    smallButton("Remove") { viewModel.removeSelectedSegment() }
                    smallButton("Left") { viewModel.moveSelectedSegment(offset: -1) }
                    smallButton("Right") { viewModel.moveSelectedSegment(offset: 1) }
                }
                Menu {
                    ForEach(viewModel.library) { recording in
                        Button("\(recording.title) · \(recordingEditorDurationText(recording.durationSeconds))") {
                            viewModel.appendRecording(recording)
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus.rectangle.on.rectangle")
                        Text("Append Recording")
                    }
                    .font(.recordingsNvidia(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Color.white.opacity(0.075))
                    .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var transformAndAudio: some View {
        HStack(alignment: .top, spacing: 10) {
            editorPanel(title: "FRAME") {
                HStack(spacing: 7) {
                    ForEach(RecordingEditorCropPreset.allCases) { preset in
                        smallButton(preset.title) { viewModel.applyCropPreset(preset) }
                    }
                }
                Toggle("Custom crop", isOn: $viewModel.cropEnabled)
                    .toggleStyle(.checkbox)
                    .font(.recordingsNvidia(size: 11, weight: .medium))
                if viewModel.cropEnabled {
                    compactSlider("X", value: $viewModel.cropX, range: 0...max(0, 1 - viewModel.cropWidth))
                    compactSlider("Y", value: $viewModel.cropY, range: 0...max(0, 1 - viewModel.cropHeight))
                    compactSlider("W", value: $viewModel.cropWidth, range: 0.1...max(0.1, 1 - viewModel.cropX))
                    compactSlider("H", value: $viewModel.cropHeight, range: 0.1...max(0.1, 1 - viewModel.cropY))
                }
                HStack(spacing: 7) {
                    smallButton("Rotate L") { viewModel.rotateLeft() }
                    smallButton("Rotate R") { viewModel.rotateRight() }
                    smallButton(viewModel.isFlippedHorizontally ? "Unflip H" : "Flip H") { viewModel.toggleHorizontalFlip() }
                    smallButton(viewModel.isFlippedVertically ? "Unflip V" : "Flip V") { viewModel.toggleVerticalFlip() }
                }
            }
            editorPanel(title: "PLAYBACK + AUDIO") {
                compactSlider("Speed \(String(format: "%.2fx", viewModel.playbackRate))", value: $viewModel.playbackRate, range: 0.25...4)
                Toggle("Mute audio", isOn: $viewModel.isMuted)
                    .toggleStyle(.checkbox)
                    .font(.recordingsNvidia(size: 11, weight: .medium))
                compactSlider("Volume \(Int(viewModel.volume * 100))%", value: $viewModel.volume, range: 0...2)
                    .disabled(viewModel.isMuted)
                compactSlider("Fade In", value: $viewModel.fadeInSeconds, range: 0...10)
                    .disabled(viewModel.isMuted)
                compactSlider("Fade Out", value: $viewModel.fadeOutSeconds, range: 0...10)
                    .disabled(viewModel.isMuted)
                Picker("Quality", selection: $viewModel.exportQuality) {
                    ForEach(RecordingEditorExportQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var exportBar: some View {
        HStack(spacing: 10) {
            if viewModel.isExporting {
                ProgressView(value: viewModel.exportProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 180)
                Text("Exporting \(Int(viewModel.exportProgress * 100))%")
                    .font(.recordingsNvidia(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.68))
                Button("Cancel Export") {
                    exportTask?.cancel()
                    exportTask = nil
                }
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
            } else if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.recordingsNvidia(size: 11, weight: .medium))
                    .foregroundStyle(.red.opacity(0.88))
                    .lineLimit(1)
            } else {
                Text("Edits are non-destructive. Export creates a new recording.")
                    .font(.recordingsNvidia(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
            }
            Spacer(minLength: 0)
            Button("Save as New Video") {
                exportTask = Task {
                    do {
                        let recording = try await viewModel.export()
                        exportTask = nil
                        onSaved(recording)
                    } catch {
                        exportTask = nil
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
            }
            .disabled(!viewModel.canExport)
            .buttonStyle(RecordingActionButtonStyle(tone: .primary))
        }
    }

    private func editorPanel<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.recordingsNvidia(size: 9, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Color.openNowGreen.opacity(0.82))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(Color.white.opacity(0.045))
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }

    private func timelineSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) · \(recordingEditorDurationText(value.wrappedValue))")
                .font(.recordingsNvidia(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
            Slider(value: value, in: range)
                .tint(Color.openNowGreen)
        }
    }

    private func compactSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.recordingsNvidia(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 78, alignment: .leading)
            Slider(value: value, in: range)
                .tint(Color.openNowGreen)
        }
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.recordingsNvidia(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.86))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.white.opacity(0.07))
            .overlay { Rectangle().stroke(Color.white.opacity(0.11), lineWidth: 1) }
            .buttonStyle(.plain)
            .disabled(viewModel.isExporting)
    }
}
