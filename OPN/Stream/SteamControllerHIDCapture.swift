//  Taking exclusive control of a controller for streaming: seizing the device, turning lizard
//  mode off, the keepalive heartbeat, and the property reads that identify a device.
//  Split out of SteamControllerHIDMonitor.swift.
//

import AppKit
import Combine
import Foundation
import IOKit
import IOKit.hid
import os

extension SteamControllerHIDMonitor {
    /// Capture with a trackpad bound to mouse/scroll behavior: the vendor interface is
    /// seized so the firmware's lizard mouse/keyboard events never reach macOS,
    /// while the firmware profile itself stays enabled — the pads keep their
    /// native haptics and the raw reports drive the stream. When seizing fails
    /// (or no trackpad wants raw capture) the firmware emulation is disabled instead.
    func configureCapture(for context: DeviceContext) {
        let wantsRawTrackpadCapture = mappingProvider.activeProfile?.wantsRawTrackpadCapture ?? false
        if wantsRawTrackpadCapture, reopenVendorDevice(context, seize: true) {
            context.isSeized = true
            enableLizardMode(for: context)
        } else {
            context.isSeized = false
            disableLizardMode(for: context)
        }
    }

    func restoreAfterCapture(for context: DeviceContext) {
        if context.isSeized {
            context.isSeized = false
            _ = reopenVendorDevice(context, seize: false)
        } else {
            enableLizardMode(for: context)
        }
    }

    func reopenVendorDevice(_ context: DeviceContext, seize: Bool) -> Bool {
        let device = context.device
        IOHIDDeviceRegisterInputReportCallback(device, context.reportBuffer, SteamControllerReport.reportLength, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        let options = IOOptionBits(seize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone)
        let status = IOHIDDeviceOpen(device, options)
        if status == kIOReturnSuccess {
            registerVendorReportCallback(for: context)
            return true
        }
        guard seize else {
            captureDeviceOpenFailure(interface: "vendor", context: context, status: status)
            return false
        }
        OpenNOWLog.warning(.controller, "Seize failed status=0x\(String(format: "%08X", status)) — falling back to lizard-off capture")
        let reopenStatus = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if reopenStatus == kIOReturnSuccess {
            registerVendorReportCallback(for: context)
        } else {
            captureDeviceOpenFailure(interface: "vendor", context: context, status: reopenStatus)
        }
        return false
    }

    func disableLizardMode(for context: DeviceContext) {
        let attempts = context.isActive ? Self.featureReportAttempts : 1
        for report in SteamControllerReport.lizardModeDisableReports(model: context.model) {
            sendFeatureReport(report, to: context.device, attempts: attempts)
        }
    }

    func enableLizardMode(for context: DeviceContext) {
        let attempts = context.isActive ? Self.featureReportAttempts : 1
        for report in SteamControllerReport.lizardModeEnableReports(model: context.model) {
            sendFeatureReport(report, to: context.device, attempts: attempts)
        }
    }

    func startHeartbeatIfNeeded() {
        guard heartbeatTimer == nil else { return }
        let timer = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendHeartbeats() }
        }
        heartbeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func sendHeartbeats() {
        guard isInputCaptureActive else { return }
        for context in devices.values where context.isActive && !context.isSeized {
            sendFeatureReport(SteamControllerReport.lizardModeHeartbeatReport(model: context.model), to: context.device, attempts: 1)
        }
    }

    func sendFeatureReport(_ report: SteamControllerFeatureReport, to device: IOHIDDevice, attempts: Int = SteamControllerHIDMonitor.featureReportAttempts) {
        report.bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for _ in 0..<max(1, attempts) {
                if IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(report.reportID), base, buffer.count) == kIOReturnSuccess {
                    return
                }
            }
        }
    }

    public func sendRumble(deviceID: InputDeviceID, leftAmplitude: UInt16, rightAmplitude: UInt16) {
        guard let context = devices.values.first(where: { $0.deviceID == deviceID }) else { return }
        let report = SteamControllerReport.rumbleReport(model: context.model, leftAmplitude: leftAmplitude, rightAmplitude: rightAmplitude)
        sendFeatureReport(report, to: context.device, attempts: 3)
    }

    func stringProperty(_ device: IOHIDDevice, key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    func intProperty(_ device: IOHIDDevice, key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    func registryID(of device: IOHIDDevice) -> UInt64 {
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entryID)
        return entryID
    }

    func controllerID(of device: IOHIDDevice, isWirelessReceiver: Bool) -> UInt64 {
        isWirelessReceiver ? registryID(of: device) : usbDeviceRegistryID(of: device)
    }

    func usbDeviceRegistryID(of device: IOHIDDevice) -> UInt64 {
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
