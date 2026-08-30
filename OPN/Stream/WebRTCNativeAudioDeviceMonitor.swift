//
//  WebRTCNativeAudioDeviceMonitor.swift
//  OpenNOW
//
//  Lets `OPNCoreAudioRTCDevice` follow the default output device on its own.
//
//  `OPNLibWebRTCAudio` already does this for the libwebrtc session, but it is tied to an
//  `OPNLibWebRTCSessionImpl` that the native NVST bundle never creates. Without this the bundle's
//  playout unit stays pinned to whatever device was default when the stream started, so plugging in
//  headphones mid-game leaves the audio on the speakers.
//
//  Split out of WebRTCNativeAudio.swift.
//

import AudioUnit
import CoreAudio
import Foundation

private let coreAudioDeviceDefaultChangedCallback: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let clientData else { return noErr }
    let device = Unmanaged<OPNCoreAudioRTCDevice>.fromOpaque(clientData).takeUnretainedValue()
    device.scheduleSelfDeviceChange()
    return noErr
}

extension OPNCoreAudioRTCDevice {
    func startSelfDeviceMonitoring() {
        var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &outputAddress, coreAudioDeviceDefaultChangedCallback, context)
        WebRTCMediaTelemetry.capture("webrtc.native.audio.self_monitor.start", level: .debug, message: "CoreAudio RTC device is following the default output device.", attributes: ["status": String(status)])
    }

    func stopSelfDeviceMonitoring() {
        guard monitorsDefaultDeviceChanges else { return }
        var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let context = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &outputAddress, coreAudioDeviceDefaultChangedCallback, context)
    }

    /// Debounced because a single hotplug fires the property several times, and because the new
    /// default is briefly unknown while CoreAudio settles — rebinding then would pick nothing.
    func scheduleSelfDeviceChange() {
        // The generation is read and written from the CoreAudio notification thread and from the
        // debounce tasks, so it lives on the same queue as the rest of this device's state.
        let generation = audioQueue.sync { () -> UInt64 in
            selfDeviceChangeGeneration &+= 1
            return selfDeviceChangeGeneration
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.isCurrentSelfDeviceChange(generation) else { return }
            self.applySelfDeviceChange(generation: generation, attempt: 0)
        }
    }

    private func isCurrentSelfDeviceChange(_ generation: UInt64) -> Bool {
        audioQueue.sync { selfDeviceChangeGeneration == generation }
    }

    private func applySelfDeviceChange(generation: UInt64, attempt: Int) {
        let current = OPNLibWebRTCAudio.defaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice)
        guard current != AudioDeviceID(kAudioObjectUnknown) else {
            guard attempt < 10 else {
                WebRTCMediaTelemetry.capture("webrtc.native.audio.self_monitor.unavailable", level: .warning, message: "Default output device stayed unavailable after a hotplug.")
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isCurrentSelfDeviceChange(generation) else { return }
                self.applySelfDeviceChange(generation: generation, attempt: attempt + 1)
            }
            return
        }
        guard audioQueue.sync(execute: { current != outputDevice }) else { return }
        WebRTCMediaTelemetry.capture("webrtc.native.audio.self_monitor.changed", level: .info, message: "Default output device changed; rebinding the CoreAudio RTC device.", attributes: ["outputDevice": String(current)])
        handleDefaultDeviceChange()
    }
}
