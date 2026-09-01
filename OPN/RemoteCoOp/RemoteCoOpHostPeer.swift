import Foundation

public enum OPNRemoteCoOpHostPeerError: LocalizedError, Equatable, Sendable {
    case peerNotFound
    case invalidSignal
    case negotiationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .peerNotFound: "Remote Co-Op peer was not found."
        case .invalidSignal: "Remote Co-Op peer signal is invalid."
        case .negotiationFailed(let message): message.isEmpty ? "Remote Co-Op WebRTC negotiation failed." : message
        }
    }
}

/// What a guest is actually being sent, as opposed to what was asked for.
///
/// A preset is a ceiling, not a promise. Three separate things hold a guest below it: the seat not
/// sending that much (the relay never upscales), aspect ratio (the preset is a bounding box, so a
/// 5120x2160 seat on the 4K preset gives 3840x1620), and libwebrtc downscaling because Low Latency
/// mode trades resolution to hold frame rate. The first two are geometry and the third is
/// `qualityLimitationReason`, so both the source size and the reason are carried here.
public struct OPNRemoteCoOpGuestDeliveryStats: Equatable, Sendable {
    public var frameWidth: Int
    public var frameHeight: Int
    public var encodedFramesPerSecond: Double
    /// `cpu`, `bandwidth`, `none`, or `unknown` before the encoder has reported.
    public var qualityLimitationReason: String
    /// What the relay hands the encoder. A delivered frame matching this means the preset is simply
    /// above the source.
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var targetPreset: OPNRemoteCoOpQualityPreset

    public init(frameWidth: Int = 0,
                frameHeight: Int = 0,
                encodedFramesPerSecond: Double = 0,
                qualityLimitationReason: String = "unknown",
                sourceWidth: Int = 0,
                sourceHeight: Int = 0,
                targetPreset: OPNRemoteCoOpQualityPreset = .p720f60) {
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.encodedFramesPerSecond = encodedFramesPerSecond
        self.qualityLimitationReason = qualityLimitationReason
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.targetPreset = targetPreset
    }

    public var isAtSource: Bool {
        frameWidth > 0 && frameWidth == sourceWidth && frameHeight == sourceHeight
    }

    /// Below the preset is not a fault when the source is the limit - the common case, and the one
    /// that reads as a bug.
    ///
    /// Either dimension reaching the box is enough, because the preset *is* a bounding box: a
    /// 5120x2160 seat pre-scaled for a 4K guest hands a 720p guest 3840x1620, whose encoder emits
    /// 1280x540 - exactly the preset's width, and short of its height only because the aspect ratio
    /// says so. Requiring both reported "network limited" for the whole session on every multi-guest
    /// room, which is where this branch's per-guest presets put everyone.
    public var isAtBest: Bool {
        guard frameWidth > 0 else { return false }
        return isAtSource || frameWidth >= targetPreset.width || frameHeight >= targetPreset.height
    }

    public var summary: String {
        guard frameWidth > 0, frameHeight > 0 else { return "measuring…" }
        let size = "\(frameWidth)x\(frameHeight)"
        let rate = encodedFramesPerSecond > 0 ? String(format: " @%.0f", encodedFramesPerSecond) : ""
        if isAtBest {
            return isAtSource && (frameWidth < targetPreset.width || frameHeight < targetPreset.height)
                ? "\(size)\(rate) · source limit"
                : "\(size)\(rate)"
        }
        switch qualityLimitationReason {
        case "bandwidth": return "\(size)\(rate) · network limited"
        case "cpu": return "\(size)\(rate) · encoder limited"
        case "none": return "\(size)\(rate) · ramping up"
        default: return "\(size)\(rate)"
        }
    }
}

public struct OPNRemoteCoOpHostPeerCallbacks: Sendable {
    public var sendSignal: @Sendable (OPNRemoteCoOpWirePeerSignal) async -> Void
    public var receiveInput: @Sendable (OPNRemoteCoOpInputPacket) async -> Void
    public var reportDelivery: @Sendable (OPNRemoteCoOpGuestDeliveryStats) async -> Void

    public init(sendSignal: @escaping @Sendable (OPNRemoteCoOpWirePeerSignal) async -> Void,
                receiveInput: @escaping @Sendable (OPNRemoteCoOpInputPacket) async -> Void,
                reportDelivery: @escaping @Sendable (OPNRemoteCoOpGuestDeliveryStats) async -> Void = { _ in }) {
        self.sendSignal = sendSignal
        self.receiveInput = receiveInput
        self.reportDelivery = reportDelivery
    }
}

