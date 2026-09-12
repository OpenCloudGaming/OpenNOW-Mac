//  Wiring the native stream view's callbacks into the host: where input goes, which commands the
//  shell keeps, and how the on-screen keyboard is fed.
//

//  AppKit is imported deliberately here for the same reason NativeNVSTHostViewModel.swift does:
//  `NativeWebRTCStreamView` *is* the stream surface, and the input wiring below is a set of real
//  side effects on it. See that file's note for the full rationale.
//
//  swiftlint:disable:next no_appkit_in_view_model
import AppKit
import Foundation

extension NativeNVSTHostViewModel {
    func configureNativeView(_ view: NativeWebRTCStreamView) {
        guard !didEnd, !isEnding else {
            view.remoteInputEnabled = false
            view.setNativeNVSTVideoVisible(false)
            return
        }
        let profile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: OPNStreamPreferences.loadDeviceCapabilities())
        view.directMouseInputEnabled = profile.directMouseInput
        mouseSensitivityPercent = profile.mouseSensitivityPercent
        view.mouseSensitivity = Double(profile.mouseSensitivityPercent) / 100
        view.rawMouseInputEnabled = profile.rawMouseInput
        view.cursorPolicy = profile.cursorPolicy
        cursorPolicyIndex = profile.cursorPolicy.rawValue
        view.locksPointerWhenRelativeModeSelected = true
        view.confinesCursorToWindowInAbsoluteMode = profile.directMouseInput
        view.hidesCursorWhilePointerLocked = true
        view.onPointerLockChanged = { [weak self, weak view] locked in
            self?.pointerLocked = locked
            self?.mouseInputIsRelative = view?.effectiveMouseMode == .relative
        }
        view.onMouseInputModeChanged = { [weak self] mode in self?.mouseInputIsRelative = mode == .relative }
        if path == nil { view.mouseInputMode = .absolute }
        // A bootstrap so the surface has an aspect before any frame arrives. The requested profile is
        // only a request — the first decoded frame reports what the seat actually sent and corrects
        // this, which matters most on a cross-device resume, where the geometry stays the origin
        // device's and this value would otherwise letterbox and aim the pointer against a fiction.
        view.setStreamContentSize(width: profile.resolution.width, height: profile.resolution.height)
        view.remoteInputEnabled = isConnected && !unifiedHUDVisible && !streamControlsVisible
        let pushToTalkEnabled = profile.microphoneMode.caseInsensitiveCompare("push-to-talk") == .orderedSame
        view.configurePushToTalk(
            keyCode: pushToTalkEnabled ? profile.microphonePushToTalkKeyCode : nil,
            modifierMask: profile.microphonePushToTalkModifierMask
        ) { [weak self] enabled in
            self?.requestNativeMicrophoneEnabled(enabled, source: "push-to-talk")
        }
        configureInput(for: view)
        installNativeFullScreenObservers(for: view)
    }

    /// The HUD's full-screen tile reads `streamWindowIsFullScreen` rather than the style mask, so it
    /// also stays honest when the window is toggled by the green button, ⌃⌘F or the menu bar.
    func installNativeFullScreenObservers(for view: NativeWebRTCStreamView) {
        removeNativeFullScreenObservers()
        guard let window = view.window else { return }
        streamWindowIsFullScreen = window.styleMask.contains(.fullScreen)
        let center = NotificationCenter.default
        let transitions: [(name: NSNotification.Name, isTransitioning: Bool, isFullScreen: Bool)] = [
            (NSWindow.willEnterFullScreenNotification, true, true),
            (NSWindow.didEnterFullScreenNotification, false, true),
            (NSWindow.willExitFullScreenNotification, true, false),
            (NSWindow.didExitFullScreenNotification, false, false),
        ]
        for transition in transitions {
            let token = center.addObserver(forName: transition.name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isFullScreenTransitioning = transition.isTransitioning
                    guard !transition.isTransitioning else {
                        self.startFullScreenTransitionWatchdog()
                        return
                    }
                    self.fullScreenTransitionWatchdog?.cancel()
                    self.fullScreenTransitionWatchdog = nil
                    self.streamWindowIsFullScreen = transition.isFullScreen
                }
            }
            fullScreenObserverTokens.append(token)
        }
    }

    /// AppKit reports a refused transition through `windowDidFailToEnter/ExitFullScreen`, which post
    /// no notification, so without this the latch would stay set and the tile inert for the session.
    private func startFullScreenTransitionWatchdog() {
        fullScreenTransitionWatchdog?.cancel()
        fullScreenTransitionWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: NativeNVSTHostViewModel.fullScreenTransitionTimeout)
            guard !Task.isCancelled, let self else { return }
            self.fullScreenTransitionWatchdog = nil
            self.isFullScreenTransitioning = false
            guard let window = self.nativeView?.window else { return }
            self.streamWindowIsFullScreen = window.styleMask.contains(.fullScreen)
        }
    }

    func removeNativeFullScreenObservers() {
        let center = NotificationCenter.default
        fullScreenObserverTokens.forEach { center.removeObserver($0) }
        fullScreenObserverTokens.removeAll()
        fullScreenTransitionWatchdog?.cancel()
        fullScreenTransitionWatchdog = nil
        isFullScreenTransitioning = false
    }

    /// Every callback below is stored *on the view*, and the view model holds the view - so each one
    /// captures `self` weakly. As `@State` on a struct this was not a cycle; as a class it would be,
    /// and the session would never deallocate.
    /// Where one input event goes. The on-screen keyboard takes gamepad input for itself while it
    /// is up, but still forwards a neutral state so the game does not see a button stuck down.
    func routeInputEvent(_ event: UserInputEvent, view: NativeWebRTCStreamView) {
        if onScreenKeyboardVisible, !isEnding, !didEnd, case .gamepad(let state) = event {
            onScreenKeyboard.handleGamepadState(state)
            if isConnected {
                inputDispatcher?.enqueue(.gamepad(GamepadState(deviceID: state.deviceID, playerIndex: state.playerIndex, timestamp: state.timestamp)))
            }
            return
        }
        guard path != nil, isConnected, !unifiedHUDVisible, !streamControlsVisible, !isEnding, !didEnd else { return }
        if view.remoteInputEnabled && !NativeNVSTInputDispatcher.isNeutralizing(event) {
            guard NSApplication.shared.isActive, view.window?.isKeyWindow == true else { return }
        }
        lastAcceptedStreamInputAt = Date()
        if case .mouse = event {
            if view.mouseInputMode == .relative, !view.isPointerLocked { return }
            inputDispatcher?.enqueue(event)
            return
        }
        inputDispatcher?.enqueue(event)
    }

    func configureInput(for view: NativeWebRTCStreamView) {
        view.onInputEvent = { [weak self, weak view] event in
            guard let self, let view else { return }
            self.routeInputEvent(event, view: view)
        }
        view.shouldHandleCommand = { [weak self] _ in
            self?.isConnected ?? false
        }
        view.onCommand = { [weak self] command in
            self?.handleNativeCommand(command)
        }
        view.onAbsoluteMouseMove = { [weak self, weak view] event in
            guard let self, let view else { return }
            guard self.isConnected, !self.unifiedHUDVisible, !self.streamControlsVisible, !self.isEnding, !self.didEnd,
                  view.remoteInputEnabled, view.mouseInputMode == .absolute else { return }
            guard view.isEmittingNeutralizingAbsolutePosition ||
                    (NSApplication.shared.isActive && view.window?.isKeyWindow == true) else { return }
            self.lastAcceptedStreamInputAt = Date()
            self.inputDispatcher?.enqueueAbsoluteMove(event)
        }
        view.onGamepadTopologyChanged = { [weak self] topology in
            guard let self, self.isConnected, !self.isEnding, !self.didEnd else { return }
            // The view only knows about pads plugged into this Mac. Remote Co-Op guests hold slots
            // the seat must keep believing in, so the announced topology is the merge of the two -
            // sending the local one raw would disconnect every guest the moment a controller is
            // plugged in or unplugged.
            //
            // Routed through `syncRemoteCoOpGamepadTopology` rather than announcing directly,
            // because that is where a departing pad's neutral state is ordered ahead of the
            // announce. Announcing here would let an unplugged pad's release be dropped.
            self.localGamepadTopology = topology
            Task { @MainActor in await self.syncRemoteCoOpGamepadTopology() }
        }
        view.onScreenKeyboardCapture = { [weak self] deviceID, snapshot in
            guard let self, self.onScreenKeyboardVisible else { return false }
            self.onScreenKeyboard.handleSteamSnapshot(deviceID: deviceID, snapshot: snapshot)
            return true
        }
        onScreenKeyboard.onOutput = { [weak self] output in
            self?.sendOnScreenKeyboardOutput(output)
        }
        onScreenKeyboard.onDismiss = { [weak self] in
            self?.setOnScreenKeyboardVisible(false)
        }
        view.onLocalGamepadState = { [weak self] state in
            guard let self, !self.isEnding, !self.didEnd, !self.showingControllerMapping else { return }
            if self.streamControlsVisible {
                self.handleStreamControlsGamepad(state)
            } else if self.unifiedHUDVisible {
                self.handleHUDGamepad(state)
            }
        }
    }
}
