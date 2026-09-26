import AudioToolbox
import CoreAudio
import Foundation

private let nvstPlayoutCallback: AURenderCallback = { refCon, actionFlags, timestamp, busNumber, frameCount, outputData in
    let device = Unmanaged<NvstCoreAudioDevice>.fromOpaque(refCon).takeUnretainedValue()
    return device.renderPlayout(actionFlags: actionFlags, timestamp: timestamp, busNumber: Int(busNumber), frameCount: frameCount, outputData: outputData)
}

private let nvstCaptureCallback: AURenderCallback = { refCon, actionFlags, timestamp, busNumber, frameCount, _ in
    let device = Unmanaged<NvstCoreAudioDevice>.fromOpaque(refCon).takeUnretainedValue()
    return device.captureMicrophone(actionFlags: actionFlags, timestamp: timestamp, busNumber: Int(busNumber), frameCount: frameCount)
}

private let nvstDefaultOutputListener: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let clientData else { return noErr }
    let device = Unmanaged<NvstCoreAudioDevice>.fromOpaque(clientData).takeUnretainedValue()
    device.handleDefaultOutputDeviceChange()
    return noErr
}

private let nvstInputDeviceListener: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let clientData else { return noErr }
    let device = Unmanaged<NvstCoreAudioDevice>.fromOpaque(clientData).takeUnretainedValue()
    device.handleInputDeviceEnvironmentChange()
    return noErr
}

/// Which device capture is running on, reported when it changes under the session's feet: the saved
/// device came back, or it went away and capture fell back to the system default.
public struct NvstCaptureDeviceChange: Equatable, Sendable {
    /// The UID capture actually runs on. Nil when CoreAudio reports no default input at all.
    public let resolvedUniqueID: String?
    /// The UID the user chose. Nil or empty means "Default Device", which never counts as a fallback.
    public let preferredUniqueID: String?
    /// True when the chosen device is gone and capture is running on the default instead.
    public let isFallback: Bool
}

/// The native audio device the NVST bundle's audio runs through.
///
/// It replaces the libwebrtc `RTCAudioDevice` the bundle used to borrow: the playout callback is
/// where decoded game audio crosses out to be recorded and relayed to a Remote Co-Op guest, and the
/// capture callback is where the microphone's PCM enters the up-path. Neither direction knows about
/// Opus or SRTP — the pipelines do — so the device is only format conversion and timing.
public final class NvstCoreAudioDevice: NSObject, @unchecked Sendable {
    /// Fills `sampleCount` interleaved 16-bit samples for the speaker. Called on the audio render
    /// thread, so it must not allocate or block; the caller's provider writes into the buffer.
    public var fillPlayout: (@Sendable (UnsafeMutablePointer<Int16>, Int) -> Void)?
    /// Decoded game audio as it is handed to the speaker, before any local mute. Feeds recording and
    /// the Co-Op relay, which must keep hearing the game while the speakers are silenced.
    public var onGameAudio: (@Sendable (UnsafeRawPointer?, UInt32, Double, UInt32) -> Void)?
    /// Captured microphone PCM, interleaved 16-bit, at `inputSampleRate` and `inputChannels`.
    public var onMicrophoneAudio: (@Sendable (UnsafeRawPointer?, UInt32, Double, UInt32) -> Void)?
    public var onMicrophoneLevel: (@Sendable (Double) -> Void)?
    /// The microphone gate. While false the capture callback hands on silence, so the hardware stays
    /// idle-gated without the device having to be torn down.
    public var isMicrophoneCaptureEnabled: (@Sendable () -> Bool)?
    /// Silences this Mac's speakers only, applied after the tee. Never upstream of it.
    public var isPlayoutMuted = false

    /// A capture device swap, or a plug/unplug that removes the one in use. Never fires for a
    /// deliberate change to a device that is present.
    public var onCaptureDeviceChange: (@Sendable (NvstCaptureDeviceChange) -> Void)?
    /// The set of input devices changed at all, whatever it resolved to. Fires for a device that was
    /// plugged in, which is what makes it selectable without reopening the HUD.
    public var onInputDeviceListChange: (@Sendable () -> Void)?

