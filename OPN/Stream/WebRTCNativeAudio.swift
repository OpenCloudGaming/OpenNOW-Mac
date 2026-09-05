import CoreAudio
import AudioUnit
import Foundation
@preconcurrency import WebRTC

private let audioDeviceChangedCallback: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let clientData else { return noErr }
    let audio = Unmanaged<OPNLibWebRTCAudio>.fromOpaque(clientData).takeUnretainedValue()
    audio.scheduleAudioDeviceChange()
    return noErr
}

@objc(OPNLibWebRTCAudio)
final class OPNLibWebRTCAudio: NSObject, @unchecked Sendable {
    private weak var owner: OPNLibWebRTCStreamSession?
    private var microphoneEnabled = false
    @objc private(set) var gameVolume = 1.0
    private var microphoneVolume = 1.0
    private var microphoneLevelRequestInFlight = false
    private var microphoneLevelTimer: DispatchSourceTimer?
    private var audioMonitoringActive = false
    private var defaultInputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var defaultOutputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var audioDeviceChangeGeneration: UInt64 = 0
    private var audioDeviceUnavailableRetryCount = 0
    private weak var sessionImpl: OPNLibWebRTCSessionImpl?

    @objc(initWithOwner:)
    init(owner: OPNLibWebRTCStreamSession?) {
        self.owner = owner
        super.init()
    }

    @objc(setMicrophoneEnabled:sessionImpl:)
    func setMicrophoneEnabled(_ enabled: Bool, sessionImpl: OPNLibWebRTCSessionImpl?) {
        microphoneEnabled = enabled
        self.sessionImpl = sessionImpl
        sessionImpl?.localMicrophoneTrack?.isEnabled = enabled
        if enabled, sessionImpl?.localMicrophoneTrack != nil, sessionImpl?.audioDevice == nil {
            startMicrophoneLevelPolling(sessionImpl: sessionImpl, statsQueue: DispatchQueue.global(qos: .utility))
        } else if sessionImpl?.audioDevice != nil {
            stopMicrophoneLevelPolling()
        } else if !enabled {
            owner?.handleMicrophoneLevel(0)
        }
    }

    @objc(setGameVolume:sessionImpl:)
    func setGameVolume(_ volume: Double, sessionImpl: OPNLibWebRTCSessionImpl?) {
        gameVolume = min(max(volume, 0), 1)
        sessionImpl?.remoteAudioTrack?.source.volume = gameVolume
    }

    @objc(setMicrophoneVolume:sessionImpl:)
    func setMicrophoneVolume(_ volume: Double, sessionImpl: OPNLibWebRTCSessionImpl?) {
        microphoneVolume = min(max(volume, 0), 1)
        sessionImpl?.localMicrophoneTrack?.source.volume = microphoneVolume
    }

    @objc(refreshAudioDevicesWithSessionImpl:)
    func refreshAudioDevices(sessionImpl: OPNLibWebRTCSessionImpl?) {
        self.sessionImpl = sessionImpl
        guard audioMonitoringActive else {
            WebRTCMediaTelemetry.capture("webrtc.native.audio.refresh_skipped", level: .debug, message: "Audio device refresh skipped because monitoring is inactive.")
            return
        }
        guard let sessionImpl, sessionImpl.peerConnection != nil else {
            WebRTCMediaTelemetry.capture("webrtc.native.audio.refresh_skipped", level: .debug, message: "Audio device refresh skipped because the peer connection is missing.")
            return
        }
        if let audioDevice = sessionImpl.audioDevice {
            audioDevice.handleDefaultDeviceChange()
            WebRTCMediaTelemetry.capture("webrtc.native.audio.refresh_delegated", level: .debug, message: "Audio device refresh delegated to CoreAudio RTC device.", attributes: ["inputDevice": String(defaultInputDevice), "outputDevice": String(defaultOutputDevice)])
            return
        }
        let refreshGeneration = audioDeviceChangeGeneration
        let shouldRestoreMicrophone = sessionImpl.localMicrophoneTrack?.isEnabled ?? false
        sessionImpl.remoteAudioTrack?.isEnabled = false
        sessionImpl.localMicrophoneTrack?.isEnabled = false
        setRTCAudioSessionEnabled(false)
        WebRTCMediaTelemetry.capture("webrtc.native.audio.refresh_scheduled", level: .debug, message: "Audio device refresh scheduled.", attributes: ["inputDevice": String(defaultInputDevice), "outputDevice": String(defaultOutputDevice)])

        Task { @MainActor [weak self, weak sessionImpl] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, self.audioMonitoringActive, self.audioDeviceChangeGeneration == refreshGeneration else { return }
            self.setRTCAudioSessionEnabled(true)
            sessionImpl?.remoteAudioTrack?.isEnabled = true
            sessionImpl?.remoteAudioTrack?.source.volume = self.gameVolume
            if let localMicrophoneTrack = sessionImpl?.localMicrophoneTrack {
                localMicrophoneTrack.isEnabled = self.microphoneEnabled && shouldRestoreMicrophone
                localMicrophoneTrack.source.volume = self.microphoneVolume
            }
            WebRTCMediaTelemetry.capture("webrtc.native.audio.refresh_applied", level: .debug, message: "Audio device refresh applied.", attributes: ["inputDevice": String(self.defaultInputDevice), "outputDevice": String(self.defaultOutputDevice), "remoteTrack": String(sessionImpl?.remoteAudioTrack != nil), "microphoneTrack": String(sessionImpl?.localMicrophoneTrack != nil), "microphoneEnabled": String(sessionImpl?.localMicrophoneTrack?.isEnabled == true)])
        }
    }

