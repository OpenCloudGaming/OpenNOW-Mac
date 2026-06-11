import CoreAudio
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
        if enabled, sessionImpl?.localMicrophoneTrack != nil {
            startMicrophoneLevelPolling(sessionImpl: sessionImpl, statsQueue: DispatchQueue.global(qos: .utility))
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
            NSLog("[LibWebRTC] audio device refresh skipped: monitor inactive")
            return
        }
        guard let sessionImpl, sessionImpl.peerConnection != nil else {
            NSLog("[LibWebRTC] audio device refresh skipped: peer connection missing")
            return
        }
        let refreshGeneration = audioDeviceChangeGeneration
        let shouldRestoreMicrophone = sessionImpl.localMicrophoneTrack?.isEnabled ?? false
        sessionImpl.remoteAudioTrack?.isEnabled = false
        sessionImpl.localMicrophoneTrack?.isEnabled = false
        setRTCAudioSessionEnabled(false)
        NSLog("[LibWebRTC] audio device refresh scheduled input=%u output=%u rtcAudioSession=1", defaultInputDevice, defaultOutputDevice)

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self, weak sessionImpl] in
            guard let self, self.audioMonitoringActive, self.audioDeviceChangeGeneration == refreshGeneration else { return }
            self.setRTCAudioSessionEnabled(true)
            sessionImpl?.remoteAudioTrack?.isEnabled = true
            sessionImpl?.remoteAudioTrack?.source.volume = self.gameVolume
            if let localMicrophoneTrack = sessionImpl?.localMicrophoneTrack {
                localMicrophoneTrack.isEnabled = self.microphoneEnabled && shouldRestoreMicrophone
                localMicrophoneTrack.source.volume = self.microphoneVolume
            }
            NSLog("[LibWebRTC] audio device refresh applied input=%u output=%u remoteTrack=%d micTrack=%d micEnabled=%d",
                  self.defaultInputDevice,
                  self.defaultOutputDevice,
                  sessionImpl?.remoteAudioTrack == nil ? 0 : 1,
                  sessionImpl?.localMicrophoneTrack == nil ? 0 : 1,
                  sessionImpl?.localMicrophoneTrack?.isEnabled == true ? 1 : 0)
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
        NSLog("[LibWebRTC] audio device monitoring started devices=%d input=%d output=%d currentInput=%u currentOutput=%u", devicesStatus, inputStatus, outputStatus, defaultInputDevice, defaultOutputDevice)
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
        NSLog("[LibWebRTC] audio device monitoring stopped")
    }

    func scheduleAudioDeviceChange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
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
                NSLog("[LibWebRTC] default output device unavailable during hotplug input=%u output=%u retry=%d", inputDevice, outputDevice, audioDeviceUnavailableRetryCount)
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                    guard let self, self.audioMonitoringActive, self.audioDeviceChangeGeneration == generation else { return }
                    self.handleAudioDeviceChange(sessionImpl: self.sessionImpl)
                }
            } else {
                NSLog("[LibWebRTC] default output device remained unavailable after headset hotplug retries")
            }
            return
        }

        audioDeviceUnavailableRetryCount = 0
        let inputChanged = inputDevice != defaultInputDevice
        let outputChanged = outputDevice != defaultOutputDevice
        guard inputChanged || outputChanged else { return }
        NSLog("[LibWebRTC] default audio device changed input=%u->%u output=%u->%u", defaultInputDevice, inputDevice, defaultOutputDevice, outputDevice)
        defaultInputDevice = inputDevice
        defaultOutputDevice = outputDevice
        refreshAudioDevices(sessionImpl: sessionImpl)

        audioDeviceChangeGeneration &+= 1
        let generation = audioDeviceChangeGeneration
        if Self.envFlagEnabled("OPN_ENABLE_WEBRTC_AUDIO_HOTSWAP_RECOVERY", defaultValue: true) {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(700)) { [weak self] in
                guard let self, self.audioMonitoringActive, self.audioDeviceChangeGeneration == generation else { return }
                NSLog("[LibWebRTC] forcing stream recovery after audio device change input=%u output=%u", self.defaultInputDevice, self.defaultOutputDevice)
                self.owner?.handleConnectionState(false, error: "webrtc audio device changed")
            }
        }
    }

    @objc(startMicrophoneLevelPollingWithSessionImpl:statsQueue:)
    func startMicrophoneLevelPolling(sessionImpl: OPNLibWebRTCSessionImpl?, statsQueue: DispatchQueue) {
        guard microphoneLevelTimer == nil else { return }
        self.sessionImpl = sessionImpl
        let timer = DispatchSource.makeTimerSource(queue: statsQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
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
        NSLog("[LibWebRTC] microphone level polling started")
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

    private static func defaultAudioDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
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
