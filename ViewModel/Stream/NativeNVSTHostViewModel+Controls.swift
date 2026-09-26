//  What the HUD and the shortcut keys can do to a running stream: focus traversal, the video
//  enhancement controls, microphone, anti-AFK, pointer lock, the on-screen keyboard, stats polling
//  and the network governor.
//
//  AppKit is imported for the same reason as the main file: `NativeStreamView` is the stream
//  surface these controls act on. See the note there.
//
//  swiftlint:disable:next no_appkit_in_view_model
import AppKit
import Foundation

@MainActor
extension NativeNVSTHostViewModel {

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
        updateNativeUpscalingTier(value: Self.upscalingTierDisplayOrder.map(\.value).wrappingNext(after: currentValue))
    }

    func cycleNativeUpscalingTarget() {
        let count = OPNStreamPreferences.upscalingTargetOptions.count
        guard count > 0 else { return }
        updateNativeUpscalingTarget(targetIndex: (upscalingTargetIndex + 1) % count)
    }

    /// The rumble ceiling, saved as the global setting; the gamepad monitor reads it per command.
    func updateRumbleIntensity(percent: Int) {
        let clamped = min(max(percent, ControllerRumblePreference.range.lowerBound), ControllerRumblePreference.range.upperBound)
        rumbleIntensityPercent = clamped
        ControllerRumblePreference.saveIntensityPercent(clamped)
        OPNStreamTelemetry.capture("nvst.ui.rumble.intensity", level: .info, message: "Rumble intensity changed.", attributes: ["applicationID": configuration.applicationID, "percent": String(clamped)])
    }

    /// Controller/keyboard step through the HUD row: +25% per press, wrapping to off.
    func cycleRumbleIntensity() {
        let next = rumbleIntensityPercent + 25
        updateRumbleIntensity(percent: next > ControllerRumblePreference.range.upperBound ? ControllerRumblePreference.range.lowerBound : next)
    }

    /// Relative mouse multiplier for the stream, applied live and saved as the global setting.
    func updateNativeMouseSensitivity(percent: Int) {
        let range = OPNStreamPreferences.mouseSensitivityRange
        let clamped = min(max(percent, range.lowerBound), range.upperBound)
        mouseSensitivityPercent = clamped
        OPNStreamPreferences.saveMouseSensitivityPercent(clamped)
        nativeView?.mouseSensitivity = Double(clamped) / 100
        OPNStreamTelemetry.capture("nvst.ui.mouse.sensitivity", level: .info, message: "Native NVST mouse sensitivity changed.", attributes: ["applicationID": configuration.applicationID, "percent": String(clamped)])
    }

    /// Controller/keyboard step through the HUD row: +25% per press, wrapping to the minimum.
    func cycleNativeMouseSensitivity() {
        let range = OPNStreamPreferences.mouseSensitivityRange
        let next = mouseSensitivityPercent + 25
        updateNativeMouseSensitivity(percent: next > range.upperBound ? range.lowerBound : next)
    }

    func cycleNativeClarity() {
        updateNativeUpscalingClarity(sharpness: (upscalingSharpness + 1) % 16)
    }

    func cycleNativeNoiseReduction() {
        updateNativeUpscalingClarity(denoise: (upscalingDenoise + 1) % 21)
    }

    func cycleNativePillarboxFill() {
        updateNativePillarboxFill(modeIndex: OPNPillarboxFillMode.pickerCases.map(\.rawValue).wrappingNext(after: pillarboxFillModeIndex))
    }

    func handleHUDGamepad(_ state: GamepadState) {
        guard let step = hudGamepadTracker.navigationStep(state) else { return }
        switch step {
        case .move(let direction):
            // An open dropdown owns the pad: every direction walks its rows, so a horizontal stick
            // nudge does not silently close a panel the user just opened. Focus stays on the trigger,
            // which is what makes cancel land back on it.
            if isHUDDropdownOpen {
                moveHUDDropdownHighlight(step: direction.linearStep)
            } else {
                moveHUDFocus(direction)
            }
        case .activate:
            if isHUDDropdownOpen {
                commitHUDDropdownHighlight()
            } else {
                StreamHUDFocusEntry.activatable(hudFocusID, in: hudFocusEntries)?.action()
            }
        case .back:
            // Back leaves the panel first and only then the HUD; closing both at once is how a user
            // who mistook a long list for the end of the HUD loses the stream overlay entirely.
            if isHUDDropdownOpen { closeHUDDropdown() } else { setUnifiedHUDVisible(false) }
        }
    }

    func moveHUDFocus(_ direction: StreamHUDFocusDirection) {
        guard !isHUDDropdownOpen else { return }
        guard let next = StreamHUDFocusEntry.focusID(from: hudFocusID, direction: direction, in: hudFocusEntries) else { return }
        hudFocusID = next
    }

    func handleStreamControlsGamepad(_ state: GamepadState) {
        guard let step = hudGamepadTracker.navigationStep(state) else { return }
        switch step {
        case .move(let direction):
            streamControlsFocusIndex = (streamControlsFocusIndex + direction.linearStep + 3) % 3
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

    func toggleOnScreenKeyboard() {
        guard isConnected, !isEnding, !didEnd, !streamControlsVisible else { return }
        setOnScreenKeyboardVisible(!onScreenKeyboardVisible)
        OPNStreamTelemetry.capture("nvst.ui.osk.toggle", level: .info, message: onScreenKeyboardVisible ? "On-screen keyboard shown." : "On-screen keyboard hidden.", attributes: ["applicationID": configuration.applicationID, "visible": String(onScreenKeyboardVisible)])
    }

    func setOnScreenKeyboardVisible(_ visible: Bool) {
        if visible {
            if unifiedHUDVisible { setUnifiedHUDVisible(false) }
            onScreenKeyboard.reset()
            restorePointerLockOnKeyboardHide = pointerLocked
            restoreManualCaptureOnKeyboardHide = nativeView?.manualPointerCaptureOverride ?? false
            if pointerLocked { nativeView?.setPointerLocked(false) }
        }
        onScreenKeyboardVisible = visible
        nativeView?.localOverlayCapturesInput = visible
        guard !visible, restorePointerLockOnKeyboardHide else { return }
        let restoreManualCapture = restoreManualCaptureOnKeyboardHide
        restorePointerLockOnKeyboardHide = false
        restoreManualCaptureOnKeyboardHide = false
        guard nativeView?.isFrontmostInputTarget == true else { return }
        // A capture the player took by hand comes back as one: restoring it as an ordinary lock
        // would hand it to the next seat cursor notification to release.
        if restoreManualCapture {
            nativeView?.setManualPointerCapture(true)
        } else {
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
                    OPNStreamTelemetry.capture("nvst.ui.microphone.update", level: .info, message: target ? "Native NVST microphone enabled." : "Native NVST microphone muted.", attributes: ["applicationID": configuration.applicationID, "enabled": String(target), "source": source])
                } catch {
                    guard !Task.isCancelled, !didEnd else { return }
                    microphoneDesiredEnabled = microphoneEnabled
                    microphonePendingStates.removeAll()
                    let message = Self.message(for: error)
                    showNativeTransientStreamMessage(message)
                    OPNStreamTelemetry.capture("nvst.ui.microphone.failed", level: .error, message: message, attributes: ["applicationID": configuration.applicationID, "source": source])
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
        OPNStreamTelemetry.capture("nvst.ui.anti_afk.toggle", level: .info, message: antiAFKMouseMovementEnabled ? "Native NVST Anti-AFK mouse movement enabled." : "Native NVST Anti-AFK mouse movement disabled.", attributes: ["applicationID": configuration.applicationID, "enabled": String(antiAFKMouseMovementEnabled)])
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
        // Not gated on the HUD or the stream controls: both are client-side overlays the seat never
        // sees, and refusing to nudge while one is open is how an idle session got dropped with
        // "AFK: On" showing in that very HUD.
        guard isConnected, antiAFKMouseMovementEnabled, !isEnding, !didEnd, inputDispatcher != nil else { return }
        guard Date().timeIntervalSince(lastAcceptedStreamInputAt) >= StreamAntiAFKInputPolicy.idleThresholdSeconds else { return }
        let delta = StreamAntiAFKInputPolicy.randomMouseDelta()
        inputDispatcher?.enqueue(StreamAntiAFKInputPolicy.mouseMove(deltaX: delta.x, deltaY: delta.y))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard isConnected, antiAFKMouseMovementEnabled, !isEnding, !didEnd else { return }
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

    func showNativeTransientStreamMessage(_ message: String, duration: Duration = .seconds(2)) {
        transientStreamMessageTask?.cancel()
        transientStreamMessage = message
        transientStreamMessageTask = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            transientStreamMessage = ""
            transientStreamMessageTask = nil
        }
    }

    func cancelNativeShortcutTasks() {
        microphoneUpdateTask?.cancel()
        microphoneUpdateTask = nil
        pendingMicrophoneDeviceChanges.removeAll()
        microphonePendingDeviceID = nil
        closeHUDDropdown()
        antiAFKMouseMovementTask?.cancel()
        antiAFKMouseMovementTask = nil
        transientStreamMessageTask?.cancel()
        transientStreamMessageTask = nil
        transientStreamMessage = ""
        recordingStatusResetTask?.cancel()
        recordingStatusResetTask = nil
        screenshotTask?.cancel()
        screenshotTask = nil
    }

    func showStreamControls(completion: StreamSessionQuitDecisionHandler? = nil) {
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
        OPNStreamTelemetry.capture("nvst.ui.controls.show", level: .info, message: "Native NVST stream controls shown.", attributes: ["applicationID": configuration.applicationID])
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
        OPNStreamTelemetry.capture("nvst.ui.controls.dismiss", level: .info, message: "Native NVST stream controls dismissed.", attributes: ["applicationID": configuration.applicationID])
    }

    func setUnifiedHUDVisible(_ visible: Bool) {
        guard isConnected, !streamControlsVisible else { return }
        hudGamepadTracker.reset()
        closeHUDDropdown()
        if visible {
            if onScreenKeyboardVisible { setOnScreenKeyboardVisible(false) }
            // Asked again on every open: the seat's answer is only known once its DESCRIBE offer has
            // been seen, so a session that was still negotiating when it launched can answer now.
            refreshMicrophoneTransportAvailability()
            // Hot-plug: a microphone connected since the HUD was last open is a row now.
            refreshMicrophoneDeviceOptions()
            // Read before the input drop: dropping remote input releases the pointer, and the
            // release is the one place that forgets the override. Without this the HUD silently
            // ended a capture the player took by hand, and closing it again left the pointer free.
            restoreManualCaptureOnHUDHide = nativeView?.manualPointerCaptureOverride ?? false
            nativeView?.remoteInputEnabled = false
            unifiedHUDVisible = true
            // Open on the first real control, skipping headers and the power button; fall back to
            // either only when every section is folded and nothing else is reachable.
            hudFocusID = hudFocusEntries.first(where: { !$0.isDisabled && $0.kind == .control })?.id
                ?? hudFocusEntries.first(where: { !$0.isDisabled })?.id
        } else {
            unifiedHUDVisible = false
            hudFocusID = nil
            let restoreManualCapture = restoreManualCaptureOnHUDHide
            restoreManualCaptureOnHUDHide = false
            // Not unconditionally `true`: the network monitor blocks remote input while the path is
            // down and puts the recovery overlay up, but `isConnected` stays true through a drop, so
            // the HUD hotkey still works. Without this term, opening and closing the HUD during an
            // outage put input back on the wire behind the overlay - pointer capture and keystrokes
            // resuming into a session that cannot receive them - until the next path update.
            nativeView?.remoteInputEnabled = networkPathAvailable
            nativeView?.restoreInputFocus()
            // Same gate as the line above, and for the same reason: `enablePointerLock` does not
            // consult `remoteInputEnabled`, so an unguarded restore would take the pointer back
            // during an outage, behind the recovery overlay.
            if restoreManualCapture, networkPathAvailable, nativeView?.isFrontmostInputTarget == true {
                nativeView?.setManualPointerCapture(true)
            }
        }
        OPNStreamTelemetry.capture("nvst.ui.hud.toggle", level: .info, message: visible ? "Native NVST HUD shown." : "Native NVST HUD hidden.", attributes: ["applicationID": configuration.applicationID, "visible": String(visible)])
    }

    func toggleNativePointerLock() {
        guard isConnected, !isEnding, !didEnd else { return }
        if pointerLocked {
            nativeView?.setManualPointerCapture(false)
        } else {
            // Close the HUD first so remote input is live, then force the capture regardless
            // of the server-driven cursor mode (this is the manual override for games that
            // never signal a cursor-hide).
            setUnifiedHUDVisible(false)
            nativeView?.setManualPointerCapture(true)
        }
    }

    func toggleNativeStatsHUD() {
        guard isConnected, !isEnding, !didEnd else { return }
        nativeStatsVisible.toggle()
        OPNStreamTelemetry.capture("nvst.ui.stats.toggle", level: .info, message: nativeStatsVisible ? "OpenNOW NVST stats shown." : "OpenNOW NVST stats hidden.", attributes: ["applicationID": configuration.applicationID, "visible": String(nativeStatsVisible)])
    }

    /// The window owns the transition: nothing here touches the style mask, collection behaviour,
    /// aspect ratio or frame - `WindowFitting` grants `.fullScreenPrimary` before the window
    /// is first painted, which is the only point the window server takes it reliably.
    /// A second toggle mid-animation cancels AppKit's entry, so transitions are refused, not queued.
    func toggleNativeFullScreen() {
        guard let window = nativeView?.window, !isFullScreenTransitioning else { return }
        guard !StreamWindowGeometryGate.shouldDeferGeometryMutation(for: window) else { return }
        // Read before the toggle: `.fullScreen` is only inserted once the transition finishes.
        let willEnterFullScreen = !window.styleMask.contains(.fullScreen)
        window.toggleFullScreen(nil)
        showNativeTransientStreamMessage(willEnterFullScreen ? "Entering full screen" : "Leaving full screen")
        OPNStreamTelemetry.capture("nvst.ui.fullscreen.toggle", level: .info, message: willEnterFullScreen ? "Native NVST stream entered full screen." : "Native NVST stream left full screen.", attributes: ["applicationID": configuration.applicationID, "fullScreen": String(willEnterFullScreen)])
    }

    /// The window is only reachable once the view is in a hierarchy and the aspect coordinator has
    /// settled the first frame, so the transition waits a beat and retries until both are true.
    func enterNativeFullScreenWhenSessionReady() {
        guard OPNSessionReadyAction.isFullScreenRequestedWhenReady else { return }
        sessionReadyFullScreenTask?.cancel()
        sessionReadyFullScreenTask = Task { @MainActor [weak self] in
            for _ in 0..<Self.sessionReadyFullScreenAttemptLimit {
                try? await Task.sleep(for: NativeNVSTHostViewModel.sessionReadyFullScreenRetryDelay)
                guard !Task.isCancelled, let self, self.isConnected, !self.isEnding, !self.didEnd else { return }
                guard let window = self.nativeView?.window, !self.isFullScreenTransitioning else { continue }
                guard !StreamWindowGeometryGate.shouldDeferGeometryMutation(for: window) else { continue }
                guard !window.styleMask.contains(.fullScreen) else { return }
                window.toggleFullScreen(nil)
                OPNStreamTelemetry.capture("nvst.ui.fullscreen.sessionReady", level: .info, message: "Native NVST stream entered full screen because the session-ready action requests it.", attributes: ["applicationID": self.configuration.applicationID])
                return
            }
        }
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
                    // Equality-gated: the poll runs once a second and a healthy stream reports the
                    // same snapshot for long stretches, but an unconditional assignment still
                    // publishes, re-rendering the whole stream surface and every HUD panel. The
                    // telemetry and governor below still run on every tick; only the published
                    // writes are skipped when the value is unchanged.
                    if latestNativeStats != snapshot { latestNativeStats = snapshot }
                    let renderDiagnostics = nativeView?.nvstBifrostFreeRenderer?.renderDiagnostics
                    if latestRenderDiagnostics != renderDiagnostics { latestRenderDiagnostics = renderDiagnostics }
                    if snapshot.serverGPU != nativeRigRawName {
                        nativeRigRawName = snapshot.serverGPU
                        nativeRigName = OPNStreamPreferences.friendlyGPUName(for: snapshot.serverGPU)
                    }
                    logRenderDiagnosticsIfDue()
                    updateBitrateStarvation(snapshot)
                    recordNativeNetworkTelemetry(snapshot)
                    let adjustments = networkGovernor?.evaluate(snapshot) ?? []
                    for adjustment in adjustments { await applyNativeNetworkAdjustment(adjustment, path: path) }
                }
                if isConnected, !isEnding, !didEnd, !isReconnecting,
                   let failure = nativeStreamHealth.observe(snapshot: snapshot, rendererReady: nativeView?.nativeNVSTRendererSurfaceReady == true) {
                    // A stalled stream is a dead link far more often than a dead seat: reconnect
                    // to the same session first, and only end the stream when that is exhausted.
                    if failure == .streamStalled, await attemptInPlaceReconnect(path: path, reason: "stall") {
                        continue
                    }
                    OPNStreamTelemetry.capture("nvst.stream.health.failed", level: .error, message: failure.message, attributes: ["applicationID": configuration.applicationID])
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
        if snapshot.latencyMilliseconds >= 0 { OPNStreamTelemetry.record("nvst.network.latency_ms", kind: .gauge, value: snapshot.latencyMilliseconds, unit: "millisecond", attributes: attributes) }
        if snapshot.jitterMilliseconds >= 0 { OPNStreamTelemetry.record("nvst.network.jitter_ms", kind: .gauge, value: snapshot.jitterMilliseconds, unit: "millisecond", attributes: attributes) }
        if snapshot.bitrateMegabitsPerSecond >= 0 { OPNStreamTelemetry.record("nvst.network.bitrate_mbps", kind: .gauge, value: snapshot.bitrateMegabitsPerSecond, unit: "megabit/second", attributes: attributes) }
        if snapshot.bandwidthUtilizationPercent >= 0 { OPNStreamTelemetry.record("nvst.network.bandwidth_utilization_percent", kind: .gauge, value: snapshot.bandwidthUtilizationPercent, unit: "percent", attributes: attributes) }
        OPNStreamTelemetry.record("nvst.network.packet_loss", kind: .gauge, value: Double(snapshot.packetLoss), unit: "packet", attributes: attributes)
        OPNStreamTelemetry.record("nvst.network.frame_loss", kind: .gauge, value: Double(snapshot.frameLoss), unit: "frame", attributes: attributes)
    }

    func startNetworkPathMonitoring() {
        networkPathTask?.cancel()
        let monitor = NativeNVSTNetworkPathMonitor()
        networkPathTask = Task { @MainActor in
            var wasUnavailable = false
            for await networkPath in monitor.updates() {
                guard !Task.isCancelled, !didEnd else { return }
                if networkPath.isSatisfied {
                    networkPathAvailable = true
                    if isConnected, !unifiedHUDVisible, !streamControlsVisible { nativeView?.remoteInputEnabled = true }
                    OPNStreamTelemetry.capture("nvst.network.path.available", level: .info, message: "Native NVST network path is available.", attributes: ["wifi": String(networkPath.usesWiFi), "ethernet": String(networkPath.usesWiredEthernet), "expensive": String(networkPath.isExpensive), "constrained": String(networkPath.isConstrained)])
                    // The path came back. The seat still sends to the address the old path had, so
                    // a stream that has already gone quiet will not resume on its own: reconnect
                    // now rather than waiting out the stall watchdog.
                    if wasUnavailable, isConnected, !isEnding, let path, nativeStreamHealth.zeroFrameStreak >= 2 {
                        Task {
                            if await !self.attemptInPlaceReconnect(path: path, reason: "network path restored") {
                                _ = await self.finish(reason: .failed, message: NativeNVSTStreamHealthFailure.streamStalled.message)
                            }
                        }
                    }
                    wasUnavailable = false
                } else {
                    wasUnavailable = true
                    networkPathAvailable = false
                    nativeView?.remoteInputEnabled = false
                    showNativeTransientStreamMessage("Network interrupted - waiting to reconnect", duration: .seconds(30))
                    OPNStreamTelemetry.capture("nvst.network.path.unavailable", level: .warning, message: "Native NVST network path is unavailable.")
                }
            }
        }
    }

    /// Reconnects to the same seat through the path's in-place recovery, keeping the HUD honest
    /// about it. Returns false when the path has spent its attempts, in which case the caller ends
    /// the stream with the failure it was about to report.
    func attemptInPlaceReconnect(path: NativeNVSTStreamingPath, reason: String) async -> Bool {
        guard !isReconnecting, await path.canRecoverInPlace() else { return false }
        isReconnecting = true
        nativeView?.remoteInputEnabled = false
        showNativeTransientStreamMessage("Connection lost - reconnecting…", duration: .seconds(60))
        OPNStreamTelemetry.capture("nvst.stream.reconnect.start", level: .warning, message: "Native NVST reconnecting in place.", attributes: ["applicationID": configuration.applicationID, "reason": reason])
        let recovered = await path.recoverInPlace(reason: reason)
        isReconnecting = false
        guard recovered, !didEnd, !isEnding else {
            OPNStreamTelemetry.capture("nvst.stream.reconnect.failed", level: .error, message: "Native NVST could not reconnect in place.", attributes: ["applicationID": configuration.applicationID, "reason": reason])
            return false
        }
        // A fresh transport: the watchdog starts over, the mic gate is re-applied (the new bundle
        // comes up muted), and input is live again.
        nativeStreamHealth = NativeNVSTStreamHealthMonitor(stalledSampleLimit: Self.stalledSamplesBeforeReconnect)
        try? await path.setMicrophoneEnabled(microphoneEnabled)
        if isConnected, !unifiedHUDVisible, !streamControlsVisible { nativeView?.remoteInputEnabled = networkPathAvailable }
        showNativeTransientStreamMessage("Reconnected")
        OPNStreamTelemetry.capture("nvst.stream.reconnect.succeeded", level: .info, message: "Native NVST reconnected in place.", attributes: ["applicationID": configuration.applicationID, "reason": reason])
        return true
    }

    func applyNativeNetworkAdjustment(_ adjustment: NativeNVSTNetworkAdjustment, path: NativeNVSTStreamingPath) async {
        do {
            switch adjustment {
            case .maximumBitrateKbps(let bitrate): try await path.setMaximumBitrateKbps(bitrate)
            case .dynamicStreamingMode(let mode): try await path.setDynamicStreamingMode(mode)
            case .l4sEnabled(let enabled): try await path.setL4SEnabled(enabled)
            }
            OPNStreamTelemetry.capture("nvst.network.adjustment", level: .info, message: "Applied native NVST network adjustment.", attributes: ["adjustment": String(describing: adjustment)])
        } catch {
            OPNStreamTelemetry.capture("nvst.network.adjustment.failed", level: .warning, message: Self.message(for: error), attributes: ["adjustment": String(describing: adjustment)])
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
        OPNStreamTelemetry.capture("nvst.ui.pillarbox.update", level: .info, message: "Native NVST pillarbox fill changed.", attributes: ["applicationID": configuration.applicationID, "mode": mode.label])
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
        OPNStreamTelemetry.capture("nvst.ui.upscaling.tier", level: .info, message: "Native NVST upscaling tier changed.", attributes: ["applicationID": configuration.applicationID, "mode": String(value)])
    }

    func updateNativeUpscalingTarget(targetIndex: Int) {
        let clampedIndex = min(max(targetIndex, 0), OPNStreamPreferences.upscalingTargetOptions.count - 1)
        upscalingTargetIndex = clampedIndex
        OPNStreamPreferences.saveUpscalingTargetIndex(clampedIndex)
        let targetHeight = OPNStreamPreferences.upscalingTargetOptions[clampedIndex].height
        let mode = OPNStreamPreferences.upscalingModeOptions[upscalingModeIndex].value
        nativeView?.setVideoEnhancement(mode: mode, sharpness: upscalingSharpness, denoise: upscalingDenoise, targetHeight: targetHeight)
        OPNStreamTelemetry.capture("nvst.ui.upscaling.target", level: .info, message: "Native NVST upscaling target changed.", attributes: ["applicationID": configuration.applicationID, "targetHeight": String(targetHeight)])
    }

    func updateNativeUpscalingClarity(sharpness: Int? = nil, denoise: Int? = nil) {
        if let sharpness { upscalingSharpness = min(max(sharpness, 0), 15) }
        if let denoise { upscalingDenoise = min(max(denoise, 0), 20) }
        let mode = OPNStreamPreferences.upscalingModeOptions[upscalingModeIndex].value
        let targetHeight = OPNStreamPreferences.upscalingTargetOptions[upscalingTargetIndex].height
        OPNStreamPreferences.saveUpscalingSettings(mode: mode, sharpness: upscalingSharpness, denoise: upscalingDenoise, forGame: configuration.applicationID)
        nativeView?.setVideoEnhancement(mode: mode, sharpness: upscalingSharpness, denoise: upscalingDenoise, targetHeight: targetHeight)
        OPNStreamTelemetry.capture("nvst.ui.upscaling.clarity", level: .info, message: "Native NVST clarity/noise reduction changed.", attributes: ["applicationID": configuration.applicationID, "sharpness": String(upscalingSharpness), "denoise": String(upscalingDenoise)])
    }

    static func nativeVideoSurfaceHandle(for view: NativeStreamView) -> UInt? {
        guard let videoWindow = view.nativeNVSTVideoWindow() else { return nil }
        return UInt(bitPattern: Unmanaged.passUnretained(videoWindow).toOpaque())
    }

    func beginStreamingPerformanceMode() {
        guard streamingPerformanceActivity == nil else { return }
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .latencyCritical, .idleSystemSleepDisabled]
        if preventDisplaySleep { options.insert(.idleDisplaySleepDisabled) }
        streamingPerformanceActivity = ProcessInfo.processInfo.beginActivity(options: options, reason: "OpenNOW active native NVST stream")
        OPNStreamTelemetry.capture("nvst.stream.performance_mode.begin", level: .info, message: "Native NVST performance mode enabled.", attributes: ["applicationID": configuration.applicationID, "preventDisplaySleep": String(preventDisplaySleep)])
    }

    func endStreamingPerformanceMode() {
        guard let streamingPerformanceActivity else { return }
        ProcessInfo.processInfo.endActivity(streamingPerformanceActivity)
        self.streamingPerformanceActivity = nil
        OPNStreamTelemetry.capture("nvst.stream.performance_mode.end", level: .info, message: "Native NVST performance mode disabled.", attributes: ["applicationID": configuration.applicationID])
    }

    static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription.isEmpty ? "Native NVST stream request failed." : error.localizedDescription
    }
}
