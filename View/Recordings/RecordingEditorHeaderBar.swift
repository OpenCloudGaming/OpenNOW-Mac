//  The editor's identity, name field, status and actions - at the top of the page rather than at
//  the top of the drawer.
//
//  It used to sit above the timeline at the bottom of the window, which stacked four things into
//  the noisiest corner of the screen and put the primary action furthest from the eye. Up here it
//  takes the row the recording's own header occupies the rest of the time.
//

import SwiftUI

struct RecordingEditorHeaderBar: View {
    @ObservedObject var viewModel: RecordingEditorViewModel
    var isControllerFocused = false
    let onCancel: () -> Void
    let onExport: () -> Void
    let onCancelExport: () -> Void

    @Environment(\.opnUIScale) private var uiScale
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22 * uiScale)
                .padding(.vertical, 12 * uiScale)
            if viewModel.isExporting {
                exportProgressRow
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if viewModel.showsAdvanced {
                RecordingEditorAdvancedDrawer(viewModel: viewModel, section: $viewModel.advancedSection)
                    .padding(.horizontal, 22 * uiScale)
                    .padding(.bottom, 12 * uiScale)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
            .background(OpenNOWDesign.Surface.deep)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1) }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(isControllerFocused ? OpenNOWDesign.accent : Color.clear)
                    .frame(height: 2)
            }
            .animation(.easeOut(duration: 0.2), value: viewModel.isExporting)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recording editor, beta")
    }

    /// Its own row rather than a control inside the header. Inline, it grew the header's height the
    /// moment an export started and shrank it again when one finished, which moved everything else
    /// on the row.
    private var exportProgressRow: some View {
        HStack(spacing: 12 * uiScale) {
            ProgressView(value: viewModel.exportProgress)
                .progressViewStyle(.linear)
                .tint(OpenNOWDesign.accent)
                .accessibilityLabel("Export progress")
                .accessibilityValue("\(Int(viewModel.exportProgress * 100)) percent")
            Text("Exporting \(Int(viewModel.exportProgress * 100))%")
                .font(.recordingsFont(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.horizontal, 22 * uiScale)
        .frame(height: 26 * uiScale)
        .padding(.bottom, 10 * uiScale)
    }

    private var header: some View {
        HStack(spacing: 12 * uiScale) {
            HStack(spacing: 7 * uiScale) {
                Text("QUICK EDIT")
                    .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(OpenNOWDesign.accent)
                OpenNOWBetaTag(uiScale: uiScale, prominent: true)
            }
            .fixedSize()
            statusLine
            TextField("New clip title", text: coalescedUndoable(\.outputTitle, token: "outputTitle"))
                .textFieldStyle(.plain)
                .font(.recordingsFont(size: 13 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 10 * uiScale)
                // Matches the buttons beside it; 34 against their 36 read as a misaligned field.
                .frame(height: RecordingActionButtonStyle.height * uiScale)
                .background(Color.white.opacity(0.065))
                .overlay { Rectangle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
                .help("Name of the video the export will create")
                .focused($isTitleFocused)
                .onChange(of: isTitleFocused) { _, focused in viewModel.isTitleFieldFocused = focused }
            Button("Undo") { viewModel.undo() }
                .disabled(!viewModel.canUndo || viewModel.isExporting)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo (⌘Z)")
            Button("Redo") { viewModel.redo() }
                .disabled(!viewModel.canRedo || viewModel.isExporting)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo (⇧⌘Z)")
            Button("Reset") { viewModel.resetEdits() }
                .disabled(viewModel.isExporting)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
                .help("Discard every edit and start from the original recording")
            Button(viewModel.showsAdvanced ? "Hide Advanced" : "Advanced") {
                withAnimation(.easeOut(duration: 0.18)) { viewModel.showsAdvanced.toggle() }
            }
                .disabled(viewModel.isExporting)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
                .help("Arrange, frame, audio and export settings")
            Button("Cancel", action: onCancel)
                .disabled(viewModel.isExporting)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
                .keyboardShortcut(.cancelAction)
                .help("Close the editor without exporting (Esc)")
            // The primary action lives up here rather than on the bottom edge, where it was both
            // the least reachable thing on screen and the first thing to be clipped.
            if viewModel.isExporting {
                Button("Cancel Export", action: onCancelExport)
                    .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
            } else {
                Button("Save as New Video", action: onExport)
                    .disabled(!viewModel.canExport)
                    .buttonStyle(RecordingActionButtonStyle(tone: .primary, uiScale: uiScale))
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Export the edit as a new recording (⌘S)")
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8 * uiScale) {
            if let errorMessage = viewModel.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.recordingsFont(size: 11 * uiScale, weight: .bold))
                    .foregroundStyle(RecordingsLayout.danger)
                Text(errorMessage)
                    .font(.recordingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(RecordingsLayout.danger.opacity(0.92))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let hint = viewModel.hint {
                Image(systemName: "info.circle.fill")
                    .font(.recordingsFont(size: 11 * uiScale, weight: .bold))
                    .foregroundStyle(OpenNOWDesign.accent.opacity(0.85))
                Text(hint)
                    .font(.recordingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(1)
            } else {
                Text(exportSummary)
                    .font(.recordingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
            }
            if let markSummary = viewModel.markedRangeDescription {
                Text(markSummary)
                    .font(.recordingsFont(size: 11 * uiScale, weight: .bold))
                    .foregroundStyle(RecordingsLayout.danger.opacity(0.92))
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        // Yields its width to the controls beside it: a truncated status is a fair trade, a
        // squeezed Save button is not.
        .layoutPriority(-1)
    }

    private var exportSummary: String {
        let length = recordingEditorDurationText(viewModel.outputDurationSeconds)
        let clips = "\(viewModel.segments.count) clip\(viewModel.segments.count == 1 ? "" : "s")"
        let method = viewModel.exportQuality == .highest && viewModel.isTrimOnlyEdit ? "copied without re-encoding" : "re-encoded"
        return "\(length) from \(clips), \(method). The original recording is left alone."
    }

    private func coalescedUndoable<Value>(_ keyPath: ReferenceWritableKeyPath<RecordingEditorViewModel, Value>, token: String) -> Binding<Value> {
        Binding(
            get: { viewModel[keyPath: keyPath] },
            set: { newValue in
                viewModel.recordCoalescedUndo(token: token)
                viewModel[keyPath: keyPath] = newValue
            }
        )
    }
}
