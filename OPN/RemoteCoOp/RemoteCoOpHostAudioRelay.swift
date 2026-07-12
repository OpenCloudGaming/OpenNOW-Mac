import AudioUnit
import Darwin
import Foundation
@preconcurrency import WebRTC

public struct OPNRemoteCoOpHostAudioFrame: Sendable {
    public static let sampleRate = 48_000.0
    public static let channels: UInt32 = 2

    public let samples: Data
    public let frameCount: UInt32
    public let sampleRate: Double
    public let channels: UInt32

    public init(samples: Data, frameCount: UInt32, sampleRate: Double = Self.sampleRate, channels: UInt32 = Self.channels) {
        self.samples = samples
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public protocol OPNRemoteCoOpHostAudioSink: AnyObject, Sendable {
    var participantID: UUID { get }
    func renderAudioFrame(_ frame: OPNRemoteCoOpHostAudioFrame)
}

public final class OPNRemoteCoOpHostAudioRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [UUID: any OPNRemoteCoOpHostAudioSink] = [:]

    public init() {}

    public func upsert(_ sink: any OPNRemoteCoOpHostAudioSink) {
        lock.withLock { sinks[sink.participantID] = sink }
    }

    public func remove(participantID: UUID) {
        lock.withLock { sinks[participantID] = nil }
    }

    public func removeAll() {
        lock.withLock { sinks.removeAll() }
    }

    public func activeSinkCount() -> Int {
        lock.withLock { sinks.count }
    }

    public func renderAudioFrame(audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        let currentSinks = lock.withLock { Array(sinks.values) }
        guard !currentSinks.isEmpty,
              let audioBufferList,
              let frame = Self.audioFrame(from: audioBufferList.assumingMemoryBound(to: AudioBufferList.self), frameCount: frameCount, sampleRate: sampleRate, channels: channels) else { return }
        for sink in currentSinks { sink.renderAudioFrame(frame) }
    }

    public func renderAudioFrame(_ frame: OPNRemoteCoOpHostAudioFrame) {
        let currentSinks = lock.withLock { Array(sinks.values) }
        for sink in currentSinks { sink.renderAudioFrame(frame) }
    }

    private static func audioFrame(from audioBufferList: UnsafePointer<AudioBufferList>, frameCount: UInt32, sampleRate: Double, channels: UInt32) -> OPNRemoteCoOpHostAudioFrame? {
        guard let stereoSamples = stereoPCM(from: audioBufferList, frameCount: frameCount, channels: channels) else { return nil }
        let resampledSamples = resampledStereoPCM(stereoSamples, sourceSampleRate: sampleRate, targetSampleRate: OPNRemoteCoOpHostAudioFrame.sampleRate)
        let data = resampledSamples.withUnsafeBufferPointer { buffer -> Data in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Int16>.size)
        }
        guard !data.isEmpty else { return nil }
        return OPNRemoteCoOpHostAudioFrame(samples: data, frameCount: UInt32(resampledSamples.count / Int(OPNRemoteCoOpHostAudioFrame.channels)))
    }

    private static func stereoPCM(from audioBufferList: UnsafePointer<AudioBufferList>, frameCount: UInt32, channels: UInt32) -> [Int16]? {
        let outputFrames = Int(frameCount)
        guard outputFrames > 0 else { return nil }
        let sourceChannels = max(1, Int(channels))
        var samples = [Int16](repeating: 0, count: outputFrames * Int(OPNRemoteCoOpHostAudioFrame.channels))
        let bufferCount = Int(audioBufferList.pointee.mNumberBuffers)
        withUnsafePointer(to: audioBufferList.pointee.mBuffers) { firstBuffer in
            let buffers = UnsafeBufferPointer(start: firstBuffer, count: bufferCount)
            if bufferCount == 1, let buffer = buffers.first, let data = buffer.mData {
                let sourceSampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                guard sourceSampleCount >= outputFrames * sourceChannels else { return }
                let source = data.bindMemory(to: Int16.self, capacity: sourceSampleCount)
                for frame in 0..<outputFrames {
                    let sourceIndex = frame * sourceChannels
                    let left = source[sourceIndex]
                    let right = sourceChannels > 1 ? source[sourceIndex + 1] : left
                    samples[frame * 2] = left
                    samples[frame * 2 + 1] = right
                }
            } else {
                let leftSampleCount = buffers.indices.contains(0) ? Int(buffers[0].mDataByteSize) / MemoryLayout<Int16>.size : 0
                let rightSampleCount = buffers.indices.contains(1) ? Int(buffers[1].mDataByteSize) / MemoryLayout<Int16>.size : 0
                for frame in 0..<outputFrames {
                    let leftBuffer = buffers.indices.contains(0) ? buffers[0].mData : nil
                    let rightBuffer = buffers.indices.contains(1) ? buffers[1].mData : nil
                    let left = frame < leftSampleCount ? leftBuffer?.bindMemory(to: Int16.self, capacity: leftSampleCount)[frame] ?? 0 : 0
                    let right = frame < rightSampleCount ? rightBuffer?.bindMemory(to: Int16.self, capacity: rightSampleCount)[frame] ?? left : left
                    samples[frame * 2] = left
                    samples[frame * 2 + 1] = right
                }
            }
        }
        return samples
    }

