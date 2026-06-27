import AppKit
import AppKit
import AVKit
import CoreText
import SwiftUI
import WebRTCMedia

private enum RecordingsLayout {
    static let sidebar = Color(red: 18 / 255, green: 20 / 255, blue: 19 / 255)
    static let surface = Color(red: 12 / 255, green: 13 / 255, blue: 13 / 255)
    static let card = Color.white.opacity(0.055)
    static let raised = Color.white.opacity(0.085)
    static let stroke = Color.white.opacity(0.11)
    static let strongStroke = Color.white.opacity(0.18)
    static let danger = Color(red: 1, green: 78 / 255, blue: 78 / 255)
}

private enum RecordingsFont {
    enum Weight: Hashable {
        case regular
        case medium
        case bold
    }

    static func font(size: CGFloat, weight: Weight = .regular) -> Font {
        Font(nsFont(size: size, weight: weight))
    }

    private static func nsFont(size: CGFloat, weight: Weight) -> NSFont {
        if let descriptor = descriptors[weight] ?? nil {
            return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
        }
        return NSFont.systemFont(ofSize: size, weight: fallbackWeight(weight))
    }

    private static func fallbackWeight(_ weight: Weight) -> NSFont.Weight {
        switch weight {
        case .regular: return .regular
        case .medium: return .medium
        case .bold: return .bold
        }
    }

    private static let descriptors: [Weight: CTFontDescriptor?] = [
        .regular: loadDescriptor(named: "NVIDIASans_W_Rg"),
        .medium: loadDescriptor(named: "NVIDIASans_W_Md"),
        .bold: loadDescriptor(named: "NVIDIASans_W_Bd")
    ]

    private static func loadDescriptor(named name: String) -> CTFontDescriptor? {
        for subdirectory in ["NVIDIA", "Resources/NVIDIA", nil] as [String?] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "woff2", subdirectory: subdirectory),
                  let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let descriptor = descriptors.first else { continue }
            return descriptor
        }
        return nil
    }
}

private extension Font {
    static func recordingsNvidia(size: CGFloat, weight: RecordingsFont.Weight = .regular) -> Font {
        RecordingsFont.font(size: size, weight: weight)
    }
}

struct RecordingsView: View {
    @State private var recordings: [WebRTCStreamRecording] = []
    @State private var selectedRecording: WebRTCStreamRecording?
    @State private var player: AVPlayer?
    @State private var message = ""
    @State private var pendingDelete: WebRTCStreamRecording?
    @State private var searchText = ""
    @State private var sortOrder: RecordingSortOrder = .newest
    @State private var activeFilters = Set<RecordingFilter>()
    @State private var copiedPathRecordingID: UUID?

    private var visibleRecordings: [WebRTCStreamRecording] {
        let normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return recordings
            .filter { recording in
                guard !normalizedQuery.isEmpty else { return true }
                return recording.title.lowercased().contains(normalizedQuery)
                    || recording.applicationID.lowercased().contains(normalizedQuery)
                    || recording.videoURL.lastPathComponent.lowercased().contains(normalizedQuery)
            }
            .filter { recording in
                activeFilters.allSatisfy { $0.matches(recording) }
            }
            .sorted(using: sortOrder)
    }