    let audioQueue = DispatchQueue(label: "io.opencg.opennow.nvst.coreaudio")
    private let requestedPlayoutChannels: Int
    private let capturesMicrophone: Bool
    private let monitorsDefaultOutput: Bool
    private var playoutUnit: AudioUnit?
    private var captureUnit: AudioUnit?
    private var outputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var inputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var captureScratch = [Int16]()
    private var lastLevelReportNanoseconds: UInt64 = 0
    /// The UID the microphone picker saved, resolved on every rebuild. Nil or empty is
    /// "Default Device", which follows the system default input wherever it goes.
    private var preferredInputDeviceUID: String?
    /// The UID capture is running on, and whether that is a fallback from a device that went away.
    private var inputDeviceUniqueID: String?
    private var inputUsesFallbackDevice = false
    /// CoreAudio fires several notifications for one physical plug or unplug, and every rebuild
    /// disposes and recreates an AudioUnit, so the burst is collapsed into one deferred rebuild.
    private var inputDeviceChangeWorkItem: DispatchWorkItem?
    private var inputDeviceEvaluationCount = 0
    private var captureRebuildCount = 0
    private static let inputDeviceChangeDebounce = DispatchTimeInterval.milliseconds(250)
    /// Guards the capture unit and its format against the CoreAudio render thread.
    ///
    /// `captureMicrophone` runs on the IO thread and reads `captureUnit`, `inputChannels` and
    /// `captureScratch`, while a rebuild mutates all three on `audioQueue`. Without this a device
    /// swap could dispose the unit underneath an in-flight callback. The render path already takes an
    /// `NSLock` inside `NvstAudioSendPipeline.push`, so this adds no new kind of blocking to that
    /// thread; the critical section is a unit swap, which the hardware is not calling into anyway.
    private let captureStateLock = NSLock()

    /// The rate the callbacks exchange with the pipelines, always 48 kHz — the rate Opus, the RTP
    /// clock and the jitter buffer all assume. A device that runs at another rate is resampled by
    /// its HAL unit, so the pipelines never see the hardware's rate.
    public private(set) var outputSampleRate: Double = NvstCoreAudioFormat.sampleRate
    public private(set) var inputSampleRate: Double = NvstCoreAudioFormat.sampleRate
    /// The hardware's own rate, kept only for the IO-buffer and latency arithmetic, which are
    /// expressed in device frames.
    public private(set) var deviceOutputSampleRate: Double = NvstCoreAudioFormat.sampleRate
    public private(set) var deviceInputSampleRate: Double = NvstCoreAudioFormat.sampleRate
    public private(set) var outputChannels = 2
    public private(set) var inputChannels = 1
    public private(set) var outputIOBufferDuration: TimeInterval = 0.01
    public private(set) var outputLatency: TimeInterval = 0
    public private(set) var isPlayoutRunning = false
    public private(set) var isCaptureRunning = false

    /// False when CoreAudio reports no default output at all, in which case nothing can be played.
    public var hasUsableOutputDevice: Bool {
        audioQueue.sync { outputDevice != AudioDeviceID(kAudioObjectUnknown) }
    }

    public var outputPathLatencySeconds: TimeInterval { outputLatency + outputIOBufferDuration }

    public init(playoutChannelCount: Int = 2,
                capturesMicrophone: Bool = true,
                monitorsDefaultOutputDevice: Bool = true,
                preferredInputDeviceUID: String? = nil) {
        self.requestedPlayoutChannels = NvstCoreAudioFormat.supportedPlayoutChannelCount(playoutChannelCount)
        self.capturesMicrophone = capturesMicrophone
        self.monitorsDefaultOutput = monitorsDefaultOutputDevice
        self.preferredInputDeviceUID = preferredInputDeviceUID.flatMap { $0.isEmpty ? nil : $0 }
        super.init()
        audioQueue.sync { updateDeviceParameters() }
        if monitorsDefaultOutputDevice { startDefaultOutputMonitoring() }
        if capturesMicrophone { startInputDeviceMonitoring() }
    }

