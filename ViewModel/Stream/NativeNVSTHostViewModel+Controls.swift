//
//  NativeNVSTHostViewModel+Controls.swift
//  OpenNOW
//
//  What the HUD and the shortcut keys can do to a running stream: focus traversal, the video
//  enhancement controls, microphone, anti-AFK, pointer lock, the on-screen keyboard, stats polling
//  and the network governor.
//
//  Split from `NativeNVSTHostViewModel` so the session's own lifecycle - start, stop, finish - is
//  readable on its own. Same type, same state; only the file boundary is new.
//
//  AppKit is imported for the same reason as the main file: `NativeWebRTCStreamView` is the stream
//  surface these controls act on. See the note there.
//
//  swiftlint:disable:next no_appkit_in_view_model
import AppKit
import Foundation

@MainActor
extension NativeNVSTHostViewModel {

    var hudFocusEntries: [StreamHUDFocusEntry] {
        [
            StreamHUDFocusEntry(id: "microphone", isDisabled: !sidebarCapabilities.supports(.microphone) || !microphoneAvailable || microphoneUpdateTask != nil, action: toggleNativeMicrophone),
            StreamHUDFocusEntry(id: "localAudioMute", isDisabled: !isConnected, action: toggleNativeLocalAudioMute),
            StreamHUDFocusEntry(id: "recording", isDisabled: !sidebarCapabilities.supports(.recording) || !isConnected || recordingIsBusy, action: toggleNativeRecording),
            StreamHUDFocusEntry(id: "pointer", isDisabled: !isConnected || nativeView?.directMouseInputEnabled != true, action: toggleNativePointerLock),
            StreamHUDFocusEntry(id: "anti-afk", isDisabled: !sidebarCapabilities.supports(.antiAFK) || !isConnected, action: toggleNativeAntiAFKMouseMovement),
            StreamHUDFocusEntry(id: "floating-stats", isDisabled: !sidebarCapabilities.supports(.floatingStats), action: toggleNativeStatsHUD),
            StreamHUDFocusEntry(id: "coop-invite", isDisabled: !sidebarCapabilities.supports(.remoteCoOp) || (remoteCoOpSnapshot.invite == nil && !canStartRemoteCoOpInvite), action: { [weak self] in
                guard let self else { return }
                if remoteCoOpSnapshot.invite == nil { startRemoteCoOpInvite() } else { stopRemoteCoOpInvite() }
            }),
            StreamHUDFocusEntry(id: "coop-copy", isDisabled: remoteCoOpSnapshot.invite == nil, action: { [weak self] in self?.copyRemoteCoOpInvite() }),
        ]
        + remoteCoOpParticipantFocusEntries
        + [
            StreamHUDFocusEntry(id: "controller-mapping", isDisabled: false, action: { [weak self] in self?.showingControllerMapping = true }),
            StreamHUDFocusEntry(id: "quit", isDisabled: false, action: { [weak self] in self?.showStreamControls() }),
            StreamHUDFocusEntry(id: "upscaling-tier", isDisabled: !sidebarCapabilities.supports(.videoEnhancement), action: cycleNativeUpscalingTier),
            StreamHUDFocusEntry(id: "upscaling-target", isDisabled: !isConnected || upscalingModeIndex == 0 || !sidebarCapabilities.supports(.videoEnhancement), action: cycleNativeUpscalingTarget),
            StreamHUDFocusEntry(id: "clarity", isDisabled: !isConnected || upscalingModeIndex == 0 || !sidebarCapabilities.supports(.videoEnhancement), action: cycleNativeClarity),
            StreamHUDFocusEntry(id: "noise-reduction", isDisabled: !isConnected || upscalingModeIndex == 0 || !sidebarCapabilities.supports(.videoEnhancement), action: cycleNativeNoiseReduction),
            StreamHUDFocusEntry(id: "pillarbox-fill", isDisabled: !isConnected, action: cycleNativePillarboxFill),
        ]
    }

    /// One focus entry per guest, so approving and removing are reachable from a controller.
    ///
    /// Approval happens mid-game, which is exactly when reaching for the trackpad is worst - and a
    /// guest waiting for approval cannot play until someone acts. Ordered to match the rows the HUD
    /// draws, so pad navigation follows what is on screen.
    var remoteCoOpParticipantFocusEntries: [StreamHUDFocusEntry] {
        guard sidebarCapabilities.supports(.remoteCoOp) else { return [] }
        return remoteCoOpSnapshot.participants.flatMap { participant -> [StreamHUDFocusEntry] in
            var entries: [StreamHUDFocusEntry] = []
            if participant.connectionState == .waitingForApproval {
                entries.append(StreamHUDFocusEntry(id: "coop-approve-\(participant.id.uuidString)", isDisabled: false, action: { [weak self] in
                    self?.approveRemoteCoOpParticipant(participant.id)
                }))
            }
            entries.append(StreamHUDFocusEntry(id: "coop-remove-\(participant.id.uuidString)", isDisabled: false, action: { [weak self] in
                self?.removeRemoteCoOpParticipant(participant.id)
            }))
            return entries
        }
    }

