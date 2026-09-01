//
//  RemoteCoOpGuestViewModel.swift
//  OpenNOW
//
//  Drives the native Remote Co-Op guest window: browse for hosts, join one, and run the message
//  pump that carries the session from invite to video.
//

import Combine
import Foundation
@preconcurrency import WebRTC

@MainActor
final class RemoteCoOpGuestViewModel: ObservableObject {
    enum Phase: Equatable {
        case browsing
        case connecting
        case waitingForApproval
        case connected
        case failed(String)

        /// Only a connected guest may see the game.
        ///
        /// A video track can exist before approval - the host decides eligibility on connection state,
        /// so a bug there delivered one - and the guest should not be relying on the host to be right
        /// about that while showing a "waiting for approval" overlay.
        var allowsVideoPlayback: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    private static let participantIDDefaultsKey = "remoteCoOpNativeGuestParticipantID"
    private static let manualAddressDefaultsKey = "remoteCoOpNativeGuestManualAddress"
    private static let recentAddressesDefaultsKey = "remoteCoOpNativeGuestRecentAddresses"
    private static let recentAddressLimit = 5

    @Published private(set) var hosts: [OPNRemoteCoOpNativeDiscoveredHost] = []
    @Published private(set) var phase: Phase = .browsing
    @Published private(set) var statusText = "Looking for hosts on this network…"
    @Published private(set) var invite: OPNRemoteCoOpInvite?
    @Published private(set) var videoTrack: RTCVideoTrack?
    /// Live receive measurements, refreshed once a second while connected.
    @Published private(set) var stats: OPNRemoteCoOpGuestStats?
    /// Whether the overlay is shown. Off by default - it is a diagnostic, not decoration.
    @Published var statsVisible = false
    /// This guest's own participant record, as the host last described it. The source of truth for
    /// what quality they are on and what the host is willing to give them.
    @Published private(set) var participant: OPNRemoteCoOpParticipant?
    /// The host's session-wide preset, which is this guest's ceiling whenever the host has set no
    /// per-guest override.
    @Published private(set) var sessionQualityPreset: OPNRemoteCoOpQualityPreset?
    /// Whether this guest has any controller at all. Nil until input forwarding starts, so the window
    /// says nothing before there is anything to say.
    @Published private(set) var hasController: Bool?
    /// Addresses and links that have worked before, most recent first.
    @Published private(set) var recentAddresses: [String] = UserDefaults.standard.stringArray(forKey: RemoteCoOpGuestViewModel.recentAddressesDefaultsKey) ?? []
    /// The host currently being watched, for the stats overlay. Removing the "Watching <title>" pill
    /// took the host's name with it, which was the half worth keeping.
    @Published private(set) var connectedHostName: String?
    /// When the approval wait started, so the window can show how long it has been rather than an
    /// indefinite spinner.
    @Published private(set) var waitingSince: Date?
    /// Typed-in host address, for the routes Bonjour cannot see. Persisted because a guest who joins
    /// over a tailnet joins the same host every time.
    @Published var manualAddress: String = UserDefaults.standard.string(forKey: RemoteCoOpGuestViewModel.manualAddressDefaultsKey) ?? ""

    let participantID: UUID
    let displayName: String

    private let browser = OPNRemoteCoOpNativeHostBrowser()
    private var connection: (any OPNRemoteCoOpNativeGuestTransport)?
    private var peer: OPNRemoteCoOpNativeGuestPeer?
    private var inputSender: OPNRemoteCoOpNativeGuestInputSender?
    private var messageTask: Task<Void, Never>?
    /// Serializes `peerSignal` application so an ICE candidate cannot overtake the offer it belongs
    /// to. Cancelled with the session; see the comment at the `.peerSignal` case.
    private var peerSignalChain: Task<Void, Never>?
    private var connectionAttempt = 0
    private var peerStarted = false

    convenience init() {
        self.init(participantID: Self.loadOrCreateParticipantID(), displayName: Host.current().localizedName ?? "OpenNOW Guest")
    }

    init(participantID: UUID, displayName: String) {
        self.participantID = participantID
        self.displayName = displayName
        browser.onUpdate = { [weak self] hosts in
            Task { @MainActor in
                self?.hosts = hosts
            }
        }
    }

    func start() {
        browser.start()
    }

    func stop() {
        leave()
        browser.stop()
    }

