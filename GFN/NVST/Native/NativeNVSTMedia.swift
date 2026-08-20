import Foundation

public enum NativeNVSTVideoCodec: String, Equatable, Sendable {
    case h264 = "H264"
    case h265 = "H265"
    case av1 = "AV1"
    case unknown
}

public struct NativeNVSTVideoFrame: Equatable, Sendable {
    public let streamID: UInt32
    public let codec: NativeNVSTVideoCodec
    public let timestamp: MediaTimestamp
    public let durationNanoseconds: UInt64
    public let width: Int
    public let height: Int
    public let isKeyFrame: Bool
    public let payload: Data

    public init(streamID: UInt32,
                codec: NativeNVSTVideoCodec,
                timestamp: MediaTimestamp,
                durationNanoseconds: UInt64,
                width: Int,
                height: Int,
                isKeyFrame: Bool,
                payload: Data) {
        self.streamID = streamID
        self.codec = codec
        self.timestamp = timestamp
        self.durationNanoseconds = durationNanoseconds
        self.width = max(0, width)
        self.height = max(0, height)
        self.isKeyFrame = isKeyFrame
        self.payload = payload
    }
}

public struct NativeNVSTAudioFrame: Equatable, Sendable {
    public let streamID: UInt32
    public let timestamp: MediaTimestamp
    public let durationNanoseconds: UInt64
    public let sampleRate: Int
    public let channelCount: Int
    public let payload: Data

    public init(streamID: UInt32,
                timestamp: MediaTimestamp,
                durationNanoseconds: UInt64,
                sampleRate: Int,
                channelCount: Int,
                payload: Data) {
        self.streamID = streamID
        self.timestamp = timestamp
        self.durationNanoseconds = durationNanoseconds
        self.sampleRate = max(0, sampleRate)
        self.channelCount = max(0, channelCount)
        self.payload = payload
    }
}

public protocol NativeNVSTMediaReceiver: Sendable {
    func receiveVideoFrame(_ frame: NativeNVSTVideoFrame) async
    func receiveAudioFrame(_ frame: NativeNVSTAudioFrame) async
}

public actor NativeNVSTMediaSession: NativeNVSTMediaReceiver {
    private var videoContinuation: (id: UUID, value: AsyncStream<NativeNVSTVideoFrame>.Continuation)?
    private var audioContinuation: (id: UUID, value: AsyncStream<NativeNVSTAudioFrame>.Continuation)?

    public init() {}

    public func videoFrames(bufferingPolicy: AsyncStream<NativeNVSTVideoFrame>.Continuation.BufferingPolicy = .bufferingNewest(120)) -> AsyncStream<NativeNVSTVideoFrame> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            videoContinuation?.value.finish()
            videoContinuation = (id, continuation)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.clearVideoContinuation(id: id) }
            }
        }
    }

    public func audioFrames(bufferingPolicy: AsyncStream<NativeNVSTAudioFrame>.Continuation.BufferingPolicy = .bufferingNewest(240)) -> AsyncStream<NativeNVSTAudioFrame> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            audioContinuation?.value.finish()
            audioContinuation = (id, continuation)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.clearAudioContinuation(id: id) }
            }
        }
    }

    public func receiveVideoFrame(_ frame: NativeNVSTVideoFrame) async {
        videoContinuation?.value.yield(frame)
    }

    public func receiveAudioFrame(_ frame: NativeNVSTAudioFrame) async {
        audioContinuation?.value.yield(frame)
    }

    public func finish() {
        videoContinuation?.value.finish()
        audioContinuation?.value.finish()
        videoContinuation = nil
        audioContinuation = nil
    }

    private func clearVideoContinuation(id: UUID) {
        if videoContinuation?.id == id { videoContinuation = nil }
    }

    private func clearAudioContinuation(id: UUID) {
        if audioContinuation?.id == id { audioContinuation = nil }
    }
}
