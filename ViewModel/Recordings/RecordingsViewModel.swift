//  The recordings library: what is on disk, what is selected, what the player is doing, and the
//  editor preview pipeline behind it.
//
//  `RecordingEditorViewModel` still owns the edit itself; this owns which recording is being edited
//  and keeps the player in step with it.
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

/// A replay window playing in the player pane before the reader decides what to do with it. Not an
/// edit and not a library recording: just the ring, watched.
struct RetainedReplayPreview: Equatable {
    let window: StreamReplayRetainedWindow
    let recording: StreamRecording
}

@MainActor
final class RecordingsViewModel: ObservableObject {
    @Published var recordings: [StreamRecording] = []
    /// Replay windows whose stream has ended and whose ring is still on disk, newest first. One per
    /// title, kept until the reader saves or discards it, the next session of that title rolls it
    /// forward, or the storage budget evicts it.
    @Published var retainedWindows: [StreamReplayRetainedWindow] = []
    /// The window whose Keep is running, so its row can say so and refuse a second press.
    @Published var keepingWindowID: UUID?
    /// True while a replay window's ring is being measured for the editor, so a second Clip press
    /// cannot start a second pass.
    var isLoadingRetainedWindowEditor = false
    /// The replay window playing in the pane before a decision, if any.
    @Published var retainedPreview: RetainedReplayPreview?
    /// True while a ring is being composed for watching, so a second press cannot start a second.
    var isLoadingRetainedPreview = false
    @Published var retainedWindowMessage = ""
    @Published var selectedRecording: StreamRecording?
    @Published var player: AVPlayer?
    @Published var message = ""
    @Published var pendingDelete: StreamRecording?
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
    @Published var pendingEditorDiscardSelection: StreamRecording?
    /// The same confirmation for opening a second replay window in the editor.
    @Published var pendingEditorDiscardWindow: StreamReplayRetainedWindow?
    @Published var isPendingEditorClose = false
    /// The replay window the editor is showing, when it is not a library recording. It is what
    /// protects that window from being discarded out from under an open edit.
    @Published var editingRetainedWindowID: UUID?
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

    private var retentionObserver: NSObjectProtocol?

    let systemIntegration: any SystemIntegrationServing

    init(systemIntegration: any SystemIntegrationServing = AppKitSystemIntegration()) {
        self.systemIntegration = systemIntegration
    }

    // MARK: - Derived

    var visibleRecordings: [StreamRecording] {
        Self.visibleRecordings(in: recordings, searchText: searchText, filters: activeFilters, sortOrder: sortOrder)
    }