    /// Joins whatever was typed in, which can be a host address or a full invite link.
    ///
    /// Both are accepted from one field because the guest should not have to know which kind of route
    /// they have. An invite link is what the host already copies to their clipboard and is the only
    /// thing that works through a tunnel; a bare address is what a tailnet or a forwarded port needs.
    /// Separate from `join(_:)` because the failure it can hit - input that parses as neither - happens
    /// before there is any connection to report on.
    func joinManualAddress() {
        let trimmed = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        // The link is tried first: it is more specific, and an address never contains a query string.
        if let link = OPNRemoteCoOpGuestInviteLink(link: trimmed) {
            rememberManualAddress(trimmed)
            join(link)
            return
        }
        guard let host = OPNRemoteCoOpNativeDiscoveredHost(address: trimmed) else {
            phase = .failed("\"\(trimmed)\" is neither a host address nor an invite link. Use an address such as 100.101.102.103 or my-mac:\(OPNRemoteCoOpNativeGuestServer.defaultPort), or paste the link the host copied.")
            return
        }
        rememberManualAddress(trimmed)
        join(host)
    }

    private func rememberManualAddress(_ address: String) {
        manualAddress = address
        UserDefaults.standard.set(address, forKey: Self.manualAddressDefaultsKey)
        var recents = recentAddresses.filter { $0.caseInsensitiveCompare(address) != .orderedSame }
        recents.insert(address, at: 0)
        recentAddresses = Array(recents.prefix(Self.recentAddressLimit))
        UserDefaults.standard.set(recentAddresses, forKey: Self.recentAddressesDefaultsKey)
    }

    func forgetRecentAddress(_ address: String) {
        recentAddresses.removeAll { $0 == address }
        UserDefaults.standard.set(recentAddresses, forKey: Self.recentAddressesDefaultsKey)
    }

    func joinRecentAddress(_ address: String) {
        manualAddress = address
        joinManualAddress()
    }

    func join(_ host: OPNRemoteCoOpNativeDiscoveredHost) {
        // No token: the native listener greets a new socket with `hostHello` carrying the invite, so
        // the join request waits for that rather than being sent up front.
        connect(transport: OPNRemoteCoOpNativeGuestConnection(endpoint: host.endpoint), name: host.name, inviteToken: nil)
    }

    /// Joins through the embedded server's WebSocket, which is the transport a tunnel forwards.
    func join(_ link: OPNRemoteCoOpGuestInviteLink) {
        connect(
            transport: OPNRemoteCoOpNativeGuestWebSocketConnection(signalingURL: link.signalingURL),
            name: link.signalingURL.host ?? "the host",
            // This socket is never greeted - a browser reads the token out of its own URL - so the
            // token from the link is presented as soon as the socket opens.
            inviteToken: link.token
        )
    }

    private func connect(transport: any OPNRemoteCoOpNativeGuestTransport, name: String, inviteToken: String?) {
        guard phase == .browsing || phase.isFailure else { return }
        leave()
        phase = .connecting
        statusText = "Connecting to \(name)…"
        connectedHostName = name
        connection = transport
        // Subscribed before the socket connects: the native listener greets on connect, and a stream
        // that only started iterating afterwards would miss the invite entirely.
        let messages = transport.messages()
        // The attempt this task belongs to. A cancelled pump resumes on the main actor after
        // `leave()` has already installed the next attempt's task, so `messageTask != nil` alone
        // let a dead socket tear down the connection that replaced it.
        connectionAttempt &+= 1
        let attempt = connectionAttempt
        messageTask = Task { [weak self] in
            do {
                try await transport.connect()
                if let inviteToken {
                    self?.requestJoin(inviteToken: inviteToken)
                }
                await self?.pumpMessages(messages)
                guard self?.connectionAttempt == attempt else { return }
                self?.handleConnectionEnded()
            } catch {
                // Not followed by `handleConnectionEnded`: that reported the generic "closed" over
                // the real reason, so an unreachable address always read as a socket that had been
                // open once.
                guard self?.connectionAttempt == attempt else { return }
                self?.handleConnectionFailure(error)
            }
        }
    }

