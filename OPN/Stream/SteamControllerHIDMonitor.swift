import AppKit
import Combine
import Foundation
import IOKit
import IOKit.hid
import os

public enum SteamControllerPreference {
    public static let key = "OpenNOW.Input.SteamControllerSupportEnabled"

    public static var isEnabled: Bool {
        OPNAppPreferenceStorage.standard.bool(forKey: key)
    }
}

/// Superseded by per-pad `SteamControllerPadSettings` in `SteamControllerMappingProfile`.
/// `key` stays just long enough for `SteamControllerMappingStore`'s one-time migration.
public enum SteamControllerTrackpadMousePreference {
    public static let key = "OpenNOW.Input.SteamControllerTrackpadMouseEnabled"
}

public enum SteamControllerPermissionError: Error, LocalizedError {
    case missingBundleIdentifier
    case tccutilFailed(exitCode: Int, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .missingBundleIdentifier:
            return "OpenNOW bundle identifier is unavailable."
        case let .tccutilFailed(exitCode, stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "tccutil reset failed (exit \(exitCode)).\(trimmed.isEmpty ? "" : " " + trimmed)"
        }
    }
}

@MainActor
public final class SteamControllerHIDMonitor: ObservableObject {
    public static let shared = SteamControllerHIDMonitor()

    @Published public private(set) var inputMonitoringPermissionGranted = false
    @Published public private(set) var isMonitorActive = false
    @Published public private(set) var isInputCaptureActive = false
    // `internal(set)` rather than `private(set)`: the monitor's own extensions in the neighbouring
    // files write these, and the public contract is unchanged — nothing outside the module can.
    @Published public internal(set) var matchedDeviceCount = 0
    @Published public internal(set) var batteryLevels: [InputDeviceID: UInt8] = [:]
    @Published public internal(set) var batteryCharging: [InputDeviceID: Bool] = [:]
    
    public private(set) var allDevices: [DeviceInfo] = []
    
    func updateAllDevices() {
        allDevices = devices.values.map { context in
            let productID = intProperty(context.device, key: kIOHIDProductIDKey) ?? 0
            let isWirelessReceiver = SteamControllerReport.isWirelessReceiver(productID: productID)
            return DeviceInfo(
                id: context.deviceID.rawValue,
                productID: productID,
                isWirelessReceiver: isWirelessReceiver,
                isActive: context.isActive,
                model: "\(context.model)"
            )
        }
        objectWillChange.send()
    }

    public nonisolated static var connectedControllerCount: Int {
        activeCount.withLock { $0 }
    }

    /// Lowercased `kIOHIDProductKey` of every pad this monitor currently owns (e.g. "steam
    /// controller puck"). GameController republishes the same physical device and usually reuses
    /// the HID product string as its `vendorName`, so this is what lets the gamepad monitor spot
    /// the duplicate without hardcoding a guess at the name.
    public nonisolated static var claimedProductNames: Set<String> {
        claimedNames.withLock { $0 }
    }

    nonisolated static let claimedNames = OSAllocatedUnfairLock(initialState: Set<String>())
    nonisolated static let activeCount = OSAllocatedUnfairLock(initialState: 0)
    static let heartbeatInterval: TimeInterval = 5.0
    static let featureReportAttempts = 5
    static let powerOffCombo: GamepadButtons = [.mode, .north]

    struct Consumer {
        let controllersChanged: () -> Void
        let inputState: (InputDeviceID, SteamControllerInputSnapshot) -> Void
        let batteryLevel: (InputDeviceID, UInt8) -> Void
    }

    final class DeviceContext {
        let device: IOHIDDevice
        let model: SteamControllerModel
        let deviceID: InputDeviceID
        let reportBuffer: UnsafeMutablePointer<UInt8>
        let controllerID: UInt64
        var snapshot = SteamControllerInputSnapshot()
        var deckSnapshot = SteamControllerInputSnapshot()
        var mergedSnapshot = SteamControllerInputSnapshot()
        var isActive: Bool
        var isSeized = false
        var batteryLevel: UInt8?
        var gamepadDevice: IOHIDDevice?
        var gamepadReportBuffer: UnsafeMutablePointer<UInt8>?
        var powerOffComboSent = false

        init(device: IOHIDDevice, controllerID: UInt64, model: SteamControllerModel, isActive: Bool) {
            self.device = device
            self.controllerID = controllerID
            self.model = model
            self.deviceID = InputDeviceID("steam-controller-\(controllerID)")
            self.isActive = isActive
            reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: SteamControllerReport.reportLength)
            reportBuffer.initialize(repeating: 0, count: SteamControllerReport.reportLength)
        }

