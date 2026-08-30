import AppKit
import AVKit
import SwiftUI

enum RecordingsLayout {
    static let sidebar = Color(red: 18 / 255, green: 20 / 255, blue: 19 / 255)
    static let surface = Color(red: 12 / 255, green: 13 / 255, blue: 13 / 255)
    static let card = Color.white.opacity(0.055)
    static let raised = Color.white.opacity(0.085)
    static let stroke = Color.white.opacity(0.11)
    static let strongStroke = Color.white.opacity(0.18)
    static let danger = Color(red: 1, green: 78 / 255, blue: 78 / 255)
}

extension Font {
    static func recordingsNvidia(size: CGFloat, weight: OpenNOWNVIDIAFont.Weight = .regular) -> Font {
        OpenNOWNVIDIAFont.font(size: size, weight: weight)
    }
}

enum RecordingEditorBetaPreference {
    static let key = "OpenNOW.Recordings.EditorEarlyBetaOptIn"
}

enum RecordingRightsNoticePreference {
    static let key = "OpenNOW.Recordings.RightsNoticeAcknowledged"
}

struct RecordingsView: View {
    @AppStorage(RecordingEditorBetaPreference.key) private var recordingEditorEarlyBetaEnabled = false
    @AppStorage(RecordingRightsNoticePreference.key) private var rightsNoticeAcknowledged = false
    @Environment(\.opnUIScale) private var uiScale
    /// Owns the library, the selection, the player and the editor preview pipeline. A
    /// `@StateObject` on this view, so its lifetime is what the fourteen `@State` properties it
    /// replaced had.
    @StateObject private var model = RecordingsViewModel()
    /// Set only when controller mode embeds this page; nil on the desktop surface.
    @Environment(\.controllerPageCommand) private var controllerPageCommand

    private var visibleRecordings: [WebRTCStreamRecording] { model.visibleRecordings }