    @objc func startAudioDeviceMonitoring() {
        guard !audioMonitoringActive else { return }
        audioMonitoringActive = true
        defaultInputDevice = Self.defaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice)
        defaultOutputDevice = Self.defaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice)

        var devicesAddress = Self.propertyAddress(kAudioHardwarePropertyDevices)
        var inputAddress = Self.propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
        var outputAddress = Self.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let devicesStatus = AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, audioDeviceChangedCallback, context)
        let inputStatus = AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &inputAddress, audioDeviceChangedCallback, context)
        let outputStatus = AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &outputAddress, audioDeviceChangedCallback, context)
        WebRTCMediaTelemetry.capture("webrtc.native.audio.monitor.start", level: .debug, message: "Audio device monitoring started.", attributes: ["devicesStatus": String(devicesStatus), "inputStatus": String(inputStatus), "outputStatus": String(outputStatus), "inputDevice": String(defaultInputDevice), "outputDevice": String(defaultOutputDevice)])
    }

    @objc func stopAudioDeviceMonitoring() {
        guard audioMonitoringActive else { return }
        audioMonitoringActive = false
        var devicesAddress = Self.propertyAddress(kAudioHardwarePropertyDevices)
        var inputAddress = Self.propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
        var outputAddress = Self.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let context = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, audioDeviceChangedCallback, context)
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &inputAddress, audioDeviceChangedCallback, context)
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &outputAddress, audioDeviceChangedCallback, context)
        defaultInputDevice = AudioDeviceID(kAudioObjectUnknown)
        defaultOutputDevice = AudioDeviceID(kAudioObjectUnknown)
        WebRTCMediaTelemetry.capture("webrtc.native.audio.monitor.stop", level: .debug, message: "Audio device monitoring stopped.")
    }

    func scheduleAudioDeviceChange() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.audioMonitoringActive else { return }
            self.handleAudioDeviceChange(sessionImpl: self.sessionImpl)
        }
    }

    @objc(handleAudioDeviceChangeWithSessionImpl:)
    func handleAudioDeviceChange(sessionImpl: OPNLibWebRTCSessionImpl?) {
        guard audioMonitoringActive else { return }
        self.sessionImpl = sessionImpl
        let inputDevice = Self.defaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice)
        let outputDevice = Self.defaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice)
        if outputDevice == AudioDeviceID(kAudioObjectUnknown) {
            audioDeviceChangeGeneration &+= 1
            let generation = audioDeviceChangeGeneration
            if audioDeviceUnavailableRetryCount < 10 {
                audioDeviceUnavailableRetryCount += 1
                WebRTCMediaTelemetry.capture("webrtc.native.audio.output_unavailable", level: .debug, message: "Default output device unavailable during hotplug; retrying.", attributes: ["inputDevice": String(inputDevice), "outputDevice": String(outputDevice), "retry": String(audioDeviceUnavailableRetryCount)])
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, self.audioMonitoringActive, self.audioDeviceChangeGeneration == generation else { return }
                    self.handleAudioDeviceChange(sessionImpl: self.sessionImpl)
                }
            } else {
                WebRTCMediaTelemetry.capture("webrtc.native.audio.output_unavailable", level: .warning, message: "Default output device remained unavailable after hotplug retries.")
            }
            return
        }

        audioDeviceUnavailableRetryCount = 0
        let inputChanged = inputDevice != defaultInputDevice
        let outputChanged = outputDevice != defaultOutputDevice
        guard inputChanged || outputChanged else { return }
        WebRTCMediaTelemetry.capture("webrtc.native.audio.device_changed", level: .info, message: "Default audio device changed.", attributes: ["previousInput": String(defaultInputDevice), "inputDevice": String(inputDevice), "previousOutput": String(defaultOutputDevice), "outputDevice": String(outputDevice)])
        defaultInputDevice = inputDevice
        defaultOutputDevice = outputDevice
        refreshAudioDevices(sessionImpl: sessionImpl)

        audioDeviceChangeGeneration &+= 1
        let generation = audioDeviceChangeGeneration
        let customAudioDeviceActive = sessionImpl?.audioDevice != nil
        if !customAudioDeviceActive, Self.envFlagEnabled("OPN_ENABLE_WEBRTC_AUDIO_HOTSWAP_RECOVERY", defaultValue: true) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, self.audioMonitoringActive, self.audioDeviceChangeGeneration == generation else { return }
                WebRTCMediaTelemetry.capture("webrtc.native.audio.recovery", level: .warning, message: "Forcing stream recovery after audio device change.", attributes: ["inputDevice": String(self.defaultInputDevice), "outputDevice": String(self.defaultOutputDevice)])
                self.owner?.handleConnectionState(false, error: "webrtc audio device changed")
            }
        }
    }

    @objc(startMicrophoneLevelPollingWithSessionImpl:statsQueue:)
    func startMicrophoneLevelPolling(sessionImpl: OPNLibWebRTCSessionImpl?, statsQueue: DispatchQueue) {
        guard microphoneLevelTimer == nil else { return }
        self.sessionImpl = sessionImpl
        let timer = DispatchSource.makeTimerSource(queue: statsQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self, weak sessionImpl] in
            guard let self else { return }
            guard let peerConnection = sessionImpl?.peerConnection, let microphoneTrack = sessionImpl?.localMicrophoneTrack else { return }
            guard self.microphoneEnabled, microphoneTrack.isEnabled else {
                self.owner?.handleMicrophoneLevel(0)
                return
            }
            guard !self.microphoneLevelRequestInFlight else { return }
            self.microphoneLevelRequestInFlight = true
            peerConnection.statistics { [weak self] report in
                guard let self else { return }
                self.microphoneLevelRequestInFlight = false
                let level = Self.microphoneLevel(from: report)
                if level >= 0 { self.owner?.handleMicrophoneLevel(level * self.microphoneVolume) }
            }
        }
        microphoneLevelTimer = timer
        timer.resume()
        WebRTCMediaTelemetry.capture("webrtc.native.audio.microphone_level", level: .debug, message: "Microphone level polling started.")
    }

    @objc func stopMicrophoneLevelPolling() {
        microphoneLevelTimer?.cancel()
        microphoneLevelTimer = nil
        microphoneLevelRequestInFlight = false
        owner?.handleMicrophoneLevel(0)
    }

    private func setRTCAudioSessionEnabled(_ enabled: Bool) {
        guard let audioSessionClass = NSClassFromString("RTCAudioSession") as? NSObject.Type,
              let audioSession = audioSessionClass.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject else { return }
        audioSession.setValue(enabled, forKey: "isAudioEnabled")
        audioSession.setValue(false, forKey: "useManualAudio")
    }

    private static func microphoneLevel(from report: RTCStatisticsReport?) -> Double {
        guard let report else { return -1 }
        var bestLevel = -1.0
        for stat in report.statistics.values where isAudio(stat) {
            let values = stat.values
            let value = (values["audioLevel"] as? NSNumber)?.doubleValue ?? (values["totalAudioEnergy"] as? NSNumber)?.doubleValue
            guard var level = value else { continue }
            if level > 1 { level = sqrt(level) }
            bestLevel = max(bestLevel, max(0, min(level, 1)))
        }
        return bestLevel
    }

    private static func isAudio(_ stat: RTCStatistics) -> Bool {
        let values = stat.values
        if (values["mediaType"] as? String) == "audio" || (values["kind"] as? String) == "audio" || (values["trackKind"] as? String) == "audio" { return true }
        let id = stat.id.lowercased()
        return id.contains("audio") || id.contains("mic")
    }

    static func defaultAudioDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = propertyAddress(selector)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return AudioDeviceID(kAudioObjectUnknown)
        }
        return device
    }

    private static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func envFlagEnabled(_ name: String, defaultValue: Bool) -> Bool {
        guard let rawValue = getenv(name), rawValue.pointee != 0 else { return defaultValue }
        let normalized = String(cString: rawValue).lowercased()
        return !(normalized == "0" || normalized == "false" || normalized == "no" || normalized == "off")
    }
}
