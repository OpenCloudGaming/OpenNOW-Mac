import Foundation

@_silgen_name("OPNStreamSessionNativeInputReady")
private func OPNStreamSessionNativeInputReady(_ session: UnsafeMutableRawPointer?) -> Bool

@_silgen_name("OPNStreamSessionNativeSetMicrophoneEnabled")
private func OPNStreamSessionNativeSetMicrophoneEnabled(_ session: UnsafeMutableRawPointer?, _ enabled: Bool)

@_silgen_name("OPNStreamSessionNativeSetGameVolume")
private func OPNStreamSessionNativeSetGameVolume(_ session: UnsafeMutableRawPointer?, _ volume: Double)

@_silgen_name("OPNStreamSessionNativeSetMicrophoneVolume")
private func OPNStreamSessionNativeSetMicrophoneVolume(_ session: UnsafeMutableRawPointer?, _ volume: Double)

@_silgen_name("OPNStreamSessionNativeSetMaxBitrate")
private func OPNStreamSessionNativeSetMaxBitrate(_ session: UnsafeMutableRawPointer?, _ mbps: Int)

@_silgen_name("OPNStreamSessionNativeSetEnhancedVideoCaptureEnabled")
private func OPNStreamSessionNativeSetEnhancedVideoCaptureEnabled(_ session: UnsafeMutableRawPointer?, _ enabled: Bool)

@_silgen_name("OPNStreamSessionNativeSetVideoEnhancement")
private func OPNStreamSessionNativeSetVideoEnhancement(_ session: UnsafeMutableRawPointer?, _ mode: Int, _ sharpness: Int, _ denoise: Int, _ targetHeight: Int)

@_silgen_name("OPNStreamSessionNativeSendUtf8Text")
private func OPNStreamSessionNativeSendUtf8Text(_ session: UnsafeMutableRawPointer?, _ text: NSString)

@_silgen_name("OPNStreamSessionNativeSendKeyEvent")
private func OPNStreamSessionNativeSendKeyEvent(_ session: UnsafeMutableRawPointer?, _ keycode: UInt16, _ scancode: UInt16, _ modifiers: UInt16, _ down: Bool)

@_silgen_name("OPNStreamSessionNativeSendMouseMove")
private func OPNStreamSessionNativeSendMouseMove(_ session: UnsafeMutableRawPointer?, _ dx: Int16, _ dy: Int16)

@_silgen_name("OPNStreamSessionNativeSendMouseButton")
private func OPNStreamSessionNativeSendMouseButton(_ session: UnsafeMutableRawPointer?, _ button: UInt8, _ down: Bool)

@_silgen_name("OPNStreamSessionNativeSendMouseWheel")
private func OPNStreamSessionNativeSendMouseWheel(_ session: UnsafeMutableRawPointer?, _ delta: Int16)

@_silgen_name("OPNStreamSessionNativeSendGamepadState")
private func OPNStreamSessionNativeSendGamepadState(_ session: UnsafeMutableRawPointer?, _ controllerId: UInt16, _ buttons: UInt16, _ leftTrigger: UInt8, _ rightTrigger: UInt8, _ leftStickX: Int16, _ leftStickY: Int16, _ rightStickX: Int16, _ rightStickY: Int16, _ connected: Bool, _ bitmap: UInt16, _ timestampUs: UInt64)

@_silgen_name("OPNStreamSessionConfigureNativeViewCallbacks")
private func OPNStreamSessionConfigureNativeViewCallbacks(_ session: UnsafeMutableRawPointer?, _ streamView: OPNStreamView?, _ recordingManager: OPNStreamRecordingManager?)

@_silgen_name("OPNStreamSessionClearNativeCallbacks")
private func OPNStreamSessionClearNativeCallbacks(_ session: UnsafeMutableRawPointer?)

@_cdecl("OPNStreamSessionClearCallbacks")
func OPNLibWebRTCSessionSurfaceClearCallbacks(_ session: UnsafeMutableRawPointer?) {
    OPNStreamSessionClearNativeCallbacks(session)
}

@_cdecl("OPNStreamSessionConfigureViewCallbacks")
func OPNLibWebRTCSessionSurfaceConfigureViewCallbacks(_ session: UnsafeMutableRawPointer?, _ streamView: OPNStreamView?, _ recordingManager: OPNStreamRecordingManager?) {
    let sessionAddress = UInt(bitPattern: session)
    MainActor.assumeIsolated {
        OPNLibWebRTCSessionSurfaceConfigureViewCallbacksOnMainActor(sessionAddress, streamView, recordingManager)
    }
}

@MainActor
private func OPNLibWebRTCSessionSurfaceConfigureViewCallbacksOnMainActor(_ sessionAddress: UInt, _ streamView: OPNStreamView?, _ recordingManager: OPNStreamRecordingManager?) {
    guard let streamView else { return }
    streamView.clearStreamCallbacks()
    let session = UnsafeMutableRawPointer(bitPattern: sessionAddress)
    guard let session else { return }

    streamView.streamInputReadyProvider = { OPNStreamSessionNativeInputReady(session) }
    streamView.streamMicrophoneEnabledHandler = { OPNStreamSessionNativeSetMicrophoneEnabled(session, $0) }
    streamView.streamGameVolumeHandler = { OPNStreamSessionNativeSetGameVolume(session, $0) }
    streamView.streamMicrophoneVolumeHandler = { OPNStreamSessionNativeSetMicrophoneVolume(session, $0) }
    streamView.streamMaxBitrateHandler = { OPNStreamSessionNativeSetMaxBitrate(session, $0) }
    streamView.streamEnhancedVideoCaptureHandler = { OPNStreamSessionNativeSetEnhancedVideoCaptureEnabled(session, $0) }
    streamView.streamVideoEnhancementHandler = { mode, sharpness, denoise, targetHeight in
        OPNStreamSessionNativeSetVideoEnhancement(session, mode, sharpness, denoise, targetHeight)
    }
    streamView.streamUtf8TextHandler = { OPNStreamSessionNativeSendUtf8Text(session, $0 as NSString) }
    streamView.streamKeyEventHandler = { keycode, scancode, modifiers, down in
        OPNStreamSessionNativeSendKeyEvent(session, keycode, scancode, modifiers, down)
    }
    streamView.streamMouseMoveHandler = { OPNStreamSessionNativeSendMouseMove(session, $0, $1) }
    streamView.streamMouseButtonHandler = { OPNStreamSessionNativeSendMouseButton(session, $0, $1) }
    streamView.streamMouseWheelHandler = { OPNStreamSessionNativeSendMouseWheel(session, $0) }
    streamView.streamGamepadStateHandler = { controllerId, buttons, leftTrigger, rightTrigger, leftStickX, leftStickY, rightStickX, rightStickY, connected, bitmap, timestampUs in
        OPNStreamSessionNativeSendGamepadState(session, controllerId, buttons, leftTrigger, rightTrigger, leftStickX, leftStickY, rightStickX, rightStickY, connected, bitmap, timestampUs)
    }
    OPNStreamSessionConfigureNativeViewCallbacks(session, streamView, recordingManager)
}