public protocol OPNRemoteCoOpHostPeer: Sendable {
    var participantID: UUID { get }
    func start() async throws
    func apply(_ signal: OPNRemoteCoOpWirePeerSignal) async throws
    /// Retargets this guest's stream without renegotiating: resolution, frame rate and bitrate are
    /// sender-side in WebRTC, so rebuilding the peer would black the guest out for nothing.
    /// Returns false when it could not be applied - typically because the video track is not attached
    /// yet - so the caller knows to try again rather than recording a change that never happened.
    @discardableResult
    func updateQualityPreset(_ preset: OPNRemoteCoOpQualityPreset) async -> Bool
    func close() async
}

public extension OPNRemoteCoOpHostPeer {
    /// A peer that does not carry video has nothing to retarget, and nothing to retry either.
    @discardableResult
    func updateQualityPreset(_ preset: OPNRemoteCoOpQualityPreset) async -> Bool { true }
}

public protocol OPNRemoteCoOpHostPeerFactory: Sendable {
    func makePeer(participantID: UUID,
                  networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                  qualityPreset: OPNRemoteCoOpQualityPreset,
                  latencyMode: OPNRemoteCoOpLatencyMode,
                  callbacks: OPNRemoteCoOpHostPeerCallbacks) -> any OPNRemoteCoOpHostPeer
}

public enum OPNRemoteCoOpHostPeerInputDecoder {
    public static func decode(_ text: String, expectedParticipantID: UUID? = nil) -> OPNRemoteCoOpInputPacket? {
        decodePackets(Data(text.utf8), expectedParticipantID: expectedParticipantID).last
    }

    public static func decode(_ data: Data, expectedParticipantID: UUID? = nil) -> OPNRemoteCoOpInputPacket? {
        decodePackets(data, expectedParticipantID: expectedParticipantID).last
    }

    public static func decodePackets(_ text: String, expectedParticipantID: UUID? = nil) -> [OPNRemoteCoOpInputPacket] {
        decodePackets(Data(text.utf8), expectedParticipantID: expectedParticipantID)
    }

    public static func decodePackets(_ data: Data, expectedParticipantID: UUID? = nil) -> [OPNRemoteCoOpInputPacket] {
        // Native guests send the fixed-layout binary frame; browser guests send JSON. Checked first
        // because it is the high-rate case and the check is one byte.
        if let packet = OPNRemoteCoOpInputBinaryCodec.decode(data) {
            guard expectedParticipantID == nil || packet.participantID == expectedParticipantID else { return [] }
            return [packet]
        }
        guard let message = try? OPNRemoteCoOpWireCodec.decode(data), message.kind == .guestInput else { return [] }
        let packets = Self.packets(from: message)
        return packets.filter { packet in
            if let expectedParticipantID, packet.participantID != expectedParticipantID { return false }
            if let participantID = message.participantID, participantID != packet.participantID { return false }
            return true
        }.sorted { $0.sequenceNumber < $1.sequenceNumber }
    }

    private static func packets(from message: OPNRemoteCoOpWireMessage) -> [OPNRemoteCoOpInputPacket] {
        var packets = message.inputs ?? []
        if let input = message.input, !packets.contains(where: { $0.sequenceNumber == input.sequenceNumber && $0.participantID == input.participantID }) {
            packets.append(input)
        }
        return packets
    }
}

