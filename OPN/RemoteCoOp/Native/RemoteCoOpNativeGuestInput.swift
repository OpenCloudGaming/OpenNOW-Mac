//
//  RemoteCoOpNativeGuestInput.swift
//  OpenNOW
//
//  The guest's gamepad, forwarded: sends state changes down the host-opened `remote-coop-input` data
//  channel as the same packets the browser guest produces.
//
//  Field semantics mirror `NativeWebRTCGamepadMonitor` exactly, because the host's router maps packet
//  fields straight onto `GamepadState` and any reinterpretation here would make a guest's pad behave
//  differently from one plugged into the host.
//
//  Sampling is event-driven. A 60 Hz timer put 0-16.7 ms on every input before it reached the socket,
//  more than the whole end-to-end budget; `valueChangedHandler` fires on the HID report instead. The
//  200 Hz timer that remains is a safety net, not a sampler - see `OPNRemoteCoOpGuestInputRedundancy`.
//
//  Two controller sources, matching the host. `GCController` misses the Steam Controller 2 entirely,
//  which is raw HID; that path reuses `SteamControllerBindingEngine` so a guest gets the host's own
//  mapping and grip combos. Only gamepad events survive - the packet carries pad state and nothing
//  else, so a binding producing a keystroke has nowhere to go.
//
//  First controller only: a participant owns one player slot.
//

import Foundation
import GameController

public final class OPNRemoteCoOpNativeGuestInputSender: @unchecked Sendable {
    private struct Snapshot: Equatable {
        var buttons: GamepadButtons
        var leftTrigger: Float
        var rightTrigger: Float
        var leftStickX: Float
        var leftStickY: Float
        var rightStickX: Float
        var rightStickY: Float
    }

    /// The safety-net poll interval. Not the sample rate - `valueChangedHandler` is.
    private static let safetyPollInterval = 1.0 / 200.0

    private let participantID: UUID
    private let send: @Sendable (OPNRemoteCoOpInputPacket) -> Void
    private let onControllerAvailability: @Sendable (Bool) -> Void
    private let queue = DispatchQueue(label: "io.github.opencloudgaming.opennow.remote-coop.guest-input", qos: .userInteractive)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var sequenceNumber: UInt64 = 0
    private var lastSent: Snapshot?
    private var redundancy = OPNRemoteCoOpGuestInputRedundancyPolicy()
    private var steamBindingEngine = SteamControllerBindingEngine()
    private var didReportControllerAvailability: Bool?
    private var isRunning = false

    /// `send` is synchronous on purpose: it runs on the HID callback, and wrapping each packet in a
    /// `Task` would put event-driven sampling back behind the concurrent executor.
    public init(participantID: UUID,
                send: @escaping @Sendable (OPNRemoteCoOpInputPacket) -> Void,
                onControllerAvailability: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.participantID = participantID
        self.send = send
        self.onControllerAvailability = onControllerAvailability
    }