    private var stats: RecordingLibraryStats {
        RecordingLibraryStats(recordings: recordings)
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
        .onAppear { reload(showMessage: false) }
        .onChange(of: visibleRecordings.map(\.id)) { _, ids in
            guard let selectedRecording, !ids.contains(selectedRecording.id) else { return }
            select(visibleRecordings.first, autoplay: false)
        }
        .confirmationDialog(deleteDialogTitle, isPresented: deleteDialogPresented) {
            Button("Delete Recording", role: .destructive) { deletePendingRecording() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This permanently removes the video file and metadata from OpenNOW recordings.")
        }
    }

    private var recordingsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            libraryHeader
            RecordingSearchField(text: $searchText)
                .padding(.horizontal, 18)
                .padding(.top, 4)
            sortAndFilters
                .padding(.horizontal, 18)
                .padding(.top, 14)

            if recordings.isEmpty {
                RecordingEmptyState(kind: .library, action: { reload(showMessage: true) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleRecordings.isEmpty {
                RecordingEmptyState(kind: .search, action: clearSearchAndFilters)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleRecordings) { recording in
                            RecordingRow(recording: recording, isSelected: selectedRecording?.id == recording.id) {
                                select(recording, autoplay: true)
                            }
                            .contextMenu {
                                Button("Open Recording") { open(recording) }
                                Button("Reveal in Finder") { reveal(recording) }
                                Button("Copy File Path") { copyPath(recording) }
                                Divider()
                                Button("Delete", role: .destructive) { pendingDelete = recording }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 18)
                }
            }
        }
        .background(RecordingsLayout.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(RecordingsLayout.stroke).frame(width: 1) }
    }

    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("RECORDINGS")
                        .font(.recordingsNvidia(size: 11, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(Color.openNowGreen)
                    Text("Saved Videos")
                        .font(.recordingsNvidia(size: 25, weight: .bold))
                        .foregroundStyle(.white.opacity(0.96))
                    Text(stats.subtitle)
                        .font(.recordingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                        .lineLimit(1)
                }
                Spacer()
                Button { reload(showMessage: true) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.recordingsNvidia(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.075))
                        .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .help("Refresh recordings")
            }

            HStack(spacing: 8) {
                RecordingMetric(title: "VIDEOS", value: "\(recordings.count)")
                RecordingMetric(title: "RUNTIME", value: durationText(stats.totalDurationSeconds))
                RecordingMetric(title: "SIZE", value: compactFileSizeText(stats.totalBytes))
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private var sortAndFilters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(RecordingSortOrder.allCases) { order in
                        Button(order.title) { sortOrder = order }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(sortOrder.title)
                        Image(systemName: "chevron.down")
                            .font(.recordingsNvidia(size: 9, weight: .bold))
                    }
                    .font(.recordingsNvidia(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.84))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(RecordingsLayout.card)
                    .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
                }
                .buttonStyle(.plain)

                Spacer()

                Text("\(visibleRecordings.count) shown")
                    .font(.recordingsNvidia(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(RecordingFilter.allCases) { filter in
                        RecordingFilterChip(filter: filter, isActive: activeFilters.contains(filter)) {
                            toggleFilter(filter)
                        }
                    }
                }
            }
        }
    }

    private var playerPane: some View {
        ZStack {
            RecordingsBackdrop()
            if let selectedRecording, let player {
                selectedPlayer(recording: selectedRecording, player: player)
            } else {
                RecordingEmptyPlayer(message: message)
            }
        }
    }

