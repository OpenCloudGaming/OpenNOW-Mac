import Foundation

import AppKit
import CoreAudio

enum OPNLibWebRTCSessionSurface {
    @MainActor
    static func configure(session: OPNLibWebRTCStreamSession, streamView: OPNStreamView?, recordingManager: OPNStreamRecordingManager?) {
        guard let streamView else { return }
        streamView.clearStreamCallbacks()
        streamView.streamInputReadyProvider = { [weak session] in session?.isInputReady ?? false }
        streamView.streamMicrophoneEnabledHandler = { [weak session] in session?.setMicrophoneEnabled($0) }
        streamView.streamGameVolumeHandler = { [weak session] in session?.setGameVolume($0) }
        streamView.streamMicrophoneVolumeHandler = { [weak session] in session?.setMicrophoneVolume($0) }
        streamView.streamMaxBitrateHandler = { [weak session] in session?.setMaxBitrateMbps($0) }
        streamView.streamEnhancedVideoCaptureHandler = { [weak session] in session?.setEnhancedVideoFrameCaptureEnabled($0) }
        streamView.streamVideoEnhancementHandler = { [weak session] mode, sharpness, denoise, targetHeight in session?.setLocalVideoEnhancement(mode: mode, sharpness: sharpness, denoise: denoise, targetHeight: targetHeight) }
        streamView.streamUtf8TextHandler = { [weak session] in session?.sendUtf8Text($0) }
        streamView.streamKeyEventHandler = { [weak session] keycode, scancode, modifiers, down in session?.sendKey(keycode: keycode, scancode: scancode, modifiers: modifiers, down: down) }
        streamView.streamMouseMoveHandler = { [weak session] in session?.sendMouseMove(dx: $0, dy: $1) }
        streamView.streamMouseButtonHandler = { [weak session] in session?.sendMouseButton(button: $0, down: $1) }
        streamView.streamMouseWheelHandler = { [weak session] in session?.sendMouseWheel(delta: $0) }
        streamView.streamGamepadStateHandler = { [weak session] controllerId, buttons, leftTrigger, rightTrigger, leftStickX, leftStickY, rightStickX, rightStickY, connected, bitmap, timestampUs in
            session?.sendGamepadState(controllerId: controllerId, buttons: buttons, leftTrigger: leftTrigger, rightTrigger: rightTrigger, leftStickX: leftStickX, leftStickY: leftStickY, rightStickX: rightStickX, rightStickY: rightStickY, connected: connected, bitmap: bitmap, timestampUs: timestampUs)
        }
        session.onVideoFrame = { [weak streamView] frame in streamView?.receiveVideoFrame(frame) }
        session.onEnhancedVideoFrame = { [weak streamView] pixelBuffer in streamView?.receiveEnhancedVideoFrame(pixelBuffer) }
        session.onGameAudioFrame = { [weak recordingManager] audioBufferList, frameCount, sampleRate, channels in
            recordingManager?.appendWebRTCAudioBufferList(audioBufferList?.assumingMemoryBound(to: AudioBufferList.self), frameCount: frameCount, sampleRate: sampleRate, channels: channels)
        }
        session.onClipboardText = { text in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        session.onMicrophoneLevel = { _ in }
    }
}
