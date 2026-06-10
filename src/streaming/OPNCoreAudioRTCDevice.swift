import AudioUnit
import CoreAudio
import Foundation

@_silgen_name("OPNCoreAudioRTCDeviceHandleGameAudioFrame")
private func OPNCoreAudioRTCDeviceHandleGameAudioFrame(
    _ owner: UnsafeMutableRawPointer?,
    _ audioBufferList: UnsafeRawPointer?,
    _ frameCount: UInt32,
    _ sampleRate: Double,
    _ channels: UInt32
)

@_silgen_name("OPNCoreAudioRTCDeviceDelegatePreferredInputSampleRate")
private func OPNCoreAudioRTCDeviceDelegatePreferredInputSampleRate(_ delegate: AnyObject?) -> Double

@_silgen_name("OPNCoreAudioRTCDeviceDelegatePreferredOutputSampleRate")
private func OPNCoreAudioRTCDeviceDelegatePreferredOutputSampleRate(_ delegate: AnyObject?) -> Double

@_silgen_name("OPNCoreAudioRTCDeviceDelegatePreferredInputIOBufferDuration")
private func OPNCoreAudioRTCDeviceDelegatePreferredInputIOBufferDuration(_ delegate: AnyObject?) -> Double

@_silgen_name("OPNCoreAudioRTCDeviceDelegatePreferredOutputIOBufferDuration")
private func OPNCoreAudioRTCDeviceDelegatePreferredOutputIOBufferDuration(_ delegate: AnyObject?) -> Double

@_silgen_name("OPNCoreAudioRTCDeviceDelegateNotifyDeviceChange")
private func OPNCoreAudioRTCDeviceDelegateNotifyDeviceChange(_ delegate: AnyObject?)

@_silgen_name("OPNCoreAudioRTCDeviceDelegateGetPlayoutData")
private func OPNCoreAudioRTCDeviceDelegateGetPlayoutData(
    _ delegate: AnyObject?,
    _ actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?,
    _ timestamp: UnsafePointer<AudioTimeStamp>?,
    _ busNumber: Int,
    _ frameCount: UInt32,
    _ audioBufferList: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus

@_silgen_name("OPNCoreAudioRTCDeviceDelegateDeliverRecordedData")
private func OPNCoreAudioRTCDeviceDelegateDeliverRecordedData(
    _ delegate: AnyObject?,
    _ actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?,
    _ timestamp: UnsafePointer<AudioTimeStamp>?,
    _ busNumber: Int,
    _ frameCount: UInt32,
    _ audioBufferList: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus

private func defaultAudioDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
        return AudioDeviceID(kAudioObjectUnknown)
    }
    return device
}

private let playoutCallback: AURenderCallback = { refCon, actionFlags, timestamp, busNumber, frameCount, outputData in
    let device = Unmanaged<OPNCoreAudioRTCDevice>.fromOpaque(refCon).takeUnretainedValue()
    return device.renderPlayout(actionFlags: actionFlags, timestamp: timestamp, busNumber: Int(busNumber), frameCount: frameCount, outputData: outputData)
}

private let recordingCallback: AURenderCallback = { refCon, actionFlags, timestamp, busNumber, frameCount, _ in
    let device = Unmanaged<OPNCoreAudioRTCDevice>.fromOpaque(refCon).takeUnretainedValue()
    return device.captureRecording(actionFlags: actionFlags, timestamp: timestamp, busNumber: Int(busNumber), frameCount: frameCount)
}

@objc(OPNCoreAudioRTCDevice)
final class OPNCoreAudioRTCDevice: NSObject, @unchecked Sendable {
    @objc var owner: UnsafeMutableRawPointer?

    private let audioQueue = DispatchQueue(label: "io.opencg.opennow.webrtc.coreaudio")
    private var playoutUnit: AudioUnit?
    private var recordingUnit: AudioUnit?
    private var outputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var inputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var recordingScratch: [UInt8] = []
    private weak var delegate: AnyObject?

    @objc private(set) var deviceInputSampleRate = 48_000.0
    @objc private(set) var inputIOBufferDuration: TimeInterval = 0.01
    @objc private(set) var inputNumberOfChannels = 1
    @objc private(set) var inputLatency: TimeInterval = 0
    @objc private(set) var deviceOutputSampleRate = 48_000.0
    @objc private(set) var outputIOBufferDuration: TimeInterval = 0.01
    @objc private(set) var outputNumberOfChannels = 2
    @objc private(set) var outputLatency: TimeInterval = 0
    @objc private(set) var isInitialized = false
    @objc private(set) var isPlayoutInitialized = false
    @objc private(set) var isPlaying = false
    @objc private(set) var isRecordingInitialized = false
    @objc private(set) var isRecording = false

