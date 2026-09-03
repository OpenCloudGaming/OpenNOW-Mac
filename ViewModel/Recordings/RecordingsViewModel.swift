//  The recordings library: what is on disk, what is selected, what the player is doing, and the
//  editor preview pipeline behind it. Extracted from `RecordingsView`, which owned all of it as
//  `@State` and could therefore only be exercised by rendering it.
//
//  `RecordingEditorViewModel` still owns the edit itself; this owns which recording is being
//  edited and keeps the player in step with it.
//

import AVFoundation
import Combine
import Foundation

/// Where a controller's input goes while the recordings page is open. The list and the editor both
/// want the stick and the face buttons, and there is no cursor to disambiguate them with.
enum RecordingsControllerFocus {
    case library
    case editor
}

@MainActor
final class RecordingsViewModel: ObservableObject {
    @Published var recordings: [WebRTCStreamRecording] = []
    @Published var selectedRecording: WebRTCStreamRecording?
    @Published var player: AVPlayer?
    @Published var message = ""
    @Published var pendingDelete: WebRTCStreamRecording?
    @Published var searchText = ""
    @Published var sortOrder: RecordingSortOrder = .newest
    @Published var activeFilters = Set<RecordingFilter>()
    @Published var copiedPathRecordingID: UUID?
    @Published var editorViewModel: RecordingEditorViewModel?
    @Published var playerTimeSeconds = 0.0
    /// Drives the editor's transport button. Tracked from the player rather than from whoever
    /// pressed play, because the preview pipeline pauses and resumes it too.
    @Published private(set) var isPlaying = false

    /// Set when switching away from an edited recording, or closing the editor, would throw the
    /// edit away. The page turns it into a confirmation rather than doing it silently.
    @Published var pendingEditorDiscardSelection: WebRTCStreamRecording?
    @Published var isPendingEditorClose = false
    /// Settable across the file split rather than `private(set)`: the editor session owns when
    /// focus moves, and it lives in RecordingsEditorSession.swift.
    @Published var controllerFocus: RecordingsControllerFocus = .library

    var playerTimeObserver: Any?
    private var playbackStatusObserver: AnyCancellable?
    var editorPreviewTask: Task<Void, Never>?
    var editorFramePreviewTask: Task<Void, Never>?
    var editorAudioPreviewTask: Task<Void, Never>?
    var editorExportTask: Task<Void, Never>?
    var editorPreviewDurationSeconds = 0.0
    /// What the live preview already reflects, per group. A refresh only does the work whose
    /// signature actually moved.
    var appliedTimelineSignature: String?
    var appliedFrameSignature: String?
    var appliedAudioSignature: String?
    var previewRequiresVideoComposition = false

    let systemIntegration: any SystemIntegrationServing

    init(systemIntegration: any SystemIntegrationServing = AppKitSystemIntegration()) {
        self.systemIntegration = systemIntegration
    }

    // MARK: - Derived

    var visibleRecordings: [WebRTCStreamRecording] {
        Self.visibleRecordings(in: recordings, searchText: searchText, filters: activeFilters, sortOrder: sortOrder)
    }

    /// Static and pure so the filter-then-sort behaviour can be checked without a view model
    /// instance, and so the view's `onChange` can compare against it cheaply.
    static func visibleRecordings(
        in recordings: [WebRTCStreamRecording],
        searchText: String,
        filters: Set<RecordingFilter>,
        sortOrder: RecordingSortOrder
    ) -> [WebRTCStreamRecording] {
        let normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return recordings
            .filter { recording in
                guard !normalizedQuery.isEmpty else { return true }
                return recording.title.lowercased().contains(normalizedQuery)
                    || recording.applicationID.lowercased().contains(normalizedQuery)
                    || recording.videoURL.lastPathComponent.lowercased().contains(normalizedQuery)
            }
            .filter { recording in
                filters.allSatisfy { $0.matches(recording) }
            }
            .sorted(using: sortOrder)
    }

    var stats: RecordingLibraryStats {
        RecordingLibraryStats(recordings: recordings)
    }

    var deleteDialogTitle: String {
        guard let pendingDelete else { return "Delete recording?" }
        return "Delete \"\(pendingDelete.title)\"?"
    }

    // MARK: - Library

    func reload(showMessage: Bool) {
        recordings = WebRTCStreamRecordingLibrary.loadRecordings()
        if let selectedRecording, let refreshed = recordings.first(where: { $0.id == selectedRecording.id }) {
            self.selectedRecording = refreshed
            // Not just `player == nil`: leaving the page removes the time observer and the
            // playback-status sink but leaves the player, so returning found a player with nothing
            // watching it. The playhead then froze at its last value while the preview played on,
            // and every playhead-relative edit - Split, Trim Start, Set In - cut at a stale time and
            // wrote that into the export.
            if player == nil || playerTimeObserver == nil { select(refreshed, autoplay: false) }
        } else {
            select(visibleRecordings.first, autoplay: false)
        }
        if showMessage {
            message = recordings.isEmpty ? "No recordings found in your GeForce NOW movies folder." : "Loaded \(recordings.count) recording\(recordings.count == 1 ? "" : "s")."
        }
    }

