import AppKit
import Foundation
import IOKit
import IOKit.hid
import os

public enum SteamControllerPreference {
    public static let key = "OpenNOW.Input.SteamControllerSupportEnabled"

    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: key)
    }
}

@MainActor
public final class SteamControllerHIDMonitor {
    public static let shared = SteamControllerHIDMonitor()

    public nonisolated static var connectedControllerCount: Int {
        activeCount.withLock { $0 }
    }

    private nonisolated static let activeCount = OSAllocatedUnfairLock(initialState: 0)
    private static let heartbeatInterval: TimeInterval = 5.0
    private static let featureReportAttempts = 5

    private struct Consumer {
        let controllersChanged: () -> Void
        let inputState: (InputDeviceID, SteamControllerInputSnapshot) -> Void
    }

    private final class DeviceContext {
        let device: IOHIDDevice
        let model: SteamControllerModel
        let deviceID: InputDeviceID
        let reportBuffer: UnsafeMutablePointer<UInt8>
        var snapshot = SteamControllerInputSnapshot()
        var isActive: Bool

        init(device: IOHIDDevice, registryID: UInt64, model: SteamControllerModel, isActive: Bool) {
            self.device = device
            self.model = model
            self.deviceID = InputDeviceID("steam-controller-\(registryID)")
            self.isActive = isActive
            reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: SteamControllerReport.reportLength)
            reportBuffer.initialize(repeating: 0, count: SteamControllerReport.reportLength)
        }