        deinit {
            reportBuffer.deallocate()
            gamepadReportBuffer?.deallocate()
        }
    }

    private var manager: IOHIDManager?
    var devices: [ObjectIdentifier: DeviceContext] = [:]
    var gamepadDeviceContexts: [ObjectIdentifier: DeviceContext] = [:]
    var pendingGamepadDevices: [UInt64: IOHIDDevice] = [:]
    var consumers: [ObjectIdentifier: Consumer] = [:]
    private var captureRequesters: Set<ObjectIdentifier> = []
    private var permissionRetryObserver: NSObjectProtocol?
    nonisolated(unsafe) var heartbeatTimer: Timer?
    /// Rumble feature reports written this process, for the rate-limited per-interface log.
    var rumbleReportsSent = 0
    /// Writes that came from a new command rather than the 40 ms keepalive resend.
    var rumbleCommandsWritten = 0
    /// The 40 ms keep-alive re-sends for each controller currently rumbling.
    var rumbleResendTasks: [InputDeviceID: Task<Void, Never>] = [:]

    let mappingProvider: any SteamControllerMappingProviding

    init(mappingProvider: any SteamControllerMappingProviding = SteamControllerMappingStore.shared) {
        self.mappingProvider = mappingProvider
    }

    public struct DeviceInfo: Identifiable {
        public let id: String
        public let productID: Int
        public let isWirelessReceiver: Bool
        public let isActive: Bool
        public let model: String
    }

    public var activeDeviceIDs: [InputDeviceID] {
        // A composite controller (e.g. Steam Controller 2 / Triton) exposes several HID interfaces
        // that share one controllerID. Collapse them so one physical pad is one slot, not two.
        var seen = Set<UInt64>()
        return devices.values
            .filter(\.isActive)
            // Within one controllerID keep the interface that carries the gamepad reports.
            .sorted { ($0.controllerID, $0.gamepadDevice == nil ? 1 : 0) < ($1.controllerID, $1.gamepadDevice == nil ? 1 : 0) }
            .filter { seen.insert($0.controllerID).inserted }
            .map(\.deviceID)
            .sorted { $0.rawValue < $1.rawValue }
    }

    public func snapshot(for deviceID: InputDeviceID) -> SteamControllerInputSnapshot? {
        // A composite controller's interfaces share a deviceID and its reports can land on any of
        // them, so merge across all of them rather than trusting one — picking a single interface
        // silently drops whichever half of the input arrives on the other.
        let snapshots = devices.values.filter { $0.deviceID == deviceID }.map(\.mergedSnapshot)
        guard !snapshots.isEmpty else { return nil }
        let empty = SteamControllerInputSnapshot()
        return snapshots.reduce(into: empty) { merged, snapshot in
            merged.buttons.formUnion(snapshot.buttons)
            merged.leftTrigger = max(merged.leftTrigger, snapshot.leftTrigger)
            merged.rightTrigger = max(merged.rightTrigger, snapshot.rightTrigger)
            if abs(snapshot.leftStickX) > abs(merged.leftStickX) { merged.leftStickX = snapshot.leftStickX }
            if abs(snapshot.leftStickY) > abs(merged.leftStickY) { merged.leftStickY = snapshot.leftStickY }
            if abs(snapshot.rightStickX) > abs(merged.rightStickX) { merged.rightStickX = snapshot.rightStickX }
            if abs(snapshot.rightStickY) > abs(merged.rightStickY) { merged.rightStickY = snapshot.rightStickY }
            if snapshot.leftPad != empty.leftPad { merged.leftPad = snapshot.leftPad }
            if snapshot.rightPad != empty.rightPad { merged.rightPad = snapshot.rightPad }
        }
    }

    /// Re-applies the capture configuration after the active mapping profile changes, so
    /// editing trackpad behavior mid-stream takes effect immediately.
    public func refreshCaptureConfiguration() {
        guard isInputCaptureActive else { return }
        let wantsRawTrackpadCapture = mappingProvider.activeProfile?.wantsRawTrackpadCapture ?? false
        for context in devices.values {
            if wantsRawTrackpadCapture {
                guard !context.isSeized else { continue }
                configureCapture(for: context)
            } else if context.isSeized {
                _ = reopenVendorDevice(context, seize: false)
                context.isSeized = false
                disableLizardMode(for: context)
            }
        }
    }

    public func register(_ consumer: AnyObject,
                         onControllersChanged: @escaping () -> Void,
                         onInputState: @escaping (InputDeviceID, SteamControllerInputSnapshot) -> Void,
                         onBatteryLevel: @escaping (InputDeviceID, UInt8) -> Void = { _, _ in }) {
        consumers[ObjectIdentifier(consumer)] = Consumer(controllersChanged: onControllersChanged, inputState: onInputState, batteryLevel: onBatteryLevel)
    }

    public func unregister(_ consumer: AnyObject) {
        consumers.removeValue(forKey: ObjectIdentifier(consumer))
    }

    public func unregister(key: ObjectIdentifier) {
        consumers.removeValue(forKey: key)
    }

    public func setEnabled(_ enabled: Bool) {
        enabled ? activate() : deactivate()
    }

    /// While at least one requester holds input capture, the controller's built-in
    /// keyboard/mouse emulation (lizard mode) is suppressed so raw reports drive
    /// gamepad input. When the last requester ends capture, emulation is restored
    /// and the trackpads control the system cursor again.
    public func beginInputCapture(_ requester: AnyObject) {
        captureRequesters.insert(ObjectIdentifier(requester))
        updateInputCaptureState()
    }

    public func endInputCapture(_ requester: AnyObject) {
        endInputCapture(key: ObjectIdentifier(requester))
    }

    public func endInputCapture(key: ObjectIdentifier) {
        captureRequesters.remove(key)
        updateInputCaptureState()
    }

    func isInputCaptureLeased(by requester: AnyObject) -> Bool {
        captureRequesters.contains(ObjectIdentifier(requester))
    }

    private func updateInputCaptureState() {
        let shouldCapture = !captureRequesters.isEmpty
        guard shouldCapture != isInputCaptureActive else { return }
        isInputCaptureActive = shouldCapture
        OpenNOWLog.info(.controller, "Input capture \(shouldCapture ? "began" : "ended")")
        if shouldCapture {
            for context in devices.values {
                configureCapture(for: context)
            }
            if !devices.isEmpty {
                startHeartbeatIfNeeded()
            }
        } else {
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
            for context in devices.values {
                restoreAfterCapture(for: context)
            }
        }
        WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.capture", level: .info, message: "Steam Controller input capture changed.", attributes: ["active": String(shouldCapture)])
    }

    public func requestInputMonitoringPermission() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        schedulePermissionCheckOnActivation()
    }
    
    private func schedulePermissionCheckOnActivation() {
        guard permissionRetryObserver == nil else { return }
        permissionRetryObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkInputMonitoringPermission()
                self?.removeActivationRetryObserver()
            }
        }
    }

    public func checkInputMonitoringPermission() {
        if #available(macOS 10.15, *) {
            let preflightStatus = CGPreflightListenEventAccess()
            inputMonitoringPermissionGranted = preflightStatus
        } else {
            let testManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatching(testManager, [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad,
            ] as CFDictionary)
            let status = IOHIDManagerOpen(testManager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerClose(testManager, IOOptionBits(kIOHIDOptionsTypeNone))
            inputMonitoringPermissionGranted = (status == kIOReturnSuccess)
        }
    }

