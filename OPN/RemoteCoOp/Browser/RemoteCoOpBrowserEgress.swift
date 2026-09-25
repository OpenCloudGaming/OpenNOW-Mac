import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import HTTP3
import QUIC
import QUICCrypto

/// The host session's side of the browser egress.
///
/// The egress owns QUIC, TLS and the media framing; it deliberately knows nothing about invites,
/// approval or player slots. Everything that crosses into host policy - who a guest is, whether input
/// is allowed, what happens when they leave - goes through this seam, exactly as the native transport
/// consults the same host session.
public protocol OPNRemoteCoOpBrowserEgressHost: Sendable {
    /// Verifies a guest's invite token and registers them. Throws when the token is invalid, expired,
    /// or no slot is free; the message is shown to the guest. On a reconnect the guest presents the
    /// participant ID and reconnect token it was issued, so it reclaims its slot instead of arriving
    /// as a stranger.
    func browserGuestDidRequestJoin(token: String,
                                    displayName: String,
                                    participantID: UUID?,
                                    reconnectToken: String?) async throws -> OPNRemoteCoOpParticipant
    /// Routes one guest input packet into the same input scheduler the native guests use.
    func browserGuestDidSendInput(_ packet: OPNRemoteCoOpInputPacket) async
    /// The guest's session ended. Returns the neutral input the host must deliver, exactly as the
    /// native and WebSocket guests get when their socket drops.
    func browserGuestDidDisconnect(participantID: UUID) async -> [UserInputEvent]
}

/// Host side of the browser Remote Co-Op egress.
///
/// A browser guest cannot take the native path: it cannot open a raw UDP flow and it cannot decode the
/// seat's HEVC. So this runs a WebTransport server on its own UDP port that serves a WebCodecs guest,
/// transcoding each decoded frame to H.264 for the browser while the native broadcaster keeps sending
/// the source stream to native guests untouched.
///
/// One port serves every browser guest. Media goes out as datagrams - the same compressed-video and
/// PCM framings the native transport uses - and a per-guest H.264 encode is created only while that
/// guest is connected.
public final class RemoteCoOpBrowserEgress: @unchecked Sendable {
    public static let defaultPort: UInt16 = 32190

    public enum EgressError: LocalizedError {
        case notRunning

        public var errorDescription: String? {
            switch self {
            case .notRunning: "The browser Co-Op egress is not running."
            }
        }
    }

    public var onState: (@Sendable (String) -> Void)?
    /// Called after a guest joins or leaves so the host can refresh its participant list and re-announce
    /// the gamepad topology.
    public var onParticipantsChanged: (@Sendable () async -> Void)?
    /// Called once when a guest's media starts, so the host can pull a keyframe promptly rather than
    /// waiting for the periodic one.
    public var onGuestJoined: (@Sendable () -> Void)?
    /// Carries the neutral pad state the host session returns when a guest disconnects, so a button the
    /// guest was holding does not stay pressed in the game.
    public var onNeutralInput: (@Sendable ([UserInputEvent]) async -> Void)?

    private let host: OPNRemoteCoOpBrowserEgressHost
    private let lock = NSLock()
    private var server: WebTransportServer?
    private var sessionTask: Task<Void, Never>?
    private var sessions: [UInt64: RemoteCoOpBrowserSession] = [:]
    private var isRunning = false

    public private(set) var boundPort: UInt16 = 0
    public private(set) var certificateSHA256 = Data()
    public private(set) var advertisedHost = ""

    public init(host: OPNRemoteCoOpBrowserEgressHost) {
        self.host = host
    }

    public var hasGuests: Bool {
        lock.withLock { !sessions.isEmpty }
    }

    /// The endpoint information the browser page needs, or nil before the listener is bound.
    public var webTransportInfo: OPNRemoteCoOpBrowserWebTransportInfo? {
        lock.withLock {
            guard isRunning, boundPort != 0, !advertisedHost.isEmpty else { return nil }
            return OPNRemoteCoOpBrowserWebTransportInfo(host: advertisedHost,
                                                        port: boundPort,
                                                        path: RemoteCoOpBrowserProtocol.mediaPath,
                                                        certificateHash: certificateSHA256.base64EncodedString())
        }
    }