    /// Single source of truth for the segmented Picker's display order and label text, and for
    /// `cycleNativeUpscalingTier`'s gamepad wrap order - previously these were two independently
    /// hardcoded `[0, 2, 3]` arrays with nothing tying them together.
    nonisolated static let upscalingTierDisplayOrder: [(value: Int, label: String)] = [
        (0, "Off"), (2, "Spatial"), (3, "MetalFX"),
    ]

    /// Each of these advances its control by one step per gamepad activate press, wrapping at the
    /// end — the same one-action-per-press model every other HUD focus entry already uses, so a
    /// slider or dropdown doesn't need a new interaction primitive to be gamepad-usable.
    func cycleNativeUpscalingTier() {
        let currentValue = OPNStreamPreferences.upscalingModeOptions[upscalingModeIndex].value
        updateNativeUpscalingTier(value: wrappingNext(after: currentValue, in: Self.upscalingTierDisplayOrder.map(\.value)))
    }

    func cycleNativeUpscalingTarget() {
        let count = OPNStreamPreferences.upscalingTargetOptions.count
        guard count > 0 else { return }
        updateNativeUpscalingTarget(targetIndex: (upscalingTargetIndex + 1) % count)
    }

    func cycleNativeClarity() {
        updateNativeUpscalingClarity(sharpness: (upscalingSharpness + 1) % 16)
    }

    func cycleNativeNoiseReduction() {
        updateNativeUpscalingClarity(denoise: (upscalingDenoise + 1) % 21)
    }

    func cycleNativePillarboxFill() {
        updateNativePillarboxFill(modeIndex: wrappingNext(after: pillarboxFillModeIndex, in: OPNPillarboxFillMode.pickerCases.map(\.rawValue)))
    }

    /// Shared by every "cycle this control forward one step" gamepad handler that advances a value
    /// within a fixed option list, rather than each control re-implementing its own index lookup.
    func wrappingNext<T: Equatable>(after current: T, in options: [T]) -> T {
        guard !options.isEmpty else { return current }
        let currentIndex = options.firstIndex(of: current) ?? 0
        return options[(currentIndex + 1) % options.count]
    }

    func handleHUDGamepad(_ state: GamepadState) {
        guard let step = hudGamepadTracker.navigationStep(state) else { return }
        switch step {
        case .move(let delta):
            moveHUDFocus(by: delta)
        case .activate:
            StreamHUDFocusEntry.activatable(hudFocusID, in: hudFocusEntries)?.action()
        case .back:
            setUnifiedHUDVisible(false)
        }
    }

    func moveHUDFocus(by step: Int) {
        guard let next = StreamHUDFocusEntry.focusID(after: hudFocusID, in: hudFocusEntries, step: step) else { return }
        hudFocusID = next
    }

    func handleStreamControlsGamepad(_ state: GamepadState) {
        guard let step = hudGamepadTracker.navigationStep(state) else { return }
        switch step {
        case .move(let delta):
            streamControlsFocusIndex = (streamControlsFocusIndex + delta + 3) % 3
        case .activate:
            switch streamControlsFocusIndex {
            case 0: dismissStreamControls()
            case 1: pauseFromStreamControls()
            default: endFromStreamControls()
            }
        case .back:
            dismissStreamControls()
        }
    }

    func handleNativeCommand(_ command: WebRTCMediaStreamCommand) {
        switch command {
        case .toggleStatsHUD:
            toggleNativeStatsHUD()
        case .toggleUnifiedHUD:
            guard !streamControlsVisible else { return }
            setUnifiedHUDVisible(!unifiedHUDVisible)
        case .toggleMicrophone:
            toggleNativeMicrophone()
        case .toggleRecording:
            toggleNativeRecording()
        case .toggleAntiAFK:
            toggleNativeAntiAFKMouseMovement()
        case .togglePointerCapture:
            toggleNativePointerLock()
        case .showQuitMenu:
            if !streamControlsVisible { showStreamControls() }
        case .toggleOnScreenKeyboard:
            toggleOnScreenKeyboard()
        }
    }

    func toggleOnScreenKeyboard() {
        guard isConnected, !isEnding, !didEnd, !streamControlsVisible else { return }
        setOnScreenKeyboardVisible(!onScreenKeyboardVisible)
        WebRTCMediaTelemetry.capture("nvst.ui.osk.toggle", level: .info, message: onScreenKeyboardVisible ? "On-screen keyboard shown." : "On-screen keyboard hidden.", attributes: ["applicationID": configuration.applicationID, "visible": String(onScreenKeyboardVisible)])
    }