    /// Formatting the library summary is the view's job; `RecordingLibraryStats` only counts.
    private var librarySubtitle: String {
        guard let newest = model.stats.newest else { return "Gameplay capture library" }
        return "Latest: \(RecordingFormat.relativeDateText(newest.createdAt))"
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                recordingsList
                    .frame(width: OpenNOWDesign.clamped(proxy.size.width * 0.34, minimum: 380, maximum: 520))
                playerPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(RecordingsBackdrop())
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
        .onChange(of: recordingEditorEarlyBetaEnabled) { _, enabled in
            guard !enabled, model.editorViewModel != nil else { return }
            model.closeEditorForDisabledBeta()
        }
        .confirmationDialog(model.deleteDialogTitle, isPresented: deleteDialogPresented) {
            Button("Delete Recording", role: .destructive) { model.deletePendingRecording() }
            Button("Cancel", role: .cancel) { model.pendingDelete = nil }
        } message: {
            Text("This permanently removes the video file and metadata from OpenNOW recordings.")
        }
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

            if model.recordings.isEmpty {
                RecordingEmptyState(kind: .library, action: { model.reload(showMessage: true) }, uiScale: uiScale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleRecordings.isEmpty {
                RecordingEmptyState(kind: .search, action: model.clearSearchAndFilters, uiScale: uiScale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 10 * uiScale) {
                        ForEach(visibleRecordings) { recording in
                            RecordingRow(recording: recording, isSelected: model.selectedRecording?.id == recording.id, editorEarlyBetaEnabled: recordingEditorEarlyBetaEnabled, uiScale: uiScale) {
                                model.select(recording, autoplay: true)
                            }
                            .contextMenu {
                                Button("Open Recording") { model.open(recording) }
                                if recordingEditorEarlyBetaEnabled {
                                    Button("Edit Recording") { model.startEditing(recording, editorEarlyBetaEnabled: recordingEditorEarlyBetaEnabled) }
                                } else {
                                    Button("Enable in Settings > Experimental Features") { model.showRecordingEditorBetaSettingsMessage() }
                                }
                                Button("Reveal in Finder") { model.reveal(recording) }
                                Button("Copy File Path") { model.copyPath(recording) }
                                Divider()
                                Button("Delete", role: .destructive) { model.pendingDelete = recording }
                            }
                        }
                    }
                    .padding(.horizontal, 14 * uiScale)
                    .padding(.vertical, 18 * uiScale)
                }
            }
        }
        .background(RecordingsLayout.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(RecordingsLayout.stroke).frame(width: 1) }
    }

    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            HStack(alignment: .top, spacing: 12 * uiScale) {
                VStack(alignment: .leading, spacing: 5 * uiScale) {
                    Text("RECORDINGS")
                        .font(.recordingsNvidia(size: 11 * uiScale, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(OpenNOWDesign.accent)
                    Text("Saved Videos")
                        .font(.recordingsNvidia(size: 25 * uiScale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.96))
                    Text(librarySubtitle)
                        .font(.recordingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                        .lineLimit(1)
                }
                Spacer()
                Button { model.reload(showMessage: true) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.recordingsNvidia(size: 15 * uiScale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 40 * uiScale, height: 40 * uiScale)
                        .background(Color.white.opacity(0.075))
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
                OpenNOWDropdownMenu(
                    items: RecordingSortOrder.allCases.map { order in
                        OpenNOWDropdownItem(id: order.id, title: order.title, isSelected: order == model.sortOrder) { model.sortOrder = order }
                    }
                ) {
                    HStack(spacing: 8 * uiScale) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(model.sortOrder.title)
                        Image(systemName: "chevron.down")
                            .font(.recordingsNvidia(size: 9 * uiScale, weight: .bold))
                    }
                    .font(.recordingsNvidia(size: 11 * uiScale, weight: .bold))
                    .foregroundStyle(.white.opacity(0.84))
                    .padding(.horizontal, OpenNOWDesign.Spacing.controlRow(scale: uiScale))
                    .frame(height: 32 * uiScale)
                    .background(RecordingsLayout.card)
                    .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
                }

                Spacer()

                Text("\(visibleRecordings.count) shown")
                    .font(.recordingsNvidia(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
            }

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
        ZStack {
            RecordingsBackdrop()
            if let selectedRecording = model.selectedRecording, let player = model.player {
                selectedPlayer(recording: selectedRecording, player: player)
            } else {
                RecordingEmptyPlayer(message: model.message, uiScale: uiScale)
            }
        }
    }

    private func selectedPlayer(recording: WebRTCStreamRecording, player: AVPlayer) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                RecordingPlayerView(player: player)
                    .background(Color.black)
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0.00)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 120 * uiScale)
                    }
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.black.opacity(0.00), .black.opacity(0.58)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 140 * uiScale)
                    }
                    .onAppear { player.play() }

                RecordingNowPlayingBadge(recording: recording, uiScale: uiScale)
                    .padding(22 * uiScale)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { Rectangle().stroke(Color.black.opacity(0.72), lineWidth: 1) }

            RecordingInspector(
                recording: recording,
                copiedPath: model.copiedPathRecordingID == recording.id,
                message: model.message,
                editorEarlyBetaEnabled: recordingEditorEarlyBetaEnabled,
                uiScale: uiScale,
                onRestart: { model.restart(recording) },
                onEdit: { model.startEditing(recording, editorEarlyBetaEnabled: recordingEditorEarlyBetaEnabled) },
                onEditorLocked: model.showRecordingEditorBetaSettingsMessage,
                onOpen: { model.open(recording) },
                onReveal: { model.reveal(recording) },
                onCopyPath: { model.copyPath(recording) },
                onDelete: { model.pendingDelete = recording }
            )
            if let editorViewModel = model.editorViewModel, editorViewModel.primaryRecording.id == recording.id {
                RecordingEditorView(
                    viewModel: editorViewModel,
                    playheadSeconds: model.playerTimeSeconds,
                    onSeek: model.seekEditorPreview,
                    onCancel: model.closeEditor,
                    onSaved: model.editedRecordingSaved,
                    onPreviewChanged: { model.refreshEditedPreview(debounce: true) }
                )
                .frame(maxHeight: 390)
            }
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
                .font(.recordingsNvidia(size: 9 * uiScale, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.42))
            Text(value)
                .font(.recordingsNvidia(size: 13 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
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
                .font(.recordingsNvidia(size: 13 * uiScale, weight: .bold))
                .foregroundStyle(OpenNOWDesign.accent.opacity(0.85))
            TextField("Search title, file, or app ID", text: $text)
                .textFieldStyle(.plain)
                .font(.recordingsNvidia(size: 13 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.94))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.42))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12 * uiScale)
        .frame(height: 40 * uiScale)
        .background(Color.white.opacity(0.065))
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
                    .font(.recordingsNvidia(size: 10 * uiScale, weight: .bold))
                Text(filter.title)
            }
            .font(.recordingsNvidia(size: 10 * uiScale, weight: .bold))
            .foregroundStyle(isActive ? .black.opacity(0.86) : .white.opacity(isHovering ? 0.92 : 0.64))
            .padding(.horizontal, 9 * uiScale)
            .frame(height: 28 * uiScale)
            .background(isActive ? OpenNOWDesign.accent : Color.white.opacity(isHovering ? 0.09 : 0.055))
            .overlay { Rectangle().stroke(isActive ? OpenNOWDesign.accent : RecordingsLayout.stroke, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct RecordingRow: View {
    let recording: WebRTCStreamRecording
    let isSelected: Bool
    let editorEarlyBetaEnabled: Bool
    let uiScale: CGFloat
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        if editorEarlyBetaEnabled {
            content
                .onDrag {
                    NSItemProvider(object: RecordingEditorDragPayload.recording(recording.id).stringValue as NSString)
                }
        } else {
            content
        }
    }

    private var content: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12 * uiScale) {
                HStack(alignment: .top, spacing: 12 * uiScale) {
                    RecordingThumbnail(recording: recording, isSelected: isSelected, isHovering: isHovering, uiScale: uiScale)
                    VStack(alignment: .leading, spacing: 6 * uiScale) {
                        Text(recording.title)
                            .font(.recordingsNvidia(size: 14 * uiScale, weight: .bold))
                            .foregroundStyle(.white.opacity(0.96))
                            .lineLimit(2)
                        Text(RecordingFormat.relativeDateText(recording.createdAt))
                            .font(.recordingsNvidia(size: 11 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.54))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 7 * uiScale) {
                    RecordingPill(text: RecordingFormat.durationText(recording.durationSeconds), active: isSelected, uiScale: uiScale)
                    RecordingPill(text: RecordingFormat.qualityText(recording), active: false, uiScale: uiScale)
                    RecordingPill(text: RecordingFormat.compactFileSizeText(recording.fileSizeBytes), active: false, uiScale: uiScale)
                    Spacer(minLength: 0)
                    if recording.enhancedVideo {
                        RecordingPill(text: "RTX", active: true, uiScale: uiScale)
                    }
                }
            }
            .padding(13 * uiScale)
            .background(background)
            .overlay(alignment: .leading) { Rectangle().fill(isSelected ? OpenNOWDesign.accent : .clear).frame(width: 3) }
            .overlay { Rectangle().stroke(isSelected ? OpenNOWDesign.accent.opacity(0.48) : Color.white.opacity(isHovering ? 0.18 : 0.08), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var background: some ShapeStyle {
        if isSelected { return AnyShapeStyle(OpenNOWDesign.accent.opacity(0.105)) }
        return AnyShapeStyle(Color.white.opacity(isHovering ? 0.075 : 0.04))
    }
}

private struct RecordingThumbnail: View {
    let recording: WebRTCStreamRecording
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
                    colors: [Color.white.opacity(0.13), Color.white.opacity(0.03), OpenNOWDesign.accent.opacity(isSelected ? 0.24 : 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                DiagonalGrid()
                    .stroke(Color.black.opacity(0.35), lineWidth: 1)
            }
            Image(systemName: isHovering || isSelected ? "play.fill" : "play.rectangle.fill")
                .font(.recordingsNvidia(size: 19 * uiScale, weight: .bold))
                .foregroundStyle(isSelected ? OpenNOWDesign.accent : .white.opacity(thumbnail == nil ? 0.76 : 0.92))
                .shadow(color: .black.opacity(thumbnail == nil ? 0 : 0.60), radius: 7 * uiScale, x: 0, y: 2 * uiScale)
        }
        .frame(width: 76 * uiScale, height: 46 * uiScale)
        .overlay(alignment: .bottomTrailing) {
            Text(RecordingFormat.resolutionBadge(recording))
                .font(.recordingsNvidia(size: 8 * uiScale, weight: .bold))
                .foregroundStyle(.black.opacity(0.86))
                .padding(.horizontal, 5 * uiScale)
                .frame(height: 15 * uiScale)
                .background(OpenNOWDesign.accent)
        }
        .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
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

    static func thumbnail(for recording: WebRTCStreamRecording) async -> NSImage? {
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
    let active: Bool
    let uiScale: CGFloat

    var body: some View {
        Text(text)
            .font(.recordingsNvidia(size: 9 * uiScale, weight: .bold))
            .foregroundStyle(active ? .black.opacity(0.86) : .white.opacity(0.62))
            .lineLimit(1)
            .padding(.horizontal, 7 * uiScale)
            .frame(height: 20 * uiScale)
            .background(active ? OpenNOWDesign.accent : Color.white.opacity(0.065))
            .overlay { Rectangle().stroke(active ? OpenNOWDesign.accent : Color.white.opacity(0.10), lineWidth: 1) }
    }
}

private struct RecordingNowPlayingBadge: View {
    let recording: WebRTCStreamRecording
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            HStack(spacing: 8 * uiScale) {
                Circle()
                    .fill(OpenNOWDesign.accent)
                    .frame(width: 8 * uiScale, height: 8 * uiScale)
                Text("NOW PLAYING")
                    .font(.recordingsNvidia(size: 10 * uiScale, weight: .bold))
                    .tracking(1.3)
                    .foregroundStyle(OpenNOWDesign.accent)
            }
            Text(recording.title)
                .font(.recordingsNvidia(size: 20 * uiScale, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(RecordingFormat.qualityText(recording)) · \(RecordingFormat.durationText(recording.durationSeconds)) · \(RecordingFormat.compactFileSizeText(recording.fileSizeBytes))")
                .font(.recordingsNvidia(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
                .lineLimit(1)
        }
        .padding(15 * uiScale)
        .background(.black.opacity(0.55))
        .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
    }
}
