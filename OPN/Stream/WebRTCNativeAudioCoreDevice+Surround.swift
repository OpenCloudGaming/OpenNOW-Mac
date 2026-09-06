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
