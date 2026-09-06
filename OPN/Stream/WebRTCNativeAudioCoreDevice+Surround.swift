//  Surround playout: the multi-channel client format and the stereo fold the recorder and
//  Remote Co-Op tee receive from it.
//

import AudioToolbox
import CoreAudio
import Foundation

extension OPNCoreAudioRTCDevice {
    /// 2, 6 or 8; anything else is stereo, matching what the SDP can express.
    static func supportedPlayoutChannelCount(_ requested: Int) -> Int {
        switch requested {
        case 6, 8: requested
        default: 2
        }
    }

    /// Per-channel (left, right) weights folding an interleaved surround frame to stereo for the
    /// recorder and Remote Co-Op tee, which both expect stereo. Channel order is the one the
    /// multi-channel Opus mapping produces: L R C LFE Ls Rs, then Lb Rb for 7.1. Centre and the
    /// surrounds come in at -3 dB, LFE is dropped, and the sum is scaled so full-scale input on
    /// every channel stays in range.
    static func stereoDownmixWeights(channels: Int) -> [(left: Float, right: Float)] {
        let side: Float = 0.7071
        let layout: [(Float, Float)] = switch channels {
        case 6: [(1, 0), (0, 1), (side, side), (0, 0), (side, 0), (0, side)]
        case 8: [(1, 0), (0, 1), (side, side), (0, 0), (side, 0), (0, side), (side, 0), (0, side)]
        default: [(1, 0), (0, 1)]
        }
        let peak = layout.reduce(Float(0)) { max($0, $1.0 + $1.1) }
        let total = layout.reduce(Float(0)) { $0 + max($1.0, $1.1) }
        let gain = peak > 0 ? 1 / max(total / 2, 1) : 1
        return layout.map { (left: $0.0 * gain, right: $0.1 * gain) }
    }

    /// Hands the tee a stereo fold of the surround playout, in a scratch buffer this device owns.
    func deliverStereoTee(_ outputData: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let channels = outputNumberOfChannels
        let frames = Int(frameCount)
        let list = UnsafeMutableAudioBufferListPointer(outputData)
        guard frames > 0, let first = list.first, let base = first.mData,
              Int(first.mDataByteSize) >= frames * channels * MemoryLayout<Int16>.size else { return }
        let source = base.assumingMemoryBound(to: Int16.self)
        let weights = Self.stereoDownmixWeights(channels: channels)
        if stereoTeeScratch.count < frames * 2 { stereoTeeScratch = [Int16](repeating: 0, count: frames * 2) }
        let sampleRate = deviceOutputSampleRate
        stereoTeeScratch.withUnsafeMutableBufferPointer { destination in
            for frame in 0..<frames {
                var left: Float = 0
                var right: Float = 0
                let offset = frame * channels
                for channel in 0..<channels {
                    let sample = Float(source[offset + channel])
                    left += sample * weights[channel].left
                    right += sample * weights[channel].right
                }
                destination[frame * 2] = Int16(clamping: Int(left.rounded()))
                destination[frame * 2 + 1] = Int16(clamping: Int(right.rounded()))
            }
            guard let destinationBase = destination.baseAddress else { return }
            var teeList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 2 * MemoryLayout<Int16>.size), mData: UnsafeMutableRawPointer(destinationBase))
            )
            owner?.handleGameAudioFrame(UnsafeRawPointer(&teeList), frameCount: frameCount, sampleRate: sampleRate, channels: 2)
        }
    }
}

// MARK: - Rendering a surround stream down to the output device

