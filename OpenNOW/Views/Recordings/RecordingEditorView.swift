import SwiftUI
import WebRTCMedia

private enum RecordingAdvancedEditorSection: String, CaseIterable, Identifiable {
    case arrange
    case frame
    case audio
    case export

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrange: return "Arrange"
        case .frame: return "Frame"
        case .audio: return "Audio"
        case .export: return "Export"
        }
    }
}

struct RecordingEditorView: View {
    @ObservedObject var viewModel: RecordingEditorViewModel
    let playheadSeconds: Double
    let onSeek: (Double) -> Void
    let onCancel: () -> Void
    let onSaved: (WebRTCStreamRecording) -> Void

    @State private var exportTask: Task<Void, Never>?
    @State private var showsAdvanced = false
    @State private var advancedSection: RecordingAdvancedEditorSection = .arrange

    var body: some View {
        VStack(spacing: 10) {
            header
            timelineCard
            quickActions
            if showsAdvanced { advancedDrawer }
            exportBar
        }
        .padding(14)
        .background(Color(red: 14 / 255, green: 15 / 255, blue: 15 / 255))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("QUICK EDIT")
                    .font(.recordingsNvidia(size: 10, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Color.openNowGreen)
                Text("Drag the green handles to trim. Drag across the timeline to select a cut.")
                    .font(.recordingsNvidia(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
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
            Button(showsAdvanced ? "Hide Advanced" : "Advanced") { showsAdvanced.toggle() }
                .disabled(viewModel.isExporting)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
            Button("Cancel", action: onCancel)
                .disabled(viewModel.isExporting)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
        }
    }

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Timeline")
                    .font(.recordingsNvidia(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.openNowGreen.opacity(0.86))
                Text("\(recordingEditorDurationText(viewModel.outputDurationSeconds)) output")
                    .font(.recordingsNvidia(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                Spacer(minLength: 0)
                Text("\(viewModel.segments.count) clip\(viewModel.segments.count == 1 ? "" : "s")")
                    .font(.recordingsNvidia(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
            }
            RecordingTimelineView(
                segments: viewModel.segments,
                selectedSegmentID: viewModel.selectedSegmentID,
                playheadSeconds: playheadSeconds,
                markInSeconds: viewModel.markInSeconds,
                markOutSeconds: viewModel.markOutSeconds,
                onSelect: viewModel.selectSegment,
                onSeek: seekTimeline,
                onRangeSelected: selectTimelineRange,
                onPayloadDropped: { payload, insertionIndex in viewModel.handleDropPayload(payload, at: insertionIndex) },
                onTrimBegin: { _ in viewModel.beginInteractiveEdit() },
                onSegmentTrimStart: viewModel.updateSegmentStart,
                onSegmentTrimEnd: viewModel.updateSegmentEnd
            )
        }
        .padding(10)
        .background(Color.white.opacity(0.045))
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }

    private var quickActions: some View {
        HStack(spacing: 8) {
            quickButton("Trim Start", systemImage: "arrow.left.to.line") { viewModel.trimStartToPlayhead(playheadSeconds) }
            quickButton("Trim End", systemImage: "arrow.right.to.line") { viewModel.trimEndToPlayhead(playheadSeconds) }
            quickButton("Split", systemImage: "scissors") { viewModel.splitAtPlayhead(playheadSeconds) }
            quickButton("Set In", systemImage: "bracket.left") { viewModel.markIn(playheadSeconds) }
            quickButton("Set Out", systemImage: "bracket.right") { viewModel.markOut(playheadSeconds) }
            quickButton("Remove Selection", systemImage: "trash") { viewModel.cutMarkedRange() }
            Spacer(minLength: 0)
            Button("Reset") { viewModel.resetEdits() }
                .disabled(viewModel.isExporting)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
        }
    }

    private var advancedDrawer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Advanced section", selection: $advancedSection) {
                ForEach(RecordingAdvancedEditorSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch advancedSection {
            case .arrange:
                arrangePanel
            case .frame:
                framePanel
            case .audio:
                audioPanel
            case .export:
                exportSettingsPanel
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.035))
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }

    private var arrangePanel: some View {
        HStack(alignment: .top, spacing: 10) {
            editorPanel(title: "Selected Clip") {
                HStack(spacing: 7) {
                    smallButton("Duplicate") { viewModel.duplicateSelectedSegment() }
                    smallButton("Remove") { viewModel.removeSelectedSegment() }
                    smallButton("Move Left") { viewModel.moveSelectedSegment(offset: -1) }
                    smallButton("Move Right") { viewModel.moveSelectedSegment(offset: 1) }
                }
            }
            editorPanel(title: "Add Clip") {
                Menu {
                    ForEach(viewModel.library) { recording in
                        Button("\(recording.title) · \(recordingEditorDurationText(recording.durationSeconds))") {
                            viewModel.appendRecording(recording)
                        }
                    }
                } label: {
                    menuLabel("Append Recording", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var framePanel: some View {
        HStack(alignment: .top, spacing: 10) {
            editorPanel(title: "Crop") {
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
            }
            editorPanel(title: "Orientation") {
                HStack(spacing: 7) {
                    smallButton("Rotate Left") { viewModel.rotateLeft() }
                    smallButton("Rotate Right") { viewModel.rotateRight() }
                    smallButton(viewModel.isFlippedHorizontally ? "Unflip H" : "Flip H") { viewModel.toggleHorizontalFlip() }
                    smallButton(viewModel.isFlippedVertically ? "Unflip V" : "Flip V") { viewModel.toggleVerticalFlip() }
                }
            }
        }
    }

    private var audioPanel: some View {
        HStack(alignment: .top, spacing: 10) {
            editorPanel(title: "Playback") {
                compactSlider("Speed \(String(format: "%.2fx", viewModel.playbackRate))", value: $viewModel.playbackRate, range: 0.25...4)
            }
            editorPanel(title: "Audio") {
                Toggle("Mute audio", isOn: $viewModel.isMuted)
                    .toggleStyle(.checkbox)
                    .font(.recordingsNvidia(size: 11, weight: .medium))
                compactSlider("Volume \(Int(viewModel.volume * 100))%", value: $viewModel.volume, range: 0...2)
                    .disabled(viewModel.isMuted)
                compactSlider("Fade In", value: $viewModel.fadeInSeconds, range: 0...10)
                    .disabled(viewModel.isMuted)
                compactSlider("Fade Out", value: $viewModel.fadeOutSeconds, range: 0...10)
                    .disabled(viewModel.isMuted)
            }
        }
    }

    private var exportSettingsPanel: some View {
        editorPanel(title: "Output") {
            HStack(spacing: 10) {
                Text("Quality")
                    .font(.recordingsNvidia(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
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
            Button("Save as New Video") { startExport() }
                .disabled(!viewModel.canExport)
                .buttonStyle(RecordingActionButtonStyle(tone: .primary))
        }
    }

    private func seekTimeline(_ timelineSeconds: Double) {
        guard let target = viewModel.sourceTime(forTimelineSeconds: timelineSeconds) else { return }
        viewModel.selectSegment(target.segment)
        onSeek(target.seconds)
    }

    private func selectTimelineRange(startSeconds: Double, endSeconds: Double) {
        guard let start = viewModel.sourceTime(forTimelineSeconds: min(startSeconds, endSeconds)),
              let end = viewModel.sourceTime(forTimelineSeconds: max(startSeconds, endSeconds)) else { return }
        viewModel.selectSegment(start.segment)
        if start.segment.id == end.segment.id {
            viewModel.markInSeconds = min(start.seconds, end.seconds)
            viewModel.markOutSeconds = max(start.seconds, end.seconds)
        } else {
            viewModel.markInSeconds = start.seconds
            viewModel.markOutSeconds = start.segment.endSeconds
        }
    }

    private func startExport() {
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

    private func compactSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.recordingsNvidia(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 82, alignment: .leading)
            Slider(value: value, in: range)
                .tint(Color.openNowGreen)
        }
    }

    private func quickButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.recordingsNvidia(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.white.opacity(0.065))
            .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isExporting)
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

    private func menuLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.recordingsNvidia(size: 11, weight: .bold))
        .foregroundStyle(.white.opacity(0.88))
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(Color.white.opacity(0.075))
        .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
    }
}