    override init() {
        super.init()
        updateDeviceParameters()
    }

    deinit {
        _ = terminateDevice()
    }

    @objc(initializeWithDelegate:)
    func initialize(with delegate: AnyObject) -> Bool {
        audioQueue.sync {
            self.delegate = delegate
            isInitialized = true
            updateDeviceParameters()
        }
        return true
    }

    @objc func terminateDevice() -> Bool {
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

    @objc func initializePlayout() -> Bool {
        audioQueue.sync { initializePlayoutLocked() }
    }

    @objc func startPlayout() -> Bool {
        audioQueue.sync { startPlayoutLocked() }
    }

    @objc func stopPlayout() -> Bool {
        audioQueue.sync { stopPlayoutLocked() }
        return true
    }

    @objc func initializeRecording() -> Bool {
        audioQueue.sync { initializeRecordingLocked() }
    }

    @objc func startRecording() -> Bool {
        audioQueue.sync { startRecordingLocked() }
    }

    @objc func stopRecording() -> Bool {
        audioQueue.sync { stopRecordingLocked() }
        return true
    }

    @objc func handleDefaultDeviceChange() {
        audioQueue.async {
            let restartPlayout = self.isPlaying
            let restartRecording = self.isRecording
            self.stopPlayoutLocked()
            self.stopRecordingLocked()
            self.disposePlayoutUnitLocked()
            self.disposeRecordingUnitLocked()
            self.updateDeviceParameters()
            OPNCoreAudioRTCDeviceDelegateNotifyDeviceChange(self.delegate)
            if restartPlayout { _ = self.startPlayoutLocked() }
            if restartRecording { _ = self.startRecordingLocked() }
            NSLog("[LibWebRTC] CoreAudio RTC device hot-swapped input=%u output=%u play=%d record=%d", self.inputDevice, self.outputDevice, self.isPlaying ? 1 : 0, self.isRecording ? 1 : 0)
        }
    }

    fileprivate func renderPlayout(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?,
        timestamp: UnsafePointer<AudioTimeStamp>?,
        busNumber: Int,
        frameCount: UInt32,
        outputData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let delegate, let outputData else {
            clearAudioBufferList(outputData)
            return noErr
        }
        let status = OPNCoreAudioRTCDeviceDelegateGetPlayoutData(delegate, actionFlags, timestamp, busNumber, frameCount, outputData)
        if status != noErr { clearAudioBufferList(outputData) }
        if status == noErr {
            OPNCoreAudioRTCDeviceHandleGameAudioFrame(owner, UnsafeRawPointer(outputData), frameCount, deviceOutputSampleRate, UInt32(outputNumberOfChannels))
        }
        return status
    }

    fileprivate func captureRecording(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?,
        timestamp: UnsafePointer<AudioTimeStamp>?,
        busNumber: Int,
        frameCount: UInt32
    ) -> OSStatus {
        guard let delegate, let recordingUnit, let timestamp else { return noErr }
        let format = streamFormat(sampleRate: deviceInputSampleRate, channels: UInt32(inputNumberOfChannels))
        let requiredBytes = Int(frameCount) * Int(format.mBytesPerFrame)
        if recordingScratch.count < requiredBytes {
            recordingScratch = [UInt8](repeating: 0, count: requiredBytes)
        }
        return recordingScratch.withUnsafeMutableBytes { scratch in
            var inputData = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(inputNumberOfChannels),
                    mDataByteSize: UInt32(requiredBytes),
                    mData: scratch.baseAddress
                )
            )
            let renderStatus = AudioUnitRender(recordingUnit, actionFlags, timestamp, 1, frameCount, &inputData)
            guard renderStatus == noErr else { return renderStatus }
            return OPNCoreAudioRTCDeviceDelegateDeliverRecordedData(delegate, actionFlags, timestamp, busNumber, frameCount, &inputData)
        }
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
        guard outputDevice != kAudioObjectUnknown, let unit = createHALOutputUnit() else { return false }
        playoutUnit = unit
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disable, UInt32(MemoryLayout<UInt32>.size))
        var selectedOutputDevice = outputDevice
        let deviceStatus = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selectedOutputDevice, UInt32(MemoryLayout<AudioDeviceID>.size))
        if deviceStatus != noErr { NSLog("[LibWebRTC] CoreAudio set output device failed status=%d device=%u", deviceStatus, selectedOutputDevice) }
        var format = streamFormat(sampleRate: deviceOutputSampleRate, channels: UInt32(outputNumberOfChannels))
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var callback = AURenderCallbackStruct(inputProc: playoutCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        let initStatus = AudioUnitInitialize(unit)
        guard initStatus == noErr else {
            NSLog("[LibWebRTC] CoreAudio playout initialize failed status=%d", initStatus)
            disposePlayoutUnitLocked()
            return false
        }
        isPlayoutInitialized = true
        return true
    }

    private func initializeRecordingLocked() -> Bool {
        if isRecordingInitialized, recordingUnit != nil { return true }
        updateDeviceParameters()
        guard inputDevice != kAudioObjectUnknown, let unit = createHALOutputUnit() else { return false }
        recordingUnit = unit
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        var selectedInputDevice = inputDevice
        let deviceStatus = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selectedInputDevice, UInt32(MemoryLayout<AudioDeviceID>.size))
        if deviceStatus != noErr { NSLog("[LibWebRTC] CoreAudio set input device failed status=%d device=%u", deviceStatus, selectedInputDevice) }
        var format = streamFormat(sampleRate: deviceInputSampleRate, channels: UInt32(inputNumberOfChannels))
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var callback = AURenderCallbackStruct(inputProc: recordingCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        let initStatus = AudioUnitInitialize(unit)
        guard initStatus == noErr else {
            NSLog("[LibWebRTC] CoreAudio recording initialize failed status=%d", initStatus)
            disposeRecordingUnitLocked()
            return false
        }
        isRecordingInitialized = true
        return true
    }

    private func createHALOutputUnit() -> AudioUnit? {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
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
        guard let unit = playoutUnit else { return }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        playoutUnit = nil
        isPlayoutInitialized = false
    }

    private func disposeRecordingUnitLocked() {
        guard let unit = recordingUnit else { return }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        recordingUnit = nil
        isRecordingInitialized = false
    }

    private func updateDeviceParameters() {
        inputDevice = defaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice)
        outputDevice = defaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let preferredInputRate = OPNCoreAudioRTCDeviceDelegatePreferredInputSampleRate(delegate)
        let preferredOutputRate = OPNCoreAudioRTCDeviceDelegatePreferredOutputSampleRate(delegate)
        deviceInputSampleRate = nominalSampleRate(for: inputDevice, fallback: preferredInputRate > 0 ? preferredInputRate : 48_000.0)
        deviceOutputSampleRate = nominalSampleRate(for: outputDevice, fallback: preferredOutputRate > 0 ? preferredOutputRate : 48_000.0)
        inputNumberOfChannels = max(1, min(2, channelCount(for: inputDevice, scope: kAudioDevicePropertyScopeInput, fallback: 1)))
        outputNumberOfChannels = max(1, min(2, channelCount(for: outputDevice, scope: kAudioDevicePropertyScopeOutput, fallback: 2)))
        inputIOBufferDuration = OPNCoreAudioRTCDeviceDelegatePreferredInputIOBufferDuration(delegate)
        if inputIOBufferDuration <= 0 { inputIOBufferDuration = 0.01 }
        outputIOBufferDuration = OPNCoreAudioRTCDeviceDelegatePreferredOutputIOBufferDuration(delegate)
        if outputIOBufferDuration <= 0 { outputIOBufferDuration = 0.01 }
        inputLatency = latency(for: inputDevice, scope: kAudioDevicePropertyScopeInput)
        outputLatency = latency(for: outputDevice, scope: kAudioDevicePropertyScopeOutput)
    }

    private func nominalSampleRate(for device: AudioDeviceID, fallback: Double) -> Double {
        guard device != kAudioObjectUnknown else { return fallback }
        var rate = Float64(fallback)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return fallback }
        return rate
    }

    private func channelCount(for device: AudioDeviceID, scope: AudioObjectPropertyScope, fallback: Int) -> Int {
        guard device != kAudioObjectUnknown else { return fallback }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return fallback }
        var storage = [UInt8](repeating: 0, count: Int(size))
        let channels = storage.withUnsafeMutableBytes { rawBuffer -> UInt32 in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            let bufferList = baseAddress.assumingMemoryBound(to: AudioBufferList.self)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferList) == noErr else { return 0 }
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            return buffers.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
        }
        return channels > 0 ? Int(channels) : fallback
    }

    private func latency(for device: AudioDeviceID, scope: AudioObjectPropertyScope) -> TimeInterval {
        guard device != kAudioObjectUnknown else { return 0 }
        var latencyFrames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyLatency, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &latencyFrames) == noErr else { return 0 }
        let rate = scope == kAudioDevicePropertyScopeInput ? deviceInputSampleRate : deviceOutputSampleRate
        return rate > 0 ? Double(latencyFrames) / rate : 0
    }

    private func streamFormat(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        let channelCount = max(UInt32(1), channels)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate > 0 ? sampleRate : 48_000.0,
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
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for index in buffers.indices {
            if let data = buffers[index].mData, buffers[index].mDataByteSize > 0 {
                memset(data, 0, Int(buffers[index].mDataByteSize))
            }
        }
    }
}