    deinit {
        stopDefaultOutputMonitoring()
        stopInputDeviceMonitoring()
        inputDeviceChangeWorkItem?.cancel()
        audioQueue.sync {
            stopPlayoutLocked()
            stopCaptureLocked()
            disposePlayoutUnitLocked()
            disposeCaptureUnitLocked()
        }
    }

    public func start() {
        audioQueue.sync {
            updateDeviceParameters()
            _ = startPlayoutLocked()
            if capturesMicrophone { _ = startCaptureLocked() }
        }
    }

    public func stop() {
        audioQueue.sync {
            stopPlayoutLocked()
            stopCaptureLocked()
        }
    }

    // MARK: - Callbacks

    func renderPlayout(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?, timestamp: UnsafePointer<AudioTimeStamp>?, busNumber: Int, frameCount: UInt32, outputData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let outputData else { return noErr }
        let channels = outputChannels
        let frames = Int(frameCount)
        let list = UnsafeMutableAudioBufferListPointer(outputData)
        guard let first = list.first, let base = first.mData,
              Int(first.mDataByteSize) >= frames * channels * MemoryLayout<Int16>.size else {
            clear(outputData)
            return noErr
        }
        let destination = base.assumingMemoryBound(to: Int16.self)
        if let fillPlayout { fillPlayout(destination, frames * channels) }
        if fillPlayout == nil { destination.update(repeating: 0, count: frames * channels) }
        // After the fill, never before: a recording and a Co-Op guest are fed from here and must keep
        // hearing the game while these speakers are silent.
        onGameAudio?(UnsafeRawPointer(outputData), frameCount, outputSampleRate, UInt32(channels))
        if isPlayoutMuted { clear(outputData) }
        return noErr
    }

    func captureMicrophone(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?, timestamp: UnsafePointer<AudioTimeStamp>?, busNumber: Int, frameCount: UInt32) -> OSStatus {
        // The whole render is under the capture lock, so a device swap on `audioQueue` cannot dispose
        // the unit or reallocate the scratch buffer underneath it. The level reading is handed back
        // rather than delivered here: nothing outside the device's own state should run while the
        // lock is held, and a receiver that hops to its own queue must be free to do so.
        var sampledLevel: Double?
        captureStateLock.lock()
        let status = renderCaptureLocked(actionFlags: actionFlags, timestamp: timestamp, frameCount: frameCount, sampledLevel: &sampledLevel)
        captureStateLock.unlock()
        if let sampledLevel { onMicrophoneLevel?(sampledLevel) }
        return status
    }

