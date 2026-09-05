//  What the HUD's controls do: focus movement, recording, upscaling changes and the paste and
//  pointer shortcuts. Split out of WebRTCMediaStreamSurface.swift.
//

import AppKit
import Combine
import GameController
import Foundation
import SwiftUI

extension WebRTCMediaStreamSurface {
    func toggleUnifiedHUD() {
        setUnifiedHUDVisible(!unifiedHUDVisible)
        WebRTCMediaTelemetry.capture("webrtc.ui.hud.toggle", level: .info, message: unifiedHUDVisible ? "Unified HUD shown." : "Unified HUD hidden.", attributes: ["visible": String(unifiedHUDVisible)])
    }

    /// No Remote Co-Op entries here: this HUD belongs to the WebRTC surface, which can no longer host
    /// a session, so the invite and copy rows that used to be appended went with it.
    var hudFocusEntries: [StreamHUDFocusEntry] {
        // One wrapping row of icon tiles; the wrap width follows the dock, so the grid model
        // treats them as a single row and up/down has nothing to do here.
        [
            StreamHUDFocusEntry(id: "microphone", isDisabled: runtimeSettings.microphoneMode == "disabled", group: "controls", columns: 8, action: toggleMicrophone),
            StreamHUDFocusEntry(id: "recording", isDisabled: !isStreamReady || recordingIsBusy, group: "controls", columns: 8, action: toggleRecording),
            StreamHUDFocusEntry(id: "anti-afk", isDisabled: !isStreamReady, group: "controls", columns: 8, action: toggleAntiAFKMouseMovement),
            StreamHUDFocusEntry(id: "controller-mapping", isDisabled: false, group: "controls", columns: 8, action: openControllerMapping),
            StreamHUDFocusEntry(id: "quit", isDisabled: false, group: "controls", columns: 8, action: { showQuitMenu() }),
        ]
    }

    func handleHUDGamepad(_ state: GamepadState) {
        guard let step = hudGamepadTracker.navigationStep(state) else { return }
        switch step {
        case .move(let direction):
            moveHUDFocus(direction)
        case .activate:
            StreamHUDFocusEntry.activatable(hudFocusID, in: hudFocusEntries)?.action()
        case .back:
            setUnifiedHUDVisible(false)
        }
    }

    func moveHUDFocus(_ direction: StreamHUDFocusDirection) {
        guard let next = StreamHUDFocusEntry.focusID(from: hudFocusID, direction: direction, in: hudFocusEntries) else { return }
        hudFocusID = next
    }

    func handleQuitMenuGamepad(_ state: GamepadState) {
        guard let step = hudGamepadTracker.navigationStep(state) else { return }
        switch step {
        case .move(let direction):
            quitMenuFocusIndex = (quitMenuFocusIndex + direction.linearStep + 3) % 3
        case .activate:
            switch quitMenuFocusIndex {
            case 0: dismissQuitMenu()
            case 1: pauseFromQuitMenu()
            default: quitStreamFromMenu()
            }
        case .back:
            dismissQuitMenu()
        }
    }

    func setUnifiedHUDVisible(_ visible: Bool) {
        unifiedHUDVisible = visible
        hudGamepadTracker.reset()
        guard visible else {
            hudFocusID = nil
            if restorePointerLockOnHUDHide {
                restorePointerLockOnHUDHide = false
                if NSApplication.shared.isActive, nativeView?.window?.isKeyWindow == true {
                    nativeView?.setPointerLocked(true)
                }
            }
            return
        }
        if onScreenKeyboardVisible { setOnScreenKeyboardVisible(false) }
        restorePointerLockOnHUDHide = pointerLocked
        hudFocusID = hudFocusEntries.first(where: { !$0.isDisabled })?.id
        nativeView?.setPointerLocked(false)
    }

    func toggleRecording() {
        if recordingCanStop {
            transport?.stopRecording()
            WebRTCMediaTelemetry.capture("webrtc.ui.recording.stop", level: .info, message: "Stream recording stop requested.", attributes: ["applicationID": configuration.applicationID])
            return
        }
        guard !recordingIsBusy else { return }
        guard let transport else {
            WebRTCMediaTelemetry.capture("webrtc.ui.recording.start.unavailable", level: .warning, message: "Stream recording start requested before transport was ready.", attributes: ["applicationID": configuration.applicationID])
            return
        }
        let recordingConfiguration = WebRTCStreamRecordingConfiguration(
            title: configuration.title,
            applicationID: configuration.applicationID,
            width: runtimeSettings.resolutionWidth,
            height: runtimeSettings.resolutionHeight,
            fps: runtimeSettings.fps,
            videoBitrateMbps: runtimeSettings.recordingVideoBitrateMbps,
            audioBitrateKbps: runtimeSettings.recordingAudioBitrateKbps,
            enhancedVideoEnabled: runtimeSettings.recordingEnhancedVideoEnabled
        )
        recordingStatus = .starting
        transport.startRecording(configuration: recordingConfiguration)
        WebRTCMediaTelemetry.capture("webrtc.ui.recording.start", level: .info, message: "Stream recording start requested.", attributes: ["applicationID": configuration.applicationID, "enhancedVideo": String(recordingConfiguration.enhancedVideoEnabled)])
    }

