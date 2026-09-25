import CoreAudio
import Foundation
import Testing
@testable import OpenNOW

/// The device's format arithmetic, checked without a sound device. These decide the channel count
/// and buffer size everything downstream assumes, and getting them wrong is audible only on the
/// hardware that happens to expose the difference.
@Suite struct NvstCoreAudioFormatTests {
    @Test func onlySixAndEightChannelSurroundSurviveTheClamp() {
        #expect(NvstCoreAudioFormat.supportedPlayoutChannelCount(6) == 6)
        #expect(NvstCoreAudioFormat.supportedPlayoutChannelCount(8) == 8)
        // No four-channel format exists on the wire, and anything else collapses to stereo.
        #expect(NvstCoreAudioFormat.supportedPlayoutChannelCount(4) == 2)
        #expect(NvstCoreAudioFormat.supportedPlayoutChannelCount(0) == 2)
        #expect(NvstCoreAudioFormat.supportedPlayoutChannelCount(2) == 2)
    }

    @Test func aStereoDeviceNeverReceivesASurroundPlayoutCount() {
        // libwebrtc cannot fold a surround decode down, so a two-channel device must ask for stereo
        // however many channels the profile wanted.
        #expect(NvstCoreAudioFormat.playoutChannelCount(requested: 8, deviceChannels: 2) == 2)
        #expect(NvstCoreAudioFormat.playoutChannelCount(requested: 6, deviceChannels: 2) == 2)
        // A device that can carry it gets what was asked for.
        #expect(NvstCoreAudioFormat.playoutChannelCount(requested: 6, deviceChannels: 6) == 6)
        #expect(NvstCoreAudioFormat.playoutChannelCount(requested: 8, deviceChannels: 8) == 8)
        // Stereo stays within what the device has.
        #expect(NvstCoreAudioFormat.playoutChannelCount(requested: 2, deviceChannels: 1) == 1)
    }

    @Test func captureIsMonoOrStereoWhateverTheDeviceOffers() {
        #expect(NvstCoreAudioFormat.captureChannelCount(deviceChannels: 2) == 2)
        #expect(NvstCoreAudioFormat.captureChannelCount(deviceChannels: 1) == 1)
        // A multi-channel interface is captured as stereo; the mic section is not surround.
        #expect(NvstCoreAudioFormat.captureChannelCount(deviceChannels: 8) == 2)
        #expect(NvstCoreAudioFormat.captureChannelCount(deviceChannels: 0) == 1)
    }

