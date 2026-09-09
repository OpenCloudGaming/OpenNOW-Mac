//  Raw (unaccelerated) mouse counts: an IOHID reader that runs beside AppKit's pointer stream
//  while a stream holds the pointer, so aim comes from what the mouse reported rather than from
//  what the macOS acceleration curve made of it.
//

import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
import os

/// Relative HID counts summed since the last drain. Counts, not points: this is what the mouse
/// reported over the wire, before macOS applied its pointer-acceleration curve.
struct OPNRawMouseDelta: Equatable, Sendable {
    var x = 0
    var y = 0

    var isZero: Bool { x == 0 && y == 0 }
}

/// The X and Y halves of one physical mouse report arrive as two separate IOHID element callbacks,
/// and IOHIDManager exposes no report-boundary hook to pair them with. This sums both axes until
/// somebody drains, which pairs them by construction and needs no timing heuristic.
struct OPNRawMouseDeltaAccumulator {
    private(set) var pending = OPNRawMouseDelta()

    mutating func add(x: Int) {
        pending.x = Self.saturatingSum(pending.x, x)
    }

    mutating func add(y: Int) {
        pending.y = Self.saturatingSum(pending.y, y)
    }

    /// Nil rather than a zero delta: a no-motion report is not worth a packet, the same rule
    /// `emitMouseMove(deltaX:deltaY:)` applies to the AppKit path.
    mutating func drain() -> OPNRawMouseDelta? {
        defer { pending = OPNRawMouseDelta() }
        return pending.isZero ? nil : pending
    }

    mutating func reset() {
        pending = OPNRawMouseDelta()
    }

    /// A drain that never comes — a mouse dragged across the desk while the app is not reading —
    /// must not trap on overflow. Int32 is the clamp because the seat takes Int16 anyway, so the
    /// saturated value is already far past anything that survives the sensitivity stage.
    static func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflowed) = lhs.addingReportingOverflow(rhs)
        guard !overflowed else { return rhs > 0 ? Int(Int32.max) : Int(Int32.min) }
        return max(Int(Int32.min), min(Int(Int32.max), sum))
    }
}

/// Why raw capture is not reading counts. Both outcomes leave the AppKit delta path in charge, so
/// neither is fatal to the stream — they only decide what the telemetry line says.
enum OPNRawMouseCaptureFailure: String, Sendable {
    case permissionDenied
    case managerOpenFailed

    var message: String {
        switch self {
        case .permissionDenied:
            "Raw mouse input needs the Input Monitoring permission; using accelerated deltas."
        case .managerOpenFailed:
            "Unable to open the raw mouse HID manager; using accelerated deltas."
        }
    }
}

enum OPNRawMouseCaptureOutcome: Equatable, Sendable {
    case started
    case alreadyRunning
    case failed(OPNRawMouseCaptureFailure)
}

/// What the raw source has to offer for one AppKit motion event.
enum OPNRawMouseMotion: Equatable, Sendable {
    /// Counts collected since the last read. These replace the event's accelerated delta.
    case counts(OPNRawMouseDelta)
    /// Capture is live and a matched mouse reported moments ago, but this event's counts have not
    /// landed on the HID queue yet. Sending the accelerated delta now would send the same movement
    /// a second time when they do, so this event contributes nothing and the next one carries both.
    case pending
    /// Nothing raw on offer: capture is off, or the motion came from a device the reader does not
    /// read — a trackpad, or a Steam Controller, which reaches the stream by its own path. The
    /// AppKit delta is the only source of that movement and must still be sent.
    case unavailable
}

/// Reads relative counts straight from the mice, bypassing the pointer-acceleration curve that
/// `NSEvent.deltaX/deltaY` has already been through.
///
/// The counts are *pulled*, by the same AppKit motion event that would otherwise have carried the
/// accelerated delta, rather than pushed from the HID callback. That keeps the emit cadence, the
/// packet rate and the main-actor traffic exactly as they are on the accelerated path — only the
/// numbers change — and it makes double movement structurally impossible instead of a matter of
/// getting a guard right. Coalescing is free as a consequence: whatever a mouse reported between
/// two motion events is one summed pair, which is what the accelerated delta was too.
///
/// One reader for the process: only one view can hold the pointer at a time, and two managers
/// matching the same mice would each be handed the same counts.
final class OPNRawMouseHIDMonitor: @unchecked Sendable {
    static let shared = OPNRawMouseHIDMonitor()