public actor OPNRemoteCoOpHostPeerController {
    private let signaling: any OPNRemoteCoOpSignalingSession
    private let coordinator: OPNRemoteCoOpHostCoordinator
    private let peerFactory: any OPNRemoteCoOpHostPeerFactory
    private let inputScheduler: OPNRemoteCoOpHostInputScheduler
    private let videoRelay: OPNRemoteCoOpHostVideoRelay?
    private let audioRelay: OPNRemoteCoOpHostAudioRelay?
    private var networkConfiguration: OPNRemoteCoOpNetworkConfiguration
    private var qualityPreset: OPNRemoteCoOpQualityPreset
    private var latencyMode: OPNRemoteCoOpLatencyMode
    private var peers: [UUID: any OPNRemoteCoOpHostPeer] = [:]
    /// What each live peer was last told to stream at, so `sync` can tell a real change from a
    /// participant record that merely got rewritten.
    private var appliedQualityPresets: [UUID: OPNRemoteCoOpQualityPreset] = [:]
    private var deliveryStatsByParticipant: [UUID: OPNRemoteCoOpGuestDeliveryStats] = [:]

    public init(signaling: any OPNRemoteCoOpSignalingSession,
                coordinator: OPNRemoteCoOpHostCoordinator,
                networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                qualityPreset: OPNRemoteCoOpQualityPreset = .p720f60,
                latencyMode: OPNRemoteCoOpLatencyMode = .quality,
                videoRelay: OPNRemoteCoOpHostVideoRelay? = nil,
                audioRelay: OPNRemoteCoOpHostAudioRelay? = nil,
                peerFactory: any OPNRemoteCoOpHostPeerFactory = OPNRemoteCoOpWebRTCHostPeerFactory(),
                forwardInput: @escaping @Sendable (UserInputEvent) async -> Void) {
        self.signaling = signaling
        self.coordinator = coordinator
        self.networkConfiguration = networkConfiguration
        self.qualityPreset = qualityPreset
        self.latencyMode = latencyMode
        self.videoRelay = videoRelay
        self.audioRelay = audioRelay
        self.peerFactory = peerFactory
        self.inputScheduler = OPNRemoteCoOpHostInputScheduler(coordinator: coordinator, latencyMode: latencyMode, forwardInput: forwardInput)
    }

    public func updateNetworkConfiguration(_ configuration: OPNRemoteCoOpNetworkConfiguration) {
        networkConfiguration = configuration
    }

    public func updateQualityPreset(_ preset: OPNRemoteCoOpQualityPreset) {
        qualityPreset = preset
    }

    public func updateLatencyMode(_ mode: OPNRemoteCoOpLatencyMode) async {
        latencyMode = mode
        await inputScheduler.updateLatencyMode(mode)
    }

    /// Driven from `sync` because every path that changes a participant already ends here, so a preset
    /// change has one place to be missed rather than several.
    public func sync(participants: [OPNRemoteCoOpParticipant]) async throws {
        // Eligibility is about the media session, so it turns on `connectionState` alone. Including
        // `inputEnabled` meant benching a guest with `setInputEnabled(false)` - whose whole purpose is
        // to keep them in the session without a pad - fell through the teardown loop below and closed
        // their peer, so they went black and silent and re-enabling had to renegotiate from scratch.
        // A guest who reconnects while benched was never given a peer at all. Input itself is gated
        // where it is routed, by `OPNRemoteCoOpInputRouter`.
        let eligibleParticipants = participants.filter { $0.connectionState == .connected }
        let eligibleIDs = Set(eligibleParticipants.map(\.id))
        for (participantID, peer) in peers where !eligibleIDs.contains(participantID) {
            peers[participantID] = nil
            appliedQualityPresets[participantID] = nil
            deliveryStatsByParticipant[participantID] = nil
            // Detached before the first suspension. `sync` runs on every signaling message, so a
            // guest rejoining inside the grace period drives a second `sync` that reaches
            // `startPeer` and upserts the new sinks - which this loop, resuming afterwards, then
            // removed by participant ID. The new peer stayed in `peers`, so nothing ever rebuilt
            // it: a negotiated guest receiving no video and no audio for the rest of the session.
            videoRelay?.remove(participantID: participantID)
            audioRelay?.remove(participantID: participantID)
            await inputScheduler.remove(participantID: participantID)
            await peer.close()
        }
        // One guest's failure must not cost the others theirs. `startPeer` used to throw straight out
        // of this loop, so a guest whose peer could not be built skipped every guest after them -
        // and because the order is stable, the same guest failed first on every later sync and the
        // rest never got an offer for the whole session.
        var firstFailure: Error?
        for participant in eligibleParticipants {
            let preset = participant.effectiveQualityPreset(sessionDefault: qualityPreset)
            guard let peer = peers[participant.id] else {
                do {
                    try await startPeer(for: participant)
                } catch {
                    firstFailure = firstFailure ?? error
                }
                continue
            }
            guard appliedQualityPresets[participant.id] != preset else { continue }
            // Recorded only on success. `startPeer` inserts into `peers` before awaiting `start()`, so
            // a reentrant `sync` - and this runs on every signaling message - can reach a peer whose
            // video track is not attached yet. Recording first left the guest on the old preset with
            // nothing ever retrying.
            if await peer.updateQualityPreset(preset) {
                appliedQualityPresets[participant.id] = preset
            }
        }
        // The relay's pre-scale belongs here, not at each call site. `sync` is the one function every
        // path that changes a participant already funnels through, and the hand-written copies missed
        // both the guest's own quality request and the approval that seats them - so a peer was
        // retargeted to a larger preset while the relay kept feeding it frames scaled for the old
        // ceiling, capping that guest with no way to recover.
        let ceiling = largestActiveQualityPreset(participants: participants)
        videoRelay?.setPreferredOutputSize(width: ceiling.width, height: ceiling.height)
        if let firstFailure { throw firstFailure }
    }

    /// One buffer feeds every guest's encoder, so the pre-scale must satisfy the most demanding guest.
    /// Anyone below it downscales again in their own encoder for free; scaling to the smallest would
    /// cap everyone at the worst connection in the room.
    public func largestActiveQualityPreset(participants: [OPNRemoteCoOpParticipant]) -> OPNRemoteCoOpQualityPreset {
        let active = participants
            .filter { $0.connectionState == .connected }
            .map { $0.effectiveQualityPreset(sessionDefault: qualityPreset) }
        guard !active.isEmpty else { return qualityPreset }
        return active.max { ($0.width * $0.height) < ($1.width * $1.height) } ?? qualityPreset
    }

    public func startPeer(for participant: OPNRemoteCoOpParticipant) async throws {
        guard participant.connectionState == .connected else { return }
        guard peers[participant.id] == nil else { return }
        let participantID = participant.id
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.peer.start", level: .info, message: "Starting Remote Co-Op host peer.", attributes: ["participantID": participantID.uuidString])
        let callbacks = OPNRemoteCoOpHostPeerCallbacks(
            sendSignal: { [signaling] signal in
                WebRTCMediaTelemetry.capture("webrtc.remote_coop.peer.signal.send", level: .info, message: "Sending Remote Co-Op peer signal.", attributes: ["participantID": participantID.uuidString, "kind": signal.kind.rawValue])
                await signaling.send(.peerSignal(participantID: participantID, signal: signal))
            },
            receiveInput: { [inputScheduler] packet in
                await inputScheduler.receive(packet, expectedParticipantID: participantID)
            },
            reportDelivery: { [weak self] stats in
                await self?.recordDelivery(stats, for: participantID)
            }
        )
        let preset = participant.effectiveQualityPreset(sessionDefault: qualityPreset)
        let peer = peerFactory.makePeer(participantID: participantID, networkConfiguration: networkConfiguration, qualityPreset: preset, latencyMode: latencyMode, callbacks: callbacks)
        peers[participantID] = peer
        appliedQualityPresets[participantID] = preset
        do {
            try await peer.start()
            WebRTCMediaTelemetry.capture("webrtc.remote_coop.peer.started", level: .info, message: "Remote Co-Op host peer started.", attributes: ["participantID": participantID.uuidString])
            if let sink = peer as? any OPNRemoteCoOpHostVideoSink { videoRelay?.upsert(sink) }
            if let sink = peer as? any OPNRemoteCoOpHostAudioSink { audioRelay?.upsert(sink) }
        } catch {
            WebRTCMediaTelemetry.capture("webrtc.remote_coop.peer.start.failed", level: .warning, message: error.localizedDescription, attributes: ["participantID": participantID.uuidString])
            peers[participantID] = nil
            appliedQualityPresets[participantID] = nil
            videoRelay?.remove(participantID: participantID)
            audioRelay?.remove(participantID: participantID)
            await peer.close()
            throw error
        }
    }

    private func recordDelivery(_ stats: OPNRemoteCoOpGuestDeliveryStats, for participantID: UUID) {
        guard peers[participantID] != nil else { return }
        deliveryStatsByParticipant[participantID] = stats
    }

    public func deliveryStats() -> [UUID: OPNRemoteCoOpGuestDeliveryStats] {
        deliveryStatsByParticipant
    }

    public func receiveSignal(participantID: UUID, signal: OPNRemoteCoOpWirePeerSignal) async throws {
        guard let peer = peers[participantID] else { throw OPNRemoteCoOpHostPeerError.peerNotFound }
        try await peer.apply(signal)
    }

    public func removePeer(participantID: UUID) async {
        appliedQualityPresets[participantID] = nil
        deliveryStatsByParticipant[participantID] = nil
        guard let peer = peers.removeValue(forKey: participantID) else { return }
        videoRelay?.remove(participantID: participantID)
        audioRelay?.remove(participantID: participantID)
        await inputScheduler.remove(participantID: participantID)
        await peer.close()
    }

    public func removeAll() async {
        let currentPeers = Array(peers.values)
        peers.removeAll()
        appliedQualityPresets.removeAll()
        deliveryStatsByParticipant.removeAll()
        await inputScheduler.removeAll()
        videoRelay?.removeAll()
        audioRelay?.removeAll()
        for peer in currentPeers { await peer.close() }
    }
}

