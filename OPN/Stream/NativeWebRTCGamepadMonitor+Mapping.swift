import Foundation

extension NativeWebRTCGamepadMonitor {
    /// While the Guide/Steam button is held, `includePointerMotion` is false — trackpad
    /// and stick pointer motion is suppressed here so `SteamControllerLocalCursorInjector`
    /// can drive the real macOS cursor from the right pad instead. Buttons/triggers/sticks
    /// keep forwarding normally either way.
    func applyBindingEngine(deviceID: InputDeviceID, playerIndex: Int, snapshot: ControllerInputSnapshot, includePointerMotion: Bool) {
        reapplyTasks.removeValue(forKey: deviceID)?.cancel()
        guard mappingsEnabled else {
            var snapshot = snapshot
            snapshot.buttons.remove(.mode)
            emitInputEvent(.gamepad(snapshot.gamepadState(deviceID: deviceID, playerIndex: playerIndex,
                                                       timestamp: MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds))))
            return
        }
        let profile = mappingProvider.profile(for: deviceID, family: .steam) ?? ControllerMappingProfile(name: "Default")
        let timestamp = MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
        var engine = bindingEngines[deviceID] ?? ControllerBindingEngine()
        var result = engine.applyDiscreteControls(profile: profile, snapshot: snapshot, deviceID: deviceID, playerIndex: playerIndex, now: bindingClock.now, timestamp: timestamp, includePointerMotion: includePointerMotion)
        if includePointerMotion {
            result.events.append(contentsOf: engine.applyPointerMotion(profile: profile, snapshot: snapshot, deviceID: deviceID, timestamp: timestamp))
        }
        bindingEngines[deviceID] = engine
        for event in result.events {
            emitInputEvent(event)
        }
        if let delay = result.nextReapplyDelay {
            scheduleReapply(deviceID: deviceID, playerIndex: playerIndex, after: delay)
        }
    }

    func emitInputEvent(_ event: UserInputEvent) {
        if !mappingsEnabled || !pollingAllowed {
            switch event {
            case .keyboard(let key) where key.isPressed: return
            case .mouse(.button(_, _, true, _)), .mouse(.moved), .mouse(.wheel), .mouse(.horizontalWheel): return
            default: break
            }
        }
        for output in bindingOutputLedger.events(for: event) { onInputEvent?(output) }
    }

    func setMappingsEnabled(_ enabled: Bool) {
        guard mappingsEnabled != enabled else { return }
        mappingsEnabled = enabled
        releaseSteamBindings()
        refreshMappingConfiguration()
    }

    func releaseSteamBinding(deviceID: InputDeviceID, playerIndex: Int) {
        guard var engine = bindingEngines.removeValue(forKey: deviceID) else { return }
        let events = engine.reset(deviceID: deviceID, playerIndex: playerIndex,
                                  timestamp: MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds))
        for event in events { emitInputEvent(event) }
    }

    func releaseSteamBindings() {
        reapplyTasks.values.forEach { $0.cancel() }
        reapplyTasks.removeAll()
        for deviceID in Array(bindingEngines.keys) {
            releaseSteamBinding(deviceID: deviceID, playerIndex: pollState.steamControllerSlots[deviceID] ?? 0)
        }
    }

    func refreshMappingConfiguration(replaySteam: Bool = true) {
        SteamControllerHIDMonitor.shared.refreshCaptureConfiguration()
        let registry = ControllerMappingDevices.shared
        var configuration: [ObjectIdentifier: NativeControllerMappingConfiguration] = [:]
        for controller in pollState.cachedControllers {
            guard let id = registry.id(for: controller),
                  let device = registry.devices.first(where: { $0.id == id }),
                  let slot = pollState.controllerSlots[ObjectIdentifier(controller)] else { continue }
            let profile = mappingsEnabled ? mappingProvider.profile(for: id, family: device.family) : nil
            configuration[ObjectIdentifier(controller)] = NativeControllerMappingConfiguration(deviceID: id, playerIndex: slot, profile: profile)
        }
        let releases = pollingQueue.sync {
            pollState.takePendingEvents() + pollState.configureMappings(configuration)
        }
        for event in releases { emitInputEvent(event) }
        guard replaySteam else { return }
        for deviceID in Array(bindingEngines.keys) {
            guard let slot = pollState.steamControllerSlots[deviceID],
                  let snapshot = SteamControllerHIDMonitor.shared.snapshot(for: deviceID), pollingAllowed else { continue }
            processSteamSnapshot(deviceID: deviceID, playerIndex: slot, snapshot: snapshot)
        }
    }

    func scheduleReapply(deviceID: InputDeviceID, playerIndex: Int, after delay: Duration) {
        reapplyTasks[deviceID] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.pollingAllowed else { return }
            self.reapplyTasks.removeValue(forKey: deviceID)
            guard self.pollState.steamControllerSlots[deviceID] == playerIndex,
                  let latest = SteamControllerHIDMonitor.shared.snapshot(for: deviceID) else { return }
            self.processSteamSnapshot(deviceID: deviceID, playerIndex: playerIndex, snapshot: latest)
        }
    }

}
