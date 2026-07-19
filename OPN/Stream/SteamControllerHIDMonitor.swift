import AppKit
import Combine
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
public final class SteamControllerHIDMonitor: ObservableObject {
    public static let shared = SteamControllerHIDMonitor()

    @Published public private(set) var inputMonitoringPermissionGranted = false
    @Published public private(set) var isMonitorActive = false
    @Published public private(set) var matchedDeviceCount = 0
    
    public private(set) var allDevices: [DeviceInfo] = []
    
    private func updateAllDevices() {
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
        let controllerID: UInt64
        var snapshot = SteamControllerInputSnapshot()
        var deckSnapshot = SteamControllerInputSnapshot()
        var mergedSnapshot = SteamControllerInputSnapshot()
        var isActive: Bool
        var gamepadDevice: IOHIDDevice?
        var gamepadReportBuffer: UnsafeMutablePointer<UInt8>?

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
    private var devices: [ObjectIdentifier: DeviceContext] = [:]
    private var gamepadDeviceContexts: [ObjectIdentifier: DeviceContext] = [:]
    private var pendingGamepadDevices: [UInt64: IOHIDDevice] = [:]
    private var consumers: [ObjectIdentifier: Consumer] = [:]
    private var permissionRetryObserver: NSObjectProtocol?
    nonisolated(unsafe) private var heartbeatTimer: Timer?

    private init() {}

    public struct DeviceInfo: Identifiable {
        public let id: String
        public let productID: Int
        public let isWirelessReceiver: Bool
        public let isActive: Bool
        public let model: String
    }

    public var activeDeviceIDs: [InputDeviceID] {
        devices.values
            .filter(\.isActive)
            .map(\.deviceID)
            .sorted { $0.rawValue < $1.rawValue }
    }

    public func snapshot(for deviceID: InputDeviceID) -> SteamControllerInputSnapshot? {
        devices.values.first { $0.deviceID == deviceID }?.mergedSnapshot
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

    public func requestInputMonitoringPermission() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        checkInputMonitoringPermission()
    }

    public func checkInputMonitoringPermission() {
        let testManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let status = IOHIDManagerOpen(testManager, IOOptionBits(kIOHIDOptionsTypeNone))
        inputMonitoringPermissionGranted = (status == kIOReturnSuccess)
        if status == kIOReturnSuccess {
            IOHIDManagerClose(testManager, IOOptionBits(kIOHIDOptionsTypeNone))
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
        removeActivationRetryObserver()
        print("[SteamController] monitor activated")
        WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.monitor.enabled", level: .info, message: "Steam Controller support enabled.")
    }

    private func deactivate() {
        removeActivationRetryObserver()
        guard let manager else { return }
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        for context in devices.values {
            emitNeutralStateIfNeeded(for: context)
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
        let usagePage = intProperty(device, key: kIOHIDDeviceUsagePageKey) ?? 0
        let usage = intProperty(device, key: kIOHIDDeviceUsageKey) ?? 0
        let isWirelessReceiver = SteamControllerReport.isWirelessReceiver(productID: productID)
        let controllerID = controllerID(of: device, isWirelessReceiver: isWirelessReceiver)

        print("[SteamController] matched device: productID=0x\(String(format: "%04X", productID)) usagePage=0x\(String(format: "%04X", usagePage)) usage=0x\(String(format: "%04X", usage)) controllerID=0x\(String(format: "%016X", controllerID)) wirelessReceiver=\(isWirelessReceiver)")

        if usagePage == SteamControllerReport.gamepadUsagePage {
            handleGamepadDeviceMatched(device, controllerID: controllerID)
            return
        }

        let context = DeviceContext(
            device: device,
            controllerID: controllerID,
            model: model,
            isActive: !isWirelessReceiver
        )
        devices[ObjectIdentifier(device)] = context
        matchedDeviceCount = devices.count
        updateAllDevices()

        if let gamepadDevice = pendingGamepadDevices.removeValue(forKey: controllerID) {
            associateGamepadDevice(gamepadDevice, with: context)
        }

        openVendorDevice(device, context: context)
        disableLizardMode(for: context)
        startHeartbeatIfNeeded()
        publishActiveCount()
        WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.device.matched", level: .info, message: "Steam Controller vendor interface matched.", attributes: ["wireless": String(isWirelessReceiver), "active": String(context.isActive)])
    }

    private func handleGamepadDeviceMatched(_ device: IOHIDDevice, controllerID: UInt64) {
        if let context = devices.values.first(where: { $0.controllerID == controllerID }) {
            associateGamepadDevice(device, with: context)
            print("[SteamController] gamepad interface associated with vendor controllerID=0x\(String(format: "%016X", controllerID))")
        } else {
            pendingGamepadDevices[controllerID] = device
            print("[SteamController] gamepad interface pending for controllerID=0x\(String(format: "%016X", controllerID))")
        }
        WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.gamepad.matched", level: .info, message: "Steam Controller gamepad interface matched.")
    }

    private func openVendorDevice(_ device: IOHIDDevice, context: DeviceContext) {
        let deviceOpenStatus = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))

        var finalDeviceOpenStatus = deviceOpenStatus
        if deviceOpenStatus == kIOReturnNotPermitted {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            finalDeviceOpenStatus = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        guard finalDeviceOpenStatus == kIOReturnSuccess else {
            WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.device.open.failed", level: .warning, message: "Unable to open Steam Controller vendor interface.", attributes: ["status": String(finalDeviceOpenStatus)])
            return
        }

        IOHIDDeviceRegisterInputReportCallback(
            device,
            context.reportBuffer,
            SteamControllerReport.reportLength,
            Self.inputReportReceived,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func associateGamepadDevice(_ gamepadDevice: IOHIDDevice, with context: DeviceContext) {
        guard context.gamepadDevice == nil else { return }
        context.gamepadDevice = gamepadDevice
        gamepadDeviceContexts[ObjectIdentifier(gamepadDevice)] = context
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: SteamControllerReport.reportLength)
        buffer.initialize(repeating: 0, count: SteamControllerReport.reportLength)
        context.gamepadReportBuffer = buffer

        var openStatus = IOHIDDeviceOpen(gamepadDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        if openStatus == kIOReturnNotPermitted {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            openStatus = IOHIDDeviceOpen(gamepadDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard openStatus == kIOReturnSuccess else {
            WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.gamepad.open.failed", level: .warning, message: "Unable to open Steam Controller gamepad interface.", attributes: ["status": String(openStatus)])
            return
        }

        IOHIDDeviceRegisterInputReportCallback(
            gamepadDevice,
            buffer,
            SteamControllerReport.reportLength,
            Self.inputReportReceived,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func closeGamepadDevice(for context: DeviceContext) {
        if let gamepadDevice = context.gamepadDevice, let buffer = context.gamepadReportBuffer {
            IOHIDDeviceRegisterInputReportCallback(gamepadDevice, buffer, SteamControllerReport.reportLength, nil, nil)
            IOHIDDeviceClose(gamepadDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            gamepadDeviceContexts.removeValue(forKey: ObjectIdentifier(gamepadDevice))
            context.gamepadDevice = nil
        }
        context.gamepadReportBuffer?.deallocate()
        context.gamepadReportBuffer = nil
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        if let context = devices.removeValue(forKey: ObjectIdentifier(device)) {
            matchedDeviceCount = devices.count
            updateAllDevices()
            emitNeutralStateIfNeeded(for: context)
            closeGamepadDevice(for: context)
            IOHIDDeviceRegisterInputReportCallback(device, context.reportBuffer, SteamControllerReport.reportLength, nil, nil)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            if devices.isEmpty {
                heartbeatTimer?.invalidate()
                heartbeatTimer = nil
            }
            publishActiveCount()
            WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.device.removed", level: .info, message: "Steam Controller vendor interface removed.")
            return
        }

        if let context = gamepadDeviceContexts.removeValue(forKey: ObjectIdentifier(device)) {
            closeGamepadDevice(for: context)
            WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.gamepad.removed", level: .info, message: "Steam Controller gamepad interface removed.")
            return
        }

        let productID = intProperty(device, key: kIOHIDProductIDKey) ?? SteamControllerReport.wiredProductID
        let isWirelessReceiver = SteamControllerReport.isWirelessReceiver(productID: productID)
        let controllerID = controllerID(of: device, isWirelessReceiver: isWirelessReceiver)
        if pendingGamepadDevices.removeValue(forKey: controllerID) != nil {
            WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.gamepad.pending.removed", level: .info, message: "Steam Controller pending gamepad interface removed.")
            print("[SteamController] pending gamepad interface removed controllerID=0x\(String(format: "%016X", controllerID))")
        }
    }

    private func handleInputReport(device: IOHIDDevice, length: Int) {
        guard let context = devices[ObjectIdentifier(device)] ?? gamepadDeviceContexts[ObjectIdentifier(device)] else { return }
        let isGamepad = context.gamepadDevice === device
        let reportBuffer = isGamepad ? context.gamepadReportBuffer : context.reportBuffer
        guard let reportBuffer = reportBuffer else { return }

        let count = min(max(length, 0), SteamControllerReport.reportLength)
        let report = Array(UnsafeBufferPointer(start: reportBuffer, count: count))
        let isDeckStateReport = report.first == SteamControllerReport.deckStateReportID
        if isGamepad, !isDeckStateReport, report.first != 0 {
            print("[SteamController] gamepad input report: id=0x\(String(format: "%02X", report.first ?? 0)) length=\(report.count)")
        }
        let event = isDeckStateReport
            ? SteamControllerReport.parseDeckState(report, previous: context.deckSnapshot)
            : SteamControllerReport.parse(report, previous: context.snapshot, model: context.model)

        switch event {
        case .connected:
            setActive(true, for: context)
            disableLizardMode(for: context)
        case .disconnected:
            emitNeutralStateIfNeeded(for: context)
            setActive(false, for: context)
        case .state(let snapshot):
            setActive(true, for: context)
            if isDeckStateReport {
                context.deckSnapshot = snapshot
            } else {
                context.snapshot = snapshot
            }
            let merged = mergedSnapshot(for: context)
            guard merged != context.mergedSnapshot else { return }
            if merged.buttons != context.mergedSnapshot.buttons {
                if isDeckStateReport, report.count >= 16 {
                    let bits = UInt64(report[8]) | (UInt64(report[9]) << 8) | (UInt64(report[10]) << 16) | (UInt64(report[11]) << 24) | (UInt64(report[12]) << 32) | (UInt64(report[13]) << 40) | (UInt64(report[14]) << 48) | (UInt64(report[15]) << 56)
                    print("[SteamController] buttons changed: deck raw=0x\(String(format: "%016X", bits)) parsed=\(merged.buttons)")
                } else if context.model == .triton, report.count >= 6 {
                    let bits = UInt32(report[2]) | (UInt32(report[3]) << 8) | (UInt32(report[4]) << 16) | (UInt32(report[5]) << 24)
                    print("[SteamController] buttons changed: triton raw=0x\(String(format: "%08X", bits)) parsed=\(merged.buttons)")
                } else {
                    print("[SteamController] buttons changed: \(merged.buttons)")
                }
            }
            context.mergedSnapshot = merged
            notifyInputState(context.deviceID, merged)
        case .ignored:
            break
        }
    }

    private func mergedSnapshot(for context: DeviceContext) -> SteamControllerInputSnapshot {
        var merged = context.snapshot
        merged.buttons.formUnion(context.deckSnapshot.buttons)
        return merged
    }

    private func emitNeutralStateIfNeeded(for context: DeviceContext) {
        let neutral = SteamControllerInputSnapshot()
        guard context.mergedSnapshot != neutral else { return }
        context.snapshot = neutral
        context.deckSnapshot = neutral
        context.mergedSnapshot = neutral
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

    private func intProperty(_ device: IOHIDDevice, key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private func registryID(of device: IOHIDDevice) -> UInt64 {
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entryID)
        return entryID
    }

    private func controllerID(of device: IOHIDDevice, isWirelessReceiver: Bool) -> UInt64 {
        isWirelessReceiver ? registryID(of: device) : usbDeviceRegistryID(of: device)
    }

    private func usbDeviceRegistryID(of device: IOHIDDevice) -> UInt64 {
        let hidService = IOHIDDeviceGetService(device)
        var service = hidService
        var parent: io_registry_entry_t = 0
        defer {
            if service != hidService {
                IOObjectRelease(service)
            }
        }
        while true {
            var className = [Int8](repeating: 0, count: 128)
            IOObjectGetClass(service, &className)
            let nullIndex = className.firstIndex(of: 0) ?? className.endIndex
            let bytes = className[..<nullIndex].map { UInt8(bitPattern: $0) }
            let classNameString = String(decoding: bytes, as: UTF8.self)
            if classNameString == "IOUSBHostDevice" || classNameString == "IOUSBDevice" || classNameString == "AppleUSBDevice" {
                var entryID: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(service, &entryID) == kIOReturnSuccess {
                    return entryID
                }
            }
            let status = IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent)
            guard status == kIOReturnSuccess else {
                break
            }
            if service != hidService {
                IOObjectRelease(service)
            }
            service = parent
        }
        return UInt64(intProperty(device, key: kIOHIDLocationIDKey) ?? 0)
    }
}