public nonisolated func resetInputMonitoringPermission(thenRelaunch: Bool) throws {
    try Self.resetInputMonitoringPermissionViaTccUtil(thenRelaunch: thenRelaunch)
}

public nonisolated static func resetInputMonitoringPermissionViaTccUtil(thenRelaunch: Bool) throws {
    guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
        throw SteamControllerPermissionError.missingBundleIdentifier
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
    process.arguments = ["reset", "All", bundleID]
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: data, encoding: .utf8) ?? "Unknown tccutil error."
        throw SteamControllerPermissionError.tccutilFailed(exitCode: Int(process.terminationStatus), stderr: message)
    }
    WebRTCMediaTelemetry.capture(
        "webrtc.input.steamcontroller.input_monitoring.reset",
        level: .info,
        message: "Input Monitoring permissions reset via tccutil.",
        attributes: ["bundleID": bundleID, "relaunch": String(thenRelaunch)]
    )
    guard thenRelaunch else { return }
    let appURL = Bundle.main.bundleURL
    Task { @MainActor in
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        relaunch.arguments = ["-n", appURL.path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}

    func captureDeviceOpenFailure(interface: String, context: DeviceContext, status: Int32) {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let baseAttributes: [String: String] = [
            "interface": interface,
            "bundleID": bundleID,
            "model": String(describing: context.model),
            "controllerID": String(format: "%016X", context.controllerID)
        ]
        if status == kIOReturnNotPermitted {
            var attributes = baseAttributes
            attributes["remediation"] = "open_experimental_steam_controller_support_reset_permission"
            WebRTCMediaTelemetry.capture(
                "webrtc.input.steamcontroller.device.open.permission_denied",
                level: .warning,
                message: "Input Monitoring permission denied while opening Steam Controller \(interface) interface. Use Settings → Experimental Features → Steam Controller Support → Reset Permission, then grant access on next launch.",
                attributes: attributes
            )
        } else {
            var attributes = baseAttributes
            attributes["status"] = String(status)
            WebRTCMediaTelemetry.capture(
                "webrtc.input.steamcontroller.device.open.failed",
                level: .warning,
                message: "Unable to open Steam Controller \(interface) interface.",
                attributes: attributes
            )
        }
    }

    private func activate() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let vendorMatching: [[String: Int]] = SteamControllerReport.matchedProductIDs.map {
            [
                kIOHIDVendorIDKey: SteamControllerReport.vendorID,
                kIOHIDProductIDKey: $0,
                kIOHIDDeviceUsagePageKey: SteamControllerReport.vendorUsagePage,
                kIOHIDDeviceUsageKey: SteamControllerReport.vendorUsage,
            ]
        }
        let gamepadMatching: [[String: Int]] = SteamControllerReport.matchedProductIDs.flatMap { productID in
            [SteamControllerReport.gamepadUsage, 4].map { usage in
                [
                    kIOHIDVendorIDKey: SteamControllerReport.vendorID,
                    kIOHIDProductIDKey: productID,
                    kIOHIDDeviceUsagePageKey: SteamControllerReport.gamepadUsagePage,
                    kIOHIDDeviceUsageKey: usage,
                ]
            }
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, (vendorMatching + gamepadMatching) as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemoved, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        var openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openStatus == kIOReturnNotPermitted {
            inputMonitoringPermissionGranted = false
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard openStatus == kIOReturnSuccess else {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            let permissionDenied = openStatus == kIOReturnNotPermitted
            if permissionDenied {
                scheduleActivationRetryAfterPermissionChange()
            }
            WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.open.failed", level: .warning, message: permissionDenied ? "Steam Controller support needs the Input Monitoring permission." : "Unable to open Steam Controller HID manager.", attributes: ["status": String(openStatus), "permissionDenied": String(permissionDenied)])
            return
        }
        inputMonitoringPermissionGranted = true
        isMonitorActive = true
        self.manager = manager
        scheduleActivationRetryAfterPermissionChange()
        OpenNOWLog.info(.controller, "Monitor activated")
        WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.monitor.enabled", level: .info, message: "Steam Controller support enabled.")
    }

    private func deactivate() {
        removeActivationRetryObserver()
        guard let manager else { return }
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        for context in devices.values {
            cancelPowerOffCombo(for: context)
            emitNeutralStateIfNeeded(for: context)
            if isInputCaptureActive {
                enableLizardMode(for: context)
            }
            closeGamepadDevice(for: context)
            IOHIDDeviceRegisterInputReportCallback(context.device, context.reportBuffer, SteamControllerReport.reportLength, nil, nil)
            IOHIDDeviceClose(context.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        pendingGamepadDevices.removeAll()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        devices.removeAll()
        gamepadDeviceContexts.removeAll()
        self.manager = nil
        isMonitorActive = false
        matchedDeviceCount = 0
        batteryLevels.removeAll()
        batteryCharging.removeAll()
        publishActiveCount()
        WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.monitor.disabled", level: .info, message: "Steam Controller support disabled.")
    }

    private func scheduleActivationRetryAfterPermissionChange() {
        guard permissionRetryObserver == nil else { return }
        permissionRetryObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryActivationAfterPermissionChange() }
        }
    }

    private func retryActivationAfterPermissionChange() {
        checkInputMonitoringPermission()
        if !inputMonitoringPermissionGranted, isMonitorActive {
            deactivate()
        }
        guard manager == nil else {
            if !SteamControllerPreference.isEnabled {
                removeActivationRetryObserver()
            }
            return
        }
        guard SteamControllerPreference.isEnabled else {
            removeActivationRetryObserver()
            return
        }
        if inputMonitoringPermissionGranted {
            activate()
        }
    }

    private func removeActivationRetryObserver() {
        if let permissionRetryObserver {
            NotificationCenter.default.removeObserver(permissionRetryObserver)
        }
        permissionRetryObserver = nil
    }

}