    func recordingElapsedText(_ elapsedSeconds: Double) -> String {
        let seconds = max(0, Int(elapsedSeconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    func settingsRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.streamNvidia(size: 11, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(.streamNvidia(size: 11, weight: .bold))
                .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    func videoStepperRow(_ label: String, value: Int, range: ClosedRange<Int>, step: Int = 1, action: @escaping (Int) -> Void) -> some View {
        StreamHUDSliderRow(label: label, value: value, range: range, step: step, isDisabled: !isStreamReady, action: action)
    }


    func updateVideoEnhancement(mode: Int? = nil, sharpness: Int? = nil, denoise: Int? = nil, targetHeight: Int? = nil, pillarboxFillMode: Int? = nil, pillarboxFillDim: Int? = nil, pillarboxFillColor: Int? = nil) {
        runtimeSettings.updateVideoEnhancement(mode: mode, sharpness: sharpness, denoise: denoise, targetHeight: targetHeight, pillarboxFillMode: pillarboxFillMode, pillarboxFillDim: pillarboxFillDim, pillarboxFillColor: pillarboxFillColor)
        onVideoEnhancementChange?(runtimeSettings.upscalingMode, runtimeSettings.upscalingSharpness, runtimeSettings.upscalingDenoise)
        transport?.setLocalVideoEnhancement(mode: runtimeSettings.upscalingMode, sharpness: runtimeSettings.upscalingSharpness, denoise: runtimeSettings.upscalingDenoise, targetHeight: runtimeSettings.upscalingTargetHeight, pillarboxFillMode: runtimeSettings.pillarboxFillMode, pillarboxFillDim: runtimeSettings.pillarboxFillDim, pillarboxFillColor: runtimeSettings.pillarboxFillColor)
        WebRTCMediaTelemetry.capture(
            "webrtc.ui.video_enhancement.update",
            level: .info,
            message: "Video enhancement settings updated.",
            attributes: [
                "mode": String(runtimeSettings.upscalingMode),
                "enhancementPreset": runtimeSettings.upscalingMode == 3 ? "metalfx_m1" : (runtimeSettings.upscalingMode == 2 ? "spatial" : "off"),
                "sharpness": String(runtimeSettings.upscalingSharpness),
                "denoise": String(runtimeSettings.upscalingDenoise),
                "targetHeight": String(runtimeSettings.upscalingTargetHeight),
            ]
        )
    }

    var clipboardTextAvailable: Bool {
        guard let text = NSPasteboard.general.string(forType: .string) else { return false }
        return !text.isEmpty
    }

    var networkHealthText: String {
        guard let latestStats, latestStats.available else { return "No stats" }
        return networkWarningText.isEmpty ? "Good" : "Watch"
    }

    var networkHealthIsGood: Bool {
        guard let latestStats, latestStats.available else { return false }
        return networkWarningText.isEmpty
    }

    var networkWarningText: String {
        guard let latestStats else { return "Waiting for WebRTC stats." }
        guard latestStats.available else { return "Stats are not available yet." }
        if latestStats.packetLossPercent >= 2 { return "Packet loss is high; expect visible artifacts or input delay." }
        if latestStats.latencyMs >= 120 { return "Latency is high; input may feel delayed." }
        if latestStats.jitterMs >= 35 { return "Network jitter is unstable; gameplay may stutter." }
        if latestStats.inboundBitrateMbps >= 0 && latestStats.inboundBitrateMbps < 5 { return "Inbound bitrate is low for cloud gaming quality." }
        if latestStats.videoMaxFrameIntervalMs >= 80 { return "Frame pacing spikes detected in the video pipeline." }
        return ""
    }

    func toggleStatsHUD() {
        statsVisible.toggle()
        WebRTCMediaTelemetry.capture("webrtc.ui.stats.toggle", level: .info, message: statsVisible ? "Stats HUD shown." : "Stats HUD hidden.", attributes: ["visible": String(statsVisible)])
    }

    func pasteClipboardIntoStream() {
        guard isStreamReady, !isEndingStream, !didEndStream else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            showTransientStreamMessage("Clipboard is empty")
            return
        }
        transport?.sendNow(.text(deviceID: "keyboard", value: text, timestamp: MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)))
        lastAcceptedStreamInputAt = Date()
        showTransientStreamMessage("Clipboard sent")
        WebRTCMediaTelemetry.capture("webrtc.ui.clipboard.paste", level: .info, message: "Clipboard text sent to stream.", attributes: ["applicationID": configuration.applicationID, "characters": String(text.count)])
    }

    func togglePointerLockFromHUD() {
        guard isStreamReady, runtimeSettings.directMouseInput else { return }
        nativeView?.setPointerLocked(!pointerLocked)
    }

    func toggleFullScreenFromHUD() {
        guard let window = nativeView?.window else { return }
        window.toggleFullScreen(nil)
        showTransientStreamMessage(window.styleMask.contains(.fullScreen) ? "Leaving full screen" : "Entering full screen")
    }

    func statsRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.streamNvidia(size: 11, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            Spacer()
            Text(value)
                .font(.streamNvidia(size: 11, weight: .bold))
                .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
        }
    }

    func formatted(_ value: Double?, suffix: String) -> String {
        guard let value, value >= 0 else { return "-" }
        return String(format: "%.1f%@", value, suffix)
    }

    func frameTimeValue(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "Pending" }
        return String(format: "%.1f ms", value)
    }

    func liveEnhancementValue(_ value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty, value != "unknown", value != "pending" else { return fallback }
        return value
    }
}
