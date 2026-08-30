//
//  WebRTCMediaStreamRemoteCoOp.swift
//  OpenNOW
//
//  Hosting a Remote Co-Op session from the stream surface: the invite, the participants and
//  the peer plumbing behind them. Split out of WebRTCMediaStreamSurface.swift.
//

import AppKit
import Combine
import GameController
import Foundation
import SwiftUI

extension WebRTCMediaStreamSurface {
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

    var remoteCoOpInviteCode: String {
        remoteCoOpSnapshot.invite?.code ?? "No active invite"
    }

    var remoteCoOpInviteActionSubtitle: String {
        guard remoteCoOpSnapshot.preferences.isAvailable else { return "Enable in Settings" }
        guard isStreamReady else { return "Stream not ready" }
        if let invite = remoteCoOpSnapshot.invite {
            return invite.isExpired ? "Refresh" : invite.code
        }
        return "Create + copy"
    }

    func refreshRemoteCoOpState() {
        let preferences = remoteCoOpLaunchPreferences
        remoteCoOpNetworkConfiguration = OPNRemoteCoOpNetworkConfiguration(transportMode: preferences.transportMode, latencyMode: preferences.latencyMode)
        remoteCoOpSnapshot = OPNRemoteCoOpHostSnapshot(preferences: preferences, invite: remoteCoOpSnapshot.invite, participants: remoteCoOpSnapshot.participants)
        Task { @MainActor in
            await remoteCoOpHostSession.updatePreferences(preferences)
            await remoteCoOpPeerController?.updateNetworkConfiguration(remoteCoOpNetworkConfiguration)
            await remoteCoOpPeerController?.updateQualityPreset(preferences.qualityPreset)
            await remoteCoOpPeerController?.updateLatencyMode(preferences.latencyMode)
            remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
        }
    }

    func startRemoteCoOpInvite() {
        let preferences = remoteCoOpLaunchPreferences
        guard preferences.isAlphaOptedIn else { return }
        remoteCoOpMessage = "Creating..."
        Task { @MainActor in
            let neutralEvents = await stopRemoteCoOpSession()
            neutralEvents.forEach { transport?.sendNow($0) }
            await remoteCoOpHostSession.updatePreferences(preferences)
            do {
                let coordinator = makeRemoteCoOpCoordinator(preferences: preferences)
                let invite = try await coordinator.startInvite(applicationID: configuration.applicationID, title: configuration.title, joinBaseURL: remoteCoOpJoinBaseURL(preferences), signalingServerURL: preferences.signalingServerURL)
                remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
                copyRemoteCoOpInvite(invite)
                remoteCoOpMessage = invite.joinURL == nil ? "Copied \(invite.code)" : "Link copied"
                showTransientStreamMessage("Remote Co-Op invite copied")
                WebRTCMediaTelemetry.capture("webrtc.remote_coop.invite.created", level: .info, message: "Remote Co-Op invite created.", attributes: ["applicationID": configuration.applicationID, "reservedSlots": String(preferences.effectiveReservedGuestSlots), "transportMode": preferences.transportMode.rawValue, "latencyMode": preferences.latencyMode.rawValue])
            } catch {
                _ = await stopRemoteCoOpSession()
                remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
                remoteCoOpMessage = Self.message(for: error)
                WebRTCMediaTelemetry.capture("webrtc.remote_coop.invite.failed", level: .warning, message: remoteCoOpMessage, attributes: ["applicationID": configuration.applicationID])
            }
        }
    }

    func stopRemoteCoOpInvite() {
        Task { @MainActor in
            let neutralEvents = await stopRemoteCoOpSession()
            neutralEvents.forEach { transport?.sendNow($0) }
            remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
            remoteCoOpMessage = "Ended"
            showTransientStreamMessage("Remote Co-Op invite ended")
            WebRTCMediaTelemetry.capture("webrtc.remote_coop.invite.ended", level: .info, message: "Remote Co-Op invite ended.", attributes: ["applicationID": configuration.applicationID])
        }
    }

    func copyRemoteCoOpInvite() {
        guard let invite = remoteCoOpSnapshot.invite else { return }
        copyRemoteCoOpInvite(invite)
        remoteCoOpMessage = invite.joinURL == nil ? "Token copied" : "Link copied"
        showTransientStreamMessage("Remote Co-Op invite copied")
    }

    func copyRemoteCoOpInvite(_ invite: OPNRemoteCoOpInvite) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(remoteCoOpClipboardText(invite), forType: .string)
    }

    func remoteCoOpClipboardText(_ invite: OPNRemoteCoOpInvite) -> String {
        if let joinURL = invite.joinURL {
            return joinURL.absoluteString
        }
        return invite.token
    }

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
                try await syncRemoteCoOpPeers()
                remoteCoOpMessage = "Approved \(participant.displayName) for player \((participant.playerIndex ?? 0) + 1)."
                showTransientStreamMessage("Remote Co-Op guest approved")
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
                neutralEvents.forEach { transport?.sendNow($0) }
                await remoteCoOpPeerController?.removePeer(participantID: participantID)
                remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
                remoteCoOpMessage = "Remote Co-Op guest removed."
                showTransientStreamMessage("Remote Co-Op guest removed")
            } catch {
                remoteCoOpMessage = Self.message(for: error)
            }
        }
    }

    var remoteCoOpLaunchPreferences: OPNRemoteCoOpPreferences {
        OPNRemoteCoOpPreferences.launchPreferences(from: configuration.metadata, fallback: OPNRemoteCoOpPreferencesStore.load())
    }

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
                    for routedEvent in routedEvents { transport?.sendNow(routedEvent) }
                }
                remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
                try? await syncRemoteCoOpPeers()
            }
        }
        return coordinator
    }

    func makeRemoteCoOpPeerController(signaling: any OPNRemoteCoOpSignalingSession, coordinator: OPNRemoteCoOpHostCoordinator) -> OPNRemoteCoOpHostPeerController {
        let inputTransport = transport
        return OPNRemoteCoOpHostPeerController(
            signaling: signaling,
            coordinator: coordinator,
            networkConfiguration: remoteCoOpNetworkConfiguration,
            qualityPreset: remoteCoOpLaunchPreferences.qualityPreset,
            latencyMode: remoteCoOpLaunchPreferences.latencyMode,
            videoRelay: remoteCoOpVideoRelay,
            audioRelay: remoteCoOpAudioRelay,
            forwardInput: { event in inputTransport?.sendNow(event) }
        )
    }

    func syncRemoteCoOpPeers() async throws {
        guard let remoteCoOpPeerController else { return }
        do {
            try await remoteCoOpPeerController.sync(participants: remoteCoOpSnapshot.participants)
        } catch {
            remoteCoOpMessage = Self.message(for: error)
            WebRTCMediaTelemetry.capture("webrtc.remote_coop.peer_sync.failed", level: .warning, message: remoteCoOpMessage, attributes: ["applicationID": configuration.applicationID])
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