    /// Binds the WebTransport listener and returns once it is accepting.
    public func start(host advertisedHost: String, port: UInt16 = RemoteCoOpBrowserEgress.defaultPort) async throws {
        guard !lock.withLock({ isRunning }) else { return }

        let certificate = try OPNRemoteCoOpTLSIdentity.webTransportCertificate(for: advertisedHost)
        var tls = try TLSConfiguration.server(certificatePath: certificate.certificatePath,
                                              privateKeyPath: certificate.privateKeyPath,
                                              alpnProtocols: ["h3"])
        // The guest proves its identity with the invite token, not a client certificate; requiring one
        // would put a second, unrequested certificate prompt in front of every browser.
        tls.verifyPeer = false
        let serverTLS = tls
        var quic = QUICConfiguration.development { TLS13Handler(configuration: serverTLS) }
        quic.alpn = ["h3"]
        quic.maxIdleTimeout = .seconds(30)
        quic.initialMaxStreamsBidi = 32
        quic.initialMaxStreamsUni = 32
        quic.enableDatagrams = true
        quic.maxDatagramFrameSize = 65_535

        let server = try await WebTransportServer.listen(
            host: "0.0.0.0",
            port: port,
            configuration: WebTransportConfiguration(quic: quic, maxSessions: 4),
            serverOptions: WebTransportServer.ServerOptions(maxConnections: 16,
                                                            allowedPaths: [RemoteCoOpBrowserProtocol.mediaPath])
        )
        await server.onRequest { context in
            try await context.respond(status: 200,
                                      headers: [("content-type", "text/plain")],
                                      Data("OpenNOW Remote Co-Op WebTransport".utf8))
        }

        lock.withLock {
            self.server = server
            boundPort = port
            certificateSHA256 = certificate.sha256
            self.advertisedHost = advertisedHost
            isRunning = true
        }
        sessionTask = Task { [weak self] in
            for await session in await server.incomingSessions {
                guard let self else { return }
                await self.accept(session)
            }
        }
        onState?("Browser Co-Op on UDP \(port).")
    }

    public func stop() async {
        let (server, active): (WebTransportServer?, [RemoteCoOpBrowserSession]) = lock.withLock {
            let server = self.server
            let active = Array(sessions.values)
            sessions.removeAll()
            self.server = nil
            isRunning = false
            sessionTask?.cancel()
            sessionTask = nil
            return (server, active)
        }
        for session in active { session.close() }
        await server?.stop(gracePeriod: .seconds(1))
        lock.withLock {
            boundPort = 0
            certificateSHA256 = Data()
        }
    }

    /// Tells the matching browser guest where it is in the approval flow. Called when the host approves
    /// or benches a participant, or when the participant record otherwise changes.
    public func update(_ participant: OPNRemoteCoOpParticipant) {
        let session = lock.withLock { sessions.values.first { $0.matches(participantID: participant.id) } }
        session?.apply(participant)
    }

    /// Ends the matching browser guest's session. Called when the host removes a participant, so an
    /// evicted guest's transcode does not keep running against a session nobody owns.
    public func remove(participantID: UUID) {
        let session = lock.withLock { sessions.values.first { $0.matches(participantID: participantID) } }
        session?.close()
    }

    /// Forwards one decoded seat frame. The browser guest's own H.264 encode is created on first use,
    /// so a browser guest costs nothing until its media actually starts. `isKeyframe` carries the
    /// source's keyframe boundary through so the transcode can emit an IDR the guest can start from.
    public func forward(video pixelBuffer: CVPixelBuffer, presentationTime: CMTime, isKeyframe: Bool = false) {
        let active = snapshotSessions()
        guard !active.isEmpty else { return }
        for session in active {
            session.encodeAndSend(pixelBuffer: pixelBuffer, presentationTime: presentationTime, isKeyframe: isKeyframe)
        }
    }

