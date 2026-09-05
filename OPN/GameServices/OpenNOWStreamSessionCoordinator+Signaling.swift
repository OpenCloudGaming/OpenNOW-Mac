//  The signaling leg: connecting to the seat's WebSocket, wiring its callbacks and turning its
//  offer into a `StreamOffer`.
//

import Foundation

extension OpenNOWStreamSessionCoordinator {
    func connectSignaling(sessionInfo: AllocatedStreamSession, settings: [String: Any], descriptor: StreamSessionDescriptor) async throws -> StreamOffer {
        try await withCheckedThrowingContinuation { continuation in
            // Store the continuation synchronously so a concurrent `cancelSessionStart` always
            // finds and resumes it; the main-actor client work follows and refuses to connect if
            // the continuation was already taken.
            lock.withLock {
                offerContinuation = continuation
            }
            // Serialize before the main-actor hop: the raw dictionary is not Sendable.
            let settingsJSON = jsonString(settings)
            Task { @MainActor [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let client = NVSTWebSocketSignalingClient(
                    signalingServer: sessionInfo.signalingServer,
                    sessionId: descriptor.id,
                    signalingUrl: sessionInfo.signalingUrl,
                    queryParameters: sessionInfo.signalingQueryParameters,
                    additionalSubprotocols: sessionInfo.signalingHeaders
                )
                self.installSignalingHandlers(client, sessionInfo: sessionInfo, settingsJSON: settingsJSON, descriptor: descriptor)

                let installed = self.lock.withLock { () -> Bool in
                    guard self.offerContinuation != nil else { return false }
                    self.signaling = client
                    return true
                }
                guard installed else { return }
                client.connect { [weak self] success, error in
                    guard let self else { return }
                    if success {
                        self.startOfferTimeout(client: client, descriptor: descriptor)
                        return
                    }
                    self.resumeOffer(error: OpenNOWStreamSessionError.signalingFailed(error.isEmpty ? "Unable to connect signaling." : error))
                }
            }
        }
    }

    /// Wires the signaling client's callbacks to the coordinator.
    @MainActor
    func installSignalingHandlers(_ client: NVSTWebSocketSignalingClient,
                                          sessionInfo: AllocatedStreamSession,
                                          settingsJSON: String,
                                          descriptor: StreamSessionDescriptor) {
        client.onOffer = { [weak self] sessionOffer in
        guard let self else { return }
        // Capture the NVST video handoff (sanitized) for the Bifrost-free receiver.
        if !sessionOffer.nvstSdp.isEmpty {
            let handoff = (try? JSONSerialization.jsonObject(with: Data(sessionOffer.nvstSdp.utf8))) ?? sessionOffer.nvstSdp
            OPNProtocolDebug.logJSONObject(label: "nvst-signaling-handoff", object: handoff)
        } else {
            OPNProtocolDebug.logJSONObject(label: "nvst-signaling-handoff-empty", object: ["sdpLength": sessionOffer.sdp.count, "nvstServerOverrides": sessionOffer.nvstServerOverrides])
        }
        let metadata = self.offerMetadata(sessionInfo: sessionInfo, settingsJSON: settingsJSON, descriptor: descriptor)
            .merging([
                "nvstSdp": sessionOffer.nvstSdp,
                "nvstServerOverrides": sessionOffer.nvstServerOverrides,
            ]) { current, _ in current }
            .filter { !$0.value.isEmpty }
        let offer = StreamOffer(session: descriptor, sdp: sessionOffer.sdp, metadata: metadata)
        self.resumeOffer(offer)
    }
        client.onIceCandidate = { [weak self] candidate in
        guard let self else { return }
        self.handleRemoteIceCandidate(StreamIceCandidate(
            sdp: candidate.candidate,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex,
            usernameFragment: candidate.usernameFragment,
            isEndOfCandidates: candidate.isEndOfCandidates
        ))
    }
        client.onClosed = { [weak self] clean, reason in
        guard let self else { return }
        let isWaitingForOffer = self.lock.withLock { self.offerContinuation != nil }
        guard !clean || isWaitingForOffer else { return }
        if !isWaitingForOffer, Self.isRemoteEndReason(reason) {
            self.handleRemoteEnd(reason.isEmpty ? "Stream ended by remote peer." : reason)
            return
        }
        self.resumeOffer(error: OpenNOWStreamSessionError.signalingFailed(reason.isEmpty ? "Signaling connection closed before receiving an offer." : reason))
    }
    }

    func startOfferTimeout(client: NVSTWebSocketSignalingClient, descriptor: StreamSessionDescriptor) {
        Task { @MainActor [weak self, weak client] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, let client else { return }
            let shouldFail = self.lock.withLock { self.signaling === client && self.offerContinuation != nil }
            guard shouldFail else { return }
            client.disconnect()
            self.resumeOffer(error: OpenNOWStreamSessionError.signalingFailed("Signaling connected but no stream offer was received within 20 seconds for session \(descriptor.id)."))
        }
    }

    func handleRemoteIceCandidate(_ candidate: StreamIceCandidate) {
        guard !candidate.sdp.isEmpty || candidate.isEndOfCandidates else { return }
        lock.withLock {
            if let iceContinuation {
                iceContinuation.yield(candidate)
                return
            }
            pendingIceCandidates.append(candidate)
            if pendingIceCandidates.count > Self.maxBufferedIceCandidates {
                pendingIceCandidates.removeFirst(pendingIceCandidates.count - Self.maxBufferedIceCandidates)
            }
        }
    }

    func handleRemoteEnd(_ message: String) {
        lock.withLock {
            if let remoteEndContinuation {
                remoteEndContinuation.yield(message)
                remoteEndContinuation.finish()
                self.remoteEndContinuation = nil
            } else {
                pendingRemoteEndMessage = message
            }
        }
    }

    private static func isRemoteEndReason(_ reason: String) -> Bool {
        reason.contains("peerRemoved") || reason.contains("BYE")
    }
}
