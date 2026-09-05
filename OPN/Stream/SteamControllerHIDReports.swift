//  Turning input reports into published controller state, plus the battery and power-off paths that
//  ride the same reports.
//

import AppKit
import Combine
import Foundation
import IOKit
import IOKit.hid
import os

extension SteamControllerHIDMonitor {
    func handleInputReport(device: IOHIDDevice, length: Int) {
        guard let context = devices[ObjectIdentifier(device)] ?? gamepadDeviceContexts[ObjectIdentifier(device)] else { return }
        let isGamepad = context.gamepadDevice === device
        let reportBuffer = isGamepad ? context.gamepadReportBuffer : context.reportBuffer
        guard let reportBuffer = reportBuffer else { return }

        let count = min(max(length, 0), SteamControllerReport.reportLength)
        let report = Array(UnsafeBufferPointer(start: reportBuffer, count: count))
        // TEMP: raw report dump to locate the SC2 button bytes. Logs distinct reports (deduped by
        // content) up to a cap so a button press is visible in the raw bytes.
        let isDeckStateReport = report.first == SteamControllerReport.deckStateReportID
        if isGamepad, !isDeckStateReport, report.first != 0 {
            OpenNOWLog.debug(.controller, "Gamepad input report: id=0x\(String(format: "%02X", report.first ?? 0)) length=\(report.count)")
        }
        let event = isDeckStateReport
            ? SteamControllerReport.parseDeckState(report, previous: context.deckSnapshot)
            : SteamControllerReport.parse(report, previous: context.snapshot, model: context.model)

        switch event {
        case .connected:
            setActive(true, for: context)
            if isInputCaptureActive {
                disableLizardMode(for: context)
            }
        case .disconnected:
            emitNeutralStateIfNeeded(for: context)
            setActive(false, for: context)
        case .state(let snapshot):
            applyState(snapshot, context: context, report: report, isDeckStateReport: isDeckStateReport)
        case .battery(let level, let charging):
            context.batteryLevel = level
            batteryLevels[context.deviceID] = level
            batteryCharging[context.deviceID] = charging
            notifyBatteryLevel(context.deviceID, level)
        case .ignored:
            break
        }
    }

    /// Folds a parsed input snapshot into the device's merged state and publishes it when it
    /// actually changed.
    func applyState(_ snapshot: SteamControllerInputSnapshot,
                            context: DeviceContext,
                            report: [UInt8],
                            isDeckStateReport: Bool) {
        setActive(true, for: context)
        if isDeckStateReport {
            context.deckSnapshot = snapshot
        } else {
            context.snapshot = snapshot
        }
        let merged = mergedSnapshot(for: context)
        evaluatePowerOffCombo(for: context, buttons: merged.buttons)
        guard merged != context.mergedSnapshot else { return }
        if merged.buttons != context.mergedSnapshot.buttons {
            logButtonChange(merged.buttons, context: context, report: report, isDeckStateReport: isDeckStateReport)
        }
        context.mergedSnapshot = merged
        notifyInputState(context.deviceID, merged)
    }

    /// Raw report bytes alongside the parsed buttons: our parse reads only a few bytes, so a bit
    /// past them (grips, extra pads) would otherwise be silently dropped, and the full hex lets a
    /// one-button-at-a-time capture find it.
    func logButtonChange(_ buttons: GamepadButtons,
                                 context: DeviceContext,
                                 report: [UInt8],
                                 isDeckStateReport: Bool) {
        if isDeckStateReport, report.count >= 16 {
            let bits = UInt64(report[8]) | (UInt64(report[9]) << 8) | (UInt64(report[10]) << 16) | (UInt64(report[11]) << 24) | (UInt64(report[12]) << 32) | (UInt64(report[13]) << 40) | (UInt64(report[14]) << 48) | (UInt64(report[15]) << 56)
            OpenNOWLog.debug(.controller, "Buttons changed: deck raw=0x\(String(format: "%016X", bits)) parsed=\(buttons)")
        } else if context.model == .triton, report.count >= 6 {
            let bits = UInt32(report[2]) | (UInt32(report[3]) << 8) | (UInt32(report[4]) << 16) | (UInt32(report[5]) << 24)
            let hex = report.map { String(format: "%02x", $0) }.joined()
            OpenNOWLog.debug(.controller, "Buttons changed: triton raw=0x\(String(format: "%08X", bits)) parsed=\(buttons) len=\(report.count) full=\(hex)")
        } else {
            OpenNOWLog.debug(.controller, "Buttons changed: \(buttons)")
        }
    }

    func mergedSnapshot(for context: DeviceContext) -> SteamControllerInputSnapshot {
        var merged = context.snapshot
        merged.buttons.formUnion(context.deckSnapshot.buttons)
        return merged
    }

    func evaluatePowerOffCombo(for context: DeviceContext, buttons: GamepadButtons) {
        guard buttons.isSuperset(of: Self.powerOffCombo), !context.powerOffComboSent else { return }
        context.powerOffComboSent = true
        powerOff(context)
    }

    func powerOff(_ context: DeviceContext) {
        let report = SteamControllerReport.powerOffReport(model: context.model)
        sendFeatureReport(report, to: context.device, attempts: Self.featureReportAttempts)
        OpenNOWLog.info(.controller, "Power-off combo (Steam+Y) triggered for controllerID=0x\(String(format: "%016X", context.controllerID))")
        WebRTCMediaTelemetry.capture(
            "webrtc.input.steamcontroller.poweroff.combo",
            level: .info,
            message: "Steam+Y power-off combo triggered.",
            attributes: ["controllerID": String(format: "%016X", context.controllerID)]
        )
    }

    func cancelPowerOffCombo(for context: DeviceContext) {
        context.powerOffComboSent = false
    }

    func emitNeutralStateIfNeeded(for context: DeviceContext) {
        let neutral = SteamControllerInputSnapshot()
        guard context.mergedSnapshot != neutral else { return }
        context.snapshot = neutral
        context.deckSnapshot = neutral
        context.mergedSnapshot = neutral
        cancelPowerOffCombo(for: context)
        notifyInputState(context.deviceID, neutral)
    }

    func notifyInputState(_ deviceID: InputDeviceID, _ snapshot: SteamControllerInputSnapshot) {
        for consumer in consumers.values {
            consumer.inputState(deviceID, snapshot)
        }
    }

    func notifyBatteryLevel(_ deviceID: InputDeviceID, _ level: UInt8) {
        for consumer in consumers.values {
            consumer.batteryLevel(deviceID, level)
        }
    }

    func setActive(_ isActive: Bool, for context: DeviceContext) {
        guard context.isActive != isActive else { return }
        context.isActive = isActive
        publishActiveCount()
        WebRTCMediaTelemetry.capture("webrtc.input.steamcontroller.device.presence", level: .info, message: "Steam Controller presence changed.", attributes: ["active": String(isActive)])
    }

    func publishActiveCount() {
        let active = devices.values.filter(\.isActive)
        let count = Set(active.map(\.controllerID)).count
        Self.activeCount.withLock { $0 = count }
        let names = Set(active.compactMap { stringProperty($0.device, key: kIOHIDProductKey)?.lowercased() }
            .filter { !$0.isEmpty })
        Self.claimedNames.withLock { $0 = names }
        for consumer in consumers.values {
            consumer.controllersChanged()
        }
    }
}
