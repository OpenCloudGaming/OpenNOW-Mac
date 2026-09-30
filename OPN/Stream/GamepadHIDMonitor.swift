import Foundation
import GameController
import IOKit
import IOKit.hid
import os

/// Reads Xbox, DualSense and DualShock 4 input reports directly, so stick values reach the stream
/// without the deadzone GameController applies. GameController keeps owning connection, player
/// slots, rumble and battery; only the values of a paired controller are replaced.
final class GamepadHIDMonitor: @unchecked Sendable {
    static let shared = GamepadHIDMonitor()

    private struct State: Sendable {
        var consumers: Set<ObjectIdentifier> = []
        var activeSession: GamepadHIDSession?
        var cancellingSessions: [GamepadHIDSession] = []
    }

    private let queue = DispatchQueue(label: "io.github.opencloudgaming.opennow.gamepadhid", qos: .userInteractive)
    private let state = OSAllocatedUnfairLock(initialState: State())

    private init() {}

    func acquire(_ consumer: ObjectIdentifier) {
        state.withLock { _ = $0.consumers.insert(consumer) }
        refreshActivation()
    }

    func release(_ consumer: ObjectIdentifier) {
        state.withLock { _ = $0.consumers.remove(consumer) }
        refreshActivation()
    }

    func refreshActivation() {
        let wantsReading = ControllerInputBackendPreference.load() == .gamepadAPI
        let queue = queue
        let stopped = state.withLock { state -> [GamepadHIDSession] in
            let shouldRead = wantsReading && !state.consumers.isEmpty
            if shouldRead, state.activeSession == nil {
                let session = GamepadHIDSession(queue: queue)
                guard session.activate(onCancelled: { [weak self] cancelled in self?.finishCancellation(of: cancelled) }) else {
                    // The manager never opened, so nothing was activated and no callback can fire:
                    // dropping the session here is safe. Leaving it in `activeSession` made one
                    // failed open permanent for the rest of the stream — `refreshActivation` saw a
                    // session already present and never tried again. No session means the next
                    // activation retries.
                    return []
                }
                state.activeSession = session
            } else if !shouldRead, let session = state.activeSession {
                state.activeSession = nil
                state.cancellingSessions.append(session)
                return [session]
            }
            return []
        }
        stopped.forEach { $0.cancel() }
    }

    func snapshots() -> [ObjectIdentifier: ControllerInputSnapshot] {
        guard let session = state.withLock({ $0.activeSession }) else { return [:] }
        return session.snapshots(for: GCController.controllers())
    }

    /// The controllers the wire will send without the client deadzone. Named for what it is used
    /// for rather than for pairing alone: a pair whose reports have expired is not being read raw.
    func pairedControllerIDs() -> Set<ObjectIdentifier> {
        state.withLock { $0.activeSession }?.rawReadControllerIDs ?? []
    }

    private func finishCancellation(of session: GamepadHIDSession) {
        state.withLock { $0.cancellingSessions.removeAll { $0 === session } }
    }
}

struct GamepadHIDReading: Sendable {
    /// A pad that stops reporting — asleep, out of range, battery flat — must not keep replaying its
    /// last report: a button held at that moment would read as stuck down, and a stick as held off
    /// centre, for the rest of the session. 500 ms is far longer than any live pad's report
    /// interval, so only a pad that has genuinely gone quiet expires.
    static let maximumAge = DispatchTimeInterval.milliseconds(500)

    let family: GamepadHIDFamily
    var snapshot: ControllerInputSnapshot
    var receivedAt: DispatchTime

    func isFresh(at now: DispatchTime) -> Bool {
        receivedAt + Self.maximumAge > now
    }
}

struct GamepadHIDSessionState: Sendable {
    var families: [ObjectIdentifier: GamepadHIDFamily] = [:]
    var readings: [ObjectIdentifier: GamepadHIDReading] = [:]
    var pairing = GamepadHIDPairing<ObjectIdentifier, ObjectIdentifier>()
}