    private func renderCaptureLocked(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?, timestamp: UnsafePointer<AudioTimeStamp>?, frameCount: UInt32, sampledLevel: inout Double?) -> OSStatus {
        guard let captureUnit, let actionFlags, let timestamp else { return noErr }
        let channels = inputChannels
        let requiredSamples = Int(frameCount) * channels
        if captureScratch.count < requiredSamples {
            captureScratch = [Int16](repeating: 0, count: requiredSamples)
        }
        return captureScratch.withUnsafeMutableBufferPointer { scratch in
            guard let base = scratch.baseAddress else { return noErr }
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(requiredSamples * MemoryLayout<Int16>.size),
                    mData: base
                )
            )
            let status = AudioUnitRender(captureUnit, actionFlags, timestamp, 1, frameCount, &bufferList)
            guard status == noErr else { return status }
            guard isMicrophoneCaptureEnabled?() == true else {
                // Gated: hand the up-path silence rather than the microphone's samples, and report a
                // flat meter with it. A meter that moved while muted would say the seat is hearing
                // something it is not.
                base.update(repeating: 0, count: requiredSamples)
                return noErr
            }
            sampledLevel = levelWhenDue(base, count: requiredSamples)
            withUnsafePointer(to: &bufferList) { pointer in
                onMicrophoneAudio?(UnsafeRawPointer(pointer), frameCount, inputSampleRate, UInt32(channels))
            }
            return noErr
        }
    }

    func handleDefaultOutputDeviceChange() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let wasPlaying = isPlayoutRunning
            stopPlayoutLocked()
            disposePlayoutUnitLocked()
            rebuildCaptureLocked()
            if wasPlaying { _ = startPlayoutLocked() }
        }
    }

    /// The microphone picker's UID, applied to the running session.
    ///
    /// Only the capture unit is torn down. The send pipeline, its SSRC and its RTP sequence are
    /// untouched, because the seat's microphone contract was fixed at ANNOUNCE and a device change
    /// must not look like a new talkspurt to it.
    public func setPreferredInputDevice(uid: String?) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let normalized = uid.flatMap { $0.isEmpty ? nil : $0 }
            let previousDevice = inputDevice
            let previousFallback = inputUsesFallbackDevice
            preferredInputDeviceUID = normalized
            if OPNCoreAudioDeviceLookup.inputDevice(matching: normalized) != previousDevice {
                rebuildCaptureLocked()
            } else {
                // Same device: still re-read the parameters, because the fallback bookkeeping is what
                // the HUD reads to decide whether to label the default "(fallback)". Under the same
                // lock the rebuild takes, since this rewrites the format fields the render thread
                // reads even when the device itself did not move.
                captureStateLock.lock()
                updateDeviceParameters()
                captureStateLock.unlock()
            }
            if inputDevice != previousDevice || inputUsesFallbackDevice != previousFallback {
                notifyCaptureDeviceChange()
            }
        }
    }

    /// The UID capture is running on, and whether that is a fallback from a device that is gone.
    public var captureDeviceState: (uniqueID: String?, usesFallback: Bool) {
        audioQueue.sync { (inputDeviceUniqueID, inputUsesFallbackDevice) }
    }

    /// A plug or unplug, or a change of the system default input. Debounced: one physical event
    /// fires several notifications and each rebuild disposes and recreates an AudioUnit.
    func handleInputDeviceEnvironmentChange() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            inputDeviceChangeWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                inputDeviceChangeWorkItem = nil
                inputDeviceEvaluationCount += 1
                // Announced even when capture itself does not move: a device that was plugged in is a
                // row the picker should have whether or not it is the one in use.
                onInputDeviceListChange?()
                let resolved = OPNCoreAudioDeviceLookup.inputDevice(matching: preferredInputDeviceUID)
                guard resolved != inputDevice else { return }
                rebuildCaptureLocked()
                notifyCaptureDeviceChange()
            }
            inputDeviceChangeWorkItem = item
            audioQueue.asyncAfter(deadline: .now() + Self.inputDeviceChangeDebounce, execute: item)
        }
    }

    /// Test seam: how many debounced environment evaluations ran, and how many of them actually
    /// rebuilt capture. A burst of CoreAudio notifications for one physical event must collapse into
    /// a single evaluation, and only a genuine device change may become a rebuild.
    var captureDeviceRebuildEvidence: (evaluations: Int, rebuilds: Int) {
        audioQueue.sync { (inputDeviceEvaluationCount, captureRebuildCount) }
    }

    /// Stops, disposes and re-initialises the capture unit only, restarting it when it was running.
    ///
    /// Disposal is mandatory, not tidiness: `initializeCaptureLocked` early-returns while
    /// `captureUnit != nil`, so a swap that skipped it would silently keep capturing the old device.
    private func rebuildCaptureLocked() {
        captureRebuildCount += 1
        let wasCapturing = isCaptureRunning
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        stopCaptureLocked()
        disposeCaptureUnitLocked()
        updateDeviceParameters()
        if wasCapturing { _ = startCaptureLocked() }
    }

    private func notifyCaptureDeviceChange() {
        onCaptureDeviceChange?(NvstCaptureDeviceChange(resolvedUniqueID: inputDeviceUniqueID,
                                                      preferredUniqueID: preferredInputDeviceUID,
                                                      isFallback: inputUsesFallbackDevice))
    }

    // MARK: - Units

    private func startPlayoutLocked() -> Bool {
        guard initializePlayoutLocked(), let playoutUnit else { return false }
        let status = AudioOutputUnitStart(playoutUnit)
        isPlayoutRunning = status == noErr
        return isPlayoutRunning
    }

    private func startCaptureLocked() -> Bool {
        guard initializeCaptureLocked(), let captureUnit else { return false }
        let status = AudioOutputUnitStart(captureUnit)
        isCaptureRunning = status == noErr
        return isCaptureRunning
    }

    private func stopPlayoutLocked() {
        if let playoutUnit, isPlayoutRunning { AudioOutputUnitStop(playoutUnit) }
        isPlayoutRunning = false
    }

    private func stopCaptureLocked() {
        if captureUnit != nil, isCaptureRunning { AudioOutputUnitStop(captureUnit!) }
        isCaptureRunning = false
    }

    private func initializePlayoutLocked() -> Bool {
        if playoutUnit != nil { return true }
        guard outputDevice != AudioDeviceID(kAudioObjectUnknown), let unit = makeHALUnit() else { return false }
        playoutUnit = unit
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disable, UInt32(MemoryLayout<UInt32>.size))
        var device = outputDevice
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        applyOutputBufferFrameSize(unit: unit, device: outputDevice)
        var format = NvstCoreAudioFormat.linear16Format(sampleRate: outputSampleRate, channels: UInt32(outputChannels))
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var callback = AURenderCallbackStruct(inputProc: nvstPlayoutCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard AudioUnitInitialize(unit) == noErr else {
            disposePlayoutUnitLocked()
            return false
        }
        return true
    }

    private func initializeCaptureLocked() -> Bool {
        if captureUnit != nil { return true }
        guard inputDevice != AudioDeviceID(kAudioObjectUnknown), let unit = makeHALUnit() else { return false }
        captureUnit = unit
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        var device = inputDevice
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        var format = NvstCoreAudioFormat.linear16Format(sampleRate: inputSampleRate, channels: UInt32(inputChannels))
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var callback = AURenderCallbackStruct(inputProc: nvstCaptureCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard AudioUnitInitialize(unit) == noErr else {
            disposeCaptureUnitLocked()
            return false
        }
        return true
    }

    private func disposePlayoutUnitLocked() {
        guard let playoutUnit else { return }
        AudioUnitUninitialize(playoutUnit)
        AudioComponentInstanceDispose(playoutUnit)
        self.playoutUnit = nil
    }

    private func disposeCaptureUnitLocked() {
        guard let captureUnit else { return }
        AudioUnitUninitialize(captureUnit)
        AudioComponentInstanceDispose(captureUnit)
        self.captureUnit = nil
    }



    /// The 0...1 meter reading, throttled to 20 a second, or nil when this frame is too soon after
    /// the last one.


    // MARK: - Devices

    private func updateDeviceParameters() {
        // Resolution is shared with the Settings mic test — see `OPNCoreAudioDeviceLookup` — so the
        // pre-flight and the stream cannot disagree about which device a saved UID names. A saved UID
        // whose device is gone resolves to the system default and is reported as a fallback rather
        // than overwriting the user's choice.
        inputDevice = OPNCoreAudioDeviceLookup.inputDevice(matching: preferredInputDeviceUID)
        inputDeviceUniqueID = OPNCoreAudioDeviceLookup.uid(of: inputDevice)
        inputUsesFallbackDevice = preferredInputDeviceUID != nil
            && OPNCoreAudioDeviceLookup.inputDeviceIfPresent(matching: preferredInputDeviceUID) == nil
        outputDevice = OPNCoreAudioDeviceLookup.defaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice)
        deviceOutputSampleRate = nominalSampleRate(for: outputDevice, fallback: NvstCoreAudioFormat.sampleRate)
        deviceInputSampleRate = nominalSampleRate(for: inputDevice, fallback: NvstCoreAudioFormat.sampleRate)
        outputSampleRate = NvstCoreAudioFormat.sampleRate
        inputSampleRate = NvstCoreAudioFormat.sampleRate
        outputChannels = NvstCoreAudioFormat.playoutChannelCount(requested: requestedPlayoutChannels, deviceChannels: channelCount(for: outputDevice, scope: kAudioDevicePropertyScopeOutput))
        inputChannels = NvstCoreAudioFormat.captureChannelCount(deviceChannels: channelCount(for: inputDevice, scope: kAudioDevicePropertyScopeInput))
        outputLatency = latency(for: outputDevice, scope: kAudioDevicePropertyScopeOutput, sampleRate: deviceOutputSampleRate)
    }







}