/// Headphones are two drivers, so a 7.1 stream can only reach them by being rendered down. Doing
/// that here rather than asking the seat for a stereo mix is the difference between a surround
/// field that arrives and one that is discarded before it is ever encoded.
///
/// `AUSpatialMixer` is the real answer: it places each channel of the bed and renders binaurally,
/// which is what makes the result positional rather than merely wide. It is asked for first and a
/// matrix fold stands behind it, because this runs on the audio render thread and a stream that
/// plays correctly without spatialisation beats one that does not play at all.
extension OPNCoreAudioRTCDevice {
    func prepareSpatialRenderer(sampleRate: Double, sourceChannels: Int, destinationChannels: Int) {
        disposeSpatialRenderer()
        guard destinationChannels == 2, sourceChannels == 6 || sourceChannels == 8 else { return }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Mixer,
            componentSubType: kAudioUnitSubType_SpatialMixer,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { return }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else { return }

        var inputFormat = floatFormat(sampleRate: sampleRate, channels: UInt32(sourceChannels))
        var outputFormat = floatFormat(sampleRate: sampleRate, channels: 2)
        var outputType = AUSpatialMixerOutputType.spatialMixerOutputType_Headphones.rawValue
        var algorithm = AUSpatializationAlgorithm.spatializationAlgorithm_UseOutputType.rawValue
        var maxFrames = UInt32(4096)
        var callback = AURenderCallbackStruct(inputProc: spatialMixerInputCallback,
                                              inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        // Without a layout the mixer knows how many channels arrive but not which is which, so it
        // has nothing to place and renders silence. The order is the one the multi-channel Opus
        // mapping produces, the same order `stereoDownmixWeights` folds.
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = sourceChannels == 8 ? kAudioChannelLayoutTag_MPEG_7_1_C : kAudioChannelLayoutTag_MPEG_5_1_A
        let configured =
            AudioUnitSetProperty(unit, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Input, 0, &layout, UInt32(MemoryLayout<AudioChannelLayout>.size)) == noErr
            && AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &inputFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr
            && AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &outputFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr
            && AudioUnitSetProperty(unit, kAudioUnitProperty_SpatialMixerOutputType, kAudioUnitScope_Global, 0, &outputType, UInt32(MemoryLayout<UInt32>.size)) == noErr
            && AudioUnitSetProperty(unit, kAudioUnitProperty_SpatializationAlgorithm, kAudioUnitScope_Input, 0, &algorithm, UInt32(MemoryLayout<UInt32>.size)) == noErr
            && AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size)) == noErr
            && AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
            && AudioUnitInitialize(unit) == noErr
        guard configured else {
            AudioComponentInstanceDispose(unit)
            WebRTCMediaTelemetry.capture("webrtc.native.audio.spatial.unavailable", level: .info,
                                         message: "Spatial mixer unavailable; folding surround to stereo by matrix.",
                                         attributes: ["channels": String(sourceChannels)])
            return
        }
        spatialUnit = unit
        spatialSourceChannels = sourceChannels
        // This path cannot be judged by ear from here, and a mixer that renders silence would be
        // indistinguishable from a dead stream. Push a known-loud frame through it once and keep it
        // only if something comes back; otherwise the matrix fold takes over and audio still plays.
        guard producesAudio(unit, sourceChannels: sourceChannels) else {
            disposeSpatialRenderer()
            WebRTCMediaTelemetry.capture("webrtc.native.audio.spatial.silent", level: .warning,
                                         message: "Spatial mixer returned silence on test render; folding surround to stereo by matrix.",
                                         attributes: ["channels": String(sourceChannels)])
            return
        }
        WebRTCMediaTelemetry.capture("webrtc.native.audio.spatial.ready", level: .info,
                                     message: "Rendering surround to headphones through the spatial mixer.",
                                     attributes: ["channels": String(sourceChannels)])
    }

    /// Renders one frame of full-scale input and reports whether anything came out.
    private func producesAudio(_ unit: AudioUnit, sourceChannels: Int) -> Bool {
        let frames = 512
        spatialInputScratch = [Float](repeating: 0.5, count: frames * sourceChannels)
        spatialOutputScratch = [Float](repeating: 0, count: frames * 2)
        pendingSpatialFrames = frames
        pendingSpatialChannels = sourceChannels
        defer { spatialSampleTime = 0 }
        var loudest: Float = 0
        spatialOutputScratch.withUnsafeMutableBufferPointer { output in
            guard let base = output.baseAddress else { return }
            let renderList = AudioBufferList.allocate(maximumBuffers: 2)
            defer { free(renderList.unsafeMutablePointer) }
            for channel in 0..<2 {
                renderList[channel] = AudioBuffer(mNumberChannels: 1,
                                                  mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                                                  mData: UnsafeMutableRawPointer(base + channel * frames))
            }
            var flags = AudioUnitRenderActionFlags()
            var stamp = AudioTimeStamp()
            stamp.mSampleTime = 0
            stamp.mFlags = .sampleTimeValid
            guard AudioUnitRender(unit, &flags, &stamp, 0, UInt32(frames), renderList.unsafeMutablePointer) == noErr else { return }
            for index in 0..<(frames * 2) { loudest = max(loudest, abs(base[index])) }
        }
        return loudest > 0.0001
    }

    func disposeSpatialRenderer() {
        if let spatialUnit {
            AudioUnitUninitialize(spatialUnit)
            AudioComponentInstanceDispose(spatialUnit)
        }
        spatialUnit = nil
        spatialSourceChannels = 0
    }

    /// Renders `frames` of interleaved Int16 surround into the device's stereo buffer list.
    func renderDown(source: UnsafeMutablePointer<Int16>, frames: Int, sourceChannels: Int, into outputData: UnsafeMutablePointer<AudioBufferList>) {
        if let spatialUnit, spatialSourceChannels == sourceChannels,
           renderThroughSpatialMixer(spatialUnit, source: source, frames: frames, sourceChannels: sourceChannels, into: outputData) {
            return
        }
        foldToStereo(source: source, frames: frames, sourceChannels: sourceChannels, into: outputData)
    }

    private func renderThroughSpatialMixer(_ unit: AudioUnit, source: UnsafeMutablePointer<Int16>, frames: Int, sourceChannels: Int, into outputData: UnsafeMutablePointer<AudioBufferList>) -> Bool {
        let list = UnsafeMutableAudioBufferListPointer(outputData)
        guard let destination = list.first, let destinationBase = destination.mData,
              Int(destination.mDataByteSize) >= frames * 2 * MemoryLayout<Int16>.size else { return false }
        // De-interleave into the planar Float32 the mixer takes, once per callback.
        let required = frames * sourceChannels
        if spatialInputScratch.count < required { spatialInputScratch = [Float](repeating: 0, count: required) }
        let scale = Float(1) / 32_768
        spatialInputScratch.withUnsafeMutableBufferPointer { input in
            guard let inputBase = input.baseAddress else { return }
            for frame in 0..<frames {
                let offset = frame * sourceChannels
                for channel in 0..<sourceChannels {
                    inputBase[channel * frames + frame] = Float(source[offset + channel]) * scale
                }
            }
        }
        if spatialOutputScratch.count < frames * 2 { spatialOutputScratch = [Float](repeating: 0, count: frames * 2) }
        pendingSpatialFrames = frames
        pendingSpatialChannels = sourceChannels

        var rendered = false
        spatialOutputScratch.withUnsafeMutableBufferPointer { output in
            guard let outputBase = output.baseAddress else { return }
            let renderList = AudioBufferList.allocate(maximumBuffers: 2)
            defer { free(renderList.unsafeMutablePointer) }
            for channel in 0..<2 {
                renderList[channel] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(outputBase + channel * frames)
                )
            }
            var flags = AudioUnitRenderActionFlags()
            var stamp = AudioTimeStamp()
            stamp.mSampleTime = spatialSampleTime
            stamp.mFlags = .sampleTimeValid
            let status = AudioUnitRender(unit, &flags, &stamp, 0, UInt32(frames), renderList.unsafeMutablePointer)
            guard status == noErr else { return }
            spatialSampleTime += Double(frames)
            let target = destinationBase.assumingMemoryBound(to: Int16.self)
            for frame in 0..<frames {
                for channel in 0..<2 {
                    let value = outputBase[channel * frames + frame] * 32_767
                    target[frame * 2 + channel] = Int16(clamping: Int(value.rounded()))
                }
            }
            rendered = true
        }
        return rendered
    }

    /// Supplies the mixer with the de-interleaved frame the caller just prepared.
    func fillSpatialInput(_ ioData: UnsafeMutablePointer<AudioBufferList>?, frameCount: UInt32) -> OSStatus {
        guard let ioData else { return noErr }
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        let frames = min(Int(frameCount), pendingSpatialFrames)
        return spatialInputScratch.withUnsafeBufferPointer { input -> OSStatus in
            guard let base = input.baseAddress else { return noErr }
            for (channel, buffer) in list.enumerated() {
                guard let data = buffer.mData else { continue }
                if channel < pendingSpatialChannels {
                    memcpy(data, base + channel * pendingSpatialFrames, frames * MemoryLayout<Float>.size)
                } else {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            return noErr
        }
    }

    private func foldToStereo(source: UnsafeMutablePointer<Int16>, frames: Int, sourceChannels: Int, into outputData: UnsafeMutablePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(outputData)
        guard let destination = list.first, let destinationBase = destination.mData,
              Int(destination.mDataByteSize) >= frames * 2 * MemoryLayout<Int16>.size else { return }
        let weights = Self.stereoDownmixWeights(channels: sourceChannels)
        let target = destinationBase.assumingMemoryBound(to: Int16.self)
        for frame in 0..<frames {
            var left: Float = 0
            var right: Float = 0
            let offset = frame * sourceChannels
            for channel in 0..<sourceChannels {
                let sample = Float(source[offset + channel])
                left += sample * weights[channel].left
                right += sample * weights[channel].right
            }
            target[frame * 2] = Int16(clamping: Int(left.rounded()))
            target[frame * 2 + 1] = Int16(clamping: Int(right.rounded()))
        }
    }

    private func floatFormat(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate > 0 ? sampleRate : 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}

private func spatialMixerInputCallback(refCon: UnsafeMutableRawPointer,
                                       actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                       timestamp: UnsafePointer<AudioTimeStamp>,
                                       busNumber: UInt32,
                                       frameCount: UInt32,
                                       ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<OPNCoreAudioRTCDevice>.fromOpaque(refCon).takeUnretainedValue()
        .fillSpatialInput(ioData, frameCount: frameCount)
}