    func setOnScreenKeyboardVisible(_ visible: Bool) {
        if visible {
            if unifiedHUDVisible { setUnifiedHUDVisible(false) }
            onScreenKeyboard.reset()
            restorePointerLockOnKeyboardHide = pointerLocked
            if pointerLocked { nativeView?.setPointerLocked(false) }
        }
        onScreenKeyboardVisible = visible
        nativeView?.localOverlayCapturesInput = visible
        guard !visible, restorePointerLockOnKeyboardHide else { return }
        restorePointerLockOnKeyboardHide = false
        if NSApplication.shared.isActive, nativeView?.window?.isKeyWindow == true {
            nativeView?.setPointerLocked(true)
        }
    }

    func sendOnScreenKeyboardOutput(_ output: StreamOSKOutput) {
        guard isConnected, !isEnding, !didEnd, inputDispatcher != nil else { return }
        let timestamp = MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
        lastAcceptedStreamInputAt = Date()
        switch output {
        case .text(let value):
            inputDispatcher?.enqueue(.text(deviceID: "keyboard", value: value, timestamp: timestamp))
        case .keyPress(let keyCode):
            inputDispatcher?.enqueue(.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: keyCode, scanCode: keyCode, isPressed: true, timestamp: timestamp)))
            inputDispatcher?.enqueue(.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: keyCode, scanCode: keyCode, isPressed: false, timestamp: timestamp)))
        }
    }

    func toggleNativeMicrophone() {
        guard isConnected, !isEnding, !didEnd else { return }
        guard microphoneAvailable else {
            microphoneEnabled = false
            microphoneDesiredEnabled = false
            showNativeTransientStreamMessage("Microphone is disabled in Settings.")
            return
        }
        guard microphoneMode != "push-to-talk" else {
            showNativeTransientStreamMessage("Hold the configured Push-to-Talk key to speak.")
            return
        }
        requestNativeMicrophoneEnabled(!microphoneDesiredEnabled, source: "toggle")
    }

    func requestNativeMicrophoneEnabled(_ enabled: Bool, source: String) {
        guard microphoneAvailable, isConnected, !isEnding, !didEnd, let path else { return }
        microphoneDesiredEnabled = enabled
        let lastScheduledState = microphonePendingStates.last ?? microphoneEnabled
        if lastScheduledState != enabled { microphonePendingStates.append(enabled) }
        guard microphoneUpdateTask == nil else { return }
        microphoneUpdateTask = Task { @MainActor in
            defer { microphoneUpdateTask = nil }
            while !Task.isCancelled, !didEnd, !microphonePendingStates.isEmpty {
                let target = microphonePendingStates.removeFirst()
                do {
                    try await path.setMicrophoneEnabled(target)
                    guard !Task.isCancelled, !didEnd else { return }
                    microphoneEnabled = target
                    let enabledMessage = microphoneMode == "voice-activity" ? "Voice Activity On" : "Microphone On"
                    showNativeTransientStreamMessage(target ? enabledMessage : "Microphone Muted")
                    WebRTCMediaTelemetry.capture("nvst.ui.microphone.update", level: .info, message: target ? "Native NVST microphone enabled." : "Native NVST microphone muted.", attributes: ["applicationID": configuration.applicationID, "enabled": String(target), "source": source])
                } catch {
                    guard !Task.isCancelled, !didEnd else { return }
                    microphoneDesiredEnabled = microphoneEnabled
                    microphonePendingStates.removeAll()
                    let message = Self.message(for: error)
                    showNativeTransientStreamMessage(message)
                    WebRTCMediaTelemetry.capture("nvst.ui.microphone.failed", level: .error, message: message, attributes: ["applicationID": configuration.applicationID, "source": source])
                }
            }
        }
    }

    /// Purely local and in-process - no seat round trip the way the microphone toggle needs, so this
    /// updates immediately rather than queuing through a pending-states list.
    func toggleNativeLocalAudioMute() {
        guard isConnected, !isEnding, !didEnd, let path else { return }
        let target = !nativeLocalAudioMuted
        nativeLocalAudioMuted = target
        Task { @MainActor in
            do {
                try await path.setLocalAudioPlaybackMuted(target)
                showNativeTransientStreamMessage(target ? "Local Audio Muted" : "Local Audio On")
            } catch {
                guard !Task.isCancelled, !didEnd else { return }
                nativeLocalAudioMuted = !target
                showNativeTransientStreamMessage(Self.message(for: error))
            }
        }
    }

    func toggleNativeAntiAFKMouseMovement() {
        guard isConnected, !isEnding, !didEnd else { return }
        antiAFKMouseMovementEnabled.toggle()
        OPNStreamPreferences.saveAntiAFKMouseMovementEnabled(antiAFKMouseMovementEnabled)
        refreshAntiAFKMouseMovementTask()
        showNativeTransientStreamMessage(antiAFKMouseMovementEnabled ? "Anti-AFK On" : "Anti-AFK Off")
        WebRTCMediaTelemetry.capture("nvst.ui.anti_afk.toggle", level: .info, message: antiAFKMouseMovementEnabled ? "Native NVST Anti-AFK mouse movement enabled." : "Native NVST Anti-AFK mouse movement disabled.", attributes: ["applicationID": configuration.applicationID, "enabled": String(antiAFKMouseMovementEnabled)])
    }

    // MARK: - Recording

    /// True only while the writer is closing: the button has to stay dead until the file lands,
    /// because a second start would race the finish.
    var recordingIsBusy: Bool {
        if case .finishing = recordingStatus { return true }
        return false
    }

    var recordingCanStop: Bool {
        switch recordingStatus {
        case .starting, .recording: return true
        case .idle, .finishing, .finished, .failed: return false
        }
    }

    var recordingStatusText: String {
        switch recordingStatus {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .recording(_, let elapsedSeconds): return recordingElapsedText(elapsedSeconds)
        case .finishing: return "Saving"
        case .finished: return "Saved"
        case .failed: return "Failed"
        }
    }

    func recordingElapsedText(_ elapsedSeconds: Double) -> String {
        let seconds = max(0, Int(elapsedSeconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    func toggleNativeRecording() {
        guard sidebarCapabilities.supports(.recording) else { return }
        guard let path else { return }
        if recordingCanStop {
            Task { await path.stopRecording() }
            WebRTCMediaTelemetry.capture("nvst.ui.recording.stop", level: .info, message: "Native NVST recording stop requested.", attributes: ["applicationID": configuration.applicationID])
            return
        }
        guard !recordingIsBusy else { return }
        guard isConnected, !isEnding, !didEnd else { return }
        guard let settings = resolvedStreamSettings else {
            showNativeTransientStreamMessage("Recording unavailable")
            WebRTCMediaTelemetry.capture("nvst.ui.recording.start.unavailable", level: .warning, message: "Native NVST recording requested before the stream settings were resolved.", attributes: ["applicationID": configuration.applicationID])
            return
        }
        let size = Self.recordingResolution(settings.resolution)
        let recordingConfiguration = WebRTCStreamRecordingConfiguration(
            title: configuration.title,
            applicationID: configuration.applicationID,
            width: size.width,
            height: size.height,
            fps: settings.fps,
            videoBitrateMbps: settings.recordingVideoBitrateMbps,
            audioBitrateKbps: settings.recordingAudioBitrateKbps,
            // The enhancement readback is not wired on this transport, so the recording is always
            // the decoded stream. Claiming otherwise in the metadata would mislabel the file.
            enhancedVideoEnabled: false
        )
        recordingStatus = .starting
        Task { @MainActor [weak self] in
            let started = await path.startRecording(configuration: recordingConfiguration)
            guard let self, !started else { return }
            // The session went away between the button press and the actor hop, so no recorder was
            // started and nothing will ever emit a status. Put the button back rather than leaving
            // it reading "Stop Recording" for a recording that does not exist.
            self.handleRecordingStatusChanged(.failed("Recording could not start: the stream ended."))
        }
        showNativeTransientStreamMessage("Recording")
        WebRTCMediaTelemetry.capture("nvst.ui.recording.start", level: .info, message: "Native NVST recording start requested.", attributes: ["applicationID": configuration.applicationID])
    }

    /// Only a fallback: the writer takes the real dimensions from the first decoded frame, so this
    /// matters just for a recording that dies before one arrives.
    static func recordingResolution(_ value: String) -> (width: Int, height: Int) {
        let parts = value.split(separator: "x").compactMap { Int($0) }
        return (max(1, parts.first ?? 1920), max(1, parts.count > 1 ? parts[1] : 1080))
    }

    func handleRecordingStatusChanged(_ status: WebRTCStreamRecordingStatus) {
        recordingStatus = status
        recordingStatusResetTask?.cancel()
        recordingStatusResetTask = nil
        switch status {
        case .finished(let recording):
            showNativeTransientStreamMessage("Recording Saved")
            WebRTCMediaTelemetry.capture("nvst.ui.recording.finished", level: .info, message: "Native NVST recording saved.", attributes: ["applicationID": configuration.applicationID, "durationSeconds": String(format: "%.1f", recording.durationSeconds), "resolution": "\(recording.width)x\(recording.height)"])
        case .failed(let message):
            showNativeTransientStreamMessage("Recording Failed")
            WebRTCMediaTelemetry.capture("nvst.ui.recording.failed", level: .error, message: message, attributes: ["applicationID": configuration.applicationID])
        case .idle, .starting, .recording, .finishing:
            break
        }
        guard status.isTerminal else { return }
        // Leave the outcome on screen briefly, then go back to Idle so the button reads as ready.
        recordingStatusResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            guard let self, self.recordingStatus.isTerminal else { return }
            self.recordingStatus = .idle
        }
    }

    func refreshAntiAFKMouseMovementTask() {
        guard isConnected, antiAFKMouseMovementEnabled else {
            antiAFKMouseMovementTask?.cancel()
            antiAFKMouseMovementTask = nil
            return
        }
        guard antiAFKMouseMovementTask == nil else { return }
        antiAFKMouseMovementTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: StreamAntiAFKInputPolicy.pollInterval)
                guard !Task.isCancelled else { return }
                sendNativeAntiAFKMouseMovement()
            }
        }
    }

    func sendNativeAntiAFKMouseMovement() {
        guard isConnected, antiAFKMouseMovementEnabled, !isEnding, !didEnd, !unifiedHUDVisible, !streamControlsVisible, inputDispatcher != nil else { return }
        guard Date().timeIntervalSince(lastAcceptedStreamInputAt) >= StreamAntiAFKInputPolicy.idleThresholdSeconds else { return }
        let delta = StreamAntiAFKInputPolicy.randomMouseDelta()
        inputDispatcher?.enqueue(StreamAntiAFKInputPolicy.mouseMove(deltaX: delta.x, deltaY: delta.y))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard isConnected, antiAFKMouseMovementEnabled, !isEnding, !didEnd, !unifiedHUDVisible, !streamControlsVisible else { return }
            guard Date().timeIntervalSince(lastAcceptedStreamInputAt) >= StreamAntiAFKInputPolicy.idleThresholdSeconds else { return }
            inputDispatcher?.enqueue(StreamAntiAFKInputPolicy.mouseMove(deltaX: -delta.x, deltaY: -delta.y))
        }
    }

    /// Polls controller batteries for as long as the stream view is on screen. Driven by the view's
    /// `.task` so cancellation follows the view's lifetime, exactly as it did when the loop was
    /// written inline there - a `Timer.publish` stored on the view would be rebuilt on every
    /// re-render, resetting the interval before it ever fires.
    func pollControllerBatteries() async {
        while !Task.isCancelled {
            refreshControllerBatteries()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func refreshControllerBatteries() {
        let batteries = ControllerBatteryInfo.currentSnapshot()
        for message in batteryAlertTracker.messages(for: batteries) {
            showNativeTransientStreamMessage(message)
        }
        controllerBatteries = batteries
    }

    func showNativeTransientStreamMessage(_ message: String) {
        transientStreamMessageTask?.cancel()
        transientStreamMessage = message
        transientStreamMessageTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            transientStreamMessage = ""
            transientStreamMessageTask = nil
        }
    }

    func cancelNativeShortcutTasks() {
        microphoneUpdateTask?.cancel()
        microphoneUpdateTask = nil
        antiAFKMouseMovementTask?.cancel()
        antiAFKMouseMovementTask = nil
        transientStreamMessageTask?.cancel()
        transientStreamMessageTask = nil
        transientStreamMessage = ""
        recordingStatusResetTask?.cancel()
        recordingStatusResetTask = nil
    }

    func showStreamControls(completion: WebRTCMediaStreamQuitDecisionHandler? = nil) {
        guard isConnected else {
            let pendingStartTask = startTask
            let pendingPath = path
            pendingStartTask?.cancel()
            Task {
                await pendingStartTask?.value
                await pendingPath?.cancelStart()
                completion?(true)
            }
            return
        }
        pendingApplicationQuitCompletion?(false)
        pendingApplicationQuitCompletion = completion
        unifiedHUDVisible = false
        onScreenKeyboardVisible = false
        nativeView?.localOverlayCapturesInput = false
        hudFocusID = nil
        hudGamepadTracker.reset()
        streamControlsFocusIndex = 0
        nativeView?.remoteInputEnabled = false
        nativeView?.setNativeNVSTVideoVisible(isConnected)
        streamControlsVisible = true
        WebRTCMediaTelemetry.capture("nvst.ui.controls.show", level: .info, message: "Native NVST stream controls shown.", attributes: ["applicationID": configuration.applicationID])
    }

    func dismissStreamControls() {
        guard !isEnding else { return }
        streamControlsVisible = false
        hudGamepadTracker.reset()
        let completion = pendingApplicationQuitCompletion
        pendingApplicationQuitCompletion = nil
        nativeView?.remoteInputEnabled = isConnected && !unifiedHUDVisible && networkPathAvailable
        nativeView?.setNativeNVSTVideoVisible(isConnected)
        nativeView?.restoreInputFocus()
        completion?(false)
        WebRTCMediaTelemetry.capture("nvst.ui.controls.dismiss", level: .info, message: "Native NVST stream controls dismissed.", attributes: ["applicationID": configuration.applicationID])
    }

    func setUnifiedHUDVisible(_ visible: Bool) {
        guard isConnected, !streamControlsVisible else { return }
        hudGamepadTracker.reset()
        if visible {
            if onScreenKeyboardVisible { setOnScreenKeyboardVisible(false) }
            nativeView?.remoteInputEnabled = false
            unifiedHUDVisible = true
            hudFocusID = hudFocusEntries.first(where: { !$0.isDisabled })?.id
        } else {
            unifiedHUDVisible = false
            hudFocusID = nil
            // Not unconditionally `true`: the network monitor blocks remote input while the path is
            // down and puts the recovery overlay up, but `isConnected` stays true through a drop, so
            // the HUD hotkey still works. Without this term, opening and closing the HUD during an
            // outage put input back on the wire behind the overlay - pointer capture and keystrokes
            // resuming into a session that cannot receive them - until the next path update.
            nativeView?.remoteInputEnabled = networkPathAvailable
            nativeView?.restoreInputFocus()
        }
        WebRTCMediaTelemetry.capture("nvst.ui.hud.toggle", level: .info, message: visible ? "Native NVST HUD shown." : "Native NVST HUD hidden.", attributes: ["applicationID": configuration.applicationID, "visible": String(visible)])
    }

    func toggleNativePointerLock() {
        guard isConnected, !isEnding, !didEnd, nativeView?.directMouseInputEnabled == true else { return }
        if pointerLocked {
            nativeView?.setPointerLocked(false)
        } else {
            // Close the HUD first so remote input is live, then force the capture regardless
            // of the server-driven cursor mode (this is the manual override for games that
            // never signal a cursor-hide).
            setUnifiedHUDVisible(false)
            nativeView?.setPointerLocked(true)
        }
    }

    func toggleNativeStatsHUD() {
        guard isConnected, !isEnding, !didEnd else { return }
        nativeStatsVisible.toggle()
        WebRTCMediaTelemetry.capture("nvst.ui.stats.toggle", level: .info, message: nativeStatsVisible ? "OpenNOW NVST stats shown." : "OpenNOW NVST stats hidden.", attributes: ["applicationID": configuration.applicationID, "visible": String(nativeStatsVisible)])
    }

    func startNativeStatsPolling(path: NativeNVSTStreamingPath) {
        nativeStatsTask?.cancel()
        nativeStatsTask = Task {
            while !Task.isCancelled {
                // Deliberately no reset when the snapshot is nil. `observe` already ignores a nil
                // snapshot, and `performanceSnapshot()` returns nil whenever there is no active
                // session - during `.singleAttempt` recovery, for instance, which is exactly when a
                // stall is most likely. Rebuilding the monitor there cleared `receivedFrames` and
                // `zeroFrameSamples`, so a stall interleaved with nil samples never accumulated the
                // consecutive zero-frame samples the watchdog needs and never tripped at all.
                let snapshot = await path.performanceSnapshot()
                if let snapshot, isConnected, !isEnding, !didEnd {
                    latestNativeStats = snapshot
                    recordNativeNetworkTelemetry(snapshot)
                    let adjustments = networkGovernor?.evaluate(snapshot) ?? []
                    for adjustment in adjustments { await applyNativeNetworkAdjustment(adjustment, path: path) }
                }
                if isConnected, !isEnding, !didEnd,
                   let failure = nativeStreamHealth.observe(snapshot: snapshot, rendererReady: nativeView?.nativeNVSTRendererSurfaceReady == true) {
                    WebRTCMediaTelemetry.capture("nvst.stream.health.failed", level: .error, message: failure.message, attributes: ["applicationID": configuration.applicationID])
                    _ = await finish(reason: .failed, message: failure.message)
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    func recordNativeNetworkTelemetry(_ snapshot: NativeNVSTPerformanceSnapshot) {
        let attributes = ["transport": "nvst", "applicationID": configuration.applicationID]
        if snapshot.latencyMilliseconds >= 0 { WebRTCMediaTelemetry.record("nvst.network.latency_ms", kind: .gauge, value: snapshot.latencyMilliseconds, unit: "millisecond", attributes: attributes) }
        if snapshot.jitterMilliseconds >= 0 { WebRTCMediaTelemetry.record("nvst.network.jitter_ms", kind: .gauge, value: snapshot.jitterMilliseconds, unit: "millisecond", attributes: attributes) }
        if snapshot.bitrateMegabitsPerSecond >= 0 { WebRTCMediaTelemetry.record("nvst.network.bitrate_mbps", kind: .gauge, value: snapshot.bitrateMegabitsPerSecond, unit: "megabit/second", attributes: attributes) }
        if snapshot.bandwidthUtilizationPercent >= 0 { WebRTCMediaTelemetry.record("nvst.network.bandwidth_utilization_percent", kind: .gauge, value: snapshot.bandwidthUtilizationPercent, unit: "percent", attributes: attributes) }
        WebRTCMediaTelemetry.record("nvst.network.packet_loss", kind: .gauge, value: Double(snapshot.packetLoss), unit: "packet", attributes: attributes)
        WebRTCMediaTelemetry.record("nvst.network.frame_loss", kind: .gauge, value: Double(snapshot.frameLoss), unit: "frame", attributes: attributes)
    }

    func startNetworkPathMonitoring() {
        networkPathTask?.cancel()
        let monitor = NativeNVSTNetworkPathMonitor()
        networkPathTask = Task { @MainActor in
            for await networkPath in monitor.updates() {
                guard !Task.isCancelled, !didEnd else { return }
                if networkPath.isSatisfied {
                    networkPathAvailable = true
                    if isConnected, !unifiedHUDVisible, !streamControlsVisible { nativeView?.remoteInputEnabled = true }
                    WebRTCMediaTelemetry.capture("nvst.network.path.available", level: .info, message: "Native NVST network path is available.", attributes: ["wifi": String(networkPath.usesWiFi), "ethernet": String(networkPath.usesWiredEthernet), "expensive": String(networkPath.isExpensive), "constrained": String(networkPath.isConstrained)])
                } else {
                    networkPathAvailable = false
                    nativeView?.remoteInputEnabled = false
                    showNativeTransientStreamMessage("Network interrupted - waiting to reconnect")
                    WebRTCMediaTelemetry.capture("nvst.network.path.unavailable", level: .warning, message: "Native NVST network path is unavailable.")
                }
            }
        }
    }

    func applyNativeNetworkAdjustment(_ adjustment: NativeNVSTNetworkAdjustment, path: NativeNVSTStreamingPath) async {
        do {
            switch adjustment {
            case .maximumBitrateKbps(let bitrate): try await path.setMaximumBitrateKbps(bitrate)
            case .dynamicStreamingMode(let mode): try await path.setDynamicStreamingMode(mode)
            case .l4sEnabled(let enabled): try await path.setL4SEnabled(enabled)
            }
            WebRTCMediaTelemetry.capture("nvst.network.adjustment", level: .info, message: "Applied native NVST network adjustment.", attributes: ["adjustment": String(describing: adjustment)])
        } catch {
            WebRTCMediaTelemetry.capture("nvst.network.adjustment.failed", level: .warning, message: Self.message(for: error), attributes: ["adjustment": String(describing: adjustment)])
        }
    }

    func pauseFromStreamControls() {
        guard !isEnding else { return }
        let completion = pendingApplicationQuitCompletion
        pendingApplicationQuitCompletion = nil
        Task {
            _ = await finish(reason: .paused, message: "Native NVST stream paused.")
            completion?(false)
        }
    }

    func endFromStreamControls() {
        guard !isEnding else { return }
        let completion = pendingApplicationQuitCompletion
        let shouldTerminateApplication = completion != nil
        pendingApplicationQuitCompletion = nil
        Task {
            // Stream teardown is best-effort. When this End Stream was raised by an
            // application-quit request (Cmd+Q), the user's intent is to quit, so honor the
            // termination regardless of whether stopping the native session reported success
            // — a stop error must not leave the app stuck open.
            _ = await finish(reason: .userRequested, message: "Native NVST stream ended by user.")
            completion?(shouldTerminateApplication)
        }
    }

    func updateNativePillarboxFill(modeIndex: Int) {
        let mode = OPNPillarboxFillMode.from(modeIndex)
        pillarboxFillModeIndex = mode.rawValue
        OPNStreamPreferences.savePillarboxFillModeIndex(mode.rawValue)
        let dim = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: OPNStreamPreferences.loadDeviceCapabilities()).pillarboxFillDim
        nativeView?.setPillarboxFill(mode: mode.rawValue, dim: dim)
        WebRTCMediaTelemetry.capture("nvst.ui.pillarbox.update", level: .info, message: "Native NVST pillarbox fill changed.", attributes: ["applicationID": configuration.applicationID, "mode": mode.label])
    }

    /// Selection 0 is "Off"; selection N>0 is MetalFX targeting `upscalingTargetOptions[N-1]`. One
    /// control instead of a separate mode toggle + target dropdown, so there is no way to have a
    /// target picked while upscaling is off (that combination did nothing and looked like a bug).
    func updateNativeUpscalingTier(value: Int) {
        let modeIndex = OPNStreamPreferences.upscalingModeOptions.firstIndex(where: { $0.value == value }) ?? 0
        upscalingModeIndex = modeIndex
        OPNStreamPreferences.saveUpscalingSettings(mode: value, sharpness: upscalingSharpness, denoise: upscalingDenoise, forGame: configuration.applicationID)
        let targetHeight = OPNStreamPreferences.upscalingTargetOptions[upscalingTargetIndex].height
        nativeView?.setVideoEnhancement(mode: value, sharpness: upscalingSharpness, denoise: upscalingDenoise, targetHeight: targetHeight)
        WebRTCMediaTelemetry.capture("nvst.ui.upscaling.tier", level: .info, message: "Native NVST upscaling tier changed.", attributes: ["applicationID": configuration.applicationID, "mode": String(value)])
    }

    func updateNativeUpscalingTarget(targetIndex: Int) {
        let clampedIndex = min(max(targetIndex, 0), OPNStreamPreferences.upscalingTargetOptions.count - 1)
        upscalingTargetIndex = clampedIndex
        OPNStreamPreferences.saveUpscalingTargetIndex(clampedIndex)
        let targetHeight = OPNStreamPreferences.upscalingTargetOptions[clampedIndex].height
        let mode = OPNStreamPreferences.upscalingModeOptions[upscalingModeIndex].value
        nativeView?.setVideoEnhancement(mode: mode, sharpness: upscalingSharpness, denoise: upscalingDenoise, targetHeight: targetHeight)
        WebRTCMediaTelemetry.capture("nvst.ui.upscaling.target", level: .info, message: "Native NVST upscaling target changed.", attributes: ["applicationID": configuration.applicationID, "targetHeight": String(targetHeight)])
    }

    /// Mirrors `WebRTCMediaStreamSurface.updateVideoEnhancement`'s sharpness/denoise handling for
    /// the native NVST panel, which never got its own Clarity/Noise Reduction controls.
    func updateNativeUpscalingClarity(sharpness: Int? = nil, denoise: Int? = nil) {
        if let sharpness { upscalingSharpness = min(max(sharpness, 0), 15) }
        if let denoise { upscalingDenoise = min(max(denoise, 0), 20) }
        let mode = OPNStreamPreferences.upscalingModeOptions[upscalingModeIndex].value
        let targetHeight = OPNStreamPreferences.upscalingTargetOptions[upscalingTargetIndex].height
        OPNStreamPreferences.saveUpscalingSettings(mode: mode, sharpness: upscalingSharpness, denoise: upscalingDenoise, forGame: configuration.applicationID)
        nativeView?.setVideoEnhancement(mode: mode, sharpness: upscalingSharpness, denoise: upscalingDenoise, targetHeight: targetHeight)
        WebRTCMediaTelemetry.capture("nvst.ui.upscaling.clarity", level: .info, message: "Native NVST clarity/noise reduction changed.", attributes: ["applicationID": configuration.applicationID, "sharpness": String(upscalingSharpness), "denoise": String(upscalingDenoise)])
    }

    static func nativeVideoSurfaceHandle(for view: NativeWebRTCStreamView) -> UInt? {
        guard let videoWindow = view.nativeNVSTVideoWindow() else { return nil }
        return UInt(bitPattern: Unmanaged.passUnretained(videoWindow).toOpaque())
    }

    func beginStreamingPerformanceMode() {
        guard streamingPerformanceActivity == nil else { return }
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .latencyCritical, .idleSystemSleepDisabled]
        if preventDisplaySleep { options.insert(.idleDisplaySleepDisabled) }
        streamingPerformanceActivity = ProcessInfo.processInfo.beginActivity(options: options, reason: "OpenNOW active native NVST stream")
        WebRTCMediaTelemetry.capture("nvst.stream.performance_mode.begin", level: .info, message: "Native NVST performance mode enabled.", attributes: ["applicationID": configuration.applicationID, "preventDisplaySleep": String(preventDisplaySleep)])
    }

    func endStreamingPerformanceMode() {
        guard let streamingPerformanceActivity else { return }
        ProcessInfo.processInfo.endActivity(streamingPerformanceActivity)
        self.streamingPerformanceActivity = nil
        WebRTCMediaTelemetry.capture("nvst.stream.performance_mode.end", level: .info, message: "Native NVST performance mode disabled.", attributes: ["applicationID": configuration.applicationID])
    }

    static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription.isEmpty ? "Native NVST stream request failed." : error.localizedDescription
    }
}