    /// Static and pure so the filter-then-sort behaviour can be checked without a view model
    /// instance, and so the view's `onChange` can compare against it cheaply.
    static func visibleRecordings(
        in recordings: [StreamRecording],
        searchText: String,
        filters: Set<RecordingFilter>,
        sortOrder: RecordingSortOrder
    ) -> [StreamRecording] {
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

    /// What the player pane is showing. An edit over a replay window has no library selection, and
    /// a watched window has neither, so the pane falls back to the editor's own source and then to
    /// the window being watched rather than going blank behind them.
    var playerPaneRecording: StreamRecording? {
        selectedRecording ?? editorViewModel?.primaryRecording ?? retainedPreview?.recording
    }

    func isWatchingRetainedWindow(_ window: StreamReplayRetainedWindow) -> Bool {
        retainedPreview?.window.id == window.id
    }

    var deleteDialogTitle: String {
        guard let pendingDelete else { return "Delete recording?" }
        return "Delete \"\(pendingDelete.title)\"?"
    }

    // MARK: - Library

    func reload(showMessage: Bool) {
        recordings = StreamRecordingLibrary.loadRecordings()
        retainedWindows = StreamReplayRetentionLibrary.loadRetainedWindows()
        refreshSelectionAfterReload()
        if showMessage {
            message = recordings.isEmpty ? "No recordings found in your GeForce NOW movies folder." : "Loaded \(recordings.count) recording\(recordings.count == 1 ? "" : "s")."
        }
    }

    /// Puts the selection back on the refreshed copy, or hands the page to the first recording when
    /// there is none.
    private func refreshSelectionAfterReload() {
        if let selectedRecording, let refreshed = recordings.first(where: { $0.id == selectedRecording.id }) {
            self.selectedRecording = refreshed
            restorePlayerForRefreshedSelection(refreshed)
            return
        }
        // An edit or a watched window has no library selection to restore, and reselecting the first
        // recording would close it.
        guard editorViewModel == nil, retainedPreview == nil else { return }
        select(visibleRecordings.first, autoplay: false)
    }

    /// Not just `player == nil`: leaving the page keeps the player but drops the time observer, so
    /// returning found a playhead frozen at its last value and edits cut at a stale time.
    private func restorePlayerForRefreshedSelection(_ recording: StreamRecording) {
        guard player == nil || playerTimeObserver == nil else { return }
        select(recording, autoplay: false)
    }

    /// Saves a retained window as a permanent recording, then gives up the ring: the footage now
    /// exists once, in the library, where the editor can reach it.
    /// Plays a replay window in the pane without opening the editor, so it can be watched before
    /// deciding to clip it, save it whole, or discard it. Pressing it again stops.
    func watchRetainedWindow(_ window: StreamReplayRetainedWindow) {
        guard !isWatchingRetainedWindow(window) else {
            stopWatchingRetainedWindow()
            return
        }
        guard editorViewModel == nil else {
            message = "Close the editor before watching a replay."
            return
        }
        guard !isLoadingRetainedPreview else { return }
        isLoadingRetainedPreview = true
        player?.pause()
        selectedRecording = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isLoadingRetainedPreview = false }
            do {
                let composition = try await RetainedReplayEditing.makeWatchComposition(for: window)
                self.installRetainedPreview(composition, window: window)
            } catch {
                self.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func installRetainedPreview(_ composition: StreamRecordingPreview, window: StreamReplayRetainedWindow) {
        let item = AVPlayerItem(asset: composition.asset)
        item.audioTimePitchAlgorithm = .spectral
        item.audioMix = composition.audioMix
        item.videoComposition = composition.videoComposition
        let nextPlayer = AVPlayer(playerItem: item)
        player = nextPlayer
        playerTimeSeconds = 0
        observePlaybackStatus(of: nextPlayer)
        attachPlayheadObserver(to: nextPlayer)
        retainedPreview = RetainedReplayPreview(window: window, recording: RetainedReplayEditing.windowRecording(window))
        nextPlayer.play()
        message = "Watching \(window.title). Clip, save all, or discard it from the replay list."
    }

    func stopWatchingRetainedWindow() {
        guard retainedPreview != nil else { return }
        retainedPreview = nil
        select(nil, autoplay: false)
        message = "Stopped watching the replay."
    }

    func keepRetainedWindow(_ window: StreamReplayRetainedWindow) {
        guard keepingWindowID == nil else { return }
        // Saving the whole window gives it up once it is in the library, which would pull the files
        // out from under an open edit of that same window.
        guard editingRetainedWindowID != window.id else {
            retainedWindowMessage = "Close the editor before saving the whole replay."
            return
        }
        if isWatchingRetainedWindow(window) { stopWatchingRetainedWindow() }
        keepingWindowID = window.id
        retainedWindowMessage = "Saving \(window.title)…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.keepingWindowID = nil }
            do {
                let recording = try await StreamReplayClipExporter.exportRetainedWindow(window)
                StreamReplayRetentionLibrary.discard(window)
                reload(showMessage: false)
                retainedWindowMessage = "Saved \(recording.title)"
                select(recording, autoplay: false)
            } catch {
                retainedWindowMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func discardRetainedWindow(_ window: StreamReplayRetainedWindow) {
        guard editingRetainedWindowID != window.id else {
            retainedWindowMessage = "Close the editor before discarding this replay."
            return
        }
        if isWatchingRetainedWindow(window) { stopWatchingRetainedWindow() }
        StreamReplayRetentionLibrary.discard(window)
        retainedWindows = StreamReplayRetentionLibrary.loadRetainedWindows()
        retainedWindowMessage = "Discarded \(window.title)"
    }

    /// What the retained store holds against its ceiling. One window per title rolls across that
    /// title's sessions; this is all of them together.
    var retainedReplayUsageText: String {
        let usedBytes = retainedWindows.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        let budgetBytes = StreamReplayRetentionLibrary.bytes(forGigabytes: OPNStreamPreferences.loadRecordingReplayStorageBudgetGB())
        let used = ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
        let budget = ByteCountFormatter.string(fromByteCount: budgetBytes, countStyle: .file)
        return "\(used) of \(budget) used"
    }

    /// A retained window can appear, expire or be pruned while this page is open, so the section
    /// follows the library's own notification rather than polling.
    func observeRetentionChanges() {
        guard retentionObserver == nil else { return }
        retentionObserver = NotificationCenter.default.addObserver(
            forName: StreamReplayRetentionLibrary.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retainedWindows = StreamReplayRetentionLibrary.loadRetainedWindows()
                self.closeRetainedWindowUseIfGone()
            }
        }
    }

    /// A window can be evicted by the storage budget while it is playing in the pane. Whatever was
    /// showing it has to go with the files rather than fail on the next seek or export.
    private func closeRetainedWindowUseIfGone() {
        if let editingRetainedWindowID, !retainedWindows.contains(where: { $0.id == editingRetainedWindowID }) {
            closeEditor()
            message = "The replay being clipped is no longer on disk."
            return
        }
        guard let previewedWindowID = retainedPreview?.window.id else { return }
        guard !retainedWindows.contains(where: { $0.id == previewedWindowID }) else { return }
        stopWatchingRetainedWindow()
        message = "The replay being watched is no longer on disk."
    }

    /// Up/down walk the recordings list, left/right cycle the sort order, and confirm plays the
    /// highlighted recording. Selecting a row already loads it into the player pane, so moving the
    /// selection is enough to browse the library from a pad.
    /// The visible list is passed in: it is two filters plus a sort with no memoization, and the
    /// old shape read it three times per press. Nothing is highlighted until something is selected,
    /// so the first press only takes the selection rather than also acting on it.
    func applyControllerCommand(_ command: ControllerInputCommand, in recordings: [StreamRecording]) {
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

    private func moveSelection(delta: Int, from selected: StreamRecording, in recordings: [StreamRecording]) {
        guard let current = recordings.firstIndex(where: { $0.id == selected.id }) else { return }
        let next = min(max(current + delta, 0), recordings.count - 1)
        guard next != current else { return }
        select(recordings[next], autoplay: false)
    }

    // MARK: - Playback

    func select(_ recording: StreamRecording?, autoplay: Bool) {
        // The player belongs to a replay window the reader is watching, or to the editor, neither of
        // which has a library selection to hand the pane instead.
        guard recording != nil || (editorViewModel == nil && retainedPreview == nil) else { return }
        removePlayerTimeObserver()
        if let recording, editorViewModel?.primaryRecording.id != recording.id {
            cancelEditorPreview()
            editorViewModel = nil
            editingRetainedWindowID = nil
        }
        selectedRecording = recording
        if recording != nil { retainedPreview = nil }
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
        attachPlayheadObserver(to: nextPlayer)
        if autoplay { nextPlayer.play() }
    }

    /// One place for the periodic playhead observer, so an edit over a replay window gets the same
    /// readout as a library recording.
    func attachPlayheadObserver(to nextPlayer: AVPlayer) {
        playerTimeObserver = nextPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = max(0, time.seconds.isFinite ? time.seconds : 0)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.playerTimeSeconds = seconds
                self.syncEditorSelectionForPreviewTime(seconds)
            }
        }
    }

    func restart(_ recording: StreamRecording) {
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

    func seek(_ recording: StreamRecording, seconds: Double) {
        guard selectedRecording?.id == recording.id else { return }
        let time = CMTime(seconds: min(max(0, seconds), max(0, recording.durationSeconds)), preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        playerTimeSeconds = max(0, time.seconds)
    }

    func observePlaybackStatus(of player: AVPlayer) {
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

    func reveal(_ recording: StreamRecording) {
        systemIntegration.revealInFinder(recording.videoURL)
        message = "Revealed \(recording.videoURL.lastPathComponent) in Finder."
    }

    func open(_ recording: StreamRecording) {
        systemIntegration.open(recording.videoURL)
        message = "Opened \(recording.videoURL.lastPathComponent)."
    }

    func copyPath(_ recording: StreamRecording) {
        systemIntegration.copyToPasteboard(recording.videoURL.path)
        copiedPathRecordingID = recording.id
        message = "Copied recording path."
    }

    // MARK: - Search, filters, delete

    func clearSearch() {
        searchText = ""
    }

    func clearFilters() {
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
        // Deleting the recording out from under an open edit leaves the editor pointing at a file
        // that is gone, so it has to be closed first - same shape as the export guard above.
        guard editorViewModel?.primaryRecording.id != recording.id else {
            pendingDelete = nil
            message = "Close the editor before deleting the recording it is editing."
            return
        }
        do {
            try StreamRecordingLibrary.delete(recording)
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
