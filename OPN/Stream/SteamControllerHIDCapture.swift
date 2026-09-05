//  Taking exclusive control of a controller for streaming: seizing the device, turning lizard mode
//  off, the keepalive heartbeat, and the property reads that identify a device.
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

    @discardableResult
    func sendFeatureReport(_ report: SteamControllerFeatureReport, to device: IOHIDDevice, attempts: Int = SteamControllerHIDMonitor.featureReportAttempts) -> IOReturn {
        report.bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return kIOReturnBadArgument }
            var status = kIOReturnError
            for _ in 0..<max(1, attempts) {
                status = IOHIDDeviceSetReport(device, report.kind == .output ? kIOHIDReportTypeOutput : kIOHIDReportTypeFeature, CFIndex(report.reportID), base, buffer.count)
                if status == kIOReturnSuccess { return status }
            }
            return status
        }
    }

    /// Rumble goes to every HID interface that carries this controller, the way the lizard-mode
    /// reports do: a wireless puck exposes several interfaces under one device ID and only one of
    /// them forwards vendor commands to the pad — `first(where:)` on a dictionary picked one at
    /// random, which is why seat rumble reached this method and moved nothing (2026-09-05). The
    /// per-interface result is logged for the first few commands so a refused report is visible.
    public func sendRumble(deviceID: InputDeviceID, leftAmplitude: UInt16, rightAmplitude: UInt16) {
        writeRumble(deviceID: deviceID, leftAmplitude: leftAmplitude, rightAmplitude: rightAmplitude)
        // The 2026 controller's firmware cuts the motors ~50 ms after the last command, so a rumble
        // that should last is re-sent every 40 ms (SDL's `TRITON_RUMBLE_RESEND_INTERVAL_MS`) until
        // the caller sends zeros or a newer state. One write gave a single imperceptible blip.
        rumbleResendTasks.removeValue(forKey: deviceID)?.cancel()
        guard leftAmplitude > 0 || rightAmplitude > 0 else { return }
        rumbleResendTasks[deviceID] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(SteamControllerReport.tritonRumbleResendMilliseconds))
                guard !Task.isCancelled, let self else { return }
                self.writeRumble(deviceID: deviceID, leftAmplitude: leftAmplitude, rightAmplitude: rightAmplitude, resend: true)
            }
        }
    }

    private func writeRumble(deviceID: InputDeviceID, leftAmplitude: UInt16, rightAmplitude: UInt16, resend: Bool = false) {
        let contexts = devices.values.filter { $0.deviceID == deviceID }
        guard !contexts.isEmpty else {
            if !resend { OpenNOWLog.warning(.controller, "Rumble: no HID interface for \(deviceID.rawValue)") }
            rumbleResendTasks.removeValue(forKey: deviceID)?.cancel()
            return
        }
        rumbleReportsSent += 1
        // Resends outnumber real commands 25 to 1 at the 40 ms cadence, so counting them together
        // meant the log showed the first six *resends* of one rumble and then almost nothing.
        // Only the commands that actually ask for motion: a rumble is bracketed by zero writes,
        // and sampling "the first twelve writes" caught the silence around it instead of it.
        let isMotion = leftAmplitude > 0 || rightAmplitude > 0
        if !resend, isMotion { rumbleCommandsWritten += 1 }
        let shouldLog = !resend && isMotion && (rumbleCommandsWritten <= 12 || rumbleCommandsWritten % 50 == 0)
        for context in contexts {
            let report = SteamControllerReport.rumbleReport(model: context.model, leftAmplitude: leftAmplitude, rightAmplitude: rightAmplitude)
            let status = sendFeatureReport(report, to: context.device, attempts: 3)
            if shouldLog {
                OpenNOWLog.info(.controller, String(format: "Rumble #%d %@ model=%@ active=%d left=%d right=%d reportID=%d bytes=%@ -> 0x%08x",
                                                    rumbleReportsSent, deviceID.rawValue, String(describing: context.model), context.isActive ? 1 : 0,
                                                    Int(leftAmplitude), Int(rightAmplitude), report.reportID,
                                                    report.bytes.prefix(12).map { String(format: "%02x", $0) }.joined(), status))
            }
        }
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
