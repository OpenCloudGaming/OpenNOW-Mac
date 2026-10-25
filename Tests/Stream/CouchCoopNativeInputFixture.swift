import AppKit
import GameController
import os
import Testing
@testable import OpenNOW

@MainActor
final class CouchCoopInputFocus {
    var isApplicationActive = true
    var isWindowKey = true
}

@MainActor
final class CouchCoopFocusReleaseRecorder {
    private(set) var sequence: [String] = []
    private(set) var releaseCaptureStates: [Bool] = []

    init(view: NativeStreamView) {
        let inputHandler = view.onInputEvent
        view.onInputEvent = { [weak self, weak view] event in
            switch event {
            case .keyboard(let key) where !key.isPressed: self?.sequence.append("key-release")
            case .mouse(.button(_, _, false, _)): self?.sequence.append("mouse-release")
            default: break
            }
            if NativeNVSTInputDispatcher.isNeutralizing(event) { self?.releaseCaptureStates.append(view?.isPointerLocked == true) }
            inputHandler?(event)
        }
        let pointerHandler = view.onPointerLockChanged
        view.onPointerLockChanged = { [weak self] isLocked in
            if !isLocked { self?.sequence.append("unlock") }
            pointerHandler?(isLocked)
        }
    }
}

actor CouchCoopNativeInputRecorder {
    private var inputs: [UserInputEvent] = []
    private var barrierSnapshots: [String: [UserInputEvent]] = [:]
    private var barrierWaiters: [String: CheckedContinuation<[UserInputEvent], Error>] = [:]

    func append(_ input: NativeNVSTInput) {
        guard case .event(let event) = input else { return }
        if case .text("input-test-barrier", let marker, _) = event {
            guard let waiter = barrierWaiters.removeValue(forKey: marker) else {
                barrierSnapshots[marker] = inputs
                return
            }
            waiter.resume(returning: inputs)
            return
        }
        inputs.append(event)
    }

    func snapshot(at marker: String) async throws -> [UserInputEvent] {
        try Task.checkCancellation()
        if let snapshot = barrierSnapshots.removeValue(forKey: marker) { return snapshot }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                barrierWaiters[marker] = continuation
            }
        } onCancel: {
            Task { await self.cancelBarrier(marker) }
        }
    }

    private func cancelBarrier(_ marker: String) {
        barrierSnapshots.removeValue(forKey: marker)
        barrierWaiters.removeValue(forKey: marker)?.resume(throwing: CancellationError())
    }
}

@MainActor
final class CouchCoopNativeInputFixture {
    let focus: CouchCoopInputFocus
    let window: NSWindow
    let view: NativeStreamView
    let model: NativeNVSTHostViewModel
    let store: ControllerMappingStore
    let dispatcher: NativeNVSTInputDispatcher
    private let recorder: CouchCoopNativeInputRecorder
    private let nativePollState = NativeGamepadPollState()
    private let defaults: UserDefaults
    private let defaultsDomain: String
    private(set) var cursorAssociations: [Bool] = []

