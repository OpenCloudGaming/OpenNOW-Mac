import AppKit
import AVKit
import SwiftUI

enum RecordingsLayout {
    static var sidebar: Color { OPNDesign.Surface.deep }
    static var surface: Color { OPNDesign.Surface.deep }
    static var card: Color { OPNDesign.Fill.neutral(0.055) }
    static var raised: Color { OPNDesign.Fill.neutral(0.085) }
    static var stroke: Color { OPNDesign.Stroke.subtle }
    static var strongStroke: Color { OPNDesign.Stroke.strong }
    static let danger = OPNDesign.Semantic.destructive
}

extension Font {
    static func recordingsFont(size: CGFloat, weight: OPNUIFont.Weight = .regular) -> Font {
        OPNUIFont.font(size: size, weight: weight)
    }
}

enum RecordingRightsNoticePreference {
    static let key = "OpenNOW.Recordings.RightsNoticeAcknowledged"
}

struct RecordingsView: View {
    @AppStorage(RecordingRightsNoticePreference.key) private var rightsNoticeAcknowledged = false
    @Environment(\.opnUIScale) private var uiScale
    /// Owns the library, the selection, the player and the editor preview pipeline. A
    /// `@StateObject` on this view, so its lifetime is what the fourteen `@State` properties it
    /// replaced had.
    @StateObject private var model = RecordingsViewModel()
    /// Set only when controller mode embeds this page; nil on the desktop surface.
    @Environment(\.controllerPageCommand) private var controllerPageCommand
    /// The row whose custom right-click menu is open, if any, and where to anchor it.
    @State private var contextMenuRecording: StreamRecording?
    @State private var contextMenuAnchor: CGPoint = .zero
    /// The list's frame of reference for resolving a row's right-click into list coordinates.
    @State private var contextSurface = OPNContextSurface()

    private var visibleRecordings: [StreamRecording] { model.visibleRecordings }