    func leave() {
        messageTask?.cancel()
        messageTask = nil
        peerSignalChain?.cancel()
        peerSignalChain = nil
        inputSender?.stop()
        inputSender = nil
        peer?.close()
        peer = nil
        peerStarted = false
        connection?.close()
        connection = nil
        videoTrack = nil
        stats = nil
        participant = nil
        sessionQualityPreset = nil
        hasController = nil
        connectedHostName = nil
        waitingSince = nil
        invite = nil
        if phase != .browsing {
            phase = .browsing
            statusText = "Looking for hosts on this network…"
        }
    }

    // MARK: - Message pump

    private func pumpMessages(_ messages: AsyncStream<OPNRemoteCoOpWireMessage>) async {
        for await message in messages {
            guard !Task.isCancelled else { return }
            handle(message)
        }
    }

    private func handle(_ message: OPNRemoteCoOpWireMessage) {
        switch message.kind {
        case .heartbeat:
            // The embedded server drops a socket that stops answering, and gameplay input rides the
            // data channel, so this reply is the only traffic proving the guest is still here.
            let reply = OPNRemoteCoOpWireMessage(kind: .heartbeat, roomID: message.roomID, participantID: participantID)
            Task { [weak self] in
                try? await self?.connection?.send(reply)
            }
        case .hostHello:
            invite = message.invite
            if let invite, phase == .connecting {
                requestJoin(invite: invite)
            } else if message.invite == nil, phase == .connecting {
                statusText = "The host has no active invite yet."
            }
        case .networkConfiguration:
            guard let configuration = message.networkConfiguration else { return }
            startPeerIfNeeded(networkConfiguration: configuration)
        case .participantUpdated:
            guard let participant = message.participant, participant.id == participantID else { return }
            if let sessionQualityPreset = message.sessionQualityPreset {
                self.sessionQualityPreset = sessionQualityPreset
            }
            self.participant = participant
            switch participant.connectionState {
            case .waitingForApproval:
                phase = .waitingForApproval
                if waitingSince == nil { waitingSince = Date() }
                // Names what the host has actually been told, so a slow host is distinguishable from a
                // request that never arrived.
                statusText = "The host has been asked to let you in…"
            case .connected, .connecting:
                waitingSince = nil
                phase = .connected
                // Only the pre-video panels show this now, so it describes the wait rather than the
                // stream: once frames arrive the window shows the game itself.
                statusText = "Connected"
                startInputForwarding()
            case .disconnected:
                statusText = "Reconnecting…"
            case .failed:
                phase = .failed("The connection to the host failed.")
            }
        case .guestRejected:
            guard message.participantID == participantID else { return }
            phase = .failed(message.reason ?? "The host rejected the join request.")
        case .peerSignal:
            guard message.participantID == participantID, let signal = message.peerSignal else { return }
            guard let peer else { return }
            // Chained, not a free-standing Task per signal.
            //
            // The pump delivers signals in order, but an independent Task only runs to its first
            // suspension before yielding: the offer suspends inside `setRemoteDescription` and the ICE
            // candidate behind it then ran `addIceCandidate` against a peer connection with no remote
            // description, which libwebrtc rejects outright. The host sends candidates immediately
            // after `setLocalDescription`, so they are always in flight alongside the offer, and with
            // `gatherOnce` on both sides there is no re-gather to recover the dropped ones - it
            // presented as "guest connects, no video", intermittently and more often on fast links.
            //
            // Awaiting the previous link is safe because this is the MainActor: assignment order here
            // is arrival order. The host side never had this bug - `receiveSignal` is serialized by
            // the peer-controller actor.
            let previous = peerSignalChain
            peerSignalChain = Task { [weak self] in
                _ = await previous?.result
                do {
                    try await peer.handle(signal)
                } catch {
                    self?.handleConnectionFailure(error)
                }
            }
        case .inviteEnded:
            leave()
            statusText = "The host ended the session."
        case .participantRemoved:
            guard message.participantID == participantID else { return }
            leave()
            statusText = "The host removed you from the session."
        default:
            break
        }
    }

    /// The presets this guest may choose. The host's allowance is the ceiling, so anything more
    /// demanding is not offered rather than offered and silently ignored.
    var selectableQualityPresets: [OPNRemoteCoOpQualityPreset] {
        // The session default is the ceiling when the host has set no per-guest override, which is
        // the common case: offering everything there listed presets the host clamps straight back.
        guard let allowed = participant?.qualityPreset ?? sessionQualityPreset else {
            return OPNRemoteCoOpQualityPreset.allCases
        }
        return OPNRemoteCoOpQualityPreset.allCases.filter { $0.demand <= allowed.demand }
    }