    public func start() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !isRunning else { return false }
            isRunning = true
            lastSent = nil
            redundancy = OPNRemoteCoOpGuestInputRedundancyPolicy()
            return true
        }
        guard shouldStart else { return }

        let center = NotificationCenter.default
        let observers = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: nil) { [weak self] _ in
                self?.attachHandlers()
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: nil) { [weak self] _ in
                self?.attachHandlers()
                // A pad unplugged mid-hold leaves the seat holding whatever it had. The next emit
                // finds no controller, so the release has to be synthesised here.
                self?.emitNeutralState()
            }
        ]
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // First fire one interval out, so the handler cannot run while the commit below holds the lock.
        timer.schedule(deadline: .now() + Self.safetyPollInterval, repeating: Self.safetyPollInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.emitCurrentState(allowRedundantSend: true)
        }

        // Stored *and* resumed in one critical section. `stop()` can land in the gap after `isRunning`
        // is set above, and would otherwise either leave an unowned timer firing forever or cancel it
        // between the store and the resume.
        let didCommit = lock.withLock { () -> Bool in
            guard isRunning else { return false }
            self.observers = observers
            self.timer = timer
            timer.resume()
            return true
        }
        guard didCommit else {
            for observer in observers { center.removeObserver(observer) }
            // Cancel then resume: releasing a still-suspended dispatch source traps, and cancelling
            // alone does not clear the suspend count.
            timer.cancel()
            timer.resume()
            return
        }
        attachHandlers()
        attachSteamController()
    }

    public func stop() {
        let state = lock.withLock { () -> (DispatchSourceTimer?, [NSObjectProtocol]) in
            guard isRunning else { return (nil, []) }
            isRunning = false
            let timer = self.timer
            let observers = self.observers
            self.timer = nil
            self.observers = []
            return (timer, observers)
        }
        state.0?.cancel()
        for observer in state.1 { NotificationCenter.default.removeObserver(observer) }
        for gamepad in Self.connectedGamepads() { gamepad.valueChangedHandler = nil }
        detachSteamController()
        lock.withLock { didReportControllerAvailability = nil }
    }

    /// Handlers run on our own queue, not the main one: the guest window renders video there.
    private func attachHandlers() {
        guard lock.withLock({ isRunning }) else { return }
        reportControllerAvailability()
        for gamepad in Self.connectedGamepads() {
            gamepad.controller?.handlerQueue = queue
            gamepad.valueChangedHandler = { [weak self] _, _ in
                self?.emitCurrentState()
            }
        }
    }

    /// `beginInputCapture` matters as much as the input: without it the controller stays in lizard
    /// mode and its trackpads drive the guest's own cursor. The monitor refcounts capture requests.
    private func attachSteamController() {
        Task { @MainActor [weak self] in
            guard let self, self.lock.withLock({ self.isRunning }) else { return }
            let monitor = SteamControllerHIDMonitor.shared
            monitor.setEnabled(SteamControllerPreference.isEnabled)
            monitor.register(
                self,
                onControllersChanged: { [weak self] in self?.reportControllerAvailability() },
                onInputState: { [weak self] deviceID, snapshot in self?.emitSteamSnapshot(deviceID, snapshot) }
            )
            monitor.beginInputCapture(self)
            self.reportControllerAvailability()
        }
    }

    private func detachSteamController() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            SteamControllerHIDMonitor.shared.endInputCapture(self)
            SteamControllerHIDMonitor.shared.unregister(self)
        }
    }

    /// Player index zero throughout: the host assigns the real slot and this side is never told it.
    @MainActor
    private func emitSteamSnapshot(_ deviceID: InputDeviceID, _ snapshot: SteamControllerInputSnapshot) {
        guard lock.withLock({ isRunning }) else { return }
        let profile = SteamControllerMappingStore.shared.activeProfile ?? SteamControllerMappingProfile(name: "Default")
        let timestamp = MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
        var engine = lock.withLock { steamBindingEngine }
        let result = engine.applyDiscreteControls(
            profile: profile,
            snapshot: snapshot,
            deviceID: deviceID,
            playerIndex: 0,
            now: .now,
            timestamp: timestamp
        )
        lock.withLock { steamBindingEngine = engine }
        for event in result.events {
            guard case .gamepad(let state) = event else { continue }
            emit(Snapshot(
                buttons: state.buttons,
                leftTrigger: state.leftTrigger,
                rightTrigger: state.rightTrigger,
                leftStickX: state.leftStickX,
                leftStickY: state.leftStickY,
                rightStickX: state.rightStickX,
                rightStickY: state.rightStickY
            ))
        }
    }

    private func reportControllerAvailability() {
        let available = !Self.connectedGamepads().isEmpty || SteamControllerHIDMonitor.connectedControllerCount > 0
        let shouldReport = lock.withLock { () -> Bool in
            guard isRunning, didReportControllerAvailability != available else { return false }
            didReportControllerAvailability = available
            return true
        }
        guard shouldReport else { return }
        onControllerAvailability(available)
    }

    private static func connectedGamepads() -> [GCExtendedGamepad] {
        GCController.controllers().compactMap(\.extendedGamepad)
    }

    private func emitCurrentState(allowRedundantSend: Bool = false) {
        guard let gamepad = Self.connectedGamepads().first else {
            // A Steam Controller is invisible to `GCController`, so returning here left the safety
            // timer with nothing to do: `emitSteamSnapshot` only ever emits on change, and the
            // redundancy and keepalive branches both need a repeat of the state already sent. One
            // dropped release on an unreliable channel held the button down in the game for good.
            if allowRedundantSend, let snapshot = lock.withLock({ lastSent }) {
                emit(snapshot, allowRedundantSend: true)
            }
            return
        }
        emit(Snapshot(
            buttons: NativeWebRTCGamepadMonitor.buttons(from: gamepad),
            leftTrigger: gamepad.leftTrigger.value,
            rightTrigger: gamepad.rightTrigger.value,
            leftStickX: gamepad.leftThumbstick.xAxis.value,
            leftStickY: gamepad.leftThumbstick.yAxis.value,
            rightStickX: gamepad.rightThumbstick.xAxis.value,
            rightStickY: gamepad.rightThumbstick.yAxis.value
        ), allowRedundantSend: allowRedundantSend)
    }

    private func emitNeutralState() {
        // Both sources, or unplugging one pad while a Steam controller is still connected would
        // synthesise a release the guest never asked for.
        guard Self.connectedGamepads().isEmpty, SteamControllerHIDMonitor.connectedControllerCount == 0 else { return }
        emit(Snapshot(buttons: [], leftTrigger: 0, rightTrigger: 0, leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0))
    }

    /// Every send takes a fresh sequence number, duplicates included: the host drops any sequence it
    /// has already routed, so a repeat reusing the original's number would achieve nothing.
    private func emit(_ snapshot: Snapshot, allowRedundantSend: Bool = false) {
        let packet = lock.withLock { () -> OPNRemoteCoOpInputPacket? in
            guard isRunning else { return nil }
            let shouldSend = redundancy.shouldSend(
                isChanged: snapshot != lastSent,
                allowRedundantSend: allowRedundantSend,
                nowNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
            guard shouldSend else { return nil }
            lastSent = snapshot
            sequenceNumber &+= 1
            return OPNRemoteCoOpInputPacket(
                participantID: participantID,
                sequenceNumber: sequenceNumber,
                buttons: snapshot.buttons,
                leftTrigger: snapshot.leftTrigger,
                rightTrigger: snapshot.rightTrigger,
                leftStickX: snapshot.leftStickX,
                leftStickY: snapshot.leftStickY,
                rightStickX: snapshot.rightStickX,
                rightStickY: snapshot.rightStickY
            )
        }
        guard let packet else { return }
        send(packet)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