    /// Formatting the library summary is the view's job; `RecordingLibraryStats` only counts.
    private var librarySubtitle: String {
        guard let newest = model.stats.newest else { return "Gameplay capture library" }
        return "Latest: \(RecordingFormat.relativeDateText(newest.createdAt))"
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                recordingsList
                    .frame(width: OPNDesign.clamped(proxy.size.width * 0.34, minimum: 380, maximum: 520))
                playerPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The pane's decorative backdrop ignores the safe area; clipping keeps it inside
                    // the pane so the diagonal grid can never paint over the list.
                    .clipped()
            }
        }
        // Opaque base, not the striped backdrop: the list is the page's content surface and the
        // stripes belong to the preview pane only.
        .background(RecordingsLayout.surface)
        // The page owns the bottom of the window: the editor drawer sits on that edge, and stopping
        // at the safe area left a band of whatever is behind it.
        .ignoresSafeArea(edges: .bottom)
        .overlay {
            if !rightsNoticeAcknowledged {
                RecordingRightsNotice(onAcknowledge: { rightsNoticeAcknowledged = true }, uiScale: uiScale)
            }
        }
        .onAppear { model.reload(showMessage: false) }
        .onChange(of: controllerPageCommand) { _, pageCommand in
            guard let pageCommand else { return }
            model.applyControllerCommand(pageCommand.command, in: visibleRecordings)
        }
        .onChange(of: visibleRecordings.map(\.id)) { _, ids in
            model.reconcileSelection(withVisibleIDs: ids)
        }
        .opnConfirmation(
            isPresented: discardEditsDialogPresented,
            eyebrow: "UNSAVED EDITS",
            title: "Discard the edits to this recording?",
            message: "The edit has not been exported. Nothing is written to disk until you save it as a new video.",
            actions: [
                OPNConfirmationAction("KEEP EDITING", role: .cancel) { model.cancelPendingEditorDiscard() },
                OPNConfirmationAction("DISCARD EDITS", role: .destructive) { model.confirmPendingEditorDiscard() }
            ]
        )
        .opnConfirmation(
            isPresented: deleteDialogPresented,
            eyebrow: "DELETE RECORDING",
            title: model.deleteDialogTitle,
            message: "This permanently removes the video file and metadata from OpenNOW recordings.",
            actions: [
                OPNConfirmationAction("CANCEL", role: .cancel) { model.pendingDelete = nil },
                OPNConfirmationAction("DELETE RECORDING", role: .destructive) { model.deletePendingRecording() }
            ]
        )
        .onDisappear {
            model.cancelEditorPreview()
            model.removePlayerTimeObserver()
        }
    }

    private var recordingsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            libraryHeader
            RecordingSearchField(text: $model.searchText, uiScale: uiScale)
                .padding(.horizontal, 18 * uiScale)
                .padding(.top, 4 * uiScale)
            sortAndFilters
                .padding(.horizontal, 18 * uiScale)
                .padding(.top, 14 * uiScale)
                .zIndex(1)

            if model.recordings.isEmpty {
                RecordingEmptyState(kind: .library, action: { model.reload(showMessage: true) }, uiScale: uiScale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleRecordings.isEmpty {
                RecordingEmptyState(kind: .search, action: {
                    model.clearSearch()
                    model.clearFilters()
                }, uiScale: uiScale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 10 * uiScale) {
                        ForEach(visibleRecordings) { recording in
                            RecordingRow(recording: recording, isSelected: model.selectedRecording?.id == recording.id, uiScale: uiScale) {
                                model.requestSelect(recording, autoplay: true)
                            }
                            .background {
                                OPNContextRowAnchor(surface: contextSurface, id: recording.id)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .padding(.horizontal, 14 * uiScale)
                    .padding(.vertical, 18 * uiScale)
                }
            }
        }
        .background(RecordingsLayout.sidebar)
        .background {
            OPNContextMenuHost(
                surface: contextSurface,
                onContextClick: { id, point in
                    guard let recording = visibleRecordings.first(where: { $0.id == id }) else { return }
                    presentContextMenu(for: recording, at: point)
                },
                onDismiss: dismissContextMenu
            )
            .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) { Rectangle().fill(RecordingsLayout.stroke).frame(width: 1) }
        .overlay { contextMenuOverlay }
    }

    @ViewBuilder
    private var contextMenuOverlay: some View {
        if let recording = contextMenuRecording {
            OPNContextMenuOverlay(
                items: contextMenuItems(for: recording),
                anchor: contextMenuAnchor,
                dismiss: dismissContextMenu
            )
        }
    }

    private func presentContextMenu(for recording: StreamRecording, at point: CGPoint) {
        contextMenuRecording = recording
        contextMenuAnchor = point
    }

    private func dismissContextMenu() {
        contextMenuRecording = nil
    }

    private func contextMenuItems(for recording: StreamRecording) -> [OPNDropdownItem] {
        [
            OPNDropdownItem(id: "open", title: "Open Recording") { model.open(recording) },
            OPNDropdownItem(id: "edit", title: "Edit Recording") { model.startEditing(recording) },
            OPNDropdownItem(id: "reveal", title: "Reveal in Finder") { model.reveal(recording) },
            OPNDropdownItem(id: "copy", title: "Copy File Path") { model.copyPath(recording) },
            OPNDropdownItem(id: "delete", title: "Delete", isDestructive: true, startsGroup: true) {
                model.pendingDelete = recording
            }
        ]
    }

    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            HStack(alignment: .top, spacing: 12 * uiScale) {
                VStack(alignment: .leading, spacing: 5 * uiScale) {
                    Text("RECORDINGS")
                        .font(.recordingsFont(size: 11 * uiScale, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(OPNDesign.accentInk)
                    Text("Saved Videos")
                        .font(.recordingsFont(size: 25 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                    Text(librarySubtitle)
                        .font(.recordingsFont(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Button { model.reload(showMessage: true) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.recordingsFont(size: 15 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                        .frame(width: 40 * uiScale, height: 40 * uiScale)
                        .background(OPNDesign.Stroke.subtle)
                        .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .help("Refresh recordings")
            }

            HStack(spacing: 8 * uiScale) {
                RecordingMetric(title: "VIDEOS", value: "\(model.recordings.count)", uiScale: uiScale)
                RecordingMetric(title: "RUNTIME", value: RecordingFormat.durationText(model.stats.totalDurationSeconds), uiScale: uiScale)
                RecordingMetric(title: "SIZE", value: RecordingFormat.compactFileSizeText(model.stats.totalBytes), uiScale: uiScale)
            }

        }
        .padding(.horizontal, 22 * uiScale)
        .padding(.top, 22 * uiScale)
        .padding(.bottom, 16 * uiScale)
    }

    private var sortAndFilters: some View {
        VStack(alignment: .leading, spacing: 12 * uiScale) {
            HStack(spacing: 10 * uiScale) {
                OPNDropdownMenu(
                    items: RecordingSortOrder.allCases.map { order in
                        OPNDropdownItem(id: order.id, title: order.title, isSelected: order == model.sortOrder) { model.sortOrder = order }
                    }
                ) {
                    HStack(spacing: 8 * uiScale) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(model.sortOrder.title)
                        Image(systemName: "chevron.down")
                            .font(.recordingsFont(size: 9 * uiScale, weight: .bold))
                    }
                    .font(.recordingsFont(size: 11 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .padding(.horizontal, OPNDesign.Spacing.controlRow(scale: uiScale))
                    .frame(height: 32 * uiScale)
                    .background(RecordingsLayout.card)
                    .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
                }

                Spacer()

                Text("\(visibleRecordings.count) shown")
                    .font(.recordingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
            }
            .zIndex(1)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7 * uiScale) {
                    ForEach(RecordingFilter.allCases) { filter in
                        RecordingFilterChip(filter: filter, isActive: model.activeFilters.contains(filter), uiScale: uiScale) {
                            model.toggleFilter(filter)
                        }
                    }
                }
            }
        }
    }

    private var playerPane: some View {
        // The backdrop is a `.background`, never a ZStack sibling: an `ignoresSafeArea` child in a
        // ZStack drew its blend-mode grid over the content instead of under it.
        Group {
            if let selectedRecording = model.selectedRecording, let player = model.player {
                selectedPlayer(recording: selectedRecording, player: player)
            } else {
                RecordingEmptyPlayer(message: model.message, uiScale: uiScale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RecordingsBackdrop())
    }

    private func selectedPlayer(recording: StreamRecording, player: AVPlayer) -> some View {
        let isEditing = model.editorViewModel?.primaryRecording.id == recording.id
        return VStack(spacing: 0) {
            pageHeader(recording: recording, editorViewModel: isEditing ? model.editorViewModel : nil)
            ZStack(alignment: .topLeading) {
                RecordingPlayerView(player: player)
                    .background(Color.black)
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.black.opacity(0.00), .black.opacity(0.58)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 140 * uiScale)
                    }
                    .onAppear { player.play() }

                if let editorViewModel = model.editorViewModel {
                    RecordingCropOverlayHost(viewModel: editorViewModel, uiScale: uiScale)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { Rectangle().stroke(Color.black.opacity(0.72), lineWidth: 1) }

            if let editorViewModel = model.editorViewModel, editorViewModel.primaryRecording.id == recording.id {
                RecordingEditorView(
                    viewModel: editorViewModel,
                    playheadSeconds: model.playerTimeSeconds,
                    previewDurationSeconds: model.editorPreviewDuration,
                    isPlaying: model.isPlaying,
                    onSeek: model.seekEditorPreview,
                    onStep: model.stepEditorPreview,
                    onTogglePlayback: model.togglePlayback,
                    onSkipToEnd: model.seekEditorPreviewToEnd,
                    onPreviewChanged: { model.refreshEditedPreview(debounce: true) },
                    isControllerFocused: controllerPageCommand != nil && model.controllerFocus == .editor
                )
                .frame(maxWidth: .infinity, maxHeight: RecordingEditorView.preferredHeight(uiScale: uiScale))
            }
        }
    }

    private var discardEditsDialogPresented: Binding<Bool> {
        Binding(
            get: { model.pendingEditorDiscardSelection != nil || model.isPendingEditorClose },
            set: { if !$0 { model.cancelPendingEditorDiscard() } }
        )
    }

    /// The editor's header replaces the recording's while an edit is open: same row, different job.
    @ViewBuilder
    private func pageHeader(recording: StreamRecording, editorViewModel: RecordingEditorViewModel?) -> some View {
        if let editorViewModel {
            RecordingEditorHeaderBar(
                viewModel: editorViewModel,
                isControllerFocused: controllerPageCommand != nil && model.controllerFocus == .editor,
                onCancel: model.requestCloseEditor,
                onExport: model.startEditorExport,
                onCancelExport: model.cancelEditorExport
            )
        } else {
            RecordingInspector(
                recording: recording,
                isPathCopied: model.copiedPathRecordingID == recording.id,
                message: model.message,
                uiScale: uiScale,
                onRestart: { model.restart(recording) },
                onEdit: { model.startEditing(recording) },
                onOpen: { model.open(recording) },
                onReveal: { model.reveal(recording) },
                onCopyPath: { model.copyPath(recording) },
                onDelete: { model.pendingDelete = recording }
            )
        }
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } })
    }
}

private struct RecordingMetric: View {
    let title: String
    let value: String
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * uiScale) {
            Text(title)
                .font(.recordingsFont(size: 9 * uiScale, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(OPNDesign.Text.muted)
            Text(value)
                .font(.recordingsFont(size: 13 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10 * uiScale)
        .background(RecordingsLayout.card)
        .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
    }
}

private struct RecordingSearchField: View {
    @Binding var text: String
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 10 * uiScale) {
            Image(systemName: "magnifyingglass")
                .font(.recordingsFont(size: 13 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.accentInk.opacity(0.85))
            TextField("Search title, file, or app ID", text: $text)
                .textFieldStyle(.plain)
                .font(.recordingsFont(size: 13 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.primary)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(OPNDesign.Text.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12 * uiScale)
        .frame(height: 40 * uiScale)
        .background(OPNDesign.Stroke.subtle)
        .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
    }
}

private struct RecordingFilterChip: View {
    let filter: RecordingFilter
    let isActive: Bool
    let uiScale: CGFloat
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6 * uiScale) {
                Image(systemName: filter.systemImage)
                    .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
                Text(filter.title)
            }
            .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
            .foregroundStyle(isActive ? .black.opacity(0.86) : isHovering ? OPNDesign.Text.primary : OPNDesign.Text.secondary)
            .padding(.horizontal, 9 * uiScale)
            .frame(height: 28 * uiScale)
            .background(isActive ? OPNDesign.accent : OPNDesign.Fill.neutral(isHovering ? 0.09 : 0.055))
            .overlay { Rectangle().stroke(isActive ? OPNDesign.accent : RecordingsLayout.stroke, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct RecordingRow: View {
    let recording: StreamRecording
    let isSelected: Bool
    let uiScale: CGFloat
    let action: () -> Void
    @State private var isHovering = false

    /// Draggable so a second recording can be dropped straight onto the editor timeline.
    var body: some View {
        content
            .onDrag {
                NSItemProvider(object: RecordingEditorDragPayload.recording(recording.id).stringValue as NSString)
            }
    }

    private var content: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12 * uiScale) {
                HStack(alignment: .top, spacing: 12 * uiScale) {
                    RecordingThumbnail(recording: recording, isSelected: isSelected, isHovering: isHovering, uiScale: uiScale)
                    VStack(alignment: .leading, spacing: 6 * uiScale) {
                        Text(recording.title)
                            .font(.recordingsFont(size: 14 * uiScale, weight: .bold))
                            .foregroundStyle(OPNDesign.Text.primary)
                            .lineLimit(2)
                        Text(RecordingFormat.relativeDateText(recording.createdAt))
                            .font(.recordingsFont(size: 11 * uiScale, weight: .medium))
                            .foregroundStyle(OPNDesign.Text.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 7 * uiScale) {
                    RecordingPill(text: RecordingFormat.durationText(recording.durationSeconds), isActive: isSelected, uiScale: uiScale)
                    RecordingPill(text: RecordingFormat.qualityText(recording), isActive: false, uiScale: uiScale)
                    RecordingPill(text: RecordingFormat.compactFileSizeText(recording.fileSizeBytes), isActive: false, uiScale: uiScale)
                    Spacer(minLength: 0)
                    if recording.enhancedVideo {
                        RecordingPill(text: "RTX", isActive: true, uiScale: uiScale)
                    }
                }
            }
            .padding(13 * uiScale)
            .background(background)
            .overlay(alignment: .leading) { Rectangle().fill(isSelected ? OPNDesign.accent : .clear).frame(width: 3) }
            .overlay { Rectangle().stroke(isSelected ? OPNDesign.accent.opacity(0.48) : OPNDesign.Fill.neutral(isHovering ? 0.18 : 0.08), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recording.title)
        .accessibilityValue("\(RecordingFormat.relativeDateText(recording.createdAt)), \(RecordingFormat.durationText(recording.durationSeconds)), \(RecordingFormat.qualityText(recording)), \(RecordingFormat.compactFileSizeText(recording.fileSizeBytes))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var background: some ShapeStyle {
        if isSelected { return AnyShapeStyle(OPNDesign.accent.opacity(0.105)) }
        return AnyShapeStyle(OPNDesign.Fill.neutral(isHovering ? 0.075 : 0.04))
    }
}

private struct RecordingThumbnail: View {
    let recording: StreamRecording
    let isSelected: Bool
    let isHovering: Bool
    let uiScale: CGFloat
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 76 * uiScale, height: 46 * uiScale)
                    .clipped()
                    .overlay {
                        LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.58)], startPoint: .top, endPoint: .bottom)
                    }
            } else {
                LinearGradient(
                    colors: [OPNDesign.Fill.neutral(0.13), OPNDesign.Fill.neutral(0.03), OPNDesign.accent.opacity(isSelected ? 0.24 : 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                DiagonalGrid()
                    .stroke(Color.black.opacity(0.35), lineWidth: 1)
            }
            Image(systemName: isHovering || isSelected ? "play.fill" : "play.rectangle.fill")
                .font(.recordingsFont(size: 19 * uiScale, weight: .bold))
                .foregroundStyle(isSelected ? OPNDesign.accentInk : thumbnail == nil ? OPNDesign.Text.secondary : OPNDesign.Text.primary)
                .shadow(color: .black.opacity(thumbnail == nil ? 0 : 0.60), radius: 7 * uiScale, x: 0, y: 2 * uiScale)
        }
        .frame(width: 76 * uiScale, height: 46 * uiScale)
        .overlay(alignment: .bottomTrailing) {
            Text(RecordingFormat.resolutionBadge(recording))
                .font(.recordingsFont(size: 8 * uiScale, weight: .bold))
                .foregroundStyle(.black.opacity(0.86))
                .padding(.horizontal, 5 * uiScale)
                .frame(height: 15 * uiScale)
                .background(OPNDesign.accent)
        }
        .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
        .task(id: recording.id) {
            thumbnail = await RecordingThumbnailLoader.thumbnail(for: recording)
        }
    }
}

private struct RecordingPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(frame: .zero)
        configure(view)
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        configure(view)
        if view.player !== player {
            view.player = player
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }

    private func configure(_ view: AVPlayerView) {
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
    }
}

@MainActor
private enum RecordingThumbnailLoader {
    private static let cache = NSCache<NSString, NSImage>()

    static func thumbnail(for recording: StreamRecording) async -> NSImage? {
        let key = recording.id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await generateThumbnail(videoURL: recording.videoURL, durationSeconds: recording.durationSeconds)
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private static func generateThumbnail(videoURL: URL, durationSeconds: Double) async -> NSImage? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 216)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            let targetSeconds = max(0.2, min(max(durationSeconds * 0.18, 0.2), max(durationSeconds - 0.2, 0.2)))
            let time = CMTime(seconds: targetSeconds, preferredTimescale: 600)
            let cgImage = await withCheckedContinuation { continuation in
                generator.generateCGImageAsynchronously(for: time) { image, _, error in
                    continuation.resume(returning: error == nil ? image : nil)
                }
            }
            guard let cgImage else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
    }
}

private struct RecordingPill: View {
    let text: String
    let isActive: Bool
    let uiScale: CGFloat

    var body: some View {
        Text(text)
            .font(.recordingsFont(size: 9 * uiScale, weight: .bold))
            .foregroundStyle(isActive ? .black.opacity(0.86) : OPNDesign.Text.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7 * uiScale)
            .frame(height: 20 * uiScale)
            .background(isActive ? OPNDesign.accent : OPNDesign.Stroke.subtle)
            .overlay { Rectangle().stroke(isActive ? OPNDesign.accent : OPNDesign.Stroke.subtle, lineWidth: 1) }
    }
}
