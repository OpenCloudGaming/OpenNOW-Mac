import Foundation

public actor WebRTCMediaSession {
    private var mediaSubscribers: [UUID: AsyncStream<MediaFrame>.Continuation] = [:]
    private var inputSubscribers: [UUID: AsyncStream<UserInputEvent>.Continuation] = [:]

    public init() {}

    public func mediaFrames(bufferingPolicy: AsyncStream<MediaFrame>.Continuation.BufferingPolicy = .bufferingNewest(120)) -> AsyncStream<MediaFrame> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            mediaSubscribers[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeMediaSubscriber(id) }
            }
        }
    }

    public func inputEvents(bufferingPolicy: AsyncStream<UserInputEvent>.Continuation.BufferingPolicy = .bufferingNewest(240)) -> AsyncStream<UserInputEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            inputSubscribers[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeInputSubscriber(id) }
            }
        }
    }

    public func publish(_ frame: MediaFrame) {
        for subscriber in mediaSubscribers.values {
            subscriber.yield(frame)
        }
    }

    public func publish(_ event: UserInputEvent) {
        for subscriber in inputSubscribers.values {
            subscriber.yield(event)
        }
    }

    public func finish() {
        for subscriber in mediaSubscribers.values {
            subscriber.finish()
        }
        for subscriber in inputSubscribers.values {
            subscriber.finish()
        }
        mediaSubscribers.removeAll()
        inputSubscribers.removeAll()
    }

    private func removeMediaSubscriber(_ id: UUID) {
        mediaSubscribers.removeValue(forKey: id)
    }

    private func removeInputSubscriber(_ id: UUID) {
        inputSubscribers.removeValue(forKey: id)
    }
}

extension WebRTCMediaSession: MediaFrameReceiver {
    public func receive(_ frame: MediaFrame) async {
        publish(frame)
    }
}

extension WebRTCMediaSession: InputEventReceiver {
    public func receive(_ event: UserInputEvent) async {
        publish(event)
    }
}