    /// Up/down walk the recordings list, left/right cycle the sort order, and confirm plays the
    /// highlighted recording. Selecting a row already loads it into the player pane, so moving the
    /// selection is enough to browse the library from a pad.
    /// The visible list is passed in: it is two filters plus a sort with no memoization, and the
    /// old shape read it three times per press. Nothing is highlighted until something is selected,
    /// so the first press only takes the selection rather than also acting on it.
    func applyControllerCommand(_ command: ControllerInputCommand, in recordings: [WebRTCStreamRecording]) {
        if editorViewModel != nil, controllerFocus == .editor {
            applyEditorControllerCommand(command)
            return
        }
        if case .actions = command, editorViewModel != nil {
            controllerFocus = .editor
            message = "Editor focused. Back returns to the recording list."
            return
        }
        guard !recordings.isEmpty else { return }
        guard let selectedRecording, recordings.contains(where: { $0.id == selectedRecording.id }) else {
            select(recordings.first, autoplay: command == .confirm)
            return
        }
        switch command {
        case .move(.up), .move(.left):
            moveSelection(delta: -1, from: selectedRecording, in: recordings)
        case .move(.down), .move(.right):
            moveSelection(delta: 1, from: selectedRecording, in: recordings)
        case .confirm:
            requestSelect(selectedRecording, autoplay: true)
        default:
            break
        }
    }

    private func moveSelection(delta: Int, from selected: WebRTCStreamRecording, in recordings: [WebRTCStreamRecording]) {
        guard let current = recordings.firstIndex(where: { $0.id == selected.id }) else { return }
        let next = min(max(current + delta, 0), recordings.count - 1)
        guard next != current else { return }
        select(recordings[next], autoplay: false)
    }

    // MARK: - Playback

    func select(_ recording: WebRTCStreamRecording?, autoplay: Bool) {
        removePlayerTimeObserver()
        if let recording, editorViewModel?.primaryRecording.id != recording.id {
            cancelEditorPreview()
            editorViewModel = nil
        }
        selectedRecording = recording
        guard let recording else {
            cancelEditorPreview()
            player?.pause()
            player = nil
            playerTimeSeconds = 0
            isPlaying = false
            return
        }
        player?.pause()
        let nextPlayer = AVPlayer(url: recording.videoURL)
        player = nextPlayer
        playerTimeSeconds = 0
        observePlaybackStatus(of: nextPlayer)
        playerTimeObserver = nextPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = max(0, time.seconds.isFinite ? time.seconds : 0)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.playerTimeSeconds = seconds
                self.syncEditorSelectionForPreviewTime(seconds)
            }
        }
        if autoplay { nextPlayer.play() }
    }

    func restart(_ recording: WebRTCStreamRecording) {
        if editorViewModel?.primaryRecording.id == recording.id {
            seekEditorPreview(seconds: 0)
            player?.play()
            return
        }
        guard selectedRecording?.id == recording.id else {
            select(recording, autoplay: true)
            return
        }
        player?.seek(to: .zero)
        player?.play()
    }

    func seek(_ recording: WebRTCStreamRecording, seconds: Double) {
        guard selectedRecording?.id == recording.id else { return }
        let time = CMTime(seconds: min(max(0, seconds), max(0, recording.durationSeconds)), preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        playerTimeSeconds = max(0, time.seconds)
    }

    private func observePlaybackStatus(of player: AVPlayer) {
        isPlaying = player.timeControlStatus == .playing
        playbackStatusObserver = player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated {
                    self?.isPlaying = status == .playing
                }
            }
    }

    func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    /// The one place the periodic time observer is torn down. Called before every player swap and
    /// on disappear; leaving it out leaks one observer per selection change.
    func removePlayerTimeObserver() {
        playbackStatusObserver?.cancel()
        playbackStatusObserver = nil
        guard let playerTimeObserver else { return }
        player?.removeTimeObserver(playerTimeObserver)
        self.playerTimeObserver = nil
    }

    // MARK: - Desktop integration

    func reveal(_ recording: WebRTCStreamRecording) {
        systemIntegration.revealInFinder(recording.videoURL)
        message = "Revealed \(recording.videoURL.lastPathComponent) in Finder."
    }

    func open(_ recording: WebRTCStreamRecording) {
        systemIntegration.open(recording.videoURL)
        message = "Opened \(recording.videoURL.lastPathComponent)."
    }

    func copyPath(_ recording: WebRTCStreamRecording) {
        systemIntegration.copyToPasteboard(recording.videoURL.path)
        copiedPathRecordingID = recording.id
        message = "Copied recording path."
    }

    // MARK: - Search, filters, delete

    func clearSearchAndFilters() {
        searchText = ""
        activeFilters.removeAll()
    }

    func toggleFilter(_ filter: RecordingFilter) {
        if activeFilters.contains(filter) {
            activeFilters.remove(filter)
        } else {
            activeFilters.insert(filter)
        }
    }

    func deletePendingRecording() {
        guard let recording = pendingDelete else { return }
        // The exporter is reading this file. Deleting it mid-encode produces a truncated output
        // and an error nobody can act on.
        guard !isExportingEditor else {
            pendingDelete = nil
            message = "Finish or cancel the export before deleting a recording."
            return
        }
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

    /// Drops the selection when the recording it pointed at is no longer visible.
    ///
    /// Not while the editor is open: this runs off the search field and the filter chips, and
    /// typing a query that hid the edited recording used to silently destroy the edit.
    func reconcileSelection(withVisibleIDs ids: [UUID]) {
        guard editorViewModel == nil else { return }
        guard let selectedRecording, !ids.contains(selectedRecording.id) else { return }
        select(visibleRecordings.first, autoplay: false)
    }

}