    /// How long after the last accepted report an empty drain still means "these counts are in
    /// flight" rather than "this movement came from somewhere else".
    ///
    /// The window is global, not per device: `NSEvent` carries no usable HID identity for a motion
    /// event, so there is nothing to match a report against the event that arrives next. Every
    /// nanosecond of it is therefore time in which a *second* pointing device's motion is swallowed
    /// as if it were the first device's counts arriving late. 25 ms keeps a comfortable three
    /// periods of margin over the 8 ms report interval of a 125 Hz mouse — a legitimately in-flight
    /// report is routinely 8-9 ms old, which is why this cannot simply be shrunk to one period.
    static let inFlightWindowNanoseconds: UInt64 = 25_000_000

    private let queue = DispatchQueue(label: "io.github.opencloudgaming.opennow.rawmouse", qos: .userInteractive)
    private var lock = os_unfair_lock_s()
    private var activeManager: IOHIDManager?
    /// Managers between `IOHIDManagerCancel` and their cancel handler. IOHIDManager.h requires the
    /// reference to outlive the cancellation, so dropping it at `stop()` would be a use-after-free
    /// of whatever the queue is still draining.
    private var cancellingManagers: [IOHIDManager] = []
    private var accumulator = OPNRawMouseDeltaAccumulator()
    private var deviceAcceptance: [ObjectIdentifier: Bool] = [:]
    private var lastReportUptimeNanoseconds: UInt64 = 0

    private init() {}