    private static func resampledStereoPCM(_ samples: [Int16], sourceSampleRate: Double, targetSampleRate: Double) -> [Int16] {
        guard sourceSampleRate > 0, abs(sourceSampleRate - targetSampleRate) > 0.5 else { return samples }
        let sourceFrames = samples.count / Int(OPNRemoteCoOpHostAudioFrame.channels)
        guard sourceFrames > 1 else { return samples }
        let targetFrames = max(1, Int((Double(sourceFrames) * targetSampleRate / sourceSampleRate).rounded()))
        var output = [Int16](repeating: 0, count: targetFrames * Int(OPNRemoteCoOpHostAudioFrame.channels))
        for frame in 0..<targetFrames {
            let sourcePosition = Double(frame) * sourceSampleRate / targetSampleRate
            let lower = min(sourceFrames - 1, max(0, Int(sourcePosition.rounded(.down))))
            let upper = min(sourceFrames - 1, lower + 1)
            let fraction = sourcePosition - Double(lower)
            for channel in 0..<Int(OPNRemoteCoOpHostAudioFrame.channels) {
                let a = Double(samples[lower * 2 + channel])
                let b = Double(samples[upper * 2 + channel])
                output[frame * 2 + channel] = Int16(max(Double(Int16.min), min(Double(Int16.max), a + ((b - a) * fraction))))
            }
        }
        return output
    }
}

@objc(OPNRemoteCoOpHostAudioDevice)
final class OPNRemoteCoOpHostAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    private let lock = NSLock()
    private weak var delegate: RTCAudioDeviceDelegate?
    private var sampleIndex: UInt64 = 0

    private(set) var deviceInputSampleRate = OPNRemoteCoOpHostAudioFrame.sampleRate
    private(set) var inputIOBufferDuration: TimeInterval = 0.01
    private(set) var inputNumberOfChannels = Int(OPNRemoteCoOpHostAudioFrame.channels)
    private(set) var inputLatency: TimeInterval = 0
    private(set) var deviceOutputSampleRate = OPNRemoteCoOpHostAudioFrame.sampleRate
    private(set) var outputIOBufferDuration: TimeInterval = 0.01
    private(set) var outputNumberOfChannels = Int(OPNRemoteCoOpHostAudioFrame.channels)
    private(set) var outputLatency: TimeInterval = 0
    private(set) var isInitialized = false
    private(set) var isPlayoutInitialized = false
    private(set) var isPlaying = false
    private(set) var isRecordingInitialized = false
    private(set) var isRecording = false

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        lock.withLock {
            self.delegate = delegate
            isInitialized = true
        }
        return true
    }

    func terminateDevice() -> Bool {
        lock.withLock {
            delegate = nil
            isInitialized = false
            isPlayoutInitialized = false
            isPlaying = false
            isRecordingInitialized = false
            isRecording = false
            sampleIndex = 0
        }
        return true
    }

    func initializePlayout() -> Bool {
        lock.withLock { isPlayoutInitialized = true }
        return true
    }

    func startPlayout() -> Bool {
        lock.withLock { isPlaying = true }
        return true
    }

    func stopPlayout() -> Bool {
        lock.withLock { isPlaying = false }
        return true
    }

    func initializeRecording() -> Bool {
        lock.withLock { isRecordingInitialized = true }
        return true
    }

    func startRecording() -> Bool {
        lock.withLock {
            isRecordingInitialized = true
            isRecording = true
        }
        return true
    }

    func stopRecording() -> Bool {
        lock.withLock { isRecording = false }
        return true
    }

    func shutdown() {
        _ = terminateDevice()
    }

    func renderAudioFrame(_ frame: OPNRemoteCoOpHostAudioFrame) {
        guard frame.frameCount > 0, frame.channels == OPNRemoteCoOpHostAudioFrame.channels else { return }
        let state = lock.withLock { () -> (RTCAudioDeviceDelegate, UInt64)? in
            guard isRecording, let delegate else { return nil }
            let currentSampleIndex = sampleIndex
            sampleIndex &+= UInt64(frame.frameCount)
            return (delegate, currentSampleIndex)
        }
        guard let state else { return }
        frame.samples.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var actionFlags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = Double(state.1)
            timestamp.mHostTime = mach_absolute_time()
            var audioBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: OPNRemoteCoOpHostAudioFrame.channels, mDataByteSize: UInt32(bytes.count), mData: UnsafeMutableRawPointer(mutating: baseAddress))
            )
            _ = state.0.deliverRecordedData(&actionFlags, &timestamp, 0, frame.frameCount, &audioBufferList, nil, nil)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
