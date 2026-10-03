import AudioToolbox
import CoreAudio
import Foundation
import Testing
@testable import OpenNOW

/// The post-tee local gain. The device's playout callback is the only place a decoded game sample
/// crosses out to the speakers, to the recorder, to Instant Replay and to every Co-Op guest, so the
/// tee has to keep the unscaled samples while the speaker path is scaled or muted.
///
/// `renderPlayout` is driven directly with a fabricated buffer: no AudioUnit is opened, so this runs
/// on a machine with no output device at all.
@Suite struct NvstCoreAudioPlayoutGainTests {
    private struct PlayoutCapture {
        let samples: [Int16]
        let tee: [Int16]
    }

    /// The tee callback is `@Sendable`, so the samples it observes are collected through a box
    /// rather than a captured local. The callback runs synchronously on the calling thread, so there
    /// is no actual concurrency here.
    private final class TeeCapture: @unchecked Sendable {
        var samples: [Int16] = []
    }

    /// One render with a constant source sample, capturing both what the tee saw and what reached
    /// the destination buffer.
    private func render(gain: Float, muted: Bool = false, source: Int16 = 10000, frames: Int = 8) -> PlayoutCapture {
        let device = NvstCoreAudioDevice(playoutChannelCount: 2, capturesMicrophone: false, monitorsDefaultOutputDevice: false)
        device.playoutGain = gain
        device.isPlayoutMuted = muted
        device.fillPlayout = { destination, sampleCount in
            destination.update(repeating: source, count: sampleCount)
        }
        let channels = device.outputChannels
        let sampleCount = frames * channels
        let tee = TeeCapture()
        device.onGameAudio = { pointer, frameCount, _, reportedChannels in
            guard let pointer else { return }
            let list = pointer.assumingMemoryBound(to: AudioBufferList.self)
            guard let data = list.pointee.mBuffers.mData else { return }
            tee.samples = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self),
                                                   count: Int(frameCount) * Int(reportedChannels)))
        }
        var storage = [Int16](repeating: 0, count: sampleCount)
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(sampleCount * MemoryLayout<Int16>.size),
                mData: nil
            )
        )
        storage.withUnsafeMutableBufferPointer { buffer in
            list.mBuffers.mData = UnsafeMutableRawPointer(buffer.baseAddress)
            withUnsafeMutablePointer(to: &list) { pointer in
                _ = device.renderPlayout(actionFlags: nil,
                                         timestamp: nil,
                                         busNumber: 0,
                                         frameCount: UInt32(frames),
                                         outputData: pointer)
            }
        }
        return PlayoutCapture(samples: storage, tee: tee.samples)
    }

    @Test func unityGainLeavesTheSamplesUntouched() {
        let capture = render(gain: 1)
        #expect(capture.samples.allSatisfy { $0 == 10000 })
        #expect(capture.tee.allSatisfy { $0 == 10000 })
    }

    /// The whole point of applying gain after the tee: a recording, a replay and a Co-Op guest keep
    /// hearing the game at full level while these speakers are quieter.
    @Test func halfGainScalesPlaybackAndNotTheTee() {
        let capture = render(gain: 0.5)
        #expect(capture.samples.allSatisfy { $0 == 5000 })
        #expect(capture.tee.allSatisfy { $0 == 10000 })
    }

    @Test func zeroGainIsSilentAndStillFeedsTheTeeUnscaled() {
        let capture = render(gain: 0)
        #expect(capture.samples.allSatisfy { $0 == 0 })
        #expect(capture.tee.allSatisfy { $0 == 10000 })
    }

    @Test func muteSilencesPlaybackAndNotTheTee() {
        let capture = render(gain: 1, muted: true)
        #expect(capture.samples.allSatisfy { $0 == 0 })
        #expect(capture.tee.allSatisfy { $0 == 10000 })
    }

    /// Nothing above unity is reachable, however the value arrives.
    @Test func gainIsClampedToUnityAndToSilence() {
        let device = NvstCoreAudioDevice(playoutChannelCount: 2, capturesMicrophone: false, monitorsDefaultOutputDevice: false)
        device.playoutGain = 4
        #expect(device.playoutGain == 1)
        device.playoutGain = -1
        #expect(device.playoutGain == 0)
        device.playoutGain = .nan
        #expect(device.playoutGain == 1)
    }

    /// Mute is the gain path at zero, not a second state the render callback has to reconcile, so a
    /// muted stream and a zero-gain stream produce the same samples.
    @Test func mutedAndZeroGainProduceTheSamePlayback() {
        #expect(render(gain: 0).samples == render(gain: 1, muted: true).samples)
    }
}
