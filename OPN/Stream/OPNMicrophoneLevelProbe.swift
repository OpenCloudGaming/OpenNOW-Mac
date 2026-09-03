//  Standalone CoreAudio input tap for the Settings microphone test. Deliberately libwebrtc-free:
//  settings has no streaming session, and needing one to confirm the mic is alive is exactly the
//  trap the test exists to avoid. Opens a HAL input unit on the selected (or default) input
//  device, measures the RMS of what arrives, and reports a 0...1 level scaled the same way as
//  the in-stream device's meter, so the two read identically.
//

import AudioUnit
import CoreAudio
import Foundation

final class OPNMicrophoneLevelProbe: @unchecked Sendable {
    enum ProbeFailure: Error, Equatable, Sendable {
        case noInputDevice
        case unitCreationFailed
        case unitConfigurationFailed(OSStatus)
        case unitStartFailed(OSStatus)
    }

    /// Called with a 0...1 level at most every 50 ms, on the CoreAudio render thread: receivers
    /// must hop to their own queue and never block here.
    var onLevel: (@Sendable (Double) -> Void)?

    private let audioQueue = DispatchQueue(label: "io.opencg.opennow.microphone-level-probe")
    private var unit: AudioUnit?
    private var scratch = [Int16]()
    private var channelCount = 1
    private var lastReportNanoseconds: UInt64 = 0

    deinit {
        audioQueue.sync { stopLocked() }
    }

    var isRunning: Bool {
        audioQueue.sync { unit != nil }
    }

    /// Starts capture on the device whose UID is `deviceUniqueId`, or on the system default
    /// input when that is nil or empty. Throws `ProbeFailure` when nothing can be opened.
    func start(deviceUniqueId: String?) throws {
        try audioQueue.sync { try startLocked(deviceUniqueId: deviceUniqueId) }
    }

    func stop() {
        audioQueue.sync { stopLocked() }
    }

    private func startLocked(deviceUniqueId: String?) throws {
        guard unit == nil else { return }
        let device = Self.inputDevice(matching: deviceUniqueId)
        guard device != AudioDeviceID(kAudioObjectUnknown) else { throw ProbeFailure.noInputDevice }
        guard let created = Self.createHALInputUnit() else { throw ProbeFailure.unitCreationFailed }
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        var status = AudioUnitSetProperty(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size))
        if status == noErr { status = AudioUnitSetProperty(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)) }
        var deviceID = device
        if status == noErr { status = AudioUnitSetProperty(created, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) }
        channelCount = Self.inputChannelCount(for: device)
        var format = Self.streamFormat(sampleRate: Self.nominalSampleRate(for: device), channels: UInt32(channelCount))
        if status == noErr { status = AudioUnitSetProperty(created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) }
        var callback = AURenderCallbackStruct(inputProc: Self.captureCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        if status == noErr { status = AudioUnitSetProperty(created, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) }
        if status == noErr { status = AudioUnitInitialize(created) }
        guard status == noErr else {
            AudioComponentInstanceDispose(created)
            throw ProbeFailure.unitConfigurationFailed(status)
        }
        status = AudioOutputUnitStart(created)
        guard status == noErr else {
            AudioUnitUninitialize(created)
            AudioComponentInstanceDispose(created)
            throw ProbeFailure.unitStartFailed(status)
        }
        unit = created
    }

    private func stopLocked() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        scratch.removeAll()
        lastReportNanoseconds = 0
    }

    private static let captureCallback: AURenderCallback = { refCon, actionFlags, timestamp, _, frameCount, _ in
        let probe = Unmanaged<OPNMicrophoneLevelProbe>.fromOpaque(refCon).takeUnretainedValue()
        return probe.capture(actionFlags: actionFlags, timestamp: timestamp, frameCount: frameCount)
    }

    private func capture(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?, timestamp: UnsafePointer<AudioTimeStamp>?, frameCount: UInt32) -> OSStatus {
        guard let unit, let actionFlags, let timestamp else { return noErr }
        let requiredSamples = Int(frameCount) * channelCount
        let requiredBytes = requiredSamples * MemoryLayout<Int16>.size
        if scratch.count < requiredSamples { scratch = [Int16](repeating: 0, count: requiredSamples) }
        return scratch.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return noErr }
            var inputData = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: UInt32(channelCount), mDataByteSize: UInt32(requiredBytes), mData: baseAddress)
            )
            let status = AudioUnitRender(unit, actionFlags, timestamp, 1, frameCount, &inputData)
            guard status == noErr else { return status }
            // The level is measured off the local buffer copy, never off `scratch` itself: this
            // closure already holds the exclusive mutable access to `scratch`, so touching the
            // property again here would trip Swift's exclusivity check on the IO thread.
            return reportLevelIfNeeded(samples: buffer, sampleCount: requiredSamples)
        }
    }

    /// RMS over the frame, throttled to 20 reports a second. Same `* 6` gain as the streaming
    /// device's meter: normal speech should sit mid-scale on both.
    private func reportLevelIfNeeded(samples: UnsafeMutableBufferPointer<Int16>, sampleCount: Int) -> OSStatus {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastReportNanoseconds >= 50_000_000 else { return noErr }
        lastReportNanoseconds = now
        let count = min(sampleCount, samples.count)
        guard count > 0 else { return noErr }
        var sumSquares = 0.0
        for index in 0..<count {
            let sample = Double(samples[index]) / Double(Int16.max)
            sumSquares += sample * sample
        }
        let level = min(1, sqrt(sumSquares / Double(count)) * 6)
        onLevel?(level)
        return noErr
    }

    // MARK: - Device lookup

    static func inputDevice(matching uniqueId: String?) -> AudioDeviceID {
        if let uniqueId, !uniqueId.isEmpty {
            for device in allInputDevices() where uid(of: device) == uniqueId { return device }
        }
        return defaultInputDevice()
    }

    static func defaultInputDevice() -> AudioDeviceID {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return AudioDeviceID(kAudioObjectUnknown)
        }
        return device
    }

    /// Same enumeration as `OPNStreamPreferences.loadMicrophoneDeviceOptions`: only devices with
    /// at least one input stream qualify, so a selected-but-gone device falls back to the default.
    static func allInputDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices) == noErr else { return [] }
        return devices.filter { device in
            var streamAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamDataSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &streamDataSize) == noErr && streamDataSize > 0
        }
    }

    static func uid(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: - Format

    private static func createHALInputUnit() -> AudioUnit? {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr else { return nil }
        return unit
    }

    private static func nominalSampleRate(for device: AudioDeviceID) -> Double {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return 48_000 }
        return rate
    }

    private static func inputChannelCount(for device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 1 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let bufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferList) == noErr else { return 1 }
        var channels: UInt32 = 0
        for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
            channels += buffer.mNumberChannels
        }
        return max(1, min(2, Int(channels)))
    }

    private static func streamFormat(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
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
}