    /// Asks the host to lower this guest's stream, or clears the request with nil.
    ///
    /// A request, not a setting: the guest's stream is spent from the host's uplink and one of the
    /// host's encoders, so the host's allowance always wins. The clamp is applied host-side, which is
    /// the only place it can be trusted.
    func requestQualityPreset(_ preset: OPNRemoteCoOpQualityPreset?) {
        guard phase == .connected else { return }
        let message = OPNRemoteCoOpWireMessage(kind: .guestQualityRequested, participantID: participantID, qualityPreset: preset)
        Task { [weak self] in
            try? await self?.connection?.send(message)
        }
    }

    private func requestJoin(invite: OPNRemoteCoOpInvite) {
        statusText = "Joining \(invite.title.isEmpty ? "the session" : invite.title)…"
        requestJoin(inviteToken: invite.token)
    }

    private func requestJoin(inviteToken: String) {
        if statusText.hasPrefix("Connecting") { statusText = "Joining the session…" }
        let message = OPNRemoteCoOpWireMessage(kind: .guestJoinRequested, participantID: participantID, inviteToken: inviteToken, displayName: displayName)
        Task {
            try? await connection?.send(message)
        }
    }

    private func startPeerIfNeeded(networkConfiguration: OPNRemoteCoOpNetworkConfiguration) {
        guard !peerStarted, peer == nil else { return }
        let peer = OPNRemoteCoOpNativeGuestPeer(participantID: participantID)
        do {
            try peer.start(networkConfiguration: networkConfiguration)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        peerStarted = true
        peer.onVideoTrack = { [weak self] track in
            Task { @MainActor in
                self?.videoTrack = track
            }
        }
        peer.onStats = { [weak self] stats in
            Task { @MainActor in
                self?.stats = stats
            }
        }
        peer.onSignal = { [weak self] signal in
            guard let self else { return }
            let message = OPNRemoteCoOpWireMessage(kind: .peerSignal, participantID: self.participantID, peerSignal: signal)
            do {
                try await self.sendSignaling(message)
            } catch {
                await self.handleConnectionFailure(error)
            }
        }
        self.peer = peer
    }

    private func sendSignaling(_ message: OPNRemoteCoOpWireMessage) async throws {
        try await connection?.send(message)
    }

    /// Approval is what makes the host open the input channel, so forwarding starts here rather
    /// than at join. Idempotent: reconnects and duplicate participant updates re-enter.
    private func startInputForwarding() {
        guard inputSender == nil, let peer else { return }
        let sender = OPNRemoteCoOpNativeGuestInputSender(
            participantID: participantID,
            send: { [weak peer] packet in peer?.sendInput(packet) },
            onControllerAvailability: { [weak self] available in
                Task { @MainActor in self?.hasController = available }
            }
        )
        sender.start()
        inputSender = sender
    }

    private func handleConnectionFailure(_ error: Error) {
        guard phase != .browsing else { return }
        // The pump has to be torn down here too, or the specific reason set below is immediately
        // overwritten. Reached mid-session, `connection?.close()` finishes the message stream, the
        // pump falls out, and `handleConnectionEnded` passes its `messageTask != nil` guard and calls
        // back in with `.closed` - replacing "the host rejected the join request" with "closed".
        // Same class of bug the connect path's comment records as fixed.
        messageTask?.cancel()
        messageTask = nil
        peerSignalChain?.cancel()
        peerSignalChain = nil
        inputSender?.stop()
        inputSender = nil
        peer?.close()
        peer = nil
        peerStarted = false
        connection?.close()
        connection = nil
        videoTrack = nil
        stats = nil
        participant = nil
        sessionQualityPreset = nil
        hasController = nil
        connectedHostName = nil
        waitingSince = nil
        phase = .failed(error.localizedDescription)
    }

    private func handleConnectionEnded() {
        // A cancelled pump is `leave()` tearing down on purpose; anything else means the socket
        // went away underneath an active session.
        guard phase != .browsing, messageTask != nil else { return }
        handleConnectionFailure(OPNRemoteCoOpNativeConnectionError.closed)
    }

    private static func loadOrCreateParticipantID() -> UUID {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: participantIDDefaultsKey), let id = UUID(uuidString: stored) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: participantIDDefaultsKey)
        return id
    }
}

private extension RemoteCoOpGuestViewModel.Phase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