    init() throws {
        let defaultsDomain = "CouchCoopNativeInputTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        let store = ControllerMappingStore(defaults: defaults)
        for family in [ControllerFamily.steam, .generic] {
            var profile = store.createProfile(named: "Input ownership", family: family)
            profile.bindings[.faceA] = .mouseButton(.left)
            profile.bindings[.faceB] = .keyboardKey(keyCode: 49, modifiers: .shift)
            profile.bindings[.faceX] = .gamepadChord(ControllerButtonChord(buttons: .north))
            profile.bindings[.faceY] = .streamCommand(.togglePointerCapture)
            store.updateProfile(profile)
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 720),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let registry = ControllerMappingDevices(discovery: .init(nativeControllers: { [] }, steamDeviceIDs: { [] }))
        let view = NativeStreamView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720),
                                    mappingProvider: store, controllerRegistry: registry)
        let model = NativeNVSTHostViewModel(
            configuration: StreamLaunchConfiguration(title: "Input ownership", applicationID: "input-test",
                                                       accessToken: "unused", accountLinked: true, selectedStore: "steam"),
            sessionProvider: StubNativeNVSTSessionProvider(), preventDisplaySleep: false, onProgress: nil,
            onEnd: { _, _, _ in }
        )
        let recorder = CouchCoopNativeInputRecorder()
        self.focus = CouchCoopInputFocus()
        self.window = window
        self.view = view
        self.model = model
        self.store = store
        self.recorder = recorder
        self.defaults = defaults
        self.defaultsDomain = defaultsDomain
        self.dispatcher = NativeNVSTInputDispatcher { input in await recorder.append(input) }
        configureInputOwnership()
    }

    private func configureInputOwnership() {
        window.isReleasedWhenClosed = false
        view.inputFocusProvider = { [focus] in (focus.isApplicationActive, focus.isWindowKey) }
        view.hidesCursorWhilePointerLocked = false
        view.cursorLocationProvider = { CGPoint(x: 740, y: 460) }
        view.cursorWarpHandler = { _ in }
        window.contentView = view
        view.gamepadMonitor.stop()
        view.gamepadMonitor.pollingAllowed = true
        view.allowsBackgroundGamepadInput = true
        view.updateControllerMappingFocus()
        model.nativeView = view
        model.path = NativeNVSTStreamingPath(sessionProvider: StubNativeNVSTSessionProvider(), transport: RecordingNativeTransport())
        model.isConnected = true
        model.inputDispatcher = dispatcher
        model.configureInput(for: view)
        view.onPointerLockChanged = { [weak model] in model?.pointerLocked = $0 }
        view.cursorAssociationHandler = { [weak self] isAssociated in
            self?.cursorAssociations.append(isAssociated)
            return .success
        }
    }

    func configureNativeControllers(_ controllers: [(deviceID: InputDeviceID, controller: GCController, profile: ControllerMappingProfile?)]) {
        let monitor = view.gamepadMonitor
        let state = nativePollState
        monitor.pollingQueue.sync {
            state.cachedControllers = controllers.map { $0.controller }
            state.controllerSlots = Dictionary(uniqueKeysWithValues: controllers.enumerated().map {
                (ObjectIdentifier($0.element.controller), $0.offset)
            })
            let configurations = Dictionary(uniqueKeysWithValues: controllers.enumerated().map {
                (ObjectIdentifier($0.element.controller), NativeControllerMappingConfiguration(
                    deviceID: $0.element.deviceID, playerIndex: $0.offset, profile: $0.element.profile
                ))
            })
            _ = state.configureMappings(configurations)
            state.hidSnapshots = { [:] }
        }
    }

    func pollNativeControllers() {
        let monitor = view.gamepadMonitor
        let state = nativePollState
        let captured = OSAllocatedUnfairLock(initialState: [UserInputEvent]())
        let commands = monitor.pollingQueue.sync {
            state.pollAndEmit(onEvents: { events in captured.withLock { $0 += events } }, onBatteryChange: { _ in })
            monitor.pollState.pendingEvents.append(contentsOf: captured.withLock { $0 })
            return state.takePendingCommands()
        }
        for command in commands { monitor.onStreamCommand?(command) }
        monitor.dispatchPendingInput()
    }

    var routingDiagnostics: String {
        let monitor = view.gamepadMonitor
        let state = nativePollState
        let slots = monitor.pollingQueue.sync {
            "scriptedSlots=\(state.controllerSlots.values.sorted()) liveSlots=\(monitor.pollState.controllerSlots.values.sorted())"
        }
        let active = view.activeGamepadStates.keys.sorted().compactMap { playerIndex -> String? in
            guard let pad = view.activeGamepadStates[playerIndex] else { return nil }
            return "\(playerIndex):\(pad.deviceID.rawValue):buttons=\(pad.buttons.rawValue):leftX=\(pad.leftStickX)"
        }
        return "\(slots) active=\(active) mappings=\(monitor.mappingsEnabled) polling=\(monitor.pollingAllowed)"
    }

    func sendSteam(_ snapshot: ControllerInputSnapshot) {
        view.gamepadMonitor.processSteamSnapshot(deviceID: "steam-input-test", playerIndex: 2, snapshot: snapshot)
    }

    func recordedInputs() async throws -> [UserInputEvent] {
        let marker = UUID().uuidString
        dispatcher.enqueue(.text(deviceID: "input-test-barrier", value: marker, timestamp: MediaTimestamp(nanoseconds: 0)))
        do {
            return try await recorder.snapshot(at: marker)
        } catch {
            Issue.record("Input barrier cancelled: pending=\(dispatcher.pendingInputCount) \(routingDiagnostics)")
            throw error
        }
    }

    func close() {
        view.remoteInputEnabled = false
        view.gamepadMonitor.stop()
        view.setPointerLocked(false)
        view.onInputEvent = nil
        view.onCommand = nil
        model.cancelNativeShortcutTasks()
        model.isConnected = false
        model.nativeView = nil
        model.path = nil
        model.inputDispatcher = nil
        dispatcher.cancel()
        window.contentView = nil
        window.close()
        defaults.removePersistentDomain(forName: defaultsDomain)
    }
}