    /// Forwards one game-audio callback as PCM, the same conversion and chunking the native guests get.
    public func forwardAudio(audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        guard let audioBufferList else { return }
        let active = snapshotSessions()
        guard !active.isEmpty else { return }
        for session in active {
            session.sendAudio(audioBufferList: audioBufferList, frameCount: frameCount, sampleRate: sampleRate, channels: channels)
        }
    }

    private func accept(_ session: WebTransportSession) async {
        let sessionID = await session.sessionID
        let browserSession = RemoteCoOpBrowserSession(
            sessionID: sessionID,
            transport: session,
            host: host,
            log: { [weak self] message in self?.onState?("Browser guest: \(message)") },
            onParticipantsChanged: { [weak self] in await self?.onParticipantsChanged?() },
            onNeutralInput: { [weak self] events in await self?.onNeutralInput?(events) },
            onGuestJoined: { [weak self] in self?.onGuestJoined?() },
            onClosed: { [weak self] id in self?.remove(sessionID: id) }
        )
        lock.withLock { sessions[sessionID] = browserSession }
        browserSession.start()
        onState?("A browser guest connected.")
    }

    private func remove(sessionID: UInt64) {
        lock.withLock { sessions[sessionID] = nil }
        onState?("A browser guest disconnected.")
    }

    private func snapshotSessions() -> [RemoteCoOpBrowserSession] {
        lock.withLock { Array(sessions.values) }
    }
}

/// One browser guest's slice of the egress: its control stream, its own H.264 encode, and its share of
/// the media datagrams.
final class RemoteCoOpBrowserSession: @unchecked Sendable {
    private static let frameRate = 60

    let sessionID: UInt64

    private let transport: WebTransportSession
    private let host: OPNRemoteCoOpBrowserEgressHost
    private let log: @Sendable (String) -> Void
    private let onParticipantsChanged: @Sendable () async -> Void
    private let onNeutralInput: @Sendable ([UserInputEvent]) async -> Void
    private let onGuestJoined: @Sendable () -> Void
    private let onClosed: @Sendable (UInt64) -> Void

    private let lock = NSLock()
    private var participant: OPNRemoteCoOpParticipant?
    private var controlStream: WebTransportStream?
    /// The guest's second bidirectional stream, carrying video and audio as whole length-prefixed
    /// frames. A reliable, ordered stream is used deliberately: an unreliable datagram channel kept
    /// losing a fragment of the large keyframe frames, so a guest could never start.
    private var mediaStream: WebTransportStream?
    private var controlBuffer = Data()
    private var isClosed = false
    private var isMediaEnabled = false
    private var hasAnnouncedMedia = false

    // Touched only by the host's single video-forwarding thread.
    private var scaler: RemoteCoOpBrowserVideoScaler?
    private var transcoder: RemoteCoOpBrowserVideoTranscoder?
    private var hasSentConfig = false
    private var hasLoggedScaleFailure = false
    private var hasLoggedFirstUnit = false
    private var lastEncodeNanoseconds: UInt64 = 0

    /// The browser guest is capped at 60 fps. The seat can stream at 120, and scaling a 5K frame twice
    /// as often as the guest can show it wastes the host's decode thread for no visible gain.
    private static let minimumEncodeIntervalNanoseconds: UInt64 = 16_000_000

    /// A media frame on the reliable stream: kind, flags, a nanosecond timestamp, and the length.
    private enum MediaKind: UInt8 {
        case video = 1
        case audio = 2
    }

    private static let mediaHeaderBytes = 14

    init(sessionID: UInt64,
         transport: WebTransportSession,
         host: OPNRemoteCoOpBrowserEgressHost,
         log: @escaping @Sendable (String) -> Void,
         onParticipantsChanged: @escaping @Sendable () async -> Void,
         onNeutralInput: @escaping @Sendable ([UserInputEvent]) async -> Void,
         onGuestJoined: @escaping @Sendable () -> Void,
         onClosed: @escaping @Sendable (UInt64) -> Void) {
        self.sessionID = sessionID
        self.transport = transport
        self.host = host
        self.log = log
        self.onParticipantsChanged = onParticipantsChanged
        self.onNeutralInput = onNeutralInput
        self.onGuestJoined = onGuestJoined
        self.onClosed = onClosed
    }

