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

private let coreAudioPlayoutCallback: AURenderCallback = { refCon, actionFlags, timestamp, busNumber, frameCount, outputData in
    let device = Unmanaged<OPNCoreAudioRTCDevice>.fromOpaque(refCon).takeUnretainedValue()
    return device.renderPlayout(actionFlags: actionFlags, timestamp: timestamp, busNumber: Int(busNumber), frameCount: frameCount, outputData: outputData)
}

private let coreAudioRecordingCallback: AURenderCallback = { refCon, actionFlags, timestamp, busNumber, frameCount, _ in
    let device = Unmanaged<OPNCoreAudioRTCDevice>.fromOpaque(refCon).takeUnretainedValue()
    return device.captureRecording(actionFlags: actionFlags, timestamp: timestamp, busNumber: Int(busNumber), frameCount: frameCount)
}

@objc(OPNCoreAudioRTCDevice)
final class OPNCoreAudioRTCDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    weak var owner: OPNLibWebRTCStreamSession?

    private let audioQueue = DispatchQueue(label: "io.opencg.opennow.webrtc.coreaudio")
    private var playoutUnit: AudioUnit?
    private var recordingUnit: AudioUnit?
    private var outputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var inputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var recordingScratch = [UInt8]()
    private weak var delegate: RTCAudioDeviceDelegate?
    private var lastMicrophoneLevelReportNanoseconds: UInt64 = 0

    private(set) var deviceInputSampleRate = 48_000.0
    private(set) var inputIOBufferDuration: TimeInterval = 0.01
    private(set) var inputNumberOfChannels = 1
    private(set) var inputLatency: TimeInterval = 0
    private(set) var deviceOutputSampleRate = 48_000.0
    private(set) var outputIOBufferDuration: TimeInterval = 0.01
    private(set) var outputNumberOfChannels = 2
    private(set) var outputLatency: TimeInterval = 0
    private(set) var isInitialized = false
    private(set) var isPlayoutInitialized = false
    private(set) var isPlaying = false
    private(set) var isRecordingInitialized = false
    private(set) var isRecording = false

    @objc(initWithOwner:)
    init(owner: OPNLibWebRTCStreamSession?) {
        self.owner = owner
        super.init()
        updateDeviceParameters()
    }

    deinit {
        _ = terminateDevice()
    }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        audioQueue.sync {
            self.delegate = delegate
            isInitialized = true
            updateDeviceParameters()
        }
        return true
    }

    func terminateDevice() -> Bool {
        audioQueue.sync {
            stopPlayoutLocked()
            stopRecordingLocked()
            disposePlayoutUnitLocked()
            disposeRecordingUnitLocked()
            delegate = nil
            isInitialized = false
            isPlayoutInitialized = false
            isRecordingInitialized = false
        }
        return true
    }

    func initializePlayout() -> Bool {
        audioQueue.sync { initializePlayoutLocked() }
    }

    func startPlayout() -> Bool {
        audioQueue.sync { startPlayoutLocked() }
    }

    func stopPlayout() -> Bool {
        audioQueue.sync { stopPlayoutLocked() }
        return true
    }

    func initializeRecording() -> Bool {
        audioQueue.sync { initializeRecordingLocked() }
    }

    func startRecording() -> Bool {
        audioQueue.sync { startRecordingLocked() }
    }

    func stopRecording() -> Bool {
        audioQueue.sync { stopRecordingLocked() }
        return true
    }

    @objc func handleDefaultDeviceChange() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let restartPlayout = isPlaying
            let restartRecording = isRecording
            stopPlayoutLocked()
            stopRecordingLocked()
            disposePlayoutUnitLocked()
            disposeRecordingUnitLocked()
            updateDeviceParameters()
            if let delegate {
                delegate.dispatchAsync {
                    delegate.notifyAudioOutputInterrupted()
                    delegate.notifyAudioInputInterrupted()
                    delegate.notifyAudioOutputParametersChange()
                    delegate.notifyAudioInputParametersChange()
                }
            }
            if restartPlayout { _ = startPlayoutLocked() }
            if restartRecording { _ = startRecordingLocked() }
            NSLog("[LibWebRTC] CoreAudio RTC device hot-swapped input=%u output=%u play=%d record=%d", inputDevice, outputDevice, isPlaying ? 1 : 0, isRecording ? 1 : 0)
        }
    }

    func renderPlayout(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?, timestamp: UnsafePointer<AudioTimeStamp>?, busNumber: Int, frameCount: UInt32, outputData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let delegate, let actionFlags, let timestamp, let outputData else {
            clearAudioBufferList(outputData)
            return noErr
        }
        let status = delegate.getPlayoutData(actionFlags, timestamp, busNumber, frameCount, outputData)
        if status != noErr { clearAudioBufferList(outputData) }
        if status == noErr {
            owner?.handleGameAudioFrame(UnsafeRawPointer(outputData), frameCount: frameCount, sampleRate: deviceOutputSampleRate, channels: UInt32(outputNumberOfChannels))
        }
        return status
    }

    func captureRecording(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?, timestamp: UnsafePointer<AudioTimeStamp>?, busNumber: Int, frameCount: UInt32) -> OSStatus {
        guard let delegate, let recordingUnit, let actionFlags, let timestamp else { return noErr }
        let format = streamFormat(sampleRate: deviceInputSampleRate, channels: UInt32(inputNumberOfChannels))
        let requiredBytes = Int(frameCount) * Int(format.mBytesPerFrame)
        if recordingScratch.count < requiredBytes { recordingScratch = [UInt8](repeating: 0, count: requiredBytes) }
        return recordingScratch.withUnsafeMutableBytes { scratchBuffer in
            guard let baseAddress = scratchBuffer.baseAddress else { return noErr }
            var inputData = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: UInt32(inputNumberOfChannels), mDataByteSize: UInt32(requiredBytes), mData: baseAddress)
            )
            let renderStatus = AudioUnitRender(recordingUnit, actionFlags, timestamp, 1, frameCount, &inputData)
            guard renderStatus == noErr else { return renderStatus }
            reportMicrophoneLevelIfNeeded(inputData: &inputData)
            return delegate.deliverRecordedData(actionFlags, timestamp, busNumber, frameCount, &inputData, nil, nil)
        }
    }

    private func reportMicrophoneLevelIfNeeded(inputData: UnsafeMutablePointer<AudioBufferList>) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastMicrophoneLevelReportNanoseconds >= 50_000_000 else { return }
        lastMicrophoneLevelReportNanoseconds = now
        owner?.handleCapturedMicrophoneLevel(microphoneLevel(from: inputData))
    }

    private func microphoneLevel(from inputData: UnsafeMutablePointer<AudioBufferList>) -> Double {
        var sumSquares = 0.0
        var sampleCount = 0
        for buffer in UnsafeMutableAudioBufferListPointer(inputData) {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
            guard count > 0 else { continue }
            let samples = data.bindMemory(to: Int16.self, capacity: count)
            for index in 0..<count {
                let sample = Double(samples[index]) / Double(Int16.max)
                sumSquares += sample * sample
            }
            sampleCount += count
        }
        guard sampleCount > 0 else { return 0 }
        return min(1, sqrt(sumSquares / Double(sampleCount)) * 6)
    }

    private func startPlayoutLocked() -> Bool {
        guard initializePlayoutLocked(), let playoutUnit else { return false }
        let status = AudioOutputUnitStart(playoutUnit)
        isPlaying = status == noErr
        if status != noErr { NSLog("[LibWebRTC] CoreAudio playout start failed status=%d", status) }
        return isPlaying
    }

    private func startRecordingLocked() -> Bool {
        guard initializeRecordingLocked(), let recordingUnit else { return false }
        let status = AudioOutputUnitStart(recordingUnit)
        isRecording = status == noErr
        if status != noErr { NSLog("[LibWebRTC] CoreAudio recording start failed status=%d", status) }
        return isRecording
    }

    private func stopPlayoutLocked() {
        if let playoutUnit, isPlaying { AudioOutputUnitStop(playoutUnit) }
        isPlaying = false
    }

    private func stopRecordingLocked() {
        if let recordingUnit, isRecording { AudioOutputUnitStop(recordingUnit) }
        isRecording = false
    }

    private func initializePlayoutLocked() -> Bool {
        if isPlayoutInitialized, playoutUnit != nil { return true }
        updateDeviceParameters()
        guard outputDevice != AudioDeviceID(kAudioObjectUnknown), let unit = createHALOutputUnit() else { return false }
        playoutUnit = unit
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disable, UInt32(MemoryLayout<UInt32>.size))
        var device = outputDevice
        var status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { NSLog("[LibWebRTC] CoreAudio set output device failed status=%d device=%u", status, outputDevice) }
        var format = streamFormat(sampleRate: deviceOutputSampleRate, channels: UInt32(outputNumberOfChannels))
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var callback = AURenderCallbackStruct(inputProc: coreAudioPlayoutCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            NSLog("[LibWebRTC] CoreAudio playout initialize failed status=%d", status)
            disposePlayoutUnitLocked()
            return false
        }
        isPlayoutInitialized = true
        return true
    }

    private func initializeRecordingLocked() -> Bool {
        if isRecordingInitialized, recordingUnit != nil { return true }
        updateDeviceParameters()
        guard inputDevice != AudioDeviceID(kAudioObjectUnknown), let unit = createHALOutputUnit() else { return false }
        recordingUnit = unit
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        var device = inputDevice
        var status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { NSLog("[LibWebRTC] CoreAudio set input device failed status=%d device=%u", status, inputDevice) }
        var format = streamFormat(sampleRate: deviceInputSampleRate, channels: UInt32(inputNumberOfChannels))
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var callback = AURenderCallbackStruct(inputProc: coreAudioRecordingCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            NSLog("[LibWebRTC] CoreAudio recording initialize failed status=%d", status)
            disposeRecordingUnitLocked()
            return false
        }
        isRecordingInitialized = true
        return true
    }

    private func createHALOutputUnit() -> AudioUnit? {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var unit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr else {
            NSLog("[LibWebRTC] CoreAudio HAL unit creation failed status=%d", status)
            return nil
        }
        return unit
    }

    private func disposePlayoutUnitLocked() {
        guard let playoutUnit else { return }
        AudioUnitUninitialize(playoutUnit)
        AudioComponentInstanceDispose(playoutUnit)
        self.playoutUnit = nil
        isPlayoutInitialized = false
    }

    private func disposeRecordingUnitLocked() {
        guard let recordingUnit else { return }
        AudioUnitUninitialize(recordingUnit)
        AudioComponentInstanceDispose(recordingUnit)
        self.recordingUnit = nil
        isRecordingInitialized = false
    }

    private func updateDeviceParameters() {
        inputDevice = OPNLibWebRTCAudio.defaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice)
        outputDevice = OPNLibWebRTCAudio.defaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let preferredInputSampleRate = delegate?.preferredInputSampleRate ?? 0
        let preferredOutputSampleRate = delegate?.preferredOutputSampleRate ?? 0
        deviceInputSampleRate = nominalSampleRate(for: inputDevice, fallback: preferredInputSampleRate > 0 ? preferredInputSampleRate : 48_000)
        deviceOutputSampleRate = nominalSampleRate(for: outputDevice, fallback: preferredOutputSampleRate > 0 ? preferredOutputSampleRate : 48_000)
        inputNumberOfChannels = max(1, min(2, channelCount(for: inputDevice, scope: kAudioDevicePropertyScopeInput, fallback: 1)))
        outputNumberOfChannels = max(1, min(2, channelCount(for: outputDevice, scope: kAudioDevicePropertyScopeOutput, fallback: 2)))
        let preferredInputBufferDuration = delegate?.preferredInputIOBufferDuration ?? 0
        let preferredOutputBufferDuration = delegate?.preferredOutputIOBufferDuration ?? 0
        inputIOBufferDuration = preferredInputBufferDuration > 0 ? preferredInputBufferDuration : 0.01
        outputIOBufferDuration = preferredOutputBufferDuration > 0 ? preferredOutputBufferDuration : 0.01
        inputLatency = latency(for: inputDevice, scope: kAudioDevicePropertyScopeInput)
        outputLatency = latency(for: outputDevice, scope: kAudioDevicePropertyScopeOutput)
    }

    private func nominalSampleRate(for device: AudioDeviceID, fallback: Double) -> Double {
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return fallback }
        var rate = Float64(fallback)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return fallback }
        return rate
    }

    private func channelCount(for device: AudioDeviceID, scope: AudioObjectPropertyScope, fallback: Int) -> Int {
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return fallback }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return fallback }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let bufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferList) == noErr else { return fallback }
        var channels: UInt32 = 0
        for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
            channels += buffer.mNumberChannels
        }
        return channels > 0 ? Int(channels) : fallback
    }

    private func latency(for device: AudioDeviceID, scope: AudioObjectPropertyScope) -> TimeInterval {
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return 0 }
        var latencyFrames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyLatency, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &latencyFrames) == noErr else { return 0 }
        let rate = scope == kAudioDevicePropertyScopeInput ? deviceInputSampleRate : deviceOutputSampleRate
        return rate > 0 ? Double(latencyFrames) / rate : 0
    }

    private func streamFormat(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        let channelCount = max(1, channels)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate > 0 ? sampleRate : 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channelCount * UInt32(MemoryLayout<Int16>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: channelCount * UInt32(MemoryLayout<Int16>.size),
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }

    private func clearAudioBufferList(_ bufferList: UnsafeMutablePointer<AudioBufferList>?) {
        guard let bufferList else { return }
        for buffer in UnsafeMutableAudioBufferListPointer(bufferList) where buffer.mData != nil && buffer.mDataByteSize > 0 {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
    }
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
        if let audioDevice = sessionImpl.audioDevice {
            audioDevice.handleDefaultDeviceChange()
            NSLog("[LibWebRTC] audio device refresh delegated to CoreAudio RTC device input=%u output=%u", defaultInputDevice, defaultOutputDevice)
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
        let customAudioDeviceActive = sessionImpl?.audioDevice != nil
        if !customAudioDeviceActive, Self.envFlagEnabled("OPN_ENABLE_WEBRTC_AUDIO_HOTSWAP_RECOVERY", defaultValue: true) {
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
        if sessionImpl?.audioDevice != nil {
            NSLog("[LibWebRTC] microphone level polling using CoreAudio capture samples")
            return
        }
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

    fileprivate static func defaultAudioDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
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