    private func selectedPlayer(recording: WebRTCStreamRecording, player: AVPlayer) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                VideoPlayer(player: player)
                    .background(Color.black)
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0.00)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 120)
                    }
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.black.opacity(0.00), .black.opacity(0.58)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 140)
                    }
                    .onAppear { player.play() }

                RecordingNowPlayingBadge(recording: recording)
                    .padding(22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { Rectangle().stroke(Color.black.opacity(0.72), lineWidth: 1) }

            RecordingInspector(
                recording: recording,
                copiedPath: copiedPathRecordingID == recording.id,
                message: message,
                onRestart: { restart(recording) },
                onOpen: { open(recording) },
                onReveal: { reveal(recording) },
                onCopyPath: { copyPath(recording) },
                onDelete: { pendingDelete = recording }
            )
        }
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var deleteDialogTitle: String {
        guard let pendingDelete else { return "Delete recording?" }
        return "Delete \"\(pendingDelete.title)\"?"
    }

    private func reload(showMessage: Bool) {
        recordings = WebRTCStreamRecordingLibrary.loadRecordings()
        if let selectedRecording, let refreshed = recordings.first(where: { $0.id == selectedRecording.id }) {
            self.selectedRecording = refreshed
            if player == nil { select(refreshed, autoplay: false) }
        } else {
            select(visibleRecordings.first, autoplay: false)
        }
        if showMessage {
            message = recordings.isEmpty ? "No recordings found in your GeForce NOW movies folder." : "Loaded \(recordings.count) recording\(recordings.count == 1 ? "" : "s")."
        }
    }

    private func select(_ recording: WebRTCStreamRecording?, autoplay: Bool) {
        selectedRecording = recording
        guard let recording else {
            player?.pause()
            player = nil
            return
        }
        player?.pause()
        let nextPlayer = AVPlayer(url: recording.videoURL)
        player = nextPlayer
        if autoplay { nextPlayer.play() }
    }

    private func restart(_ recording: WebRTCStreamRecording) {
        guard selectedRecording?.id == recording.id else {
            select(recording, autoplay: true)
            return
        }
        player?.seek(to: .zero)
        player?.play()
    }

    private func reveal(_ recording: WebRTCStreamRecording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.videoURL])
        message = "Revealed \(recording.videoURL.lastPathComponent) in Finder."
    }

    private func open(_ recording: WebRTCStreamRecording) {
        NSWorkspace.shared.open(recording.videoURL)
        message = "Opened \(recording.videoURL.lastPathComponent)."
    }

    private func copyPath(_ recording: WebRTCStreamRecording) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recording.videoURL.path, forType: .string)
        copiedPathRecordingID = recording.id
        message = "Copied recording path."
    }

    private func clearSearchAndFilters() {
        searchText = ""
        activeFilters.removeAll()
    }

    private func toggleFilter(_ filter: RecordingFilter) {
        if activeFilters.contains(filter) {
            activeFilters.remove(filter)
        } else {
            activeFilters.insert(filter)
        }
    }

    private func deletePendingRecording() {
        guard let recording = pendingDelete else { return }
        do {
            try WebRTCStreamRecordingLibrary.delete(recording)
            pendingDelete = nil
            message = "Deleted \(recording.title)."
            reload(showMessage: false)
        } catch {
            message = error.localizedDescription
            pendingDelete = nil
        }
    }
}

private struct RecordingMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.recordingsNvidia(size: 9, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.42))
            Text(value)
                .font(.recordingsNvidia(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RecordingsLayout.card)
        .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
    }
}

private struct RecordingSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.recordingsNvidia(size: 13, weight: .bold))
                .foregroundStyle(Color.openNowGreen.opacity(0.85))
            TextField("Search title, file, or app ID", text: $text)
                .textFieldStyle(.plain)
                .font(.recordingsNvidia(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.94))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.42))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color.white.opacity(0.065))
        .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
    }
}

