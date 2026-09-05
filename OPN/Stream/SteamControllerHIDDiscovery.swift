//  IOHID device discovery: matching a controller's vendor and gamepad interfaces, opening them, and
//  tearing them down again.
//

import AppKit
import Combine
import Foundation
import IOKit
import IOKit.hid
import os

extension SteamControllerHIDMonitor {
    static let deviceMatched: IOHIDDeviceCallback = { context, result, _, device in
        guard let context, result == kIOReturnSuccess else { return }
        let monitor = Unmanaged<SteamControllerHIDMonitor>.fromOpaque(context).takeUnretainedValue()
        nonisolated(unsafe) let matchedDevice = device
        MainActor.assumeIsolated { monitor.handleDeviceMatched(matchedDevice) }
    }

    static let deviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let monitor = Unmanaged<SteamControllerHIDMonitor>.fromOpaque(context).takeUnretainedValue()
        nonisolated(unsafe) let removedDevice = device
        MainActor.assumeIsolated { monitor.handleDeviceRemoved(removedDevice) }
    }

    static let inputReportReceived: IOHIDReportCallback = { context, result, sender, _, _, _, reportLength in
        guard let context, let sender, result == kIOReturnSuccess else { return }
        let monitor = Unmanaged<SteamControllerHIDMonitor>.fromOpaque(context).takeUnretainedValue()
        nonisolated(unsafe) let reportingDevice = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        MainActor.assumeIsolated { monitor.handleInputReport(device: reportingDevice, length: reportLength) }
    }

    func handleDeviceMatched(_ device: IOHIDDevice) {
        let productID = intProperty(device, key: kIOHIDProductIDKey) ?? SteamControllerReport.wiredProductID
        guard let model = SteamControllerModel(productID: productID) else { return }
        let usagePage = intProperty(device, key: kIOHIDDeviceUsagePageKey) ?? 0
        let usage = intProperty(device, key: kIOHIDDeviceUsageKey) ?? 0
        let isWirelessReceiver = SteamControllerReport.isWirelessReceiver(productID: productID)
        let controllerID = controllerID(of: device, isWirelessReceiver: isWirelessReceiver)

        OpenNOWLog.info(.controller, "Matched device: productID=0x\(String(format: "%04X", productID)) usagePage=0x\(String(format: "%04X", usagePage)) usage=0x\(String(format: "%04X", usage)) controllerID=0x\(String(format: "%016X", controllerID)) wirelessReceiver=\(isWirelessReceiver)")

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
        if isInputCaptureActive {
            configureCapture(for: context)
            startHeartbeatIfNeeded()
        }
        publishActiveCount()
        WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.device.matched", level: .info, message: "Steam Controller vendor interface matched.", attributes: ["wireless": String(isWirelessReceiver), "active": String(context.isActive)])
    }

    func handleGamepadDeviceMatched(_ device: IOHIDDevice, controllerID: UInt64) {
        if let context = devices.values.first(where: { $0.controllerID == controllerID }) {
            associateGamepadDevice(device, with: context)
            OpenNOWLog.debug(.controller, "Gamepad interface associated with vendor controllerID=0x\(String(format: "%016X", controllerID))")
        } else {
            pendingGamepadDevices[controllerID] = device
            OpenNOWLog.debug(.controller, "Gamepad interface pending for controllerID=0x\(String(format: "%016X", controllerID))")
        }
        WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.gamepad.matched", level: .info, message: "Steam Controller gamepad interface matched.")
    }

    func openVendorDevice(_ device: IOHIDDevice, context: DeviceContext) {
        let deviceOpenStatus = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))

        var finalDeviceOpenStatus = deviceOpenStatus
        if deviceOpenStatus == kIOReturnNotPermitted {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            finalDeviceOpenStatus = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        guard finalDeviceOpenStatus == kIOReturnSuccess else {
            captureDeviceOpenFailure(interface: "vendor", context: context, status: finalDeviceOpenStatus)
            return
        }

        registerVendorReportCallback(for: context)
    }

    func registerVendorReportCallback(for context: DeviceContext) {
        IOHIDDeviceRegisterInputReportCallback(
            context.device,
            context.reportBuffer,
            SteamControllerReport.reportLength,
            Self.inputReportReceived,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    func associateGamepadDevice(_ gamepadDevice: IOHIDDevice, with context: DeviceContext) {
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
            captureDeviceOpenFailure(interface: "gamepad", context: context, status: openStatus)
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

    func closeGamepadDevice(for context: DeviceContext) {
        if let gamepadDevice = context.gamepadDevice, let buffer = context.gamepadReportBuffer {
            IOHIDDeviceRegisterInputReportCallback(gamepadDevice, buffer, SteamControllerReport.reportLength, nil, nil)
            IOHIDDeviceClose(gamepadDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            gamepadDeviceContexts.removeValue(forKey: ObjectIdentifier(gamepadDevice))
            context.gamepadDevice = nil
        }
        context.gamepadReportBuffer?.deallocate()
        context.gamepadReportBuffer = nil
    }

    func handleDeviceRemoved(_ device: IOHIDDevice) {
        if let context = devices.removeValue(forKey: ObjectIdentifier(device)) {
            matchedDeviceCount = devices.count
            updateAllDevices()
            cancelPowerOffCombo(for: context)
            emitNeutralStateIfNeeded(for: context)
            batteryLevels.removeValue(forKey: context.deviceID)
            batteryCharging.removeValue(forKey: context.deviceID)
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
            OpenNOWLog.debug(.controller, "Pending gamepad interface removed controllerID=0x\(String(format: "%016X", controllerID))")
        }
    }
}