    func start() {
        Task { [weak self] in await self?.pumpControlStreams() }
        Task { [weak self] in await self?.pumpInput() }
        Task { [weak self] in await self?.watchForClosure() }
    }

    func matches(participantID: UUID) -> Bool {
        lock.withLock { participant?.id == participantID }
    }

    /// Applies a new participant record, pushing the state to the guest and gating media on it.
    func apply(_ participant: OPNRemoteCoOpParticipant) {
        let previousMediaState = lock.withLock { isMediaEnabled }
        let stream = lock.withLock { () -> WebTransportStream? in
            guard self.participant?.id == participant.id, self.participant != participant else { return nil }
            self.participant = participant
            isMediaEnabled = participant.connectionState == .connected && participant.inputEnabled
            return controlStream
        }
        announceMediaIfNeeded()
        if lock.withLock({ isMediaEnabled }) != previousMediaState {
            log("media \(lock.withLock { isMediaEnabled } ? "enabled" : "disabled") state=\(participant.connectionState.rawValue) inputEnabled=\(participant.inputEnabled)")
        }
        guard let stream else { return }
        Task { try? await stream.write(RemoteCoOpBrowserControlCodec.encode(.state(participant))) }
    }

    /// Fires once when the guest's media first becomes enabled, so the host can pull a keyframe now
    /// rather than waiting for the periodic one.
    private func announceMediaIfNeeded() {
        let shouldAnnounce = lock.withLock { () -> Bool in
            guard isMediaEnabled, !hasAnnouncedMedia else { return false }
            hasAnnouncedMedia = true
            return true
        }
        if shouldAnnounce { onGuestJoined() }
    }

    func close() {
        let (participantID, didClose): (UUID?, Bool) = lock.withLock {
            guard !isClosed else { return (nil, false) }
            isClosed = true
            return (participant?.id, true)
        }
        guard didClose else { return }
        onClosed(sessionID)
        guard let participantID else { return }
        Task { [host, onNeutralInput, onParticipantsChanged] in
            let neutral = await host.browserGuestDidDisconnect(participantID: participantID)
            if !neutral.isEmpty { await onNeutralInput(neutral) }
            await onParticipantsChanged()
        }
    }

    // MARK: - Control

    private func pumpControlStreams() async {
        for await stream in await transport.incomingBidirectionalStreams {
            // The guest opens the control stream first (and writes its join on it), then the media
            // stream. Order is what tells them apart.
            let isControl = lock.withLock { () -> Bool in
                if controlStream == nil {
                    controlStream = stream
                    return true
                }
                if mediaStream == nil {
                    mediaStream = stream
                    return false
                }
                return false
            }
            if isControl {
                // Detached: the read loop runs for the life of the session, so awaiting it here would
                // stop this loop from ever receiving the guest's media stream.
                Task { [weak self] in await self?.readControl(stream) }
            }
        }
    }

    private func readControl(_ stream: WebTransportStream) async {
        while true {
            let data: Data
            do {
                data = try await stream.read()
            } catch {
                return
            }
            if data.isEmpty { return }
            let messages = lock.withLock { () -> [RemoteCoOpBrowserControlMessage] in
                controlBuffer.append(data)
                return RemoteCoOpBrowserControlCodec.decode(from: &controlBuffer)
            }
            for message in messages { await handle(message) }
        }
    }

