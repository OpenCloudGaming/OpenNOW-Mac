//
//  RecordingEditorPanels.swift
//  OpenNOW
//
//  The editor's Advanced drawer and the small chrome the editor is built from. Split out of
//  RecordingEditorView.swift, which had grown past the type-size budget once the transport and the
//  design-system controls landed.
//

import SwiftUI

/// One row, one height. Three tiers, each used for everything on its own line - mixed heights on a
/// single row read as a broken layout however good the spacing is.
enum RecordingEditorMetrics {
    /// The page header: the recording's actions, the editor's, and the title field.
    static let headerControlHeight: CGFloat = 36
    /// The timeline's control row: transport, timecode, edit actions. Taller than the tiers above
    /// and below it because this row sits on the window's bottom edge with no padding under it.
    static let controlHeight: CGFloat = 40
    /// Inside the Advanced panels: small buttons, dropdown triggers, chip pickers.
    static let compactControlHeight: CGFloat = 28
}

enum RecordingAdvancedEditorSection: String, CaseIterable, Identifiable {
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

struct RecordingEditorAdvancedDrawer: View {
    @ObservedObject var viewModel: RecordingEditorViewModel
    @Binding var section: RecordingAdvancedEditorSection

    @Environment(\.opnUIScale) private var uiScale

    /// One row of controls and one line of explanation, the same shape on every tab.
    ///
    /// This was two bordered panels side by side, stretched to a fixed height so the tabs matched.
    /// Arrange has five small buttons and Export has three, so most of every panel was empty box.
    /// Without the boxes the tabs are naturally the same height and there is nothing to pad out.
    var body: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            SteamControllerOptionPicker(
                options: RecordingAdvancedEditorSection.allCases.map { ($0, $0.title) },
                selection: section,
                height: RecordingEditorMetrics.compactControlHeight,
                uiScale: uiScale
            ) { section = $0 }

            SettingsFlowLayout(spacing: 7 * uiScale) {
                switch section {
                case .arrange: arrangeControls
                case .frame: frameControls
                case .audio: audioControls
                case .export: exportControls
                }
            }