/// Orders guest gamepad packets and hands each one straight on. Nothing is ever held.
///
/// This buffered analog-only packets on a 4 ms timer until it was measured: the delay fell on stick
/// movement (buttons were already exempt), and `Task.sleep` overshoot made it ~6.5 ms - the whole
/// end-to-end budget, spent before the packet reached the seat. `NativeNVSTInputDispatcher` already
/// coalesces bursts a layer down without delaying packets that arrive on an idle queue.
///
/// The ordering is not optional: the channel is unordered with no retransmits, so a stale packet must
/// not overwrite a newer state.
private actor OPNRemoteCoOpHostInputScheduler {
    private static let telemetryInterval: UInt64 = 600

    private let coordinator: OPNRemoteCoOpHostCoordinator
    private let forwardInput: @Sendable (UserInputEvent) async -> Void
    private var latencyMode: OPNRemoteCoOpLatencyMode
    private var latestRoutedInputs: [UUID: OPNRemoteCoOpInputPacket] = [:]
    private var routedInputCount: UInt64 = 0
    private var supersededInputCount: UInt64 = 0

    init(coordinator: OPNRemoteCoOpHostCoordinator,
         latencyMode: OPNRemoteCoOpLatencyMode,
         forwardInput: @escaping @Sendable (UserInputEvent) async -> Void) {
        self.coordinator = coordinator
        self.latencyMode = latencyMode
        self.forwardInput = forwardInput
    }

    func updateLatencyMode(_ mode: OPNRemoteCoOpLatencyMode) {
        latencyMode = mode
    }

    func receive(_ packet: OPNRemoteCoOpInputPacket, expectedParticipantID: UUID) async {
        guard packet.participantID == expectedParticipantID else { return }
        if let routed = latestRoutedInputs[packet.participantID], routed.sequenceNumber >= packet.sequenceNumber {
            supersededInputCount &+= 1
            return
        }
        // Claimed before the first suspension. Every data-channel message arrives on its own
        // unstructured task, so two packets could both pass the check above and then resume from
        // `coordinator.handle` in either order - which is exactly the stale-overwrites-newer this
        // scheduler exists to prevent.
        latestRoutedInputs[packet.participantID] = packet
        await route(packet, receivedAtNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    func remove(participantID: UUID) {
        latestRoutedInputs[participantID] = nil
    }

    func removeAll() {
        latestRoutedInputs.removeAll()
    }

    private func route(_ packet: OPNRemoteCoOpInputPacket, receivedAtNanoseconds: UInt64) async {
        let routedEvents = await coordinator.handle(.guestInput(packet))
        // A newer packet won the race while this one was in the coordinator, so forwarding it now
        // would put the older state on the wire last.
        let claimedSequenceNumber = latestRoutedInputs[packet.participantID]?.sequenceNumber ?? packet.sequenceNumber
        guard claimedSequenceNumber <= packet.sequenceNumber else {
            supersededInputCount &+= 1
            return
        }
        for routedEvent in routedEvents { await forwardInput(routedEvent) }
        routedInputCount &+= 1
        guard routedInputCount.isMultiple(of: Self.telemetryInterval) else { return }
        let routedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.input.routed", level: .debug, message: "Remote Co-Op guest input routed.", attributes: [
            // Host-local only: the guest's send clock is another machine's uptime.
            "hostRouteMicroseconds": String(Self.microsecondsBetween(receivedAtNanoseconds, routedAtNanoseconds)),
            "latencyMode": latencyMode.rawValue,
            "participantID": packet.participantID.uuidString,
            "routedInputs": String(routedInputCount),
            "sequenceNumber": String(packet.sequenceNumber),
            "supersededInputs": String(supersededInputCount)
        ])
    }

    private static func microsecondsBetween(_ startNanoseconds: UInt64, _ endNanoseconds: UInt64) -> Int {
        guard endNanoseconds >= startNanoseconds else { return 0 }
        return Int((endNanoseconds - startNanoseconds) / 1_000)
    }
}
