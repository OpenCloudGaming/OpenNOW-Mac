//
//  RecordingsEditorSession.swift
//  OpenNOW
//
//  Everything the recordings page does once an edit is open: the live preview pipeline, the export,
//  the guards that stop an unexported edit being thrown away, and the pad routing for the editor.
//
//  Split out of RecordingsViewModel.swift, which owns the library, the selection and the player.
//  Those are one concern and this is another, and together they were past the type-size budget.
//

import AVFoundation
import Combine
import Foundation

extension RecordingsViewModel {
    /// The editor from a pad. Left and right scrub, up and down walk the clips, and the shoulder
    /// buttons trim to where the playhead ended up - the three things a trim is actually made of.
    func applyEditorControllerCommand(_ command: ControllerInputCommand) {
        guard let editorViewModel, !editorViewModel.isExporting else { return }
        switch command {
        case .move(.left):
            stepEditorPreview(bySeconds: -0.2)
        case .move(.right):
            stepEditorPreview(bySeconds: 0.2)
        case .move(.up):
            editorViewModel.selectAdjacentSegment(offset: -1)
        case .move(.down):
            editorViewModel.selectAdjacentSegment(offset: 1)
        case .confirm:
            togglePlayback()
        case .actions:
            applyEditorEditAtPlayhead(editorViewModel.splitAtPlayhead)
        case .pageLeft:
            applyEditorEditAtPlayhead(editorViewModel.trimStartToPlayhead)
        case .pageRight:
            applyEditorEditAtPlayhead(editorViewModel.trimEndToPlayhead)
        case .menu:
            editorViewModel.showsAdvanced.toggle()
        case .back:
            controllerFocus = .library
            message = "Recording list focused. Actions returns to the editor."
        case .search:
            break
        }
    }

