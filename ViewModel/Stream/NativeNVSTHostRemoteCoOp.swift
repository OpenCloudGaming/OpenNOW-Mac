//  Hosting a Remote Co-Op session from the native NVST stream: the invite, the participants, and
//  the peer plumbing behind them.
//
//  Remote Co-Op requires this transport. The WebRTC path used to host too, via a sibling file that
//  is gone: it decodes inside libwebrtc and exposes no frame tap, so sharing frames meant a second
//  decode and encode per frame. Everything above the transport - the signed invite, signaling, the
//  approval flow, the per-guest `RTCPeerConnection` - is shared with the guest side; three seams are
//  specific to this transport:
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
        if let invite = remoteCoOpSnapshot.invite, !invite.isExpired { return remoteCoOpClipboardLabel }
        return "Create invite"
    }

    /// Names what Copy actually puts on the clipboard.
    ///
    /// Never the six-character code: `validate` accepts only the signed token, and the guest window
    /// has no code field at all, so a host who reads those six characters to a friend has given them
    /// the one thing they cannot join with. The code stays useful for identifying a session in the
    /// HUD and the logs - it is just not a credential.
    var remoteCoOpClipboardLabel: String {
        guard let invite = remoteCoOpSnapshot.invite else { return "No active invite" }
        return invite.joinURL == nil ? "Copies signed token" : "Copies join link"
    }

    var remoteCoOpInviteActionSubtitle: String {
        guard remoteCoOpSnapshot.preferences.isAvailable else { return "Enable in Settings" }
        guard isConnected else { return "Stream not ready" }
        if let invite = remoteCoOpSnapshot.invite {
            return invite.isExpired ? "Refresh" : remoteCoOpClipboardLabel
        }
        return "Create + copy"
    }

    /// Whether the HUD's invite button should do anything. The stream has to be live before an
    /// invite is worth handing out: a guest who joins first would connect to a peer with no frames
    /// to send, and the seat has no pad slot to give them until input is negotiated.
    var canStartRemoteCoOpInvite: Bool {
        remoteCoOpSnapshot.preferences.isAvailable &&
            remoteCoOpSnapshot.preferences.effectiveReservedGuestSlots > 0 &&
            isConnected && !isEnding && !didEnd &&
            // In-flight counts as "cannot start again": the invite is only published at the end of a
            // multi-second bring-up, so this is the only thing standing between a double press and
            // two half-built sessions.
            !isStartingRemoteCoOpInvite
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
        remoteCoOpNetworkConfiguration = OPNRemoteCoOpNetworkConfiguration(transportMode: preferences.transportMode, latencyMode: preferences.latencyMode, sessionQualityPreset: preferences.qualityPreset)
        remoteCoOpSnapshot = OPNRemoteCoOpHostSnapshot(preferences: preferences, invite: remoteCoOpSnapshot.invite, participants: remoteCoOpSnapshot.participants)
        applyRemoteCoOpVideoScale(preferences: preferences)
        Task { @MainActor in
            await remoteCoOpHostSession.updatePreferences(preferences)
            await remoteCoOpEmbeddedServer?.updateNetworkConfiguration(remoteCoOpNetworkConfiguration)
            remoteCoOpNativeServer?.updateNetworkConfiguration(remoteCoOpNetworkConfiguration)
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
        // The largest live guest, not the session default: one buffer feeds every encoder, so a smaller
        // pre-scale would cap the most demanding guest with no way to recover.
        let preset = remoteCoOpSnapshot.participants
            .filter { $0.connectionState == .connected && $0.inputEnabled }
            .map { $0.effectiveQualityPreset(sessionDefault: preferences.qualityPreset) }
            .max { ($0.width * $0.height) < ($1.width * $1.height) } ?? preferences.qualityPreset
        remoteCoOpVideoRelay.setPreferredOutputSize(width: preset.width, height: preset.height)
    }

    /// Retargets one guest's stream, or clears them back to the session default with nil.
    func setRemoteCoOpParticipantQualityPreset(_ preset: OPNRemoteCoOpQualityPreset?, for participantID: UUID) {
        Task { @MainActor in
            do {
                let participant: OPNRemoteCoOpParticipant
                if let remoteCoOpHostCoordinator {
                    participant = try await remoteCoOpHostCoordinator.setQualityPreset(preset, for: participantID)
                } else {
                    participant = try await remoteCoOpHostSession.setQualityPreset(preset, for: participantID)
                }
                remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
                // Snapshot before rescale: the ceiling is computed from it.
                applyRemoteCoOpVideoScale(preferences: remoteCoOpLaunchPreferences)
                try await syncRemoteCoOpPeers()
                let label = participant.qualityPreset?.label ?? "session default (\(remoteCoOpLaunchPreferences.qualityPreset.label))"
                remoteCoOpMessage = "\(participant.displayName): \(label)"
                showNativeTransientStreamMessage("Remote Co-Op quality: \(label)")
            } catch {
                remoteCoOpMessage = Self.message(for: error)
            }
        }
    }

    func startRemoteCoOpInvite() {
        let preferences = remoteCoOpLaunchPreferences
        guard canStartRemoteCoOpInvite else {
            remoteCoOpMessage = isConnected ? "Remote Co-Op is unavailable for this session." : "Wait for the stream to connect."
            return
        }
        remoteCoOpMessage = "Creating..."
        // Creating an invite takes seconds - TURN probing, binding a TLS listener, minting the hosted
        // channel - and the HUD button's disabled state is driven by `remoteCoOpSnapshot.invite`,
        // which is not set until the very end. So the button stayed live throughout, and a second
        // press ran `stopRemoteCoOpSession()` against the first attempt's half-built session: it
        // cancelled that listen task and closed its signaling, then the first attempt resumed and
        // published *its* invite and copied *its* link, while the only live channel belonged to the
        // second. Every guest opening the copied link was dropped.
        isStartingRemoteCoOpInvite = true
        applyRemoteCoOpVideoScale(preferences: preferences)
        Task { @MainActor in
            defer { isStartingRemoteCoOpInvite = false }
            let neutralEvents = await stopRemoteCoOpSession()
            await sendRemoteCoOpNeutralInput(neutralEvents)
            remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
            await syncRemoteCoOpGamepadTopology()
            await remoteCoOpHostSession.updatePreferences(preferences)
            do {
                // Resolved before the invite because the link and the signed payload both carry
                // these addresses, and when hosting locally they are not known until the server
                // has bound a port.
                // Minted per invite, before the servers are handed out: the credentials are short-lived,
                // and every guest of this invite - browser or native - receives them with the rest of
                // the ICE configuration, so nobody but the host configures anything.
                // Built from the launch preferences right here rather than inherited from whatever
                // `refreshRemoteCoOpState` last left behind, so the augmented value below is the only
                // one any consumer sees. It used to be rebuilt again inside
                // `makeRemoteCoOpCoordinator`, which silently discarded the relay servers minted on
                // the line above: browser guests kept them because the embedded server was handed the
                // augmented copy, while the host's own peers and every native guest got a STUN-only
                // configuration. Visible in the logs as `host_peer.connection: iceServers=1`.
                let (hosting, invite) = try await buildRemoteCoOpHosting(preferences: preferences)
                remoteCoOpCertificateFingerprint = hosting.certificateFingerprint
                remoteCoOpIsLocallyHosted = hosting.isLocallyHosted
                remoteCoOpNativeGuestAddress = remoteCoOpNativeServer?.guestAddressHint
                remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
                copyRemoteCoOpInvite(invite)
                // Names what is actually on the clipboard. `remoteCoOpClipboardText` falls back to the
                // signed token, not the six-character code, and the host session no longer accepts a
                // bare code - so telling the host their code was copied sent them to read out the one
                // thing a guest cannot join with.
                remoteCoOpMessage = invite.joinURL == nil ? "Token copied" : "Link copied"
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
            // Refreshed before the announce, not after: `mergedGamepadTopology` reads this snapshot,
            // and the pre-stop one still lists every guest as connected - so the widened bitmap was
            // re-announced unchanged and the guest's pad was never withdrawn from the seat.
            remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
            await syncRemoteCoOpGamepadTopology()
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
    ///
    /// Single entry point for every announce, because the ordering around a *departing* pad is
    /// load-bearing. The transport drops state for a pad it no longer announces, so a neutral state
    /// has to arrive first or whatever was held stays held in the game. The monitor does emit one on
    /// unplug, but through `NativeNVSTInputDispatcher` - a queue - while the announce travels on its
    /// own task, so the announce can win. Sending the release directly here removes the race
    /// whatever the queue is doing.
    func syncRemoteCoOpGamepadTopology() async {
        guard let path, isConnected, !isEnding, !didEnd else { return }
        // Kept current before merging, so the next guest slot assignment - which can race this
        // announce - never hands out an index a local controller already holds.
        await remoteCoOpHostSession.updateReservedLocalPlayerIndices(Set(localGamepadTopology.playerIndices))
        let topology = mergedGamepadTopology(localTopology: localGamepadTopology)
        let announced = Set(topology.playerIndices)
        let departing = lastAnnouncedGamepadIndices.subtracting(announced)
        if !departing.isEmpty {
            await sendRemoteCoOpNeutralInput(departing.sorted().map { playerIndex in
                .gamepad(GamepadState(
                    deviceID: InputDeviceID("released-pad-\(playerIndex)"),
                    playerIndex: playerIndex,
                    timestamp: MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
                ))
            })
        }
        lastAnnouncedGamepadIndices = announced
        do {
            try await path.updateGamepadTopology(topology)
        } catch {
            // Silent when no invite is live. `presentStream` announces the host's own pads through
            // here before input is negotiated, so every solo session was writing "NVST input is not
            // negotiated yet." into the Remote Co-Op card and firing a warning - about a session
            // that has no guests and needs none.
            guard remoteCoOpSnapshot.invite != nil else { return }
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

    // MARK: - Hosted signaling

    /// The channel this invite's guests signal on, or nil when no Ably key is configured.
    ///
    /// Derived from the invite so a new invite is a new channel: a credential that outlived its invite
    /// has nothing left to address even before its own expiry runs out.
    func remoteCoOpHostedSignaling(inviteID: UUID, expiresAt: Date) -> OPNRemoteCoOpInviteSignaling? {
        let key = OPNRemoteCoOpAblyKeyStore.load()
        guard key.isUsable else { return nil }
        let channel = OPNRemoteCoOpAblyJWT.channelName(inviteID: inviteID)
        guard let token = OPNRemoteCoOpAblyJWT.mintGuestToken(key: key, channel: channel, expiresAt: expiresAt) else { return nil }
        return OPNRemoteCoOpInviteSignaling(channel: channel, token: token)
    }

    /// The host's own connection to that channel.
    ///
    /// Made with a JWT of its own rather than the API key, so the key stays in the keychain. The
    /// host's capability is the *mirror* of the guests' - publish on the host channel, read and watch
    /// presence on the guest channel - which is what makes a guest unable to speak as the host. Scoped
    /// to the *current* invite, so it is rebuilt when the invite is.
    private func makeRemoteCoOpHostedChannel(inviteID: UUID, expiresAt: Date) -> (any OPNRemoteCoOpSignalingChannel)? {
        let key = OPNRemoteCoOpAblyKeyStore.load()
        guard key.isUsable else { return nil }
        let channel = OPNRemoteCoOpAblyJWT.channelName(inviteID: inviteID)
        guard let token = OPNRemoteCoOpAblyJWT.mintHostToken(key: key, channel: channel, expiresAt: expiresAt) else { return nil }
        return OPNRemoteCoOpAblyChannel(
            token: token,
            channelName: channel,
            logger: { message in WebRTCMediaTelemetry.capture("nvst.remote_coop.hosted_signaling", level: .warning, message: message) }
        )
    }

    // MARK: - Signaling and peers

    /// `pendingInviteID` and `pendingInviteExpiry` describe the invite that is about to be created.
    ///
    /// The hosted channel is named after the invite, and the host has to be subscribed before the
    /// invite naming it goes out - otherwise the first guest publishes into a channel nobody is
    /// listening on. Reading the ID off `remoteCoOpSnapshot` instead would always find nil here,
    /// because the coordinator is built before the invite exists.
    func makeRemoteCoOpCoordinator(preferences: OPNRemoteCoOpPreferences,
                                   hosting: OPNRemoteCoOpHostingSession,
                                   pendingInviteID: UUID,
                                   pendingInviteExpiry: Date) -> OPNRemoteCoOpHostCoordinator {
        if let remoteCoOpHostCoordinator {
            if remoteCoOpPeerController == nil, let remoteCoOpSignalingSession {
                remoteCoOpPeerController = makeRemoteCoOpPeerController(signaling: remoteCoOpSignalingSession, coordinator: remoteCoOpHostCoordinator)
            }
            return remoteCoOpHostCoordinator
        }
        remoteCoOpEmbeddedServer = hosting.embeddedServer
        // `remoteCoOpNetworkConfiguration` is deliberately not rebuilt here. The only caller sets it
        // immediately above, relay servers included, and reconstructing it from preferences threw
        // those away - the initializer defaults `iceServers` to STUN only.
        // Native guests (another OpenNOW on this network or a shared VPN) arrive on their own
        // listener and are composed with the browser transport, so one session serves both. The
        // composite is what `stopRemoteCoOpSession` closes, which stops the listener too.
        let nativeServer = OPNRemoteCoOpNativeGuestServer(
            // The greeting invite, not the real one: this is handed to any socket that connects,
            // before it has presented anything, so it must not carry the hosted-signaling credential.
            inviteProvider: { [remoteCoOpHostSession] in await remoteCoOpHostSession.greetingInvite() },
            networkConfiguration: remoteCoOpNetworkConfiguration,
            logger: { message in WebRTCMediaTelemetry.capture("nvst.remote_coop.native_server", level: .info, message: message) }
        )
        nativeServer.start()
        remoteCoOpNativeServer = nativeServer
        // Hosted signaling joins the composite rather than replacing anything: a guest that can reach
        // this Mac directly still does, over the embedded server, with no third party involved and no
        // messages billed. Only a guest handed a hosted invite uses the channel.
        var sessions: [any OPNRemoteCoOpSignalingSession] = [hosting.signaling, nativeServer]
        if let hostedChannel = makeRemoteCoOpHostedChannel(inviteID: pendingInviteID, expiresAt: pendingInviteExpiry) {
            let hosted = OPNRemoteCoOpHostedSignalingSession(
                channel: hostedChannel,
                // The augmented configuration, same as the socket transports get - without it a
                // hosted guest is handed no ICE servers at all and cannot connect from a network
                // that blocks a direct route.
                networkConfiguration: remoteCoOpNetworkConfiguration,
                logger: { message in WebRTCMediaTelemetry.capture("nvst.remote_coop.hosted_signaling", level: .info, message: message) }
            )
            sessions.append(hosted)
        }
        let signaling: any OPNRemoteCoOpSignalingSession = OPNRemoteCoOpCompositeSignalingSession(sessions: sessions)
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: remoteCoOpHostSession, signaling: signaling)
        remoteCoOpSignalingSession = signaling
        remoteCoOpHostCoordinator = coordinator
        remoteCoOpPeerController = makeRemoteCoOpPeerController(signaling: signaling, coordinator: coordinator)
        remoteCoOpListenTask?.cancel()
        remoteCoOpListenTask = startRemoteCoOpSignalingLoop(signaling: signaling, coordinator: coordinator)
        return coordinator
    }

    /// Consumes signaling events for the life of the invite.
    ///
    /// Its own function rather than a closure inside `makeRemoteCoOpCoordinator`, which was otherwise
    /// building four objects and running a 45-line event loop in one body.
    private func startRemoteCoOpSignalingLoop(signaling: any OPNRemoteCoOpSignalingSession,
                                              coordinator: OPNRemoteCoOpHostCoordinator) -> Task<Void, Never> {
        Task { @MainActor in
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
                case .signalingError(let reason):
                    // Silent on the wire otherwise: the invite looks created and guests queue up
                    // against signaling that is not carrying anything.
                    remoteCoOpMessage = reason
                    showNativeTransientStreamMessage("Remote Co-Op: \(reason)")
                    WebRTCMediaTelemetry.capture("nvst.remote_coop.signaling.error", level: .warning, message: reason, attributes: ["applicationID": configuration.applicationID])
                case .guestInput:
                    // Input stops here, and that is the whole point.
                    //
                    // This loop runs on the MainActor - the one driving the Metal stream surface - and
                    // everything below used to run for *every* signaling message, input included: two
                    // actor round trips plus a `@Published` snapshot write, so a SwiftUI invalidation
                    // per packet. A browser guest on the WebSocket fallback (the default outside
                    // low-latency mode, and not gated on approval) polls its pad on
                    // `requestAnimationFrame`, so that was 60-120 full peer syncs a second against
                    // the host's live game. Input cannot change participants, so none of it applies.
                    let routedEvents = await coordinator.handle(event)
                    forwardRemoteCoOpInput(routedEvents)
                    continue
                default:
                    let routedEvents = await coordinator.handle(event)
                    forwardRemoteCoOpInput(routedEvents)
                }
                let previousSlots = remoteCoOpConnectedGuestSlots
                // Guests whose grace period ran out lose their slot here. Driven off signaling
                // traffic rather than a timer: the only thing that cares is the announced topology,
                // and it cannot change without some guest activity anyway.
                let expired = await remoteCoOpHostSession.expireDisconnectedParticipants()
                for participant in expired {
                    await remoteCoOpSignalingSession?.send(.participantRemoved(participant.id))
                    await remoteCoOpPeerController?.removePeer(participantID: participant.id)
                }
                let previouslyWaiting = remoteCoOpWaitingParticipantIDs
                remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
                announceRemoteCoOpArrivals(previouslyWaiting: previouslyWaiting)
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
    }

    /// Everything between "the host pressed Create" and "there is an invite": relay credentials, the
    /// local listener, the hosted channel, and the signed invite itself.
    ///
    /// Extracted from `startRemoteCoOpInvite`, which was doing this plus teardown, clipboard and HUD
    /// state in one body. The ordering here is load-bearing and the comments explain each step.
    private func buildRemoteCoOpHosting(preferences: OPNRemoteCoOpPreferences) async throws -> (hosting: OPNRemoteCoOpHostingSession, invite: OPNRemoteCoOpInvite) {
                remoteCoOpNetworkConfiguration = await OPNRemoteCoOpHostingEndpoint.relayAugmented(
            OPNRemoteCoOpNetworkConfiguration(
                transportMode: preferences.transportMode,
                latencyMode: preferences.latencyMode,
                sessionQualityPreset: preferences.qualityPreset
            ),
            credentials: OPNRemoteCoOpTURNKeyStore.load(),
            logger: { message in WebRTCMediaTelemetry.capture("nvst.remote_coop.relay", level: .info, message: message) }
        )
        let hosting = try await OPNRemoteCoOpHostingEndpoint.make(
            preferences: preferences,
            networkConfiguration: remoteCoOpNetworkConfiguration,
            logger: { message in WebRTCMediaTelemetry.capture("nvst.remote_coop.server", level: .info, message: message) }
        )
        // Generated here rather than inside `startInvite`, because the hosted channel is named
        // after it and the host must be subscribed before the invite naming it is handed out.
        let pendingInviteID = UUID()
        let inviteLifetimeSeconds: TimeInterval = 3_600
        let pendingInviteExpiry = Date().addingTimeInterval(inviteLifetimeSeconds)
        // Minted once and handed to both sides: the host subscribes with it below, and the
        // same channel and expiry go into the invite. Deriving them twice would let the two
        // drift.
        //
        // Fallback, not primary: a working tunnel already gets a guest both a public address
        // and a real route for media, so routing signaling through Ably on top of it would add
        // a dependency and a per-message cost for nothing. Only minted when there is no tunnel
        // to prefer - a host with both configured gets the tunnel, deterministically, instead
        // of whichever finished loading first deciding it silently.
        let hostedSignaling = preferences.effectivePublicAddress == nil
            ? remoteCoOpHostedSignaling(inviteID: pendingInviteID, expiresAt: pendingInviteExpiry)
            : nil
        let coordinator = makeRemoteCoOpCoordinator(
            preferences: preferences,
            hosting: hosting,
            pendingInviteID: pendingInviteID,
            pendingInviteExpiry: pendingInviteExpiry
        )
        // A static guest page only makes sense once this invite is already hosted: an
        // embedded invite still needs a guest to reach this Mac's own server to negotiate at
        // all, so pointing them at a page hosted elsewhere would hand them a page that can
        // never connect. `signalingServerURL` is left at the default when the page is static,
        // since there is no `wss://` URL for it to carry - the guest signals over the channel
        // named in the invite payload instead.
        let usesStaticGuestPage = hostedSignaling != nil && preferences.effectiveHostedGuestPageURL != nil
        let invite = try await coordinator.startInvite(
            inviteID: pendingInviteID,
            applicationID: configuration.applicationID,
            title: configuration.title,
            joinBaseURL: usesStaticGuestPage ? preferences.effectiveHostedGuestPageURL : hosting.joinBaseURL,
            signalingServerURL: usesStaticGuestPage ? "" : hosting.signalingServerURL,
            lifetimeSeconds: inviteLifetimeSeconds,
            hostedSignaling: { _, _ in hostedSignaling }
        )
        return (hosting, invite)
    }

    var remoteCoOpWaitingParticipantIDs: Set<UUID> {
        Set(remoteCoOpSnapshot.participants.filter { $0.connectionState == .waitingForApproval }.map(\.id))
    }

    /// Tells the host someone is at the door.
    ///
    /// A guest waiting for approval is blocked until the host opens the HUD, which they have no reason
    /// to do mid-game. Every lesser event here already announces itself; this was the one where
    /// somebody is actually waiting.
    func announceRemoteCoOpArrivals(previouslyWaiting: Set<UUID>) {
        let arrived = remoteCoOpSnapshot.participants.filter {
            $0.connectionState == .waitingForApproval && !previouslyWaiting.contains($0.id)
        }
        guard !arrived.isEmpty else { return }
        let names = arrived.map(\.displayName).joined(separator: ", ")
        remoteCoOpMessage = "\(names) wants to join. Open the HUD to approve."
        showNativeTransientStreamMessage(arrived.count == 1
            ? "\(names) wants to join Remote Co-Op — ⌘G to approve"
            : "\(arrived.count) guests want to join Remote Co-Op — ⌘G to approve")
    }

    /// How long the invite has left, for the HUD. Nil when there is nothing to count down.
    var remoteCoOpInviteRemainingText: String? {
        guard let invite = remoteCoOpSnapshot.invite, !invite.isExpired else { return nil }
        let remaining = Int(invite.expiresAt.timeIntervalSinceNow)
        guard remaining > 0 else { return nil }
        if remaining < 60 { return "\(remaining)s left" }
        if remaining < 3_600 { return "\(remaining / 60)m left" }
        return "\(remaining / 3_600)h \((remaining % 3_600) / 60)m left"
    }

    func copyRemoteCoOpGuestAddress() {
        guard let address = remoteCoOpNativeGuestAddress else { return }
        OPNRemoteCoOpInviteClipboard.copy(address)
        remoteCoOpMessage = "Copied \(address)"
        showNativeTransientStreamMessage("Remote Co-Op address copied")
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
            // Off the main actor: guest packets arrive on libwebrtc's network thread, and hopping to a
            // main actor that is also driving the Metal surface cost frames. The holder returns nil
            // after teardown, matching what the `isEnding`/`didEnd` guard did.
            forwardInput: { [holder = inputDispatcherHolder] event in
                holder.enqueue(event)
            }
        )
    }

    /// Pull-based so it rides the existing snapshot refresh rather than publishing per stats poll.
    func refreshRemoteCoOpDeliveryStats() async {
        guard let remoteCoOpPeerController else {
            if !remoteCoOpDeliveryStats.isEmpty { remoteCoOpDeliveryStats = [:] }
            return
        }
        remoteCoOpDeliveryStats = await remoteCoOpPeerController.deliveryStats()
    }

    func syncRemoteCoOpPeers() async throws {
        guard let remoteCoOpPeerController else { return }
        do {
            try await remoteCoOpPeerController.sync(participants: remoteCoOpSnapshot.participants)
            await refreshRemoteCoOpDeliveryStats()
        } catch {
            remoteCoOpMessage = Self.message(for: error)
            WebRTCMediaTelemetry.capture("nvst.remote_coop.peer_sync.failed", level: .warning, message: remoteCoOpMessage, attributes: ["applicationID": configuration.applicationID])
            throw error
        }
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
        // Closing the session stops the embedded server, but a session that never got as far as
        // being stored would leave the listener bound and the port held.
        await remoteCoOpEmbeddedServer?.stop()
        remoteCoOpEmbeddedServer = nil
        // The composite session's `close()` stops the listener; this only drops the HUD's reference.
        remoteCoOpNativeServer = nil
        remoteCoOpNativeGuestAddress = nil
        remoteCoOpDeliveryStats = [:]
        remoteCoOpCertificateFingerprint = nil
        remoteCoOpIsLocallyHosted = false
        remoteCoOpHostCoordinator = nil
        return neutralEvents
    }
}