/// One activation of the reader. Devices already connected are matched synchronously inside
/// `IOHIDManagerActivate` on the caller's thread, later ones on the queue, so all state is locked.
final class GamepadHIDSession: @unchecked Sendable {
    private let manager: IOHIDManager
    private let queue: DispatchQueue
    private let state = OSAllocatedUnfairLock(initialState: GamepadHIDSessionState())

    init(queue: DispatchQueue) {
        self.queue = queue
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, Self.deviceMatching())
    }

    /// Opens the manager and starts delivering reports. Returns false when the open failed, in
    /// which case nothing was activated and the caller must not treat the session as live.
    func activate(onCancelled: @escaping @Sendable (GamepadHIDSession) -> Void) -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemoved, context)
        // A queue-scheduled device rejects callbacks registered after its activation: reports are
        // taken at the manager, and the manager is opened before it is activated.
        IOHIDManagerRegisterInputReportCallback(manager, Self.reportReceived, context)
        IOHIDManagerSetDispatchQueue(manager, queue)
        IOHIDManagerSetCancelHandler(manager) { [weak self] in
            guard let self else { return }
            self.state.withLock { $0 = GamepadHIDSessionState() }
            onCancelled(self)
        }
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            // Reported, not swallowed: without Input Monitoring the open fails every time, and the
            // only visible symptom is that the Gamepad API option does nothing.
            OPNLog.warning(.controller, "Gamepad HID manager open status=\(status); will retry on the next activation")
            OPNStreamTelemetry.capture("input.gamepad.hid.unavailable", level: .warning,
                                       message: "Gamepad HID reader could not open, so raw stick values are unavailable.",
                                       attributes: ["status": String(status)])
            return false
        }
        IOHIDManagerActivate(manager)
        OPNLog.info(.controller, "Gamepad HID reader started")
        return true
    }

    /// Controller identities whose values are currently coming from this reader: paired, and with a
    /// report recent enough to be the pad's live state. `snapshots(for:)` applies the same two
    /// predicates, so a pad cannot be reported as read through the Gamepad API while the wire is
    /// actually deadzoning its GameController values.
    var rawReadControllerIDs: Set<ObjectIdentifier> {
        let now = DispatchTime.now()
        return state.withLock { state in
            Set(state.pairing.pairs.compactMap { controller, device in
                guard let reading = state.readings[device], reading.isFresh(at: now) else { return nil }
                return controller
            })
        }
    }

    func cancel() {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerCancel(manager)
        OPNLog.info(.controller, "Gamepad HID reader stopped")
    }

    func snapshots(for controllers: [GCController]) -> [ObjectIdentifier: ControllerInputSnapshot] {
        let candidates = controllers.compactMap { controller -> GamepadHIDPairing<ObjectIdentifier, ObjectIdentifier>.Controller? in
            guard let gamepad = controller.extendedGamepad else { return nil }
            return .init(id: ObjectIdentifier(controller),
                         family: GamepadHIDFamily(controller: controller, gamepad: gamepad),
                         buttons: NativeGamepadMonitor.buttons(from: gamepad))
        }
        let now = DispatchTime.now()
        let (snapshots, pairedCount, previousCount) = state.withLock { state in
            let previousCount = state.pairing.pairs.count
            // Pairing still sees every reading, including a stale one: dropping a pair because a pad
            // went quiet for a moment would make two identical pads re-pair from scratch, which
            // needs a button press.
            let devices = state.readings.map { key, reading in
                GamepadHIDPairing<ObjectIdentifier, ObjectIdentifier>.Device(id: key, family: reading.family, buttons: reading.snapshot.buttons)
            }
            state.pairing.update(controllers: candidates, devices: devices)
            let readings = state.readings
            return (state.pairing.pairs.compactMapValues { device -> ControllerInputSnapshot? in
                guard let reading = readings[device], reading.isFresh(at: now) else { return nil }
                return reading.snapshot
            }, state.pairing.pairs.count, previousCount)
        }
        if pairedCount != previousCount {
            OPNLog.info(.controller, "Gamepad HID paired \(pairedCount) controller(s)")
        }
        return snapshots
    }

    private func attach(_ device: IOHIDDevice) {
        let vendorID = Self.intProperty(device, key: kIOHIDVendorIDKey) ?? 0
        let productID = Self.intProperty(device, key: kIOHIDProductIDKey) ?? 0
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        guard let family = GamepadHIDFamily(vendorID: vendorID, productID: productID, transport: transport) else { return }
        let key = ObjectIdentifier(device)
        let isNew = state.withLock { $0.families.updateValue(family, forKey: key) == nil }
        guard isNew else { return }
        OPNLog.info(.controller, "Gamepad HID device vendor=0x\(String(format: "%04X", vendorID)) product=0x\(String(format: "%04X", productID)) transport=\(transport) family=\(family.rawValue)")
        OPNStreamTelemetry.capture("input.gamepad.hid.device", level: .info, message: "Gamepad HID device attached.",
                                   attributes: ["family": family.rawValue, "product": String(format: "%04X", productID), "transport": transport])
    }

    private func detach(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        state.withLock { state in
            state.families.removeValue(forKey: key)
            state.readings.removeValue(forKey: key)
        }
    }

    private func receive(_ report: [UInt8], from device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        let now = DispatchTime.now()
        state.withLock { state in
            guard let family = state.families[key] else { return }
            // A stale report is not a usable "previous": the legacy Xbox guide-bit carry-over would
            // otherwise resurrect a button from a pad that has since gone quiet.
            let previous = state.readings[key].flatMap { $0.isFresh(at: now) ? $0.snapshot : nil }
            guard let snapshot = GamepadHIDReport.parse(report, family: family, previous: previous) else { return }
            state.readings[key] = GamepadHIDReading(family: family, snapshot: snapshot, receivedAt: now)
        }
    }

    private static let deviceMatched: IOHIDDeviceCallback = { context, result, _, device in
        guard let context, result == kIOReturnSuccess else { return }
        Unmanaged<GamepadHIDSession>.fromOpaque(context).takeUnretainedValue().attach(device)
    }

    private static let deviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<GamepadHIDSession>.fromOpaque(context).takeUnretainedValue().detach(device)
    }

    private static let reportReceived: IOHIDReportCallback = { context, result, sender, _, _, report, length in
        // `length` is CFIndex and the report pointer is not optional in this SDK, but a zero-length
        // callback is still not a report: `Array(UnsafeBufferPointer(...))` over it would be empty.
        guard let context, let sender, result == kIOReturnSuccess, length > 0 else { return }
        let session = Unmanaged<GamepadHIDSession>.fromOpaque(context).takeUnretainedValue()
        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        session.receive(Array(UnsafeBufferPointer(start: report, count: length)), from: device)
    }

    private static func deviceMatching() -> CFArray {
        [GamepadHIDFamily.sonyVendorID, GamepadHIDFamily.microsoftVendorID].map { vendorID in
            [
                kIOHIDVendorIDKey: vendorID,
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad,
            ]
        } as CFArray
    }

    private static func intProperty(_ device: IOHIDDevice, key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }
}

extension GamepadHIDFamily {
    init?(controller: GCController, gamepad: GCExtendedGamepad) {
        switch gamepad {
        case is GCDualSenseGamepad:
            self = .dualSense
        case is GCDualShockGamepad:
            self = .dualShock4
        case is GCXboxGamepad:
            self = .xbox
        default:
            let identity = "\(controller.vendorName ?? "") \(controller.productCategory)".lowercased()
            if identity.contains("dualsense") {
                self = .dualSense
            } else if identity.contains("dualshock") {
                self = .dualShock4
            } else if identity.contains("xbox") {
                self = .xbox
            } else {
                return nil
            }
        }
    }
}