    /// The pad has no pointer, so an edit lands wherever the preview is parked. Same mapping the
    /// editor's own quick actions use: preview time to timeline time to source time.
    func applyEditorEditAtPlayhead(_ edit: (Double) -> Void) {
        guard let editorViewModel else { return }
        let timelineSeconds = playerTimeSeconds * max(0.25, editorViewModel.playbackRate)
        guard let target = editorViewModel.sourceTime(forTimelineSeconds: timelineSeconds) else { return }
        editorViewModel.selectPreviewSegment(target.segment)
        edit(target.seconds)
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

    /// Nudges the preview along its own timeline. Trimming to a beat needs a step that does not
    /// mean picking a pixel on the track.
    func stepEditorPreview(bySeconds delta: Double) {
        seekEditorPreview(seconds: playerTimeSeconds + delta)
    }

    func seekEditorPreviewToEnd() {
        seekEditorPreview(seconds: editorPreviewDurationSeconds > 0
            ? editorPreviewDurationSeconds
            : (editorViewModel?.outputDurationSeconds ?? 0))
    }

    /// The preview composition's own length, which is what the transport's readout counts against
    /// - not the source recording's.
    var editorPreviewDuration: Double {
        editorPreviewDurationSeconds > 0 ? editorPreviewDurationSeconds : (editorViewModel?.outputDurationSeconds ?? 0)
    }

    func startEditing(_ recording: WebRTCStreamRecording) {
        guard !isExportingEditor else {
            message = "Finish or cancel the export before editing another recording."
            return
        }
        if let editorViewModel, editorViewModel.primaryRecording.id != recording.id, editorViewModel.hasUnsavedEdits {
            pendingEditorDiscardSelection = recording
            return
        }
        if selectedRecording?.id != recording.id { select(recording, autoplay: false) }
        player?.pause()
        editorViewModel = RecordingEditorViewModel(recording: recording, library: recordings)
        controllerFocus = .editor
        refreshEditedPreview(debounce: false, preservePlaybackTime: false)
        message = "Editing \(recording.title). Export saves a new video."
    }

    func closeEditor() {
        cancelEditorPreview()
        editorViewModel = nil
        controllerFocus = .library
        if let selectedRecording { select(selectedRecording, autoplay: false) }
        message = "Editor closed."
    }

    var isExportingEditor: Bool { editorViewModel?.isExporting ?? false }

    /// The task lives on the page, not on the editor view. As `@State` on the view it outlived its
    /// owner: switching recordings mid-export left an encoder running with nothing to hand the
    /// finished file to.
    func startEditorExport() {
        guard let editorViewModel, editorViewModel.canExport, editorExportTask == nil else { return }
        // Nothing is going to watch the preview while the export runs, and decoding 5K for it
        // alongside the encoder is what made the whole app crawl.
        player?.pause()
        cancelEditorPreviewRefreshes()
        editorExportTask = Task { [weak self] in
            do {
                let recording = try await editorViewModel.export()
                guard let self else { return }
                self.editorExportTask = nil
                self.editedRecordingSaved(recording)
            } catch {
                self?.editorExportTask = nil
                editorViewModel.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelEditorExport() {
        editorExportTask?.cancel()
        editorExportTask = nil
    }

    func editedRecordingSaved(_ recording: WebRTCStreamRecording) {
        cancelEditorPreview()
        editorViewModel = nil
        controllerFocus = .library
        reload(showMessage: false)
        if let refreshed = recordings.first(where: { $0.id == recording.id }) {
            select(refreshed, autoplay: true)
        }
        message = "Saved \(recording.title) as a new video."
    }

    /// Routes the change to the cheapest thing that can express it. Only a timeline change needs
    /// the composition rebuilt and the player item replaced; crop and audio are properties on the
    /// item that is already playing.
    func refreshEditedPreview(debounce: Bool, preservePlaybackTime: Bool = true) {
        guard let editorViewModel else { return }
        guard appliedTimelineSignature == editorViewModel.timelineSignature else {
            rebuildEditedPreview(debounce: debounce, preservePlaybackTime: preservePlaybackTime)
            return
        }
        if appliedFrameSignature != editorViewModel.frameSignature { refreshEditedPreviewFrame() }
        if appliedAudioSignature != editorViewModel.audioSignature { refreshEditedPreviewAudio() }
    }

    /// Crop, rotation and flips: recompute the video composition against the composition already
    /// loaded and hand it to the live item. Debounced, because building one walks the asset.
    func refreshEditedPreviewFrame() {
        guard let editorViewModel, let item = player?.currentItem else { return }
        let request = editorViewModel.previewRequest()
        let signature = editorViewModel.frameSignature
        let requiresVideoComposition = previewRequiresVideoComposition
        let asset = WebRTCStreamRecordingLoadedAsset(item.asset)
        editorFramePreviewTask?.cancel()
        editorFramePreviewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            if Task.isCancelled { return }
            do {
                let videoComposition = try await WebRTCStreamRecordingLibrary.previewVideoComposition(
                    for: asset,
                    request: request,
                    requiresVideoComposition: requiresVideoComposition
                )
                guard !Task.isCancelled, let self, self.editorViewModel?.frameSignature == signature, self.player?.currentItem === item else { return }
                item.videoComposition = videoComposition
                self.appliedFrameSignature = signature
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.message = error.localizedDescription
            }
        }
    }

    /// Mute, volume and the fades: a new audio mix on the live item, no rebuild and no debounce.
    func refreshEditedPreviewAudio() {
        guard let editorViewModel, let item = player?.currentItem else { return }
        let request = editorViewModel.previewRequest()
        let signature = editorViewModel.audioSignature
        let asset = WebRTCStreamRecordingLoadedAsset(item.asset)
        editorAudioPreviewTask?.cancel()
        editorAudioPreviewTask = Task { [weak self] in
            do {
                let audioMix = try await WebRTCStreamRecordingLibrary.previewAudioMix(for: asset, request: request)
                guard !Task.isCancelled, let self, self.editorViewModel?.audioSignature == signature, self.player?.currentItem === item else { return }
                item.audioMix = audioMix
                self.appliedAudioSignature = signature
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.message = error.localizedDescription
            }
        }
    }

    func rebuildEditedPreview(debounce: Bool, preservePlaybackTime: Bool) {
        guard let editorViewModel else { return }
        let request = editorViewModel.previewRequest()
        let signature = editorViewModel.previewSignature
        let targetSeconds = preservePlaybackTime ? playerTimeSeconds : 0
        let shouldResumePlayback = player?.timeControlStatus == .playing
        editorFramePreviewTask?.cancel()
        editorAudioPreviewTask?.cancel()
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

    func applyEditedPreview(_ preview: WebRTCStreamRecordingPreview, targetSeconds: Double, shouldResumePlayback: Bool) {
        guard let player else { return }
        let item = AVPlayerItem(asset: preview.asset)
        // Pinned to match what the exporter uses, so a sped-up preview does not sound different
        // from the file it produces.
        item.audioTimePitchAlgorithm = .spectral
        item.audioMix = preview.audioMix
        item.videoComposition = preview.videoComposition
        editorPreviewDurationSeconds = preview.durationSeconds
        previewRequiresVideoComposition = preview.requiresVideoComposition
        if let editorViewModel {
            appliedTimelineSignature = editorViewModel.timelineSignature
            appliedFrameSignature = editorViewModel.frameSignature
            appliedAudioSignature = editorViewModel.audioSignature
        }
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

    func syncEditorSelectionForPreviewTime(_ outputSeconds: Double) {
        guard let editorViewModel else { return }
        let sourceTimelineSeconds = outputSeconds * max(0.25, editorViewModel.playbackRate)
        guard let target = editorViewModel.sourceTime(forTimelineSeconds: sourceTimelineSeconds) else { return }
        editorViewModel.selectPreviewSegment(target.segment)
    }

    /// Stops preview work without forgetting what the preview is showing, so an export does not
    /// force a full rebuild when it finishes.
    func cancelEditorPreviewRefreshes() {
        editorPreviewTask?.cancel()
        editorPreviewTask = nil
        editorFramePreviewTask?.cancel()
        editorFramePreviewTask = nil
        editorAudioPreviewTask?.cancel()
        editorAudioPreviewTask = nil
    }

    func cancelEditorPreview() {
        editorPreviewTask?.cancel()
        editorPreviewTask = nil
        editorFramePreviewTask?.cancel()
        editorFramePreviewTask = nil
        editorAudioPreviewTask?.cancel()
        editorAudioPreviewTask = nil
        editorPreviewDurationSeconds = 0
        appliedTimelineSignature = nil
        appliedFrameSignature = nil
        appliedAudioSignature = nil
        previewRequiresVideoComposition = false
    }

    /// What the UI calls. `select` itself still switches unconditionally, because reload and
    /// post-export refresh have to.
    func requestSelect(_ recording: WebRTCStreamRecording, autoplay: Bool) {
        guard !isExportingEditor else {
            message = "Finish or cancel the export before switching recordings."
            return
        }
        if let editorViewModel, editorViewModel.primaryRecording.id != recording.id, editorViewModel.hasUnsavedEdits {
            pendingEditorDiscardSelection = recording
            return
        }
        select(recording, autoplay: autoplay)
    }

    func requestCloseEditor() {
        guard let editorViewModel, editorViewModel.hasUnsavedEdits else {
            closeEditor()
            return
        }
        isPendingEditorClose = true
    }

    func confirmPendingEditorDiscard() {
        if let recording = pendingEditorDiscardSelection {
            pendingEditorDiscardSelection = nil
            isPendingEditorClose = false
            select(recording, autoplay: true)
            message = "Edits discarded."
            return
        }
        isPendingEditorClose = false
        closeEditor()
        message = "Edits discarded."
    }

    func cancelPendingEditorDiscard() {
        pendingEditorDiscardSelection = nil
        isPendingEditorClose = false
    }
}