            Text(detail)
                .font(.recordingsNvidia(size: 10 * uiScale, weight: .medium))
                .foregroundStyle(detailIsNotice ? OpenNOWDesign.accent.opacity(0.80) : .white.opacity(0.46))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 14 * uiScale, alignment: .topLeading)
        }
    }

    // MARK: - Tabs

    @ViewBuilder
    private var arrangeControls: some View {
        smallButton("Duplicate", help: "Copy the selected clip in place") { viewModel.duplicateSelectedSegment() }
        smallButton("Remove", help: "Delete the selected clip", isDisabled: !viewModel.canRemoveSelectedSegment) { viewModel.removeSelectedSegment() }
        smallButton("Join", help: viewModel.canJoinSelectedSection ? "Merge the two sections back into one" : "Only neighbouring sections that were split apart can merge", isDisabled: !viewModel.canJoinSelectedSection) { viewModel.joinSelectedSection() }
        smallButton("Move Left", help: "Move earlier in the timeline", isDisabled: !viewModel.canMoveSelectedSegment(offset: -1)) { viewModel.moveSelectedSegment(offset: -1) }
        smallButton("Move Right", help: "Move later in the timeline", isDisabled: !viewModel.canMoveSelectedSegment(offset: 1)) { viewModel.moveSelectedSegment(offset: 1) }
        separator
        OpenNOWDropdownMenu(
            items: viewModel.library.map { recording in
                OpenNOWDropdownItem(
                    id: recording.id.uuidString,
                    title: "\(recording.title) · \(recordingEditorDurationText(recording.durationSeconds))"
                ) { viewModel.appendRecording(recording) }
            },
            isDisabled: viewModel.isExporting || viewModel.library.isEmpty
        ) {
            HStack(spacing: 7 * uiScale) {
                Image(systemName: "plus.rectangle.on.rectangle")
                Text("Append Recording")
                Image(systemName: "chevron.down")
            }
            .font(.recordingsNvidia(size: 11 * uiScale, weight: .bold))
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 10 * uiScale)
            .frame(height: RecordingEditorMetrics.compactControlHeight * uiScale)
            .background(Color.white.opacity(0.075))
            .overlay { Rectangle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
        }
    }

    @ViewBuilder
    private var frameControls: some View {
        ForEach(RecordingEditorCropPreset.allCases) { preset in
            smallButton(preset.title, help: cropPresetHelp(preset), isSelected: viewModel.isCropPresetActive(preset)) { viewModel.applyCropPreset(preset) }
        }
        smallButton(
            viewModel.isAdjustingCrop ? "Done Adjusting" : "Adjust on Video",
            help: "Drag the crop rectangle on the video itself. The preview shows the original frame while you do.",
            isSelected: viewModel.isAdjustingCrop
        ) {
            viewModel.setAdjustingCrop(!viewModel.isAdjustingCrop)
        }
        separator
        smallButton("Rotate Left", help: "Rotate 90° anticlockwise") { viewModel.rotateLeft() }
        smallButton("Rotate Right", help: "Rotate 90° clockwise") { viewModel.rotateRight() }
        smallButton(viewModel.isFlippedHorizontally ? "Unflip H" : "Flip H", help: "Mirror left to right", isSelected: viewModel.isFlippedHorizontally) { viewModel.toggleHorizontalFlip() }
        smallButton(viewModel.isFlippedVertically ? "Unflip V" : "Flip V", help: "Mirror top to bottom", isSelected: viewModel.isFlippedVertically) { viewModel.toggleVerticalFlip() }
    }

    @ViewBuilder
    private var audioControls: some View {
        smallButton(viewModel.isMuted ? "Unmute" : "Mute", help: "Silence the exported audio", isSelected: viewModel.isMuted) {
            viewModel.recordUndo()
            viewModel.isMuted.toggle()
        }
        separator
        slider("Speed \(String(format: "%.2fx", viewModel.playbackRate))", value: $viewModel.playbackRate, range: 0.25...4)
        slider("Volume \(Int(viewModel.volume * 100))%", value: $viewModel.volume, range: 0...2, isDisabled: viewModel.isMuted)
        slider("Fade In \(seconds(viewModel.fadeInSeconds))", value: $viewModel.fadeInSeconds, range: 0...10, isDisabled: viewModel.isMuted)
        slider("Fade Out \(seconds(viewModel.fadeOutSeconds))", value: $viewModel.fadeOutSeconds, range: 0...10, isDisabled: viewModel.isMuted)
    }

    @ViewBuilder
    private var exportControls: some View {
        ForEach(RecordingEditorExportQuality.allCases) { quality in
            smallButton(quality.title, help: "Export at \(quality.title.lowercased()) quality", isSelected: viewModel.exportQuality == quality) {
                viewModel.recordUndo()
                viewModel.exportQuality = quality
            }
        }
    }

    // MARK: - Detail line

    private var detailIsNotice: Bool {
        section == .frame && viewModel.isAdjustingCrop
    }

    private var detail: String {
        switch section {
        case .arrange:
            return "Clips can also be dragged from the library list straight onto the timeline."
        case .frame:
            if viewModel.isAdjustingCrop {
                return "Drag the rectangle on the video. The preview shows the original frame; rotation and flips come back when you finish."
            }
            let orientation = viewModel.rotation == .degrees0 && !viewModel.isFlippedHorizontally && !viewModel.isFlippedVertically
                ? "Original orientation"
                : "Rotated \(viewModel.rotation.rawValue)°\(viewModel.isFlippedHorizontally ? ", mirrored horizontally" : "")\(viewModel.isFlippedVertically ? ", mirrored vertically" : "")"
            return "\(orientation). Output \(viewModel.croppedOutputDescription)."
        case .audio:
            return "Output runs \(recordingEditorDurationText(viewModel.outputDurationSeconds))."
        case .export:
            switch viewModel.exportQuality {
            case .highest:
                return viewModel.isTrimOnlyEdit
                    ? "Copies the original video and audio through without re-encoding. Fastest, and no quality is lost."
                    : "Re-encodes at the source resolution."
            case .balanced:
                return "Re-encodes smaller, up to 1080p."
            case .compact:
                return "Re-encodes smallest, up to 720p."
            }
        }
    }

    // MARK: - Helpers

    /// Groups controls that do different jobs on the same line.
    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: RecordingEditorMetrics.compactControlHeight * uiScale * 0.7)
            .padding(.horizontal, 4 * uiScale)
    }

    private func seconds(_ value: Double) -> String { value <= 0 ? "off" : String(format: "%.1fs", value) }

    private func cropPresetHelp(_ preset: RecordingEditorCropPreset) -> String {
        switch preset {
        case .full: return "No crop"
        case .square: return "Square crop, centred"
        case .wide: return "16:9 crop, centred"
        case .vertical: return "9:16 crop for vertical video, centred"
        case .center: return "Zoom into the middle 80%"
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, isDisabled: Bool = false) -> some View {
        RecordingEditorSlider(
            title: title,
            value: value,
            range: range,
            uiScale: uiScale,
            onEditingChanged: { isEditing in
                if isEditing {
                    viewModel.beginInteractiveEdit()
                } else {
                    viewModel.endInteractiveEdit()
                }
            }
        )
        .frame(width: 190 * uiScale)
        .disabled(viewModel.isExporting || isDisabled)
    }

    private func smallButton(_ title: String, help: String, isSelected: Bool = false, isDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        RecordingEditorControl(
            title,
            tone: isSelected ? .prominent : .standard,
            height: RecordingEditorMetrics.compactControlHeight,
            horizontalPadding: 9,
            fontSize: 10,
            help: help,
            isDisabled: viewModel.isExporting || isDisabled,
            action: action
        )
    }
}

// MARK: - Shared chrome

/// The undo step is taken when the drag starts, so one gesture is one step however many
/// intermediate values SwiftUI publishes along the way.
struct RecordingEditorSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let uiScale: CGFloat
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8 * uiScale) {
            Text(title)
                .font(.recordingsNvidia(size: 10 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 78 * uiScale, alignment: .leading)
                .lineLimit(1)
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .tint(OpenNOWDesign.accent)
        }
    }
}