    @Test func captureReadsTheBufferStorageAndDuplicatesMonoIntoStereo() throws {
        var samples: [Int16] = [-32768, 0, 16384]
        try samples.withUnsafeMutableBytes { storage in
            var list = AudioBufferList(mNumberBuffers: 1,
                                       mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(storage.count), mData: storage.baseAddress))
            let converted = try #require(NvstCoreAudioFormat.stereoCaptureSamples(bufferList: &list, frames: 3))
            #expect(converted == [-1, -1, 0, 0, 0.5, 0.5])
            #expect(NvstCoreAudioFormat.stereoCaptureSamples(bufferList: &list, frames: 4) == nil)
        }
    }

    @Test func captureKeepsStereoChannelsInTheirOriginalOrder() {
        var samples: [Int16] = [16384, -16384, 8192, 0]
        samples.withUnsafeMutableBytes { storage in
            var list = AudioBufferList(mNumberBuffers: 1,
                                       mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(storage.count), mData: storage.baseAddress))
            let converted = NvstCoreAudioFormat.stereoCaptureSamples(bufferList: &list, frames: 2)
            #expect(converted == [0.5, -0.5, 0.25, 0])
        }
    }

    @Test func decodedStereoMapsOntoWhateverChannelCountTheDeviceCarries() {
        let stereo: [Float] = [0.5, -0.5, 0.25, 0]
        #expect(NvstCoreAudioFormat.interleavedSamples(fromStereo: stereo, frames: 2, outputChannels: 2)
                == [16384, -16384, 8192, 0])
        // A mono device averages the pair rather than dropping a side.
        #expect(NvstCoreAudioFormat.interleavedSamples(fromStereo: stereo, frames: 2, outputChannels: 1)
                == [0, 4096])
        // A wider layout keeps the pair in the front channels and leaves the rest silent, so the
        // stereo decode is never reinterpreted as interleaved surround.
        #expect(NvstCoreAudioFormat.interleavedSamples(fromStereo: stereo, frames: 2, outputChannels: 6)
                == [16384, -16384, 0, 0, 0, 0, 8192, 0, 0, 0, 0, 0])
        // A short decode is padded with silence instead of reading past its end.
        #expect(NvstCoreAudioFormat.interleavedSamples(fromStereo: [1], frames: 2, outputChannels: 2)
                == [Int16.max, 0, 0, 0])
        // A non-finite sample saturates cleanly instead of trapping the render thread.
        #expect(NvstCoreAudioFormat.interleavedSamples(fromStereo: [.infinity, -.infinity], frames: 1, outputChannels: 2)
                == [Int16.max, -Int16.max])
    }

    @Test func theIOBufferIsFiveMillisecondsWhereTheDeviceAllowsIt() {        #expect(NvstCoreAudioFormat.preferredIOBufferFrames(sampleRate: 48_000) == 240)
        // A device whose smallest buffer is larger gets its own floor rather than an ignored request.
        let coarse = AudioValueRange(mMinimum: 512, mMaximum: 4096)
        #expect(NvstCoreAudioFormat.clampedIOBufferFrames(preferred: 240, deviceRange: coarse) == 512)
        // A device whose maximum is smaller than the request gets its ceiling.
        let tight = AudioValueRange(mMinimum: 64, mMaximum: 128)
        #expect(NvstCoreAudioFormat.clampedIOBufferFrames(preferred: 240, deviceRange: tight) == 128)
        // No usable range leaves the request alone rather than substituting zero.
        #expect(NvstCoreAudioFormat.clampedIOBufferFrames(preferred: 240, deviceRange: nil) == 240)
        #expect(NvstCoreAudioFormat.clampedIOBufferFrames(preferred: 240, deviceRange: AudioValueRange(mMinimum: 0, mMaximum: 0)) == 240)
    }

    @Test func theStreamFormatIsSixteenBitInterleaved() {
        let format = NvstCoreAudioFormat.linear16Format(sampleRate: 48_000, channels: 2)
        #expect(format.mFormatID == kAudioFormatLinearPCM)
        #expect(format.mBitsPerChannel == 16)
        #expect(format.mChannelsPerFrame == 2)
        #expect(format.mBytesPerFrame == 4)
        #expect(format.mBytesPerPacket == 4)
        #expect(format.mFramesPerPacket == 1)
        #expect(format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0)
        // A zero channel count is nonsense the hardware would reject; one channel is the floor.
        #expect(NvstCoreAudioFormat.linear16Format(sampleRate: 48_000, channels: 0).mChannelsPerFrame == 1)
    }

    @Test func theLevelMatchesTheSettingsMeterScale() {
        let silence = [Int16](repeating: 0, count: 128)
        #expect(silence.withUnsafeBufferPointer { NvstCoreAudioFormat.level(of: $0.baseAddress!, count: $0.count) } == 0)
        // Full scale reads as full scale, and speech-level input sits mid-range on the same 6x curve
        // the Settings probe uses.
        let full = [Int16](repeating: Int16.max, count: 128)
        #expect(full.withUnsafeBufferPointer { NvstCoreAudioFormat.level(of: $0.baseAddress!, count: $0.count) } == 1)
        let speech = [Int16](repeating: Int16(Int16.max / 6), count: 128)
        let level = speech.withUnsafeBufferPointer { NvstCoreAudioFormat.level(of: $0.baseAddress!, count: $0.count) }
        #expect(level > 0.9 && level <= 1.0)
        #expect(NvstCoreAudioFormat.level(of: UnsafePointer<Int16>(bitPattern: 1)!, count: 0) == 0)
    }
}
