//  What the VSync control can do to a running stream: the live half of a VSync change —
//  the `0x203` pacing-report cadence, applied through the session path while the seat-facing
//  mode stays fixed at ANNOUNCE. See `NvstVsyncMode`.
//
//  Kept out of `NativeNVSTHostViewModel+Controls.swift`, which already carries the full HUD
//  control surface at its size limit.

import Foundation

@MainActor
extension NativeNVSTHostViewModel {

    /// The options index for a `NvstVsyncMode` raw value. An unknown raw value resolves to
    /// Adaptive — the only mode every session can be in — so a bad pick can never leave the
    /// mode state undefined.
    private static func vsyncModeIndex(for modeValue: Int) -> Int {
        guard let index = OPNStreamPreferences.vsyncModeOptions.firstIndex(where: { $0.value == modeValue }) else {
            return OPNStreamPreferences.vsyncModeOptions.firstIndex(where: { $0.value == NvstVsyncMode.adaptive.rawValue }) ?? 0
        }
        return index
    }

    /// The VSync setting, applied live when a session is running. The seat-facing half
    /// (`framePacing.mode`/`feedbackMode`) was fixed at ANNOUNCE, so the live effect is the
    /// `0x203` report cadence — the client-facing half of the same pacer; the next session
    /// announces the new mode. See `NvstVsyncMode`.
    /// `modeValue` is the `NvstVsyncMode` raw value the picker hands over (rows compare against
    /// the option's value, not its index); the index is derived so the two can never disagree.
    func updateNativeVsyncMode(modeValue: Int) {
        let index = Self.vsyncModeIndex(for: modeValue)
        vsyncModeIndex = index
        OPNStreamPreferences.saveVsyncModeIndex(index)
        let mode = NvstVsyncMode(rawValue: OPNStreamPreferences.vsyncModeOptions[index].value) ?? .adaptive
        let message = "VSync \(mode.label)"
        showNativeTransientStreamMessage(message)
        guard isConnected, !isEnding, !didEnd, let path else { return }
        Task {
            do {
                try await path.setVsyncMode(mode)
                OPNStreamTelemetry.capture("nvst.ui.vsync.update", level: .info, message: message, attributes: ["applicationID": configuration.applicationID, "mode": mode.label])
            } catch {
                OPNStreamTelemetry.capture("nvst.ui.vsync.failed", level: .warning, message: Self.message(for: error), attributes: ["applicationID": configuration.applicationID, "mode": mode.label])
            }
        }
    }

    /// Controller/keyboard step through the HUD row: cycles Off → On → Adaptive and wraps.
    func cycleNativeVsyncMode() {
        let nextModeValue = wrappingNext(after: vsyncModeIndex, in: OPNStreamPreferences.vsyncModeOptions.map(\.value))
        updateNativeVsyncMode(modeValue: nextModeValue)
    }
}