private struct RecordingFilterChip: View {
    let filter: RecordingFilter
    let isActive: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: filter.systemImage)
                    .font(.recordingsNvidia(size: 10, weight: .bold))
                Text(filter.title)
            }
            .font(.recordingsNvidia(size: 10, weight: .bold))
            .foregroundStyle(isActive ? .black.opacity(0.86) : .white.opacity(isHovering ? 0.92 : 0.64))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(isActive ? Color.openNowGreen : Color.white.opacity(isHovering ? 0.09 : 0.055))
            .overlay { Rectangle().stroke(isActive ? Color.openNowGreen : RecordingsLayout.stroke, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct RecordingRow: View {
    let recording: WebRTCStreamRecording
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    RecordingThumbnail(recording: recording, isSelected: isSelected, isHovering: isHovering)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(recording.title)
                            .font(.recordingsNvidia(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.96))
                            .lineLimit(2)
                        Text(relativeDateText(recording.createdAt))
                            .font(.recordingsNvidia(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.54))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 7) {
                    RecordingPill(text: durationText(recording.durationSeconds), active: isSelected)
                    RecordingPill(text: qualityText(recording), active: false)
                    RecordingPill(text: compactFileSizeText(recording.fileSizeBytes), active: false)
                    Spacer(minLength: 0)
                    if recording.enhancedVideo {
                        RecordingPill(text: "RTX", active: true)
                    }
                }
            }
            .padding(13)
            .background(background)
            .overlay(alignment: .leading) { Rectangle().fill(isSelected ? Color.openNowGreen : .clear).frame(width: 3) }
            .overlay { Rectangle().stroke(isSelected ? Color.openNowGreen.opacity(0.48) : Color.white.opacity(isHovering ? 0.18 : 0.08), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var background: some ShapeStyle {
        if isSelected { return AnyShapeStyle(Color.openNowGreen.opacity(0.105)) }
        return AnyShapeStyle(Color.white.opacity(isHovering ? 0.075 : 0.04))
    }
}

private struct RecordingThumbnail: View {
    let recording: WebRTCStreamRecording
    let isSelected: Bool
    let isHovering: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 76, height: 46)
                    .clipped()
                    .overlay {
                        LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.58)], startPoint: .top, endPoint: .bottom)
                    }
            } else {
                LinearGradient(
                    colors: [Color.white.opacity(0.13), Color.white.opacity(0.03), Color.openNowGreen.opacity(isSelected ? 0.24 : 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                DiagonalGrid()
                    .stroke(Color.black.opacity(0.35), lineWidth: 1)
            }
            Image(systemName: isHovering || isSelected ? "play.fill" : "play.rectangle.fill")
                .font(.recordingsNvidia(size: 19, weight: .bold))
                .foregroundStyle(isSelected ? Color.openNowGreen : .white.opacity(thumbnail == nil ? 0.76 : 0.92))
                .shadow(color: .black.opacity(thumbnail == nil ? 0 : 0.60), radius: 7, x: 0, y: 2)
        }
        .frame(width: 76, height: 46)
        .overlay(alignment: .bottomTrailing) {
            Text(resolutionBadge(recording))
                .font(.recordingsNvidia(size: 8, weight: .bold))
                .foregroundStyle(.black.opacity(0.86))
                .padding(.horizontal, 5)
                .frame(height: 15)
                .background(Color.openNowGreen)
        }
        .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
        .task(id: recording.id) {
            thumbnail = await RecordingThumbnailLoader.thumbnail(for: recording)
        }
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

    var body: some View {
        Text(text)
            .font(.recordingsNvidia(size: 9, weight: .bold))
            .foregroundStyle(active ? .black.opacity(0.86) : .white.opacity(0.62))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(active ? Color.openNowGreen : Color.white.opacity(0.065))
            .overlay { Rectangle().stroke(active ? Color.openNowGreen : Color.white.opacity(0.10), lineWidth: 1) }
    }
}

private struct RecordingNowPlayingBadge: View {
    let recording: WebRTCStreamRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.openNowGreen)
                    .frame(width: 8, height: 8)
                Text("NOW PLAYING")
                    .font(.recordingsNvidia(size: 10, weight: .bold))
                    .tracking(1.3)
                    .foregroundStyle(Color.openNowGreen)
            }
            Text(recording.title)
                .font(.recordingsNvidia(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(qualityText(recording)) · \(durationText(recording.durationSeconds)) · \(compactFileSizeText(recording.fileSizeBytes))")
                .font(.recordingsNvidia(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
                .lineLimit(1)
        }
        .padding(15)
        .background(.black.opacity(0.55))
        .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
    }
}

private struct RecordingInspector: View {
    let recording: WebRTCStreamRecording
    let copiedPath: Bool
    let message: String
    let onRestart: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(recording.title)
                        .font(.recordingsNvidia(size: 18, weight: .bold))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(1)
                    Text("\(dateText(recording.createdAt)) · \(recording.videoURL.deletingLastPathComponent().lastPathComponent)")
                        .font(.recordingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Button("Restart", action: onRestart)
                    .buttonStyle(RecordingActionButtonStyle(tone: .primary))
                Button("Open", action: onOpen)
                    .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
                Button("Reveal", action: onReveal)
                    .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
                Button(copiedPath ? "Copied" : "Copy Path", action: onCopyPath)
                    .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(RecordingActionButtonStyle(tone: .destructive))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)

            HStack(spacing: 10) {
                RecordingDetailTile(title: "QUALITY", value: qualityText(recording), detail: "\(recording.width)x\(recording.height)")
                RecordingDetailTile(title: "BITRATE", value: bitrateText(recording), detail: "Audio \(recording.audioBitrateKbps) Kbps")
                RecordingDetailTile(title: "DURATION", value: durationText(recording.durationSeconds), detail: compactFileSizeText(recording.fileSizeBytes))
                RecordingDetailTile(title: "ENHANCEMENT", value: recording.enhancedVideo ? "Enabled" : "Standard", detail: recording.enhancedVideo ? "Enhanced video" : "Original stream")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            if !message.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                    Text(message)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.recordingsNvidia(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
            }
        }
        .background(Color(red: 17 / 255, green: 18 / 255, blue: 18 / 255))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1) }
    }
}

