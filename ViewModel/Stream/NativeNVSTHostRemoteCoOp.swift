//
//  NativeNVSTHostRemoteCoOp.swift
//  OpenNOW
//
//  Hosting a Remote Co-Op session from the native NVST stream: the invite, the participants, and
//  the peer plumbing behind them.
//
//  This mirrors `WebRTCMediaStreamRemoteCoOp.swift`, which does the same job for the WebRTC
//  transport. Everything above the transport - the signed invite, the broker, the approval flow,
//  the per-guest `RTCPeerConnection` - is shared; only the three seams differ, and all three are
//  native-transport-specific:
//
//  - Video and audio reach the relays from `NvstBifrostFreeTransport`'s decode and audio taps
//    rather than from libwebrtc's frame callbacks. The relays are owned by the view model and
//    handed to the transport at construction.
//  - Guest gameplay input is enqueued on `NativeNVSTInputDispatcher` instead of being written
//    straight to the transport, so it is coalesced and ordered with the host's own input on one
//    queue. The neutral states a departing guest leaves behind are the one exception - see
//    `sendRemoteCoOpNeutralInput`.
//  - A guest's player slot has to be announced to the seat as a gamepad topology change. On the
//    WebRTC path the vendored stack did that itself; here the `0x20d` descriptor is ours to send.
//

import Foundation

extension NativeNVSTHostViewModel {
    // MARK: - Presentation

    var remoteCoOpSummaryText: String {
        guard remoteCoOpSnapshot.preferences.isAvailable else { return "Off" }
        guard remoteCoOpSnapshot.preferences.effectiveReservedGuestSlots > 0 else { return "No Slot" }
        guard let invite = remoteCoOpSnapshot.invite else { return "Ready" }
        if invite.isExpired { return "Expired" }
        return remoteCoOpSnapshot.connectedParticipantCount > 0 ? "Active" : "Invite"
    }

    var remoteCoOpTitle: String {
        guard remoteCoOpSnapshot.preferences.isAvailable else { return "Disabled" }
        guard remoteCoOpSnapshot.preferences.effectiveReservedGuestSlots > 0 else { return "No Slot" }
        if let invite = remoteCoOpSnapshot.invite, !invite.isExpired { return "Invite Ready" }
        if remoteCoOpSnapshot.invite?.isExpired == true { return "Expired" }
        return "Ready"
    }

    var remoteCoOpSubtitle: String {
        guard remoteCoOpSnapshot.preferences.isAvailable else { return "Enable in Settings" }
        guard remoteCoOpSnapshot.preferences.effectiveReservedGuestSlots > 0 else { return "Reserve slot before launch" }
        if let invite = remoteCoOpSnapshot.invite, !invite.isExpired { return "Code \(invite.code)" }
        return "Create invite"
    }

    var remoteCoOpInviteActionSubtitle: String {
        guard remoteCoOpSnapshot.preferences.isAvailable else { return "Enable in Settings" }
        guard isConnected else { return "Stream not ready" }
        if let invite = remoteCoOpSnapshot.invite {
            return invite.isExpired ? "Refresh" : invite.code
        }
        return "Create + copy"
    }

    /// Whether the HUD's invite button should do anything. The stream has to be live before an
    /// invite is worth handing out: a guest who joins first would connect to a peer with no frames
    /// to send, and the seat has no pad slot to give them until input is negotiated.
    var canStartRemoteCoOpInvite: Bool {
        remoteCoOpSnapshot.preferences.isAvailable &&
            remoteCoOpSnapshot.preferences.effectiveReservedGuestSlots > 0 &&
            isConnected && !isEnding && !didEnd
    }

    /// The preferences the *session* launched with, not whatever Settings says now. Reserved
    /// controller slots are advertised to GeForce NOW before launch, so changing them mid-stream
    /// cannot add a slot the seat was never told to allocate.
    var remoteCoOpLaunchPreferences: OPNRemoteCoOpPreferences {
        OPNRemoteCoOpPreferences.launchPreferences(from: configuration.metadata, fallback: OPNRemoteCoOpPreferencesStore.load())
    }

