import Foundation
@testable import OpenNOW

extension StreamingPathTests {
    actor RecordingSessionProvider: StreamSessionProvider {
        private(set) var finished: [(StreamSessionDescriptor, StreamEndReason)] = []
        let offer: StreamOffer

        init(offer: StreamOffer) {
            self.offer = offer
        }

        func startSession(configuration: StreamLaunchConfiguration) async throws -> StreamOffer {
            offer
        }

        func finishSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async throws {
            finished.append((session, reason))
        }
    }

    actor CancellableSessionProvider: StreamSessionProvider, StreamSessionStartCancellable {
        private var startContinuation: CheckedContinuation<StreamOffer, Error>?
        private var waitingContinuation: CheckedContinuation<Void, Never>?
        private(set) var cancelCount = 0

        func startSession(configuration: StreamLaunchConfiguration) async throws -> StreamOffer {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                waitingContinuation?.resume()
                waitingContinuation = nil
            }
        }

        func finishSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async throws {}

        func cancelSessionStart() async {
            cancelCount += 1
            startContinuation?.resume(throwing: CancellationError())
            startContinuation = nil
        }

        func waitUntilStarted() async {
            guard startContinuation == nil else { return }
            await withCheckedContinuation { continuation in
                waitingContinuation = continuation
            }
        }
    }

    actor RecordingTransport: StreamTransport {
        private(set) var connectedOffer: StreamOffer?
        private(set) var sentEvents: [UserInputEvent] = []
        private(set) var remoteCandidates: [StreamIceCandidate] = []
        private(set) var disconnected = false
        private var localIceContinuation: AsyncStream<StreamIceCandidate>.Continuation?

        func connect(offer: StreamOffer, mediaReceiver: any MediaFrameReceiver) async throws -> StreamAnswer {
            connectedOffer = offer
            await mediaReceiver.receive(.audio(AudioFrame(
                trackID: "audio-main",
                timestamp: MediaTimestamp(nanoseconds: 1),
                durationNanoseconds: 20_000_000,
                sampleRate: 48_000,
                channelCount: 2,
                sampleFormat: .pcmInt16,
                payload: Data([1, 2])
            )))
            return StreamAnswer(sdp: "answer")
        }

        func addRemoteIceCandidate(_ candidate: StreamIceCandidate) async throws {
            remoteCandidates.append(candidate)
        }

        nonisolated func localIceCandidates() -> AsyncStream<StreamIceCandidate> {
            AsyncStream(bufferingPolicy: .bufferingNewest(120)) { continuation in
                Task { await self.setLocalIceContinuation(continuation) }
            }
        }

        func yieldLocalIceCandidate(_ candidate: StreamIceCandidate) {
            localIceContinuation?.yield(candidate)
        }

        func send(_ event: UserInputEvent) async throws {
            sentEvents.append(event)
        }

        func disconnect() async {
            disconnected = true
            localIceContinuation?.finish()
            localIceContinuation = nil
        }

        private func setLocalIceContinuation(_ continuation: AsyncStream<StreamIceCandidate>.Continuation) {
            localIceContinuation = continuation
        }
    }

    actor RecordingSignaling: StreamSignalingChannel {
        private(set) var sentAnswer: StreamAnswer?
        private(set) var sentLocalCandidates: [StreamIceCandidate] = []
        private var remoteIceContinuation: AsyncStream<StreamIceCandidate>.Continuation?
        private var remoteEndContinuation: AsyncStream<String>.Continuation?

        func sendAnswer(_ answer: StreamAnswer, for session: StreamSessionDescriptor) async throws {
            sentAnswer = answer
        }

        func sendLocalIceCandidate(_ candidate: StreamIceCandidate, for session: StreamSessionDescriptor) async throws {
            sentLocalCandidates.append(candidate)
        }

        nonisolated func remoteIceCandidates(for session: StreamSessionDescriptor) async throws -> AsyncStream<StreamIceCandidate> {
            AsyncStream(bufferingPolicy: .bufferingNewest(120)) { continuation in
                Task { await self.setRemoteIceContinuation(continuation) }
            }
        }

        nonisolated func remoteEndEvents(for session: StreamSessionDescriptor) async throws -> AsyncStream<String> {
            AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                Task { await self.setRemoteEndContinuation(continuation) }
            }
        }

        func yieldRemoteIceCandidate(_ candidate: StreamIceCandidate) {
            remoteIceContinuation?.yield(candidate)
        }

        func yieldRemoteEnd(_ message: String) {
            remoteEndContinuation?.yield(message)
        }

        private func setRemoteIceContinuation(_ continuation: AsyncStream<StreamIceCandidate>.Continuation) {
            remoteIceContinuation = continuation
        }

        private func setRemoteEndContinuation(_ continuation: AsyncStream<String>.Continuation) {
            remoteEndContinuation = continuation
        }
    }

    actor ProgressRecorder {
        private(set) var values: [StreamProgress] = []

        func append(_ progress: StreamProgress) {
            values.append(progress)
        }
    }
}
