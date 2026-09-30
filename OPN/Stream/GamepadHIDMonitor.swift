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
        let stopped = state.withLock { state -> GamepadHIDSession? in
            let shouldRead = wantsReading && !state.consumers.isEmpty
            if shouldRead, state.activeSession == nil {
                let session = GamepadHIDSession(queue: queue)
                state.activeSession = session
                session.activate { [weak self] cancelled in self?.finishCancellation(of: cancelled) }
            } else if !shouldRead, let session = state.activeSession {
                state.activeSession = nil
                state.cancellingSessions.append(session)
                return session
            }
            return nil
        }
        stopped?.cancel()
    }

    func snapshots() -> [ObjectIdentifier: ControllerInputSnapshot] {
        guard let session = state.withLock({ $0.activeSession }) else { return [:] }
        return session.snapshots(for: GCController.controllers())
    }

    func pairedControllerIDs() -> Set<ObjectIdentifier> {
        state.withLock { $0.activeSession }?.pairedControllerIDs ?? []
    }

    private func finishCancellation(of session: GamepadHIDSession) {
        state.withLock { $0.cancellingSessions.removeAll { $0 === session } }
    }
}

struct GamepadHIDReading: Sendable {
    let family: GamepadHIDFamily
    var snapshot: ControllerInputSnapshot
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

    func activate(onCancelled: @escaping @Sendable (GamepadHIDSession) -> Void) {
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
        IOHIDManagerActivate(manager)
        if status == kIOReturnSuccess {
            OPNLog.info(.controller, "Gamepad HID reader started")
        } else {
            OPNLog.warning(.controller, "Gamepad HID manager open status=\(status)")
        }
    }

    var pairedControllerIDs: Set<ObjectIdentifier> {
        state.withLock { Set($0.pairing.pairs.keys) }
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
        let (snapshots, pairedCount, previousCount) = state.withLock { state in
            let previousCount = state.pairing.pairs.count
            let devices = state.readings.map { key, reading in
                GamepadHIDPairing<ObjectIdentifier, ObjectIdentifier>.Device(id: key, family: reading.family, buttons: reading.snapshot.buttons)
            }
            state.pairing.update(controllers: candidates, devices: devices)
            let readings = state.readings
            return (state.pairing.pairs.compactMapValues { readings[$0]?.snapshot }, state.pairing.pairs.count, previousCount)
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
        state.withLock { state in
            guard let family = state.families[key],
                  let snapshot = GamepadHIDReport.parse(report, family: family, previous: state.readings[key]?.snapshot) else { return }
            state.readings[key] = GamepadHIDReading(family: family, snapshot: snapshot)
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
        guard let context, let sender, result == kIOReturnSuccess else { return }
        let session = Unmanaged<GamepadHIDSession>.fromOpaque(context).takeUnretainedValue()
        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        session.receive(Array(UnsafeBufferPointer(start: report, count: max(length, 0))), from: device)
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