    // MARK: - Invite lifecycle

    func refreshRemoteCoOpState() {
        let preferences = remoteCoOpLaunchPreferences
        remoteCoOpPreferences = preferences
        remoteCoOpNetworkConfiguration = OPNRemoteCoOpNetworkConfiguration(transportMode: preferences.transportMode, latencyMode: preferences.latencyMode)
        remoteCoOpSnapshot = OPNRemoteCoOpHostSnapshot(preferences: preferences, invite: remoteCoOpSnapshot.invite, participants: remoteCoOpSnapshot.participants)
        applyRemoteCoOpVideoScale(preferences: preferences)
        Task { @MainActor in
            await remoteCoOpHostSession.updatePreferences(preferences)
            await remoteCoOpPeerController?.updateNetworkConfiguration(remoteCoOpNetworkConfiguration)
            await remoteCoOpPeerController?.updateQualityPreset(preferences.qualityPreset)
            await remoteCoOpPeerController?.updateLatencyMode(preferences.latencyMode)
            remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
        }
    }

    /// Tells the relay how far down to scale before handing frames to libwebrtc. The native session
    /// decodes at full resolution - 5120x2160 on a 5K profile - and the guest preset tops out at
    /// 1080p, so without this every frame would be converted to I420 at source size and then thrown
    /// away by the encoder's own adaptation.
    func applyRemoteCoOpVideoScale(preferences: OPNRemoteCoOpPreferences) {
        remoteCoOpVideoRelay.setPreferredOutputSize(width: preferences.qualityPreset.width, height: preferences.qualityPreset.height)
    }

    func startRemoteCoOpInvite() {
        let preferences = remoteCoOpLaunchPreferences
        guard preferences.isAlphaOptedIn else { return }
        guard canStartRemoteCoOpInvite else {
            remoteCoOpMessage = isConnected ? "Remote Co-Op is unavailable for this session." : "Wait for the stream to connect."
            return
        }
        remoteCoOpMessage = "Creating..."
        applyRemoteCoOpVideoScale(preferences: preferences)
        Task { @MainActor in
            let neutralEvents = await stopRemoteCoOpSession()
            await sendRemoteCoOpNeutralInput(neutralEvents)
            await syncRemoteCoOpGamepadTopology()
            await remoteCoOpHostSession.updatePreferences(preferences)
            do {
                let coordinator = makeRemoteCoOpCoordinator(preferences: preferences)
                let invite = try await coordinator.startInvite(
                    applicationID: configuration.applicationID,
                    title: configuration.title,
                    joinBaseURL: remoteCoOpJoinBaseURL(preferences),
                    signalingServerURL: preferences.signalingServerURL
                )
                remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
                copyRemoteCoOpInvite(invite)
                remoteCoOpMessage = invite.joinURL == nil ? "Copied \(invite.code)" : "Link copied"
                showNativeTransientStreamMessage("Remote Co-Op invite copied")
                WebRTCMediaTelemetry.capture("nvst.remote_coop.invite.created", level: .info, message: "Remote Co-Op invite created.", attributes: [
                    "applicationID": configuration.applicationID,
                    "reservedSlots": String(preferences.effectiveReservedGuestSlots),
                    "transportMode": preferences.transportMode.rawValue,
                    "latencyMode": preferences.latencyMode.rawValue
                ])
            } catch {
                _ = await stopRemoteCoOpSession()
                remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
                remoteCoOpMessage = Self.message(for: error)
                WebRTCMediaTelemetry.capture("nvst.remote_coop.invite.failed", level: .warning, message: remoteCoOpMessage, attributes: ["applicationID": configuration.applicationID])
            }
        }
    }