        deinit {
            reportBuffer.deallocate()
        }
    }

    private var manager: IOHIDManager?
    private var devices: [ObjectIdentifier: DeviceContext] = [:]
    private var consumers: [ObjectIdentifier: Consumer] = [:]
    private var permissionRetryObserver: NSObjectProtocol?
    nonisolated(unsafe) private var heartbeatTimer: Timer?

    private init() {}

    public var activeDeviceIDs: [InputDeviceID] {
        devices.values
            .filter(\.isActive)
            .map(\.deviceID)
            .sorted { $0.rawValue < $1.rawValue }
    }

    public func snapshot(for deviceID: InputDeviceID) -> SteamControllerInputSnapshot? {
        devices.values.first { $0.deviceID == deviceID }?.snapshot
    }

    public func register(_ consumer: AnyObject,
                         onControllersChanged: @escaping () -> Void,
                         onInputState: @escaping (InputDeviceID, SteamControllerInputSnapshot) -> Void) {
        consumers[ObjectIdentifier(consumer)] = Consumer(controllersChanged: onControllersChanged, inputState: onInputState)
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

    private func activate() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Int]] = SteamControllerReport.matchedProductIDs.map {
            [
                kIOHIDVendorIDKey: SteamControllerReport.vendorID,
                kIOHIDProductIDKey: $0,
                kIOHIDDeviceUsagePageKey: SteamControllerReport.vendorUsagePage,
                kIOHIDDeviceUsageKey: SteamControllerReport.vendorUsage,
            ]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemoved, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        var openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openStatus == kIOReturnNotPermitted, IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
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
        self.manager = manager
        removeActivationRetryObserver()
        WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.monitor.enabled", level: .info, message: "Steam Controller support enabled.")
    }

    private func deactivate() {
        removeActivationRetryObserver()
        guard let manager else { return }
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        for context in devices.values {
            emitNeutralStateIfNeeded(for: context)
            IOHIDDeviceRegisterInputReportCallback(context.device, context.reportBuffer, SteamControllerReport.reportLength, nil, nil)
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        devices.removeAll()
        self.manager = nil
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
        guard manager == nil else {
            removeActivationRetryObserver()
            return
        }
        guard SteamControllerPreference.isEnabled else {
            removeActivationRetryObserver()
            return
        }
        activate()
    }

    private func removeActivationRetryObserver() {
        if let permissionRetryObserver {
            NotificationCenter.default.removeObserver(permissionRetryObserver)
        }
        permissionRetryObserver = nil
    }

    private static let deviceMatched: IOHIDDeviceCallback = { context, result, _, device in
        guard let context, result == kIOReturnSuccess else { return }
        let monitor = Unmanaged<SteamControllerHIDMonitor>.fromOpaque(context).takeUnretainedValue()
        nonisolated(unsafe) let matchedDevice = device
        MainActor.assumeIsolated { monitor.handleDeviceMatched(matchedDevice) }
    }

    private static let deviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let monitor = Unmanaged<SteamControllerHIDMonitor>.fromOpaque(context).takeUnretainedValue()
        nonisolated(unsafe) let removedDevice = device
        MainActor.assumeIsolated { monitor.handleDeviceRemoved(removedDevice) }
    }

    private static let inputReportReceived: IOHIDReportCallback = { context, result, sender, _, _, _, reportLength in
        guard let context, let sender, result == kIOReturnSuccess else { return }
        let monitor = Unmanaged<SteamControllerHIDMonitor>.fromOpaque(context).takeUnretainedValue()
        nonisolated(unsafe) let reportingDevice = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        MainActor.assumeIsolated { monitor.handleInputReport(device: reportingDevice, length: reportLength) }
    }

    private func handleDeviceMatched(_ device: IOHIDDevice) {
        let productID = intProperty(device, key: kIOHIDProductIDKey) ?? SteamControllerReport.wiredProductID
        guard let model = SteamControllerModel(productID: productID) else { return }
        let isWirelessReceiver = SteamControllerReport.isWirelessReceiver(productID: productID)
        let context = DeviceContext(
            device: device,
            registryID: registryID(of: device),
            model: model,
            isActive: !isWirelessReceiver
        )
        devices[ObjectIdentifier(device)] = context
        IOHIDDeviceRegisterInputReportCallback(
            device,
            context.reportBuffer,
            SteamControllerReport.reportLength,
            Self.inputReportReceived,
            Unmanaged.passUnretained(self).toOpaque()
        )
        disableLizardMode(for: context)
        startHeartbeatIfNeeded()
        publishActiveCount()
        WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.device.matched", level: .info, message: "Steam Controller interface matched.", attributes: ["wireless": String(isWirelessReceiver), "active": String(context.isActive)])
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        guard let context = devices.removeValue(forKey: ObjectIdentifier(device)) else { return }
        emitNeutralStateIfNeeded(for: context)
        IOHIDDeviceRegisterInputReportCallback(device, context.reportBuffer, SteamControllerReport.reportLength, nil, nil)
        if devices.isEmpty {
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
        }
        publishActiveCount()
        WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.device.removed", level: .info, message: "Steam Controller interface removed.")
    }

    private func handleInputReport(device: IOHIDDevice, length: Int) {
        guard let context = devices[ObjectIdentifier(device)] else { return }
        let count = min(max(length, 0), SteamControllerReport.reportLength)
        let report = Array(UnsafeBufferPointer(start: context.reportBuffer, count: count))
        switch SteamControllerReport.parse(report, previous: context.snapshot, model: context.model) {
        case .connected:
            setActive(true, for: context)
            disableLizardMode(for: context)
        case .disconnected:
            emitNeutralStateIfNeeded(for: context)
            setActive(false, for: context)
        case .state(let snapshot):
            setActive(true, for: context)
            guard snapshot != context.snapshot else { return }
            context.snapshot = snapshot
            notifyInputState(context.deviceID, snapshot)
        case .ignored:
            break
        }
    }

    private func emitNeutralStateIfNeeded(for context: DeviceContext) {
        let neutral = SteamControllerInputSnapshot()
        guard context.snapshot != neutral else { return }
        context.snapshot = neutral
        notifyInputState(context.deviceID, neutral)
    }

    private func notifyInputState(_ deviceID: InputDeviceID, _ snapshot: SteamControllerInputSnapshot) {
        for consumer in consumers.values {
            consumer.inputState(deviceID, snapshot)
        }
    }

    private func setActive(_ isActive: Bool, for context: DeviceContext) {
        guard context.isActive != isActive else { return }
        context.isActive = isActive
        publishActiveCount()
        WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.device.presence", level: .info, message: "Steam Controller presence changed.", attributes: ["active": String(isActive)])
    }

    private func publishActiveCount() {
        let count = devices.values.count(where: \.isActive)
        Self.activeCount.withLock { $0 = count }
        for consumer in consumers.values {
            consumer.controllersChanged()
        }
    }

    private func disableLizardMode(for context: DeviceContext) {
        let attempts = context.isActive ? Self.featureReportAttempts : 1
        for report in SteamControllerReport.lizardModeDisableReports(model: context.model) {
            sendFeatureReport(report, to: context.device, attempts: attempts)
        }
    }

    private func startHeartbeatIfNeeded() {
        guard heartbeatTimer == nil else { return }
        let timer = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendHeartbeats() }
        }
        heartbeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func sendHeartbeats() {
        for context in devices.values where context.isActive {
            sendFeatureReport(SteamControllerReport.lizardModeHeartbeatReport(model: context.model), to: context.device, attempts: 1)
        }
    }

    private func sendFeatureReport(_ report: SteamControllerFeatureReport, to device: IOHIDDevice, attempts: Int = SteamControllerHIDMonitor.featureReportAttempts) {
        report.bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for _ in 0..<max(1, attempts) {
                if IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(report.reportID), base, buffer.count) == kIOReturnSuccess {
                    return
                }
            }
        }
    }

    private func registryID(of device: IOHIDDevice) -> UInt64 {
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entryID)
        return entryID
    }

    private func intProperty(_ device: IOHIDDevice, key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }
}
