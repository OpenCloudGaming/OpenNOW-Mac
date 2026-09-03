//  The editor drawer under the recordings player: header, timeline, transport, quick actions and
//  the export bar. The Advanced drawer and the shared chrome live in RecordingEditorPanels.swift.
//

import SwiftUI

struct RecordingEditorView: View {
    @ObservedObject var viewModel: RecordingEditorViewModel
    let playheadSeconds: Double
    let previewDurationSeconds: Double
    let isPlaying: Bool
    let onSeek: (Double) -> Void
    let onStep: (Double) -> Void
    let onTogglePlayback: () -> Void
    let onSkipToEnd: () -> Void
    let onPreviewChanged: () -> Void
    /// True while a controller is driving the editor rather than the recording list. There is no
    /// cursor to show which half of the page has input, so the page has to say.
    var isControllerFocused = false

    /// Every control in the row is this tall. See `RecordingEditorMetrics`.
    private static let controlHeight = RecordingEditorMetrics.controlHeight

    @Environment(\.opnUIScale) private var uiScale
    /// The height the recordings page has to leave for the editor. The advanced drawer roughly
    /// doubles the content, and a single fixed cap clipped its bottom row outright.
    static func preferredHeight(uiScale: CGFloat) -> CGFloat {
        340 * uiScale
    }