    func stopRemoteCoOpInvite() {
        Task { @MainActor in
            let neutralEvents = await stopRemoteCoOpSession()
            await sendRemoteCoOpNeutralInput(neutralEvents)
            await syncRemoteCoOpGamepadTopology()
            remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
            remoteCoOpMessage = "Ended"
            showNativeTransientStreamMessage("Remote Co-Op invite ended")
            WebRTCMediaTelemetry.capture("nvst.remote_coop.invite.ended", level: .info, message: "Remote Co-Op invite ended.", attributes: ["applicationID": configuration.applicationID])
        }
    }

    func copyRemoteCoOpInvite() {
        guard let invite = remoteCoOpSnapshot.invite else { return }
        copyRemoteCoOpInvite(invite)
        remoteCoOpMessage = invite.joinURL == nil ? "Token copied" : "Link copied"
        showNativeTransientStreamMessage("Remote Co-Op invite copied")
    }

    func copyRemoteCoOpInvite(_ invite: OPNRemoteCoOpInvite) {
        OPNRemoteCoOpInviteClipboard.copy(remoteCoOpClipboardText(invite))
    }

    func remoteCoOpClipboardText(_ invite: OPNRemoteCoOpInvite) -> String {
        invite.joinURL?.absoluteString ?? invite.token
    }

    // MARK: - Participants

    func approveRemoteCoOpParticipant(_ participantID: UUID) {
        Task { @MainActor in
            do {
                let participant: OPNRemoteCoOpParticipant
                if let remoteCoOpHostCoordinator {
                    participant = try await remoteCoOpHostCoordinator.approveParticipant(participantID)
                } else {
                    participant = try await remoteCoOpHostSession.approveParticipant(participantID)
                }
                remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
                // The seat must know the pad exists before the guest's first state packet, or it
                // discards input for an unregistered device.
                await syncRemoteCoOpGamepadTopology()
                try await syncRemoteCoOpPeers()
                remoteCoOpMessage = "Approved \(participant.displayName) for player \((participant.playerIndex ?? 0) + 1)."
                showNativeTransientStreamMessage("Remote Co-Op guest approved")
            } catch {
                remoteCoOpMessage = Self.message(for: error)
            }
        }
    }

    func removeRemoteCoOpParticipant(_ participantID: UUID) {
        Task { @MainActor in
            do {
                let neutralEvents: [UserInputEvent]
                if let remoteCoOpHostCoordinator {
                    neutralEvents = try await remoteCoOpHostCoordinator.removeParticipant(participantID)
                } else {
                    neutralEvents = try await remoteCoOpHostSession.removeParticipant(participantID)
                }
                // Order matters: the neutral state has to reach the seat while the pad is still
                // announced. Dropping it from the topology first would leave whatever the guest was
                // holding pressed in the game forever.
                await sendRemoteCoOpNeutralInput(neutralEvents)
                await remoteCoOpPeerController?.removePeer(participantID: participantID)
                remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
                await syncRemoteCoOpGamepadTopology()
                remoteCoOpMessage = "Remote Co-Op guest removed."
                showNativeTransientStreamMessage("Remote Co-Op guest removed")
            } catch {
                remoteCoOpMessage = Self.message(for: error)
            }
        }
    }

    // MARK: - Input and topology

    /// Guest input goes through the same dispatcher as the host's own.
    ///
    /// Writing to the transport directly would race the dispatcher's queue - two guests and a host
    /// can each be mid-`send` on the transport actor - and would skip the coalescing that keeps a
    /// 250 Hz pad from filling the input channel. The dispatcher already keys its gamepad
    /// coalescing on `playerIndex` and `deviceID`, so one player's state can never overwrite
    /// another's.
    func forwardRemoteCoOpInput(_ events: [UserInputEvent]) {
        guard !events.isEmpty else { return }
        for event in events { forwardRemoteCoOpInput(event) }
    }

    func forwardRemoteCoOpInput(_ event: UserInputEvent) {
        guard !isEnding, !didEnd else { return }
        inputDispatcher?.enqueue(event)
    }