private struct RecordingDetailTile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.recordingsNvidia(size: 9, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Color.openNowGreen.opacity(0.86))
            Text(value)
                .font(.recordingsNvidia(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
            Text(detail)
                .font(.recordingsNvidia(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.50))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RecordingsLayout.card)
        .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
    }
}

private struct RecordingEmptyState: View {
    enum Kind {
        case library
        case search
    }

    let kind: Kind
    let action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.openNowGreen.opacity(0.10))
                    .frame(width: 78, height: 78)
                Image(systemName: kind == .library ? "record.circle" : "line.3.horizontal.decrease.circle")
                    .font(.recordingsNvidia(size: 34, weight: .bold))
                    .foregroundStyle(Color.openNowGreen)
            }
            Text(kind == .library ? "No recordings yet" : "No matches")
                .font(.recordingsNvidia(size: 18, weight: .bold))
                .foregroundStyle(.white.opacity(0.94))
            Text(kind == .library ? "Start a stream, open the sidebar, and press Record to save gameplay videos here." : "Clear search or filters to show the rest of your recording library.")
                .font(.recordingsNvidia(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button(kind == .library ? "Refresh" : "Clear Filters", action: action)
                .buttonStyle(RecordingActionButtonStyle(tone: .primary))
        }
        .padding(28)
    }
}

