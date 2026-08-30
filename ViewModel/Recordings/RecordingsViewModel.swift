//
//  RecordingsViewModel.swift
//  OpenNOW
//
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

    private var playerTimeObserver: Any?
    private var editorPreviewTask: Task<Void, Never>?
    private var editorPreviewDurationSeconds = 0.0

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
            if player == nil { select(refreshed, autoplay: false) }
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
            select(selectedRecording, autoplay: true)
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
            return
        }
        player?.pause()
        let nextPlayer = AVPlayer(url: recording.videoURL)
        player = nextPlayer
        playerTimeSeconds = 0
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

    func seekEditorPreview(seconds: Double) {
        guard editorViewModel != nil else {
            if let selectedRecording { seek(selectedRecording, seconds: seconds) }
            return
        }
        let duration = editorPreviewDurationSeconds > 0 ? editorPreviewDurationSeconds : max(0, editorViewModel?.outputDurationSeconds ?? seconds)
        let boundedSeconds = min(max(0, seconds), duration)
        let time = CMTime(seconds: boundedSeconds, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        playerTimeSeconds = boundedSeconds
        syncEditorSelectionForPreviewTime(boundedSeconds)
    }

    /// The one place the periodic time observer is torn down. Called before every player swap and
    /// on disappear; leaving it out leaks one observer per selection change.
    func removePlayerTimeObserver() {
        guard let playerTimeObserver else { return }
        player?.removeTimeObserver(playerTimeObserver)
        self.playerTimeObserver = nil
    }

    // MARK: - Editor

    func startEditing(_ recording: WebRTCStreamRecording, editorEarlyBetaEnabled: Bool) {
        guard editorEarlyBetaEnabled else {
            showRecordingEditorBetaSettingsMessage()
            return
        }
        if selectedRecording?.id != recording.id { select(recording, autoplay: false) }
        player?.pause()
        editorViewModel = RecordingEditorViewModel(recording: recording, library: recordings)
        refreshEditedPreview(debounce: false, preservePlaybackTime: false)
        message = "Editing \(recording.title). Export saves a new video."
    }

    func closeEditor() {
        cancelEditorPreview()
        editorViewModel = nil
        if let selectedRecording { select(selectedRecording, autoplay: false) }
        message = "Editor closed."
    }

    func showRecordingEditorBetaSettingsMessage() {
        message = "Enable Recording Editor Early Beta in Settings > Experimental Features."
    }

    func editedRecordingSaved(_ recording: WebRTCStreamRecording) {
        cancelEditorPreview()
        editorViewModel = nil
        reload(showMessage: false)
        if let refreshed = recordings.first(where: { $0.id == recording.id }) {
            select(refreshed, autoplay: true)
        }
        message = "Saved \(recording.title) as a new video."
    }

    func refreshEditedPreview(debounce: Bool, preservePlaybackTime: Bool = true) {
        guard let editorViewModel else { return }
        let request = editorViewModel.request()
        let signature = editorViewModel.previewSignature
        let targetSeconds = preservePlaybackTime ? playerTimeSeconds : 0
        let shouldResumePlayback = player?.timeControlStatus == .playing
        editorPreviewTask?.cancel()
        editorPreviewTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            do {
                let preview = try await WebRTCStreamRecordingLibrary.previewEditedRecording(request)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self, self.editorViewModel?.previewSignature == signature else { return }
                    self.applyEditedPreview(preview, targetSeconds: targetSeconds, shouldResumePlayback: shouldResumePlayback)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.message = error.localizedDescription
                }
            }
        }
    }

    private func applyEditedPreview(_ preview: WebRTCStreamRecordingPreview, targetSeconds: Double, shouldResumePlayback: Bool) {
        guard let player else { return }
        let item = AVPlayerItem(asset: preview.asset)
        item.audioMix = preview.audioMix
        item.videoComposition = preview.videoComposition
        editorPreviewDurationSeconds = preview.durationSeconds
        player.replaceCurrentItem(with: item)
        let boundedSeconds = min(max(0, targetSeconds), max(0, preview.durationSeconds))
        let time = CMTime(seconds: boundedSeconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        playerTimeSeconds = boundedSeconds
        syncEditorSelectionForPreviewTime(boundedSeconds)
        if shouldResumePlayback {
            player.play()
        } else {
            player.pause()
        }
    }

    private func syncEditorSelectionForPreviewTime(_ outputSeconds: Double) {
        guard let editorViewModel else { return }
        let sourceTimelineSeconds = outputSeconds * max(0.25, editorViewModel.playbackRate)
        guard let target = editorViewModel.sourceTime(forTimelineSeconds: sourceTimelineSeconds) else { return }
        editorViewModel.selectPreviewSegment(target.segment)
    }

    func cancelEditorPreview() {
        editorPreviewTask?.cancel()
        editorPreviewTask = nil
        editorPreviewDurationSeconds = 0
    }

    /// Called when the early-beta preference is switched off while the editor is open.
    func closeEditorForDisabledBeta() {
        closeEditor()
        message = "Recording editor early beta disabled. Editing tools are locked."
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
    func reconcileSelection(withVisibleIDs ids: [UUID]) {
        guard let selectedRecording, !ids.contains(selectedRecording.id) else { return }
        select(visibleRecordings.first, autoplay: false)
    }
}