    /// Delivers the neutral pad states a departing guest leaves behind, bypassing the dispatcher.
    ///
    /// The dispatcher is a queue: an event handed to it arrives at some later point. The caller
    /// un-announces the guest's slot immediately afterwards, and the transport drops state for a
    /// pad it no longer announces - so a queued neutral state would be discarded and whatever the
    /// guest was holding would stay held in the game. Writing straight to the path and awaiting it
    /// puts the neutral state ahead of the topology change on the transport actor, which is the
    /// only ordering that guarantees the release lands.
    func sendRemoteCoOpNeutralInput(_ events: [UserInputEvent]) async {
        guard !events.isEmpty, let path, !didEnd else { return }
        for event in events {
            try? await path.send(event)
        }
    }

    /// Announces the union of the host's own pads and every approved guest slot.
    ///
    /// The seat's `0x20d` descriptor carries one bitmap for all four slots, so it is never additive:
    /// announcing only the guest would disconnect the host's controller, and announcing only the
    /// host would disconnect the guest.
    func syncRemoteCoOpGamepadTopology() async {
        guard let path, isConnected, !isEnding, !didEnd else { return }
        let topology = mergedGamepadTopology(localTopology: localGamepadTopology)
        do {
            try await path.updateGamepadTopology(topology)
        } catch {
            remoteCoOpMessage = Self.message(for: error)
            WebRTCMediaTelemetry.capture("nvst.remote_coop.topology.failed", level: .warning, message: Self.message(for: error), attributes: [
                "applicationID": configuration.applicationID,
                "playerIndices": topology.playerIndices.map(String.init).joined(separator: ",")
            ])
        }
    }

    /// The local pads plus the slot of every guest whose input is enabled. Guests never get
    /// haptics: the rumble path drives a physical device on this Mac, and a guest's pad is on the
    /// other side of a browser.
    func mergedGamepadTopology(localTopology: NativeWebRTCGamepadTopology) -> NativeWebRTCGamepadTopology {
        let guestIndices = remoteCoOpSnapshot.participants.compactMap { participant -> Int? in
            guard participant.inputEnabled, participant.connectionState == .connected else { return nil }
            return participant.playerIndex
        }
        guard !guestIndices.isEmpty else { return localTopology }
        return NativeWebRTCGamepadTopology(
            playerIndices: localTopology.playerIndices + guestIndices,
            hapticPlayerIndices: localTopology.hapticPlayerIndices
        )
    }

    // MARK: - Signaling and peers