/// The device queries, the HAL unit construction and the plug/unplug listeners. Split out of the
/// class body, which is at its length budget; `private` in this file keeps them reachable from it.
extension NvstCoreAudioDevice {
    private func makeHALUnit() -> AudioUnit? {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr else { return nil }
        return unit
    }

    private func applyOutputBufferFrameSize(unit: AudioUnit, device: AudioDeviceID) {
        guard device != AudioDeviceID(kAudioObjectUnknown), deviceOutputSampleRate > 0 else { return }
        var range = AudioValueRange(mMinimum: 0, mMaximum: 0)
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        var rangeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let hasRange = AudioObjectGetPropertyData(device, &rangeAddress, 0, nil, &rangeSize, &range) == noErr
        var frames = NvstCoreAudioFormat.clampedIOBufferFrames(
            preferred: NvstCoreAudioFormat.preferredIOBufferFrames(sampleRate: deviceOutputSampleRate),
            deviceRange: hasRange ? range : nil
        )
        AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size))
        var applied: UInt32 = 0
        var appliedSize = UInt32(MemoryLayout<UInt32>.size)
        var appliedAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(device, &appliedAddress, 0, nil, &appliedSize, &applied) == noErr, applied > 0 {
            outputIOBufferDuration = Double(applied) / deviceOutputSampleRate
        }
    }

    private func levelWhenDue(_ samples: UnsafePointer<Int16>, count: Int) -> Double? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastLevelReportNanoseconds >= 50_000_000 else { return nil }
        lastLevelReportNanoseconds = now
        return NvstCoreAudioFormat.level(of: samples, count: count)
    }

    private func clear(_ bufferList: UnsafeMutablePointer<AudioBufferList>?) {
        guard let bufferList else { return }
        for buffer in UnsafeMutableAudioBufferListPointer(bufferList) where buffer.mData != nil && buffer.mDataByteSize > 0 {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
    }

    private func nominalSampleRate(for device: AudioDeviceID, fallback: Double) -> Double {
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return fallback }
        var rate = Float64(fallback)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return fallback }
        return rate
    }

    private func channelCount(for device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return 0 }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let bufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferList) == noErr else { return 0 }
        var channels: UInt32 = 0
        for buffer in UnsafeMutableAudioBufferListPointer(bufferList) { channels += buffer.mNumberChannels }
        return Int(channels)
    }

    private func latency(for device: AudioDeviceID, scope: AudioObjectPropertyScope, sampleRate: Double) -> TimeInterval {
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return 0 }
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyLatency,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &frames) == noErr, sampleRate > 0 else { return 0 }
        return Double(frames) / sampleRate
    }

    private func startInputDeviceMonitoring() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, nvstInputDeviceListener, context)
        }
    }

    private func stopInputDeviceMonitoring() {
        guard capturesMicrophone else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, nvstInputDeviceListener, context)
        }
    }

    private func startDefaultOutputMonitoring() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, nvstDefaultOutputListener, context)
    }

    private func stopDefaultOutputMonitoring() {
        guard monitorsDefaultOutput else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, nvstDefaultOutputListener, context)
    }
}