private struct RecordingEmptyPlayer: View {
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 0)
                    .fill(Color.white.opacity(0.045))
                    .frame(width: 180, height: 108)
                    .overlay { DiagonalGrid().stroke(Color.white.opacity(0.08), lineWidth: 1) }
                    .overlay { Rectangle().stroke(Color.white.opacity(0.13), lineWidth: 1) }
                Image(systemName: "play.rectangle.fill")
                    .font(.recordingsNvidia(size: 46, weight: .bold))
                    .foregroundStyle(Color.openNowGreen.opacity(0.88))
            }
            Text("Select a recording")
                .font(.recordingsNvidia(size: 24, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
            Text(message.isEmpty ? "Your saved gameplay videos appear here with playback, file actions, and capture details." : message)
                .font(.recordingsNvidia(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecordingsBackdrop: View {
    var body: some View {
        ZStack {
            RecordingsLayout.surface
            RadialGradient(colors: [Color.openNowGreen.opacity(0.12), .clear], center: .topLeading, startRadius: 20, endRadius: 620)
            RadialGradient(colors: [Color.white.opacity(0.06), .clear], center: .bottomTrailing, startRadius: 20, endRadius: 520)
            DiagonalGrid()
                .stroke(Color.white.opacity(0.026), lineWidth: 1)
                .blendMode(.screen)
        }
        .ignoresSafeArea()
    }
}

private struct DiagonalGrid: Shape {
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

private struct RecordingActionButtonStyle: ButtonStyle {
    enum Tone {
        case primary
        case secondary
        case destructive
    }

    let tone: Tone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.recordingsNvidia(size: 12, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(height: 36)
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
        case .primary: return Color.openNowGreen.opacity(isPressed ? 0.78 : 1)
        case .secondary: return Color.white.opacity(isPressed ? 0.14 : 0.075)
        case .destructive: return RecordingsLayout.danger.opacity(isPressed ? 0.18 : 0.10)
        }
    }

    private var stroke: Color {
        switch tone {
        case .primary: return Color.openNowGreen
        case .secondary: return RecordingsLayout.stroke
        case .destructive: return RecordingsLayout.danger.opacity(0.36)
        }
    }
}

private struct RecordingLibraryStats {
    let count: Int
    let totalDurationSeconds: Double
    let totalBytes: Int64
    let newest: WebRTCStreamRecording?

    init(recordings: [WebRTCStreamRecording]) {
        count = recordings.count
        totalDurationSeconds = recordings.reduce(0) { $0 + $1.durationSeconds }
        totalBytes = recordings.reduce(0) { $0 + $1.fileSizeBytes }
        newest = recordings.max { $0.createdAt < $1.createdAt }
    }

    var subtitle: String {
        guard let newest else { return "Gameplay capture library" }
        return "Latest: \(relativeDateText(newest.createdAt))"
    }
}

private enum RecordingSortOrder: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case longest
    case largest
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .longest: return "Longest"
        case .largest: return "Largest"
        case .title: return "Title A-Z"
        }
    }
}

private extension Array where Element == WebRTCStreamRecording {
    func sorted(using order: RecordingSortOrder) -> [WebRTCStreamRecording] {
        switch order {
        case .newest: return sorted { $0.createdAt > $1.createdAt }
        case .oldest: return sorted { $0.createdAt < $1.createdAt }
        case .longest: return sorted { $0.durationSeconds > $1.durationSeconds }
        case .largest: return sorted { $0.fileSizeBytes > $1.fileSizeBytes }
        case .title: return sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }
}

private enum RecordingFilter: String, CaseIterable, Identifiable {
    case fourK
    case qhd
    case fullHD
    case enhanced
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fourK: return "4K"
        case .qhd: return "1440p+"
        case .fullHD: return "1080p+"
        case .enhanced: return "Enhanced"
        case .large: return "Large"
        }
    }

    var systemImage: String {
        switch self {
        case .fourK: return "4k.tv"
        case .qhd: return "display"
        case .fullHD: return "rectangle.inset.filled"
        case .enhanced: return "sparkles"
        case .large: return "externaldrive.fill"
        }
    }

    func matches(_ recording: WebRTCStreamRecording) -> Bool {
        switch self {
        case .fourK: return recording.width >= 3840 || recording.height >= 2160
        case .qhd: return recording.width >= 2560 || recording.height >= 1440
        case .fullHD: return recording.width >= 1920 || recording.height >= 1080
        case .enhanced: return recording.enhancedVideo
        case .large: return recording.fileSizeBytes >= 1_000_000_000
        }
    }
}

private func dateText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func relativeDateText(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func durationText(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded()))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}

private func compactFileSizeText(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: bytes)
}

private func qualityText(_ recording: WebRTCStreamRecording) -> String {
    if recording.width >= 3840 || recording.height >= 2160 { return "4K" }
    if recording.width >= 2560 || recording.height >= 1440 { return "1440p" }
    if recording.width >= 1920 || recording.height >= 1080 { return "1080p" }
    if recording.height > 0 { return "\(recording.height)p" }
    return "Auto"
}

private func resolutionBadge(_ recording: WebRTCStreamRecording) -> String {
    recording.width > 0 && recording.height > 0 ? "\(recording.width)x\(recording.height)" : "AUTO"
}

private func bitrateText(_ recording: WebRTCStreamRecording) -> String {
    recording.videoBitrateMbps == 0 ? "Auto" : "\(recording.videoBitrateMbps) Mbps"
}