    func makeRemoteCoOpCoordinator(preferences: OPNRemoteCoOpPreferences) -> OPNRemoteCoOpHostCoordinator {
        if let remoteCoOpHostCoordinator {
            if remoteCoOpPeerController == nil, let remoteCoOpSignalingSession {
                remoteCoOpPeerController = makeRemoteCoOpPeerController(signaling: remoteCoOpSignalingSession, coordinator: remoteCoOpHostCoordinator)
            }
            return remoteCoOpHostCoordinator
        }
        let signaling = makeRemoteCoOpSignalingSession(preferences: preferences)
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: remoteCoOpHostSession, signaling: signaling)
        remoteCoOpNetworkConfiguration = OPNRemoteCoOpNetworkConfiguration(transportMode: preferences.transportMode, latencyMode: preferences.latencyMode)
        remoteCoOpSignalingSession = signaling
        remoteCoOpHostCoordinator = coordinator
        remoteCoOpPeerController = makeRemoteCoOpPeerController(signaling: signaling, coordinator: coordinator)
        remoteCoOpListenTask?.cancel()
        remoteCoOpListenTask = Task { @MainActor in
            for await event in signaling.events() {
                switch event {
                case .peerSignal(let participantID, let signal):
                    do {
                        try await remoteCoOpPeerController?.receiveSignal(participantID: participantID, signal: signal)
                    } catch {
                        remoteCoOpMessage = Self.message(for: error)
                    }
                case .networkConfiguration(let configuration):
                    remoteCoOpNetworkConfiguration = configuration
                    await remoteCoOpPeerController?.updateNetworkConfiguration(configuration)
                default:
                    let routedEvents = await coordinator.handle(event)
                    forwardRemoteCoOpInput(routedEvents)
                }
                let previousSlots = remoteCoOpConnectedGuestSlots
                remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
                // Auto-approval (`requireHostApproval` off) seats a guest without anyone touching
                // the HUD, so the topology has to follow the snapshot rather than the approve
                // button. Compared rather than sent unconditionally: this loop runs on every
                // signaling message, including each guest input packet on the WebSocket fallback.
                if previousSlots != remoteCoOpConnectedGuestSlots {
                    await syncRemoteCoOpGamepadTopology()
                }
                try? await syncRemoteCoOpPeers()
            }
        }
        return coordinator
    }

    var remoteCoOpConnectedGuestSlots: Set<Int> {
        Set(remoteCoOpSnapshot.participants.compactMap { participant -> Int? in
            guard participant.inputEnabled, participant.connectionState == .connected else { return nil }
            return participant.playerIndex
        })
    }

    func makeRemoteCoOpPeerController(signaling: any OPNRemoteCoOpSignalingSession, coordinator: OPNRemoteCoOpHostCoordinator) -> OPNRemoteCoOpHostPeerController {
        let preferences = remoteCoOpLaunchPreferences
        return OPNRemoteCoOpHostPeerController(
            signaling: signaling,
            coordinator: coordinator,
            networkConfiguration: remoteCoOpNetworkConfiguration,
            qualityPreset: preferences.qualityPreset,
            latencyMode: preferences.latencyMode,
            videoRelay: remoteCoOpVideoRelay,
            audioRelay: remoteCoOpAudioRelay,
            forwardInput: { [weak self] event in
                Task { @MainActor in self?.forwardRemoteCoOpInput(event) }
            }
        )
    }

    func syncRemoteCoOpPeers() async throws {
        guard let remoteCoOpPeerController else { return }
        do {
            try await remoteCoOpPeerController.sync(participants: remoteCoOpSnapshot.participants)
        } catch {
            remoteCoOpMessage = Self.message(for: error)
            WebRTCMediaTelemetry.capture("nvst.remote_coop.peer_sync.failed", level: .warning, message: remoteCoOpMessage, attributes: ["applicationID": configuration.applicationID])
            throw error
        }
    }

    func makeRemoteCoOpSignalingSession(preferences: OPNRemoteCoOpPreferences) -> any OPNRemoteCoOpSignalingSession {
        if let serverURL = URL(string: preferences.signalingServerURL.trimmingCharacters(in: .whitespacesAndNewlines)), serverURL.scheme?.hasPrefix("ws") == true {
            return OPNRemoteCoOpWebSocketSignalingSession(serverURL: serverURL)
        }
        return OPNInProcessRemoteCoOpSignalingSession()
    }

    func remoteCoOpJoinBaseURL(_ preferences: OPNRemoteCoOpPreferences) -> URL? {
        URL(string: preferences.guestJoinBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Tears the hosting side down and returns the neutral pad states the caller must still deliver.
    ///
    /// They are returned rather than sent because teardown runs from paths that are about to drop
    /// the input dispatcher, and a neutral state that arrives after the dispatcher is gone leaves
    /// the guest's last held button pressed in the game.
    @discardableResult
    func stopRemoteCoOpSession() async -> [UserInputEvent] {
        let neutralEvents: [UserInputEvent]
        if let remoteCoOpHostCoordinator {
            neutralEvents = await remoteCoOpHostCoordinator.stopInvite()
        } else {
            neutralEvents = await remoteCoOpHostSession.stopInvite()
        }
        remoteCoOpListenTask?.cancel()
        remoteCoOpListenTask = nil
        await remoteCoOpPeerController?.removeAll()
        remoteCoOpVideoRelay.removeAll()
        remoteCoOpAudioRelay.removeAll()
        remoteCoOpPeerController = nil
        await remoteCoOpSignalingSession?.close()
        remoteCoOpSignalingSession = nil
        remoteCoOpHostCoordinator = nil
        return neutralEvents
    }
}