    var isCapturing: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return activeManager != nil
    }

    /// Takes everything the mice reported since the last call. Called from the main thread, once
    /// per AppKit motion event.
    func takeMotion() -> OPNRawMouseMotion {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard activeManager != nil else { return .unavailable }
        if let delta = accumulator.drain() { return .counts(delta) }
        let inFlight = Self.isReportInFlight(lastReportUptimeNanoseconds: lastReportUptimeNanoseconds,
                                             uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
        return inFlight ? .pending : .unavailable
    }

    /// The timestamp is deliberately left standing after a drain: clearing it would let the two
    /// element callbacks of one physical report — X drained, Y still on the queue — read as a
    /// finished movement and send the same motion twice, which is the whole reason it is recorded.
    static func isReportInFlight(lastReportUptimeNanoseconds: UInt64, uptimeNanoseconds: UInt64) -> Bool {
        guard lastReportUptimeNanoseconds > 0, uptimeNanoseconds >= lastReportUptimeNanoseconds else { return false }
        return uptimeNanoseconds - lastReportUptimeNanoseconds < inFlightWindowNanoseconds
    }

    /// Opens the HID manager. Never prompts: a TCC panel raised mid-stream steals focus and drops
    /// the pointer lock that just asked for this, so a missing grant is reported and the caller
    /// stays on the accelerated deltas.
    @discardableResult
    func start() -> OPNRawMouseCaptureOutcome {
        guard !isCapturing else { return .alreadyRunning }
        guard CGPreflightListenEventAccess() else { return .failed(.permissionDenied) }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, Self.deviceMatching())
        IOHIDManagerSetInputValueMatchingMultiple(manager, Self.elementMatching())
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemoved, context)
        IOHIDManagerRegisterInputValueCallback(manager, Self.inputValueReceived, context)
        // Queue rather than run loop: a 1000 Hz mouse would otherwise land a thousand callbacks a
        // second on the thread that also drives the Metal presentation.
        IOHIDManagerSetDispatchQueue(manager, queue)
        IOHIDManagerSetCancelHandler(manager) { [weak self] in
            self?.finishCancellation(of: manager)
        }
        IOHIDManagerActivate(manager)
        let openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openStatus == kIOReturnSuccess else {
            cancel(manager)
            OpenNOWLog.warning(.controller, "Raw mouse HID manager open failed status=\(openStatus)")
            return .failed(openStatus == kIOReturnNotPermitted ? .permissionDenied : .managerOpenFailed)
        }
        os_unfair_lock_lock(&lock)
        activeManager = manager
        resetPendingCountsLocked()
        os_unfair_lock_unlock(&lock)
        OpenNOWLog.info(.controller, "Raw mouse capture started")
        return .started
    }

    func stop() {
        os_unfair_lock_lock(&lock)
        guard let manager = activeManager else {
            os_unfair_lock_unlock(&lock)
            return
        }
        activeManager = nil
        resetPendingCountsLocked()
        os_unfair_lock_unlock(&lock)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        cancel(manager)
        OpenNOWLog.info(.controller, "Raw mouse capture stopped")
    }

    /// Which pointing devices contribute raw counts. Everything excluded here still moves the
    /// stream pointer through the AppKit path, so an exclusion costs acceleration, never motion.
    ///
    /// - The Steam Controller presents as a Generic Desktop mouse in lizard mode, and its trackpad
    ///   already reaches the seat as Int16 deltas through `SteamControllerTrackpadMouseTranslator`.
    ///   Reading it here would move the pointer twice.
    /// - Apple's trackpads — the built-in one and the Magic devices — publish a mouse collection
    ///   whose relative X/Y are the multitouch driver's processed output rather than device counts,
    ///   so there is nothing raw to gain and the gesture-shaped deltas would be scaled as if there
    ///   were.
    static func acceptsDevice(vendorID: Int, isBuiltIn: Bool) -> Bool {
        guard !isBuiltIn else { return false }
        return vendorID != SteamControllerReport.vendorID && vendorID != appleVendorID
    }

    private static let appleVendorID = 0x05AC

    private static let deviceMatched: IOHIDDeviceCallback = { context, result, _, device in
        guard let context, result == kIOReturnSuccess else { return }
        let monitor = Unmanaged<OPNRawMouseHIDMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.evaluate(device)
    }

    private static let deviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let monitor = Unmanaged<OPNRawMouseHIDMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.forgetDevice(device)
    }

    private static let inputValueReceived: IOHIDValueCallback = { context, result, _, value in
        guard let context, result == kIOReturnSuccess else { return }
        let monitor = Unmanaged<OPNRawMouseHIDMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.handle(value)
    }

    private static func deviceMatching() -> CFArray {
        [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer]
        ] as CFArray
    }

    /// Keeps buttons, wheel and everything else out of the value callback: only the two axes are
    /// ever delivered.
    private static func elementMatching() -> CFArray {
        [
            [kIOHIDElementUsagePageKey: kHIDPage_GenericDesktop, kIOHIDElementUsageKey: kHIDUsage_GD_X],
            [kIOHIDElementUsagePageKey: kHIDPage_GenericDesktop, kIOHIDElementUsageKey: kHIDUsage_GD_Y]
        ] as CFArray
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        // Absolute digitizers and tablets also publish Generic Desktop X/Y, but theirs are screen
        // coordinates: taken as deltas they would inject four-digit flicks.
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_GenericDesktop),
              IOHIDElementIsRelative(element) else { return }
        let counts = IOHIDValueGetIntegerValue(value)
        guard counts != 0, isAccepted(IOHIDElementGetDevice(element)) else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard activeManager != nil else { return }
        switch IOHIDElementGetUsage(element) {
        case UInt32(kHIDUsage_GD_X):
            accumulator.add(x: counts)
        case UInt32(kHIDUsage_GD_Y):
            // HID reports Y positive downwards, which is the seat's origin too, so the counts go
            // through unflipped exactly as the AppKit deltas do.
            accumulator.add(y: counts)
        default:
            return
        }
        lastReportUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    }

    private func isAccepted(_ device: IOHIDDevice) -> Bool {
        let identifier = ObjectIdentifier(device)
        os_unfair_lock_lock(&lock)
        let cached = deviceAcceptance[identifier]
        os_unfair_lock_unlock(&lock)
        if let cached { return cached }
        return evaluate(device)
    }

    @discardableResult
    private func evaluate(_ device: IOHIDDevice) -> Bool {
        let vendorID = Self.intProperty(device, key: kIOHIDVendorIDKey) ?? 0
        let productID = Self.intProperty(device, key: kIOHIDProductIDKey) ?? 0
        let isBuiltIn = Self.boolProperty(device, key: kIOHIDBuiltInKey) ?? false
        let accepted = Self.acceptsDevice(vendorID: vendorID, isBuiltIn: isBuiltIn)
        os_unfair_lock_lock(&lock)
        let firstSighting = deviceAcceptance.updateValue(accepted, forKey: ObjectIdentifier(device)) == nil
        os_unfair_lock_unlock(&lock)
        if firstSighting {
            OpenNOWLog.info(.controller, "Raw mouse device vendor=0x\(String(format: "%04X", vendorID)) product=0x\(String(format: "%04X", productID)) builtIn=\(isBuiltIn) accepted=\(accepted)")
        }
        return accepted
    }

    private func forgetDevice(_ device: IOHIDDevice) {
        os_unfair_lock_lock(&lock)
        deviceAcceptance.removeValue(forKey: ObjectIdentifier(device))
        os_unfair_lock_unlock(&lock)
    }

    private func cancel(_ manager: IOHIDManager) {
        os_unfair_lock_lock(&lock)
        cancellingManagers.append(manager)
        os_unfair_lock_unlock(&lock)
        IOHIDManagerCancel(manager)
    }

    private func finishCancellation(of manager: IOHIDManager) {
        os_unfair_lock_lock(&lock)
        cancellingManagers.removeAll { $0 === manager }
        os_unfair_lock_unlock(&lock)
    }

    private func resetPendingCountsLocked() {
        accumulator.reset()
        deviceAcceptance.removeAll()
        lastReportUptimeNanoseconds = 0
    }

    private static func intProperty(_ device: IOHIDDevice, key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private static func boolProperty(_ device: IOHIDDevice, key: String) -> Bool? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.boolValue
    }
}