    private func handle(_ message: RemoteCoOpBrowserControlMessage) async {
        guard message.kind == .join, let token = message.token, !token.isEmpty else { return }
        do {
            let participant = try await host.browserGuestDidRequestJoin(token: token,
                                                                        displayName: message.displayName ?? "Guest",
                                                                        participantID: message.participantID,
                                                                        reconnectToken: message.reconnectToken)
            let stream = lock.withLock { () -> WebTransportStream? in
                self.participant = participant
                isMediaEnabled = participant.connectionState == .connected && participant.inputEnabled
                return controlStream
            }
            announceMediaIfNeeded()
            if lock.withLock({ isMediaEnabled }) { log("media enabled at join") }
            if let stream {
                try? await stream.write(RemoteCoOpBrowserControlCodec.encode(.joined(participant)))
            }
            log("joined displayName=\(participant.displayName) state=\(participant.connectionState.rawValue) inputEnabled=\(participant.inputEnabled)")
            await onParticipantsChanged()
        } catch {
            guard let stream = lock.withLock({ controlStream }) else { return }
            try? await stream.write(RemoteCoOpBrowserControlCodec.encode(.error(error.localizedDescription)))
        }
    }

    // MARK: - Input

    private func pumpInput() async {
        for await datagram in await transport.incomingDatagrams {
            await handleInput(datagram)
        }
    }

    private func handleInput(_ datagram: Data) async {
        let participantID: UUID? = lock.withLock {
            isClosed ? nil : participant?.id
        }
        guard let participantID, let decoded = OPNRemoteCoOpInputBinaryCodec.decode(datagram) else { return }
        // Re-stamped with the participant the host actually approved: a guest can only ever move its own
        // pad, whatever the frame claims.
        let routed = OPNRemoteCoOpInputPacket(participantID: participantID,
                                              sequenceNumber: decoded.sequenceNumber,
                                              buttons: decoded.buttons,
                                              leftTrigger: decoded.leftTrigger,
                                              rightTrigger: decoded.rightTrigger,
                                              leftStickX: decoded.leftStickX,
                                              leftStickY: decoded.leftStickY,
                                              rightStickX: decoded.rightStickX,
                                              rightStickY: decoded.rightStickY,
                                              sentAtNanoseconds: decoded.sentAtNanoseconds)
        await host.browserGuestDidSendInput(routed)
    }

    // MARK: - Video

    func encodeAndSend(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, isKeyframe: Bool) {
        let isActive = lock.withLock { isMediaEnabled && !isClosed }
        guard isActive else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastEncodeNanoseconds >= Self.minimumEncodeIntervalNanoseconds else { return }
        lastEncodeNanoseconds = now

        if scaler == nil {
            scaler = RemoteCoOpBrowserVideoScaler(sourceWidth: CVPixelBufferGetWidth(pixelBuffer),
                                                  sourceHeight: CVPixelBufferGetHeight(pixelBuffer))
            if let scaler {
                log("scaling \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) -> \(scaler.targetWidth)x\(scaler.targetHeight)")
            }
        }
        guard let scaler else { return }

        if lock.withLock({ transcoder }) == nil {
            do {
                let created = try RemoteCoOpBrowserVideoTranscoder(width: scaler.targetWidth,
                                                                   height: scaler.targetHeight,
                                                                   fps: Self.frameRate,
                                                                   averageBitrate: Self.bitrate(for: scaler))
                created.onAccessUnit = { [weak self] unit in self?.sendAccessUnit(unit) }
                lock.withLock { transcoder = created }
                log("transcoder ready \(scaler.targetWidth)x\(scaler.targetHeight) @ \(Self.bitrate(for: scaler))bps")
            } catch {
                log("transcoder creation failed: \(error.localizedDescription)")
                return
            }
        }
        guard let transcoder = lock.withLock({ self.transcoder }) else { return }
        guard let scaled = scaler.scale(pixelBuffer) else {
            if !hasLoggedScaleFailure {
                hasLoggedScaleFailure = true
                log("scaler produced no frame (source \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) format \(CVPixelBufferGetPixelFormatType(pixelBuffer)))")
            }
            return
        }
        try? transcoder.encode(scaled, presentationTime: presentationTime, forceKeyframe: isKeyframe)
    }