    var body: some View {
        VStack(spacing: 14 * uiScale) {
            timelineCard
            controlRow
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14 * uiScale)
        .padding(.top, 12 * uiScale)
        // None: the control row runs to the window's bottom edge. The buttons are tall enough to
        // stay easy to hit there, which is what the padding was really for.
        .padding(.bottom, 0)
        // The fill runs past the content into the window's bottom inset. Without this the drawer
        // stopped short of the frame and the page backdrop showed through in the corners.
        .background(OpenNOWDesign.Surface.deep.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(isControllerFocused ? OpenNOWDesign.accent : Color.white.opacity(0.10))
                .frame(height: isControllerFocused ? 2 : 1)
        }
        .onChange(of: viewModel.previewSignature) { _, _ in onPreviewChanged() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording editor, beta")
    }

    // MARK: - Header

    // MARK: - Timeline

    /// Nothing but the track. The label, the output duration and the clip summary all repeated what
    /// the status line and the timeline itself already say, and they cost the track its height.
    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 10 * uiScale) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                zoomControls
            }
            RecordingTimelineView(
                segments: viewModel.segments,
                selectedSegmentID: viewModel.selectedSegmentID,
                playheadSeconds: sourceTimelinePlayheadSeconds,
                markInSeconds: viewModel.markInSeconds,
                markOutSeconds: viewModel.markOutSeconds,
                zoom: viewModel.timelineZoom,
                uiScale: uiScale,
                onSelect: viewModel.selectSegment,
                onSeek: seekTimeline,
                onRangeSelected: selectTimelineRange,
                onPayloadDropped: { payload, insertionIndex in viewModel.handleDropPayload(payload, at: insertionIndex) },
                onTrimBegin: { _ in viewModel.beginInteractiveEdit() },
                onSegmentTrimStart: viewModel.updateSegmentStart,
                onSegmentTrimEnd: viewModel.updateSegmentEnd
            )
            .background(RecordingTimelineScrollZoom { factor in viewModel.zoomTimeline(byFactor: factor) })
        }
        .padding(.horizontal, 8 * uiScale)
        .padding(.bottom, 8 * uiScale)
        .padding(.top, 2 * uiScale)
    }

    /// A forty-minute recording is otherwise nine hundred pixels wide, and trimming to the second
    /// is a pixel hunt. Zoom follows the playhead rather than adding a pan gesture to a track that
    /// already owns click-to-seek and drag-to-select.
    private var zoomControls: some View {
        HStack(spacing: 2 * uiScale) {
            if let window = viewModel.timelineWindowDescription {
                Text(window)
                    .font(.recordingsNvidia(size: 10 * uiScale, weight: .bold))
                    .foregroundStyle(OpenNOWDesign.accent.opacity(0.80))
                    .fixedSize()
                    .padding(.trailing, 2 * uiScale)
            }
            zoomButton("minus.magnifyingglass", help: "Zoom the timeline out (⌘−, or scroll on the track)", isDisabled: !viewModel.canZoomTimelineOut) { viewModel.zoomTimelineOut() }
                .keyboardShortcut("-", modifiers: .command)
            zoomButton("plus.magnifyingglass", help: "Zoom the timeline in (⌘+, or scroll on the track)", isDisabled: !viewModel.canZoomTimelineIn) { viewModel.zoomTimelineIn() }
                .keyboardShortcut("=", modifiers: .command)
            zoomButton("arrow.left.and.right", help: "Fit the whole timeline (⌘0)", isDisabled: !viewModel.canZoomTimelineOut) { viewModel.fitTimeline() }
                .keyboardShortcut("0", modifiers: .command)
        }
    }

    /// Borderless: these sit above the track as a quiet affordance, not as three more buttons in a
    /// row of buttons.
    private func zoomButton(_ systemImage: String, help: String, isDisabled: Bool, action: @escaping () -> Void) -> some View {
        RecordingEditorControl(
            systemImage: systemImage, tone: .borderless, height: 22, width: 26,
            help: help, isDisabled: viewModel.isExporting || isDisabled, action: action
        )
    }

    // MARK: - Transport

    /// Trimming means parking the playhead on an exact moment, and the player's own floating
    /// controls scrub the whole clip rather than the edited timeline. These drive the preview.
    /// Five controls, not seven. The two ±0.2 s chevrons and the two ±5 s stopwatch glyphs read as
    /// four near-identical dark squares; the fine step is on the arrow keys instead, where a frame
    /// hunt belongs, and the coarse one says "5s" in words.
    private var transportGroup: some View {
        HStack(spacing: 4 * uiScale) {
            transportButton("backward.end.fill", help: "Go to start") { onSeek(0) }
            transportStepButton("5s", systemImage: "chevron.left", help: "Back 5 seconds") { onStep(-5) }
            transportButton(isPlaying ? "pause.fill" : "play.fill", help: isPlaying ? "Pause" : "Play", isProminent: true, action: onTogglePlayback)
            transportStepButton("5s", systemImage: "chevron.right", trailingIcon: true, help: "Forward 5 seconds") { onStep(5) }
            transportButton("forward.end.fill", help: "Go to end", action: onSkipToEnd)
        }
    }

    /// No fill and no border: given the same box as its neighbours it read as a button that would
    /// not press. The current time is the bright half, the total is context.
    private var timecodeReadout: some View {
        HStack(spacing: 4 * uiScale) {
            Text(recordingEditorPreciseTimeText(playheadSeconds))
                .font(.recordingsNvidia(size: 13 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
            Text("/")
                .font(.recordingsNvidia(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.30))
            Text(recordingEditorPreciseTimeText(previewDurationSeconds))
                .font(.recordingsNvidia(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
        }
        .monospacedDigit()
        .fixedSize()
        .padding(.horizontal, 4 * uiScale)
        .frame(height: Self.controlHeight * uiScale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playhead")
        .accessibilityValue("\(recordingEditorPreciseTimeText(playheadSeconds)) of \(recordingEditorPreciseTimeText(previewDurationSeconds))")
    }

    /// Transport and edit actions on one wrapping line. They were two fixed rows, which cost a
    /// third of the drawer's height and pushed everything below it into the window's bottom edge.
    /// Two jobs, two edges: moving the playhead on the left, changing the timeline on the right.
    /// Interleaved on one evenly-spaced line they read as one undifferentiated strip of buttons.
    ///
    /// `ViewThatFits` keeps that split for as long as the pane is wide enough and drops to a
    /// stacked pair of rows when it is not, rather than squeezing thirteen controls into a line
    /// that cannot hold them.
    private var controlRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7 * uiScale) {
                playbackControls
                Spacer(minLength: 28 * uiScale)
                HStack(spacing: 7 * uiScale) { editActionButtons }
            }
            VStack(alignment: .leading, spacing: 8 * uiScale) {
                HStack(spacing: 7 * uiScale) {
                    playbackControls
                    Spacer(minLength: 0)
                }
                SettingsFlowLayout(spacing: 7 * uiScale) { editActionButtons }
            }
        }
        .overlay(alignment: .topLeading) { keyboardNudges }
    }

    private var playbackControls: some View {
        HStack(spacing: 10 * uiScale) {
            transportGroup
            timecodeReadout
        }
    }

    /// The fine step the ±0.2 s buttons used to be. Zero-sized rather than absent: a keyboard
    /// shortcut needs a control in the hierarchy to hang off, and a frame hunt wants a key repeat,
    /// not a click repeat.
    private var keyboardNudges: some View {
        Group {
            Button("Nudge back") { onStep(-0.2) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Nudge forward") { onStep(0.2) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            // Bare Backspace, but only while the name field does not have it: there it has to keep
            // deleting characters.
            if !viewModel.isTitleFieldFocused {
                Button("Remove marked range") { viewModel.cutMarkedRange() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(!viewModel.hasMarkedRange)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .disabled(viewModel.isExporting)
        .accessibilityHidden(true)
    }

    private func transportButton(_ systemImage: String, help: String, isProminent: Bool = false, isDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        RecordingEditorControl(
            systemImage: systemImage, tone: isProminent ? .prominent : .standard, width: 34,
            help: help, isDisabled: viewModel.isExporting || isDisabled, action: action
        )
    }

    // MARK: - Quick actions

    @ViewBuilder
    private var editActionButtons: some View {
        Group {
            quickButton("Trim Start", systemImage: "arrow.left.to.line", help: "Cut everything before the playhead (⌘[)", shortcut: KeyEquivalent("["))
                { applyAtSourcePlayhead(viewModel.trimStartToPlayhead) }
            quickButton("Trim End", systemImage: "arrow.right.to.line", help: "Cut everything after the playhead (⌘])", shortcut: KeyEquivalent("]"))
                { applyAtSourcePlayhead(viewModel.trimEndToPlayhead) }
            // ⌘B, not ⌘K: the Stream menu binds ⌘K to Toggle Anti-AFK with no enablement guard, and
            // a main-menu key equivalent is dispatched before any view-level shortcut, so Split
            // never fired. ⌘B is also what a blade tool is bound to elsewhere.
            quickButton("Split", systemImage: "scissors", help: "Split the clip at the playhead (⌘B)", shortcut: "b")
                { applyAtSourcePlayhead(viewModel.splitAtPlayhead) }
            quickButton("Join", systemImage: "link", help: viewModel.canJoinSelectedSection ? "Merge the two sections back into one (⌘J)" : "Only neighbouring sections that were split apart can merge. A removed range cannot be put back.", isDisabled: !viewModel.canJoinSelectedSection, shortcut: "j")
                { viewModel.joinSelectedSection() }
            quickButton("Set In", systemImage: "bracket.left", help: "Start a selection at the playhead (⌘I)", shortcut: "i")
                { applyAtSourcePlayhead(viewModel.markIn) }
            quickButton("Set Out", systemImage: "bracket.right", help: "End the selection at the playhead (⌘O)", shortcut: "o")
                { applyAtSourcePlayhead(viewModel.markOut) }
            quickButton("Remove Selection", systemImage: "trash", help: "Cut the marked range out of the clip (⌫). Drag across the timeline, or shift-click it, to mark a range.", isDisabled: !viewModel.hasMarkedRange, shortcut: .delete)
                { viewModel.cutMarkedRange() }
        }
    }

    // MARK: - Export

    /// What just happened, what the export will produce, or how the export is going. It sat on the
    /// bottom edge of the window, which is the last place anyone looks and the first thing to be
    /// clipped; it belongs next to the thing it is describing.
    /// Labelled coarse step: "5s" with a direction, rather than a glyph that has to be decoded.
    private func transportStepButton(_ title: String, systemImage: String, trailingIcon: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        RecordingEditorControl(
            horizontalPadding: 8, help: help,
            isDisabled: viewModel.isExporting, action: action
        ) {
            HStack(spacing: 3 * uiScale) {
                if !trailingIcon { Image(systemName: systemImage) }
                Text(title)
                if trailingIcon { Image(systemName: systemImage) }
            }
        }
    }

    /// What the export is actually about to produce, rather than a standing reassurance. The
    /// original is never touched either way, which is the part worth repeating.
    // MARK: - Playhead plumbing

    private var sourceTimelinePlayheadSeconds: Double {
        playheadSeconds * max(0.25, viewModel.playbackRate)
    }

    private func seekTimeline(_ timelineSeconds: Double) {
        guard let target = viewModel.sourceTime(forTimelineSeconds: timelineSeconds) else { return }
        viewModel.selectSegment(target.segment)
        onSeek(timelineSeconds / max(0.25, viewModel.playbackRate))
    }

    private func applyAtSourcePlayhead(_ action: (Double) -> Void) {
        guard let target = viewModel.sourceTime(forTimelineSeconds: sourceTimelinePlayheadSeconds) else { return }
        if viewModel.selectedSegmentID != target.segment.id {
            viewModel.selectSegment(target.segment)
        }
        action(target.seconds)
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

    /// Continuous text: one undo step for the whole run of typing rather than one per keystroke.
    private func quickButton(_ title: String, systemImage: String, help: String, isDisabled: Bool = false, shortcut: KeyEquivalent? = nil, action: @escaping () -> Void) -> some View {
        RecordingEditorControl(
            help: help, accessibilityTitle: title,
            isDisabled: viewModel.isExporting || isDisabled, shortcut: shortcut, action: action
        ) {
            HStack(spacing: 6 * uiScale) {
                Image(systemName: systemImage)
                Text(title)
            }
        }
    }
}