    private func sendAccessUnit(_ unit: RemoteCoOpBrowserVideoTranscoder.AccessUnit) {
        let transcoder: RemoteCoOpBrowserVideoTranscoder? = lock.withLock { self.transcoder }
        let shouldSendConfig = lock.withLock { () -> Bool in
            guard isMediaEnabled, !isClosed, !hasSentConfig else { return false }
            return true
        }
        guard let transcoder, let avcC = transcoder.avcC else {
            // The first callback is the keyframe that carries the parameter sets; without them the
            // guest cannot configure a decoder, so there is nothing to send yet.
            let stillActive = lock.withLock { isMediaEnabled && !isClosed }
            guard stillActive else { return }
            return
        }
        if shouldSendConfig {
            lock.withLock { hasSentConfig = true }
            sendConfig(width: transcoder.width, height: transcoder.height, avcC: avcC)
            log("sent decoder config (\(avcC.count) bytes)")
        }
        if !hasLoggedFirstUnit {
            hasLoggedFirstUnit = true
            log("sending video \(transcoder.width)x\(transcoder.height) keyframe=\(unit.isKeyframe)")
        } else if unit.isKeyframe {
            log("keyframe access unit sent")
        }

        let timestamp = unit.presentationTime.isNumeric
            ? UInt64(max(0, unit.presentationTime.seconds) * 1_000_000_000)
            : DispatchTime.now().uptimeNanoseconds
        writeMediaFrame(kind: .video,
                        flags: unit.isKeyframe ? 0x01 : 0x00,
                        timestampNanoseconds: timestamp,
                        payload: unit.data)
    }

    /// Writes one media frame - a whole access unit or audio buffer - to the guest's reliable stream.
    private func writeMediaFrame(kind: MediaKind, flags: UInt8, timestampNanoseconds: UInt64, payload: Data) {
        let stream = lock.withLock { mediaStream }
        guard let stream else { return }
        var frame = Data(capacity: Self.mediaHeaderBytes + payload.count)
        frame.append(kind.rawValue)
        frame.append(flags)
        Self.appendUInt64(timestampNanoseconds, to: &frame)
        Self.appendUInt32(UInt32(clamping: payload.count), to: &frame)
        frame.append(payload)
        Task { try? await stream.write(frame) }
    }

    private static func appendUInt32(_ value: UInt32, to bytes: inout Data) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    private static func appendUInt64(_ value: UInt64, to bytes: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    /// Delivers the decoder configuration on the control stream, not a datagram: it must arrive once
    /// and in order, and the control stream already has those guarantees. The page buffers raw video
    /// until this lands, so a datagram that raced it is simply dropped and recovered by the next
    /// keyframe.
    private func sendConfig(width: Int, height: Int, avcC: Data) {
        let stream = lock.withLock { controlStream }
        guard let stream else { return }
        let message = RemoteCoOpBrowserControlCodec.encode(.config(avcC: avcC, width: width, height: height))
        Task { try? await stream.write(message) }
    }

    private static func bitrate(for scaler: RemoteCoOpBrowserVideoScaler) -> Int {
        let pixels = Double(scaler.targetWidth * scaler.targetHeight)
        return Int(min(20_000_000, max(2_000_000, pixels * Double(frameRate) * 0.07)))
    }

    // MARK: - Audio

    func sendAudio(audioBufferList: UnsafeRawPointer, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        guard lock.withLock({ isMediaEnabled && !isClosed }) else { return }

        let list = audioBufferList.assumingMemoryBound(to: AudioBufferList.self)
        guard let raw = RemoteCoOpNativeAudioConversion.rawInt16Copy(from: list),
              let frame = RemoteCoOpNativeAudioConversion.audioFrame(from: raw, frameCount: frameCount, sampleRate: sampleRate, channels: channels) else { return }
        writeMediaFrame(kind: .audio,
                        flags: 0,
                        timestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
                        payload: frame.samples)
    }

    // MARK: - Lifecycle

    /// A WebTransport session does not hand over a "closed" event, so its own drained state is polled.
    /// Anything else leaves a dead guest's encode running against a session nobody is reading.
    private func watchForClosure() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            let isClosedTransport = await transport.isClosed
            let isDraining = await transport.isDraining
            let isDone = isClosedTransport || isDraining
            let alreadyClosed = lock.withLock { isClosed }
            if alreadyClosed { return }
            guard !isDone else {
                close()
                return
            }
        }
    }
}
