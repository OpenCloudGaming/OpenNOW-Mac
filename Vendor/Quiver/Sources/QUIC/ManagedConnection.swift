/// QUIC Managed Connection
///
/// ## ECN Integration
///
/// `processDatagram` and `processIncomingPacket` accept an optional
/// `ECNCodepoint` from the socket layer (`IncomingPacket.ecnCodepoint`).
/// After each packet is decrypted and its encryption level is known,
/// the codepoint is fed into `handler.ecnManager.recordIncoming(_:level:)`
/// for ACK-frame ECN count reporting (RFC 9000 §13.4).
///
/// High-level connection wrapper that orchestrates handshake, packet processing,
/// and stream management. Implements QUICConnectionProtocol for public API.

import Foundation
import Logging
import Synchronization
import QUICCore
import QUICCrypto
import QUICConnection
import QUICStream
import QUICRecovery

// MARK: - Managed Connection


/// High-level managed connection for QUIC
///
/// Wraps QUICConnectionHandler and provides:
/// - Handshake state machine
/// - Packet encryption/decryption via PacketProcessor
/// - TLS 1.3 integration
/// - Stream management via QUICConnectionProtocol
/// - Anti-amplification limit enforcement (RFC 9000 Section 8.1)
public final class ManagedConnection: Sendable {

    static let logger = QuiverLogging.logger(label: "quic.connection.managed")

    // MARK: - Properties

    /// Connection handler (low-level orchestration)
    let handler: QUICConnectionHandler

    /// Packet processor (encryption/decryption)
    let packetProcessor: PacketProcessor

    /// TLS provider
    let tlsProvider: any TLS13Provider

    /// Anti-amplification limiter (RFC 9000 Section 8.1)
    /// Servers must not send more than 3x bytes received until address is validated
    let amplificationLimiter: AntiAmplificationLimiter

    /// Path validation manager for connection migration (RFC 9000 Section 9.3)
    let pathValidationManager: PathValidationManager

    /// Connection ID manager for connection migration (RFC 9000 Section 9.5)
    let connectionIDManager: ConnectionIDManager

    /// Internal state
    let state: Mutex<ManagedConnectionState>

    /// Serializes concurrent calls to `generateOutboundPackets()` (RC1 fix).
    /// Both `outboundSendLoop` and `packetReceiveLoop` may call it concurrently;
    /// this lock ensures only one executes at a time.
    private let packetGenerationLock = Mutex(())

    /// State for stream read continuations
    struct StreamContinuationsState: Sendable {
        var continuations: [UInt64: CheckedContinuation<Data, any Error>] = [:]
        /// Buffer for stream data received before read() is called
        var pendingData: [UInt64: [Data]] = [:]
        var isShutdown: Bool = false
        /// Streams whose receive side is complete (FIN received, all data read).
        /// Reads on these streams return empty `Data` to signal end-of-stream.
        var finishedStreams: Set<UInt64> = []
    }

    /// Stream continuations for async stream API
    let streamContinuationsState: Mutex<StreamContinuationsState>

    /// State for incoming stream AsyncStream (lazy initialization pattern)
    struct IncomingStreamState: Sendable {
        var continuation: AsyncStream<any QUICStreamProtocol>.Continuation?
        var stream: AsyncStream<any QUICStreamProtocol>?
        var isShutdown: Bool = false
        /// Buffer for streams that arrive before incomingStreams is accessed
        var pendingStreams: [any QUICStreamProtocol] = []
    }
    let incomingStreamState: Mutex<IncomingStreamState>

    /// State for incoming datagram AsyncStream (RFC 9221)
    struct IncomingDatagramState: Sendable {
        var continuation: AsyncStream<Data>.Continuation?
        var stream: AsyncStream<Data>?
        var isShutdown: Bool = false
        /// Buffer for datagrams that arrive before incomingDatagrams is accessed
        var pendingDatagrams: [Data] = []
    }
    let incomingDatagramState: Mutex<IncomingDatagramState>

    /// State for session ticket stream (lazy initialization pattern)
    struct SessionTicketState: Sendable {
        var continuation: AsyncStream<NewSessionTicketInfo>.Continuation?
        var stream: AsyncStream<NewSessionTicketInfo>?
        var isShutdown: Bool = false
        /// Buffer for tickets that arrive before sessionTickets is accessed
        var pendingTickets: [NewSessionTicketInfo] = []
    }
    let sessionTicketState: Mutex<SessionTicketState>

    /// Original connection ID (for Initial key derivation)
    /// This is the DCID from the first client Initial packet
    let originalConnectionID: ConnectionID

    /// Transport parameters (stored for TLS)
    let transportParameters: TransportParameters

    /// Local address
    public let localAddress: SocketAddress?

    /// Remote address
    public let remoteAddress: SocketAddress

    /// Closure called when a new connection ID is received
    /// Used to register the CID with the ConnectionRouter
    let onNewConnectionID: Mutex<(@Sendable (ConnectionID) -> Void)?>

    // MARK: - Initialization

    /// Creates a new managed connection
    /// - Parameters:
    ///   - role: Connection role (client or server)
    ///   - version: QUIC version
    ///   - sourceConnectionID: Local connection ID
    ///   - destinationConnectionID: Remote connection ID
    ///   - originalConnectionID: Original DCID for Initial key derivation (defaults to destinationConnectionID)
    ///   - transportParameters: Transport parameters to use
    ///   - tlsProvider: TLS 1.3 provider
    ///   - localAddress: Local socket address (optional)
    ///   - remoteAddress: Remote socket address
    public convenience init(
        role: ConnectionRole,
        version: QUICVersion,
        sourceConnectionID: ConnectionID,
        destinationConnectionID: ConnectionID,
        originalConnectionID: ConnectionID? = nil,
        transportParameters: TransportParameters,
        tlsProvider: any TLS13Provider,
        localAddress: SocketAddress? = nil,
        remoteAddress: SocketAddress,
        maxDatagramSize: Int = ProtocolLimits.minimumMaximumDatagramSize
    ) {
        self.init(
            role: role,
            version: version,
            sourceConnectionID: sourceConnectionID,
            destinationConnectionID: destinationConnectionID,
            originalConnectionID: originalConnectionID,
            transportParameters: transportParameters,
            tlsProvider: tlsProvider,
            congestionControllerFactory: NewRenoFactory(),
            localAddress: localAddress,
            remoteAddress: remoteAddress,
            maxDatagramSize: maxDatagramSize
        )
    }

    /// Creates a new managed connection with a custom congestion controller factory.
    ///
    /// This initializer is `package` access because `CongestionControllerFactory`
    /// and its dependency types are package-internal. Use the public `init` for
    /// default NewReno congestion control.
    ///
    /// - Parameters:
    ///   - role: Connection role (client or server)
    ///   - version: QUIC version
    ///   - sourceConnectionID: Local connection ID
    ///   - destinationConnectionID: Remote connection ID
    ///   - originalConnectionID: Original DCID for Initial key derivation (defaults to destinationConnectionID)
    ///   - transportParameters: Transport parameters to use
    ///   - tlsProvider: TLS 1.3 provider
    ///   - congestionControllerFactory: Factory for creating the congestion controller
    ///   - localAddress: Local socket address (optional)
    ///   - remoteAddress: Remote socket address
    ///   - maxDatagramSize: Configured path MTU from
    ///     `QUICConfiguration.maxUDPPayloadSize`.  Plumbed into
    ///     `QUICConnectionHandler` and `PacketProcessor`.
    package init(
        role: ConnectionRole,
        version: QUICVersion,
        sourceConnectionID: ConnectionID,
        destinationConnectionID: ConnectionID,
        originalConnectionID: ConnectionID? = nil,
        transportParameters: TransportParameters,
        tlsProvider: any TLS13Provider,
        congestionControllerFactory: any CongestionControllerFactory,
        localAddress: SocketAddress? = nil,
        remoteAddress: SocketAddress,
        maxDatagramSize: Int = ProtocolLimits.minimumMaximumDatagramSize
    ) {
        self.incomingDatagramState = Mutex(IncomingDatagramState())
        self.handler = QUICConnectionHandler(
            role: role,
            version: version,
            sourceConnectionID: sourceConnectionID,
            destinationConnectionID: destinationConnectionID,
            transportParameters: transportParameters,
            congestionControllerFactory: congestionControllerFactory,
            maxDatagramSize: maxDatagramSize
        )
        self.packetProcessor = PacketProcessor(
            dcidLength: sourceConnectionID.length,
            maxDatagramSize: maxDatagramSize
        )
        self.tlsProvider = tlsProvider
        self.amplificationLimiter = AntiAmplificationLimiter(isServer: role == .server)
        self.pathValidationManager = PathValidationManager()
        self.connectionIDManager = ConnectionIDManager(
            activeConnectionIDLimit: transportParameters.activeConnectionIDLimit
        )
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        // For clients, original DCID is the initial destination CID
        // For servers, original DCID is the DCID from the client's Initial packet
        self.originalConnectionID = originalConnectionID ?? destinationConnectionID
        self.transportParameters = transportParameters
        self.onNewConnectionID = Mutex(nil)  // Set later via setNewConnectionIDCallback
        var initialState = ManagedConnectionState(
            role: role,
            sourceConnectionID: sourceConnectionID,
            destinationConnectionID: destinationConnectionID
        )
        initialState.currentRemoteAddress = remoteAddress
        self.state = Mutex(initialState)
        self.streamContinuationsState = Mutex(StreamContinuationsState())
        self.incomingStreamState = Mutex(IncomingStreamState())
        self.sessionTicketState = Mutex(SessionTicketState())

        // Set TLS provider on handler
        handler.setTLSProvider(tlsProvider)
    }

    // MARK: - Connection ID Management

    /// Sets the callback for new connection IDs
    /// - Parameter callback: Closure to call when a NEW_CONNECTION_ID frame is received
    public func setNewConnectionIDCallback(_ callback: (@Sendable (ConnectionID) -> Void)?) {
        onNewConnectionID.withLock { $0 = callback }
    }

    // MARK: - Connection Lifecycle

    /// Starts the connection handshake
    /// - Returns: Initial packets to send (for client)
    public func start() async throws -> [Data] {
        // Prevent double-start: check and set state atomically
        let role = try state.withLock { s -> ConnectionRole in
            guard s.handshakeState == .idle else {
                throw ManagedConnectionError.invalidState("Handshake already started")
            }
            s.handshakeState = .connecting
            return s.role
        }

        // Derive initial keys using the original connection ID
        // RFC 9001: Both client and server derive Initial keys from the
        // Destination Connection ID in the first Initial packet sent by the client
        // PacketProcessor is the single source of truth for crypto contexts
        let (_, _) = try packetProcessor.deriveAndInstallInitialKeys(
            connectionID: originalConnectionID,
            isClient: role == .client,
            version: handler.version
        )

        // Set transport parameters on TLS (use the stored parameters)
        let encodedParams = encodeTransportParameters(transportParameters)
        try tlsProvider.setLocalTransportParameters(encodedParams)

        // Start TLS handshake
        let outputs = try await tlsProvider.startHandshake(isClient: role == .client)

        // State was already set to connecting at the beginning of this method

        // Process TLS outputs
        return try await processTLSOutputs(outputs)
    }

    /// Starts the connection handshake with 0-RTT early data
    ///
    /// RFC 9001 Section 4.6.1: Client sends Initial + 0-RTT packets in first flight
    /// when resuming a session that supports early data.
    ///
    /// - Parameters:
    ///   - session: The cached session to use for resumption
    ///   - earlyData: Optional early data to send as 0-RTT
    /// - Returns: Tuple of (Initial packets, 0-RTT packets)
    public func startWith0RTT(
        session: ClientSessionCache.CachedSession,
        earlyData: Data?
    ) async throws -> (initialPackets: [Data], zeroRTTPackets: [Data]) {
        // Prevent double-start: check and set state atomically
        try state.withLock { s in
            guard s.handshakeState == .idle else {
                throw ManagedConnectionError.invalidState("Handshake already started")
            }
            guard s.role == .client else {
                throw QUICEarlyDataError.earlyDataNotSupported
            }
            s.handshakeState = .connecting
            s.is0RTTAttempted = true
        }

        // Derive initial keys using the original connection ID
        let (_, _) = try packetProcessor.deriveAndInstallInitialKeys(
            connectionID: originalConnectionID,
            isClient: true,
            version: handler.version
        )

        // Set transport parameters on TLS
        let encodedParams = encodeTransportParameters(transportParameters)
        try tlsProvider.setLocalTransportParameters(encodedParams)

        // Configure TLS for session resumption with 0-RTT
        // This must be done BEFORE startHandshake() so the ClientStateMachine
        // can derive 0-RTT keys using the correct ClientHello transcript hash
        try tlsProvider.configureResumption(
            ticket: session.sessionTicketData,
            attemptEarlyData: earlyData != nil
        )

        // Start TLS handshake (will include PSK extension for resumption)
        // The TLS provider will:
        // 1. Build ClientHello with PSK extension
        // 2. Derive early secret from PSK
        // 3. Compute ClientHello transcript hash
        // 4. Derive client_early_traffic_secret with correct transcript
        // 5. Return 0-RTT keys in the outputs
        let outputs = try await tlsProvider.startHandshake(isClient: true)

        // State was already set to connecting at the beginning of this method

        // Process TLS outputs (installs 0-RTT keys and generates Initial packets)
        let initialPackets = try await processTLSOutputs(outputs)

        // Generate 0-RTT packets with early data
        var zeroRTTPackets: [Data] = []
        if let data = earlyData, !data.isEmpty {
            // Open a stream for early data (stream ID 0 for client-initiated bidirectional)
            let streamID: UInt64 = 0
            handler.queueFrame(.stream(StreamFrame(
                streamID: streamID,
                offset: 0,
                data: data,
                fin: false
            )), level: .zeroRTT)

            // Generate 0-RTT packet
            let packets = try generate0RTTPackets()
            zeroRTTPackets.append(contentsOf: packets)
        }

        return (initialPackets, zeroRTTPackets)
    }

    /// Generates 0-RTT packets from queued frames
    private func generate0RTTPackets() throws -> [Data] {
        let outboundPackets = handler.getOutboundPackets()
        var result: [Data] = []

        for packet in outboundPackets where packet.level == .zeroRTT {
            let pn = handler.getNextPacketNumber(for: .zeroRTT)
            let header = build0RTTHeader(packetNumber: pn)

            let encrypted = try packetProcessor.encryptLongHeaderPacket(
                frames: packet.frames,
                header: header,
                packetNumber: pn,
                padToMinimum: false
            )
            result.append(encrypted)
        }

        return result
    }

    /// Builds a 0-RTT packet header
    private func build0RTTHeader(packetNumber: UInt64) -> LongHeader {
        let (scid, dcid) = state.withLock { ($0.sourceConnectionID, $0.destinationConnectionID) }
        return LongHeader(
            packetType: .zeroRTT,
            version: handler.version,
            destinationConnectionID: dcid,
            sourceConnectionID: scid,
            packetNumber: packetNumber
        )
    }

    // MARK: - ECN Control

    /// Enables ECN marking on outgoing packets and starts ECN validation.
    ///
    /// Call this after confirming the socket was created with ECN support
    /// (i.e. `PlatformSocketOptions.ecnEnabled == true`).
    public func enableECN() {
        handler.ecnManager.enableECN()
    }

    /// Disables ECN marking on outgoing packets.
    public func disableECN() {
        handler.ecnManager.disableECN()
    }

    /// Whether ECN is currently enabled on this connection.
    public var isECNEnabled: Bool {
        handler.ecnManager.isEnabled
    }

    /// Current ECN validation state for this connection's path.
    public var ecnValidationState: ECNValidationState {
        handler.ecnManager.validationState
    }

    /// Whether ECN validation has succeeded on this path.
    public var isECNValidated: Bool {
        handler.ecnManager.isValidated
    }

    // MARK: - DPLPMTUD Control

    /// Enables DPLPMTUD probing on this connection.
    ///
    /// Call this after confirming the socket has the DF bit set
    /// (i.e. `PlatformSocketOptions.dfEnabled == true`).
    /// Without DF, routers may silently fragment and probes always
    /// "succeed", yielding an incorrect path MTU.
    public func enablePMTUD() {
        handler.pmtuDiscovery.enable()
    }

    /// Disables DPLPMTUD and reverts to the base MTU.
    public func disablePMTUD() {
        handler.pmtuDiscovery.disable()
    }

    /// The currently confirmed path MTU from DPLPMTUD.
    ///
    /// In `disabled` or `error` states this returns `basePLPMTU`
    /// (i.e. `ProtocolLimits.minimumMaximumDatagramSize`).
    public var currentPathMTU: Int {
        handler.pmtuDiscovery.currentPLPMTU
    }

    /// Current DPLPMTUD state machine phase.
    public var pmtuState: PMTUState {
        handler.pmtuDiscovery.state
    }

    /// Resets DPLPMTUD state after a path change (connection migration).
    ///
    /// Reverts the confirmed MTU to base and restarts the search
    /// on the next timer tick.
    public func resetPMTUDForPathChange() {
        handler.pmtuDiscovery.resetForPathChange()
    }

    /// Diagnostic summary of the DPLPMTUD state for logging.
    public var pmtuDiagnostics: String {
        handler.pmtuDiscovery.diagnosticSummary
    }

    /// The number of confirmed MTU entries in the PMTUD history.
    public var pmtuHistoryCount: Int {
        handler.pmtuDiscovery.mtuHistory.count
    }

    /// Attempts to generate a DPLPMTUD probe.
    ///
    /// Returns `nil` when the state machine is not in a probing phase
    /// (e.g. `disabled`, `searchComplete`, or an active probe is already
    /// in flight).
    public func generatePMTUProbe() -> PMTUDiscoveryManager.ProbeRequest? {
        handler.pmtuDiscovery.generateProbe()
    }

    /// Generates a DPLPMTUD probe, builds a padded packet, enqueues it
    /// for transmission, and signals the outbound send loop.
    ///
    /// The probe packet contains a PATH_CHALLENGE frame plus PADDING
    /// frames to reach the target probe size.  It bypasses the normal
    /// frame queue because its size intentionally exceeds
    /// `maxDatagramSize`.
    ///
    /// - Returns: The probe request metadata, or `nil` if no probe is
    ///   needed (PMTUD disabled, search complete, or probe already in
    ///   flight).
    @discardableResult
    public func sendPMTUProbe() throws -> PMTUDiscoveryManager.ProbeRequest? {
        guard let probe = generatePMTUProbe() else { return nil }

        // Build the probe packet directly (not via the frame queue,
        // because probe.packetSize > maxDatagramSize).
        let dcid = state.withLock { $0.destinationConnectionID }
        let pn = handler.getNextPacketNumber(for: .application)
        let header = ShortHeader(
            destinationConnectionID: dcid,
            packetNumberLength: 4,
            spinBit: false,
            keyPhase: false
        )

        // Compute per-packet overhead so we can size the PADDING frame.
        //   1           first byte
        // + dcid.count  DCID
        // + pnLength    packet number (before encryption)
        // + 16          AEAD tag  (PacketConstants.aeadTagSize)
        // + 9           PATH_CHALLENGE (1 type + 8 data)
        let overhead = 1 + dcid.bytes.count + header.packetNumberLength
                     + PacketConstants.aeadTagSize + 9
        let paddingCount = max(0, probe.packetSize - overhead)

        var frames: [Frame] = [probe.frame]
        if paddingCount > 0 {
            frames.append(.padding(count: paddingCount))
        }

        let encrypted = try packetProcessor.encryptShortHeaderPacket(
            frames: frames,
            header: header,
            packetNumber: pn,
            maxPacketSize: probe.packetSize
        )

        Self.logger.info(
            "DPLPMTUD: sending probe packet (\(encrypted.count) bytes, target=\(probe.packetSize), challenge=\(probe.challengeData.count) bytes)"
        )

        // Enqueue and signal the outbound send loop.
        state.withLock { $0.probePacketQueue.append(encrypted) }
        signalNeedsSend()

        return probe
    }

    // MARK: - Packet Processing

    /// Processes an incoming packet
    /// - Parameters:
    ///   - data: The encrypted packet data
    ///   - ecnCodepoint: ECN codepoint from the IP header (via `IncomingPacket`).
    ///     Defaults to `.notECT` when the transport does not provide ECN metadata.
    /// - Returns: Outbound packets to send in response
    public func processIncomingPacket(_ data: Data, ecnCodepoint: ECNCodepoint = .notECT) async throws -> [Data] {
        // Record received bytes for anti-amplification limit
        amplificationLimiter.recordBytesReceived(UInt64(data.count))

        // RFC 9001 §5.8: Check for Retry packet and verify integrity tag
        // Retry packets use special handling - they don't use normal AEAD encryption
        if RetryIntegrityTag.isRetryPacket(data) {
            return try await processRetryPacket(data)
        }

        // Decrypt the packet
        let parsed = try packetProcessor.decryptPacket(data)

        // RFC 9000 Section 7.2: Client MUST update DCID to server's SCID from first Initial packet
        // This is critical for QUIC handshake: client uses server's SCID as DCID in all subsequent packets
        if parsed.encryptionLevel == .initial, case .long(let longHeader) = parsed.header {
            let (role, currentDCID) = state.withLock { ($0.role, $0.destinationConnectionID) }

            if role == .client {
                let serverSCID = longHeader.sourceConnectionID
                // Only update on first Initial packet (when DCIDs differ)
                if currentDCID != serverSCID {
                    Self.logger.debug("Client updating DCID from \(currentDCID) to server's SCID \(serverSCID)")
                    state.withLock { state in
                        state.destinationConnectionID = serverSCID
                    }
                    // Update PacketProcessor's DCID length for short header parsing
                    packetProcessor.setDCIDLength(serverSCID.bytes.count)
                }
            }
        }

        // RFC 9000 Section 8.1: Server validates client address upon receiving Handshake packet
        if parsed.encryptionLevel == .handshake {
            amplificationLimiter.validateAddress()
        }

        // Record ECN codepoint for this packet's encryption level
        handler.ecnManager.recordIncoming(ecnCodepoint, level: parsed.encryptionLevel)

        // Record received packet
        handler.recordReceivedPacket(
            packetNumber: parsed.packetNumber,
            level: parsed.encryptionLevel,
            isAckEliciting: parsed.frames.contains { $0.isAckEliciting },
            receiveTime: .now
        )

        // Process frames
        let result = try handler.processFrames(parsed.frames, level: parsed.encryptionLevel)

        // Handle frame results (common logic)
        var outboundPackets = try await processFrameResult(result)

        // Generate response packets (ACKs, etc.)
        let responsePackets = try generateOutboundPackets()
        outboundPackets.append(contentsOf: responsePackets)

        // Apply anti-amplification limit
        return applyAmplificationLimit(to: outboundPackets)
    }

    /// Processes a coalesced datagram (multiple packets)
    /// - Parameters:
    ///   - datagram: The UDP datagram
    ///   - ecnCodepoint: ECN codepoint from the IP header (via `IncomingPacket`).
    ///     Applied to every coalesced packet within the datagram (a single UDP
    ///     datagram has exactly one IP header, so all coalesced QUIC packets
    ///     share the same ECN marking). Defaults to `.notECT`.
    /// - Returns: Outbound packets to send in response
    ///
    /// RFC 9000 Section 12.2: A single UDP datagram may contain multiple
    /// coalesced QUIC packets at different encryption levels (e.g., Initial +
    /// Handshake).  We MUST decrypt and process each packet incrementally so
    /// that keys derived from processing one packet (e.g., the Initial packet
    /// containing ServerHello, which installs Handshake keys) are available
    /// when decrypting the next coalesced packet (e.g., the Handshake packet
    /// containing EncryptedExtensions / Certificate / Finished).
    ///
    /// The previous implementation called `decryptDatagram()` up-front, which
    /// tried to decrypt ALL coalesced packets before any frames were processed.
    /// This caused the Handshake packet to be silently dropped (no keys yet),
    /// losing the first 110 bytes of Handshake-level CRYPTO data and stalling
    /// the TLS handshake.
    public func processDatagram(_ datagram: Data, ecnCodepoint: ECNCodepoint = .notECT) async throws -> [Data] {
        // Record received bytes for anti-amplification limit
        amplificationLimiter.recordBytesReceived(UInt64(datagram.count))

        // RFC 9001 §5.8: Check for Retry packet and verify integrity tag
        // Retry packets are never coalesced, but check the first packet anyway
        if RetryIntegrityTag.isRetryPacket(datagram) {
            return try await processRetryPacket(datagram)
        }

        // Step 1: Split the datagram into individual packet boundaries WITHOUT
        // decrypting.  CoalescedPacketParser uses the Length field in long
        // headers to find packet boundaries.
        let dcidLen = packetProcessor.dcidLengthValue
        let packetInfos: [CoalescedPacketParser.PacketInfo]
        do {
            packetInfos = try CoalescedPacketParser.parse(datagram: datagram, dcidLength: dcidLen)
        } catch {
            Self.logger.warning("Failed to parse coalesced datagram: \(error)")
            return []
        }

        var allOutbound: [Data] = []
        var processedAny = false

        // Step 2: Decrypt-then-process each packet sequentially.
        // This ensures that keys installed by processing packet N are
        // available when decrypting packet N+1.
        for info in packetInfos {
            // Attempt to decrypt this individual packet
            let parsed: ParsedPacket
            do {
                parsed = try packetProcessor.decryptPacket(info.data)
            } catch PacketCodecError.noOpener {
                // No keys for this encryption level yet.
                // This can still happen legitimately (e.g. 0-RTT keys not yet
                // available).  Log at trace level and skip.
                Self.logger.trace("Skipping coalesced packet at offset \(info.offset): no keys for this encryption level yet")
                continue
            } catch PacketCodecError.decryptionFailed {
                // Decryption failed — packet may be corrupted or keys are wrong
                Self.logger.trace("Skipping coalesced packet at offset \(info.offset): decryption failed")
                continue
            } catch QUICError.decryptionFailed {
                // AEAD authentication tag mismatch
                Self.logger.trace("Skipping coalesced packet at offset \(info.offset): AEAD decryption failed")
                continue
            } catch {
                // Unexpected error — propagate
                throw error
            }

            processedAny = true

            // RFC 9000 Section 7.2: Client MUST update DCID to server's SCID from first Initial packet
            // This is critical for QUIC handshake: client uses server's SCID as DCID in all subsequent packets
            if parsed.encryptionLevel == .initial, case .long(let longHeader) = parsed.header {
                let (role, currentDCID) = state.withLock { ($0.role, $0.destinationConnectionID) }

                if role == .client {
                    let serverSCID = longHeader.sourceConnectionID
                    // Only update on first Initial packet (when DCIDs differ)
                    if currentDCID != serverSCID {
                        Self.logger.debug("Client updating DCID from \(currentDCID) to server's SCID \(serverSCID)")
                        state.withLock { state in
                            state.destinationConnectionID = serverSCID
                        }
                        // Update PacketProcessor's DCID length for short header parsing
                        packetProcessor.setDCIDLength(serverSCID.bytes.count)
                    }
                }
            }

            // RFC 9000 Section 8.1: Server validates client address upon receiving Handshake packet
            if parsed.encryptionLevel == .handshake {
                amplificationLimiter.validateAddress()
            }

            // Record ECN codepoint for this packet's encryption level.
            // All coalesced packets in a single UDP datagram share the
            // same IP header, so the ECN codepoint applies uniformly.
            handler.ecnManager.recordIncoming(ecnCodepoint, level: parsed.encryptionLevel)

            // Record received packet
            handler.recordReceivedPacket(
                packetNumber: parsed.packetNumber,
                level: parsed.encryptionLevel,
                isAckEliciting: parsed.frames.contains { $0.isAckEliciting },
                receiveTime: .now
            )

            // Process frames — this may call processFrameResult → processTLSOutputs,
            // which installs new crypto keys (e.g., Handshake keys from ServerHello,
            // Application keys from Finished).  These keys are now available for
            // decrypting the next coalesced packet in the loop.
            let result = try handler.processFrames(parsed.frames, level: parsed.encryptionLevel)

            // Handle frame results (common logic)
            let outbound = try await processFrameResult(result)
            allOutbound.append(contentsOf: outbound)
        }

        // RFC 9000 Section 6.2: Mark that we've received a valid packet
        // This prevents late Version Negotiation packets from being processed
        if processedAny {
            state.withLock { $0.hasReceivedValidPacket = true }
        }

        // Generate response packets
        let responsePackets = try generateOutboundPackets()
        allOutbound.append(contentsOf: responsePackets)

        // Apply anti-amplification limit to outbound packets (servers only)
        return applyAmplificationLimit(to: allOutbound)
    }

    /// Applies the anti-amplification limit to outbound packets
    ///
    /// RFC 9000 Section 8.1: Before address validation, servers MUST NOT send
    /// more than 3 times the data received from the client.
    ///
    /// - Parameter packets: Packets to potentially send
    /// - Returns: Packets that fit within the amplification limit
    private func applyAmplificationLimit(to packets: [Data]) -> [Data] {
        var allowedPackets: [Data] = []

        for packet in packets {
            let packetSize = UInt64(packet.count)

            if amplificationLimiter.canSend(bytes: packetSize) {
                amplificationLimiter.recordBytesSent(packetSize)
                allowedPackets.append(packet)
            }
            // Packets that exceed the limit are dropped
            // They will be retransmitted once more data is received
        }

        return allowedPackets
    }

    // MARK: - Retry Packet Processing

    /// Processes a Retry packet from the server
    ///
    /// RFC 9001 Section 5.8: A client that receives a Retry packet MUST verify
    /// the Retry Integrity Tag before processing the packet.
    ///
    /// RFC 9000 Section 8.1:
    /// - A client MUST accept and process at most one Retry packet
    /// - A client MUST discard a Retry packet if it has received a valid packet
    /// - A client MUST discard a Retry packet with an invalid integrity tag
    ///
    /// - Parameter data: The Retry packet data
    /// - Returns: New Initial packets to send with the retry token
    private func processRetryPacket(_ data: Data) async throws -> [Data] {
        // Only clients process Retry packets
        let (role, hasProcessedRetry, hasReceivedValidPacket) = state.withLock { s in
            (s.role, s.hasProcessedRetry, s.hasReceivedValidPacket)
        }

        guard role == .client else {
            // Servers don't process Retry packets - silently discard
            return []
        }

        // RFC 9000: A client MUST accept and process at most one Retry packet
        guard !hasProcessedRetry else {
            // Already processed a Retry - discard this one
            return []
        }

        // RFC 9000: A client that has received and successfully processed a valid
        // Initial or Handshake packet MUST discard subsequent Retry packets
        guard !hasReceivedValidPacket else {
            return []
        }

        // Parse the Retry packet
        let (version, _, sourceCID, retryToken, integrityTag) =
            try RetryIntegrityTag.parseRetryPacket(data)

        // RFC 9001 §5.8: Verify the Retry Integrity Tag
        // The tag is computed using the ORIGINAL destination connection ID
        // (the one the client used in its first Initial packet)
        let packetWithoutTag = RetryIntegrityTag.retryPacketWithoutTag(data)

        let isValid = try RetryIntegrityTag.verify(
            tag: integrityTag,
            originalDCID: originalConnectionID,
            retryPacketWithoutTag: packetWithoutTag,
            version: version
        )

        guard isValid else {
            // RFC 9001 §5.8: Discard Retry packet with invalid integrity tag
            // Do NOT treat this as a connection error - just silently discard
            return []
        }

        // RFC 9000: The client MUST use the value from the Source Connection ID
        // field of the Retry packet in the Destination Connection ID field of
        // subsequent packets
        state.withLock { s in
            s.hasProcessedRetry = true
            s.retryToken = retryToken
            s.destinationConnectionID = sourceCID
        }

        // RFC 9001: The client MUST discard Initial keys derived from the original
        // Destination Connection ID and derive new Initial keys using the
        // Source Connection ID from the Retry packet
        packetProcessor.discardKeys(for: .initial)

        // Derive new Initial keys using the server's SCID (our new DCID)
        let (_, _) = try packetProcessor.deriveAndInstallInitialKeys(
            connectionID: sourceCID,
            isClient: true,
            version: version
        )

        // Update the handler's destination CID
        handler.updateDestinationConnectionID(sourceCID)

        // RFC 9000 Section 8.1.2: Resend Initial packet with the retry token
        // Get the current CRYPTO data to resend
        let cryptoData = handler.getCryptoDataForRetry(level: .initial)

        // Build and send new Initial packet with retry token
        var initialPackets: [Data] = []
        if !cryptoData.isEmpty {
            let (scid, dcid) = state.withLock { ($0.sourceConnectionID, $0.destinationConnectionID) }
            let pn = handler.getNextPacketNumber(for: .initial)

            let header = LongHeader(
                packetType: .initial,
                version: version,
                destinationConnectionID: dcid,
                sourceConnectionID: scid,
                token: retryToken,  // Include the retry token
                packetNumber: pn
            )

            let frames: [Frame] = [.crypto(CryptoFrame(offset: 0, data: cryptoData))]

            let encrypted = try packetProcessor.encryptLongHeaderPacket(
                frames: frames,
                header: header,
                packetNumber: pn,
                padToMinimum: true  // Initial packets must be padded to minimumInitialPacketSize (RFC 9000 Section 14.1)
            )
            initialPackets.append(encrypted)
        }

        return applyAmplificationLimit(to: initialPackets)
    }

    /// Generates outbound packets ready to send
    /// - Returns: Array of encrypted packet data
    public func generateOutboundPackets() throws -> [Data] {
        // Phase 1: Serialize so outboundSendLoop + packetReceiveLoop
        // cannot interleave frame queue operations (RC1).
        try packetGenerationLock.withLock { _ in
            try _generateOutboundPacketsLocked()
        }
    }

    /// The actual packet generation logic, called under `packetGenerationLock`.
    private func _generateOutboundPacketsLocked() throws -> [Data] {
        // Drain pre-built PMTUD probe packets first — these were
        // constructed by sendPMTUProbe() and already encrypted.
        var result: [Data] = state.withLock { s in
            let probes = s.probePacketQueue
            s.probePacketQueue.removeAll(keepingCapacity: true)
            return probes
        }

        let outboundPackets = handler.getOutboundPackets()

        // Consolidate all frames by encryption level.
        var framesByLevel: [EncryptionLevel: [Frame]] = [:]

        for packet in outboundPackets {
            // Skip levels whose keys have already been discarded.
            guard packetProcessor.hasKeys(for: packet.level) else {
                continue
            }
            framesByLevel[packet.level, default: []].append(contentsOf: packet.frames)
        }

        // Phase 3: For each level, pack frames into MTU-sized packets
        // instead of cramming all frames into a single packet (RC2/RC4).
        for level in [EncryptionLevel.initial, .handshake, .application] {
            guard let frames = framesByLevel[level], !frames.isEmpty else { continue }
            let packets = try buildMTUPackets(frames: frames, level: level)
            result.append(contentsOf: packets)
        }

        return result
    }

    // MARK: - MTU-Aware Packet Builder (Phase 3)

    /// Splits `frames` into one or more packets that each fit within `maxDatagramSize`.
    ///
    /// Delegates pure batching logic to ``MTUFramePacker.pack(frames:maxPayload:)``
    /// and encrypts each batch via ``encryptAndFlush(_:level:)``.
    ///
    /// If a single frame exceeds the MTU payload budget it is emitted alone so that
    /// other frames are not lost when the encoder throws `packetTooLarge` (RC4 fix).
    private func buildMTUPackets(frames: [Frame], level: EncryptionLevel) throws -> [Data] {
        let (scid, dcid) = state.withLock { s in
            (s.sourceConnectionID, s.destinationConnectionID)
        }
        let maxPayload = MTUFramePacker.maxPayload(
            for: level,
            maxDatagramSize: packetProcessor.maxDatagramSize,
            dcidLength: dcid.length,
            scidLength: scid.length
        )

        let batches = MTUFramePacker.pack(frames: frames, maxPayload: maxPayload)
        var result: [Data] = []

        for batch in batches {
            if batch.isOversized {
                // Oversized single frame -- attempt encryption but don't
                // propagate the error so subsequent batches survive.
                do {
                    result.append(try encryptAndFlush(batch.frames, level: level))
                } catch {
                    Self.logger.warning("Oversized frame (\(batch.totalSize) > \(maxPayload)) at \(level): \(error)")
                }
            } else {
                result.append(try encryptAndFlush(batch.frames, level: level))
            }
        }

        return result
    }

    /// Encrypts a batch of frames into a single packet at the given level.
    private func encryptAndFlush(_ frames: [Frame], level: EncryptionLevel) throws -> Data {
        let pn = handler.getNextPacketNumber(for: level)
        let header = buildPacketHeader(for: level, packetNumber: pn)

        let encrypted: Data
        switch (level, header) {
        case (.initial, .long(let lh)):
            encrypted = try packetProcessor.encryptLongHeaderPacket(
                frames: frames, header: lh, packetNumber: pn, padToMinimum: true
            )
        case (.handshake, .long(let lh)):
            encrypted = try packetProcessor.encryptLongHeaderPacket(
                frames: frames, header: lh, packetNumber: pn, padToMinimum: false
            )
        case (.application, .short(let sh)):
            encrypted = try packetProcessor.encryptShortHeaderPacket(
                frames: frames, header: sh, packetNumber: pn
            )
        default:
            throw PacketCodecError.invalidPacketFormat("Header type mismatch for level \(level)")
        }

        Self.logger.trace("Emitting \(level) packet: \(encrypted.count) bytes (\(frames.count) frames)")
        return encrypted
    }

    /// Called when a timer expires
    /// - Returns: Packets to send (probes, retransmits)
    public func onTimerExpired() throws -> [Data] {
        let action = handler.onTimerExpired()

        switch action {
        case .none:
            return []

        case .retransmit(_, let level):
            // SentPacket doesn't contain frame data, so we send a PING as probe
            // The actual retransmission is handled by the stream manager when
            // data hasn't been ACKed
            handler.queueFrame(.ping, level: level)
            return try generateOutboundPackets()

        case .probe:
            // Send a PING to probe
            let level: EncryptionLevel = isEstablished ? .application : .initial
            handler.queueFrame(.ping, level: level)
            return try generateOutboundPackets()
        }
    }

    /// Gets the next timer deadline
    public func nextTimerDeadline() -> ContinuousClock.Instant? {
        handler.nextTimerDeadline()
    }

    // MARK: - Handshake Helpers

    /// Processes TLS outputs and generates packets
    private func processTLSOutputs(_ outputs: [TLSOutput]) async throws -> [Data] {
        var outboundPackets: [Data] = []
        var handshakeCompleted = false

        for output in outputs {
            switch output {
            case .handshakeData(let data, let level):
                // Queue CRYPTO frames
                handler.queueCryptoData(data, level: level)
                // NOTE: Do NOT call signalNeedsSend() here.
                // The inline path (generateOutboundPackets at the end of this
                // method) will build and return these packets directly.
                // Signaling the outboundSendLoop here causes a race where
                // the loop drains partially-queued frames, splitting handshake
                // CRYPTO data across competing senders and losing packets.

            case .keysAvailable(let info):
                // Install keys via PacketProcessor (single source of truth for crypto)
                let isClient = state.withLock { $0.role == .client }
                try packetProcessor.installKeys(info, isClient: isClient)

            case .handshakeComplete(let info):
                state.withLock { $0.negotiatedALPN = info.alpn }

                // Parse peer transport parameters
                if let peerParams = tlsProvider.getPeerTransportParameters() {
                    Self.logger.debug("Received peer transport parameters: \(peerParams.count) bytes")
                    if let params = decodeTransportParameters(peerParams) {
                        Self.logger.debug("Decoded peer params: maxData=\(params.initialMaxData), bidiLocal=\(params.initialMaxStreamDataBidiLocal), bidiRemote=\(params.initialMaxStreamDataBidiRemote)")
                        handler.setPeerTransportParameters(params)
                    } else {
                        Self.logger.error("Failed to decode transport parameters!")
                    }
                } else {
                    Self.logger.error("No peer transport parameters received from TLS!")
                }

                // RFC 9000 Section 8.1: Lift amplification limit when handshake is confirmed
                amplificationLimiter.confirmHandshake()

                // RFC 9001 Section 4.1.1: Handshake is complete when TLS reports completion
                // Both client and server can send 1-RTT data immediately after handshake completes
                // HANDSHAKE_DONE frame is for "handshake confirmation", not a requirement to start sending data
                handler.markHandshakeComplete()
                Self.logger.debug("TLS handshake complete - enabling 1-RTT data transmission")

                // Server: Send HANDSHAKE_DONE frame to client (RFC 9001 Section 4.1.2)
                let role = state.withLock { $0.role }
                if role == .server {
                    handler.queueFrame(.handshakeDone, level: .application)
                    Self.logger.debug("Server queued HANDSHAKE_DONE frame")
                    // NOTE: Do NOT signal here — the inline generateOutboundPackets()
                    // below will pick up HANDSHAKE_DONE along with all other queued frames.
                }

                // Mark handshake as established, drain waiters, and propagate 0-RTT result
                let waiters = state.withLock { s -> [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] in
                    s.handshakeState = .established
                    // Propagate actual 0-RTT acceptance from the TLS provider
                    if s.is0RTTAttempted {
                        s.is0RTTAccepted = self.tlsProvider.is0RTTAccepted
                    }
                    let w = s.handshakeCompletionContinuations
                    s.handshakeCompletionContinuations.removeAll()
                    return w
                }
                handshakeCompleted = true

                // Resume all callers that are waiting in waitForHandshake()
                // (server-side: handshake completes here via TLS output)
                for waiter in waiters {
                    waiter.continuation.resume()
                }

            case .needMoreData:
                // Wait for more data
                break

            case .error(let error):
                throw error

            case .alert(let alert):
                // TLS Alert received - for QUIC, this results in CONNECTION_CLOSE
                // with crypto error code (0x100 + alert code) per RFC 9001 Section 4.8
                // For now, we throw an error which will be handled by the caller
                throw TLSError.handshakeFailed(
                    alert: alert.alertDescription.rawValue,
                    description: alert.description
                )

            case .newSessionTicket(let ticketInfo):
                // RFC 8446 Section 4.6.1: NewSessionTicket received post-handshake
                // Store it for the client to use for future connections
                notifySessionTicketReceived(ticketInfo)
            }
        }

        // Generate packets from queued frames (BEFORE discarding keys).
        // This is the ONLY place that should drain the outbound queue during
        // TLS processing — no signalNeedsSend() was issued above, so the
        // outboundSendLoop is not competing for the queue.
        let packets = try generateOutboundPackets()
        outboundPackets.append(contentsOf: packets)

        // Now signal the outboundSendLoop so it's ready for any future
        // packets (e.g. post-handshake stream data, session tickets).
        // At this point the queue has been drained, so the loop will find
        // nothing immediately — but it will be primed for the next write.
        signalNeedsSend()

        // Discard Initial and Handshake keys if handshake completed
        // RFC 9001 Section 4.9.2:
        // - Server: Discard when TLS handshake completes (here)
        // - Client: Discard when HANDSHAKE_DONE is received (in completeHandshake)
        if handshakeCompleted {
            let role = state.withLock { $0.role }
            if role == .server {
                // Server discards keys immediately after handshake completes
                packetProcessor.discardKeys(for: .initial)
                packetProcessor.discardKeys(for: .handshake)
                handler.discardLevel(.initial)
                handler.discardLevel(.handshake)
            }
            // Client waits for HANDSHAKE_DONE before discarding keys
        }

        return outboundPackets
    }

    /// Completes the handshake (called when HANDSHAKE_DONE frame is received)
    ///
    /// RFC 9001 Section 4.9.2:
    /// - Server: Already discarded keys in processTLSOutputs()
    /// - Client: Discards keys here when HANDSHAKE_DONE is received
    private func completeHandshake() throws {
        // Single lock acquisition to get role, update state, and drain waiters
        let (role, waiters) = state.withLock { s -> (ConnectionRole, [(id: UUID, continuation: CheckedContinuation<Void, any Error>)]) in
            s.handshakeState = .established
            let w = s.handshakeCompletionContinuations
            s.handshakeCompletionContinuations.removeAll()
            return (s.role, w)
        }

        // Client discards keys when HANDSHAKE_DONE is received (RFC 9001 compliance)
        if role == .client {
            packetProcessor.discardKeys(for: .initial)
            packetProcessor.discardKeys(for: .handshake)
            handler.discardLevel(.initial)
            handler.discardLevel(.handshake)

            // CRITICAL: Mark handshake complete to enable stream frame generation
            handler.markHandshakeComplete()
        }
        // Server already discarded keys in processTLSOutputs()

        // Resume all callers that are waiting in waitForHandshake()
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }

    /// Processes frame processing result (common logic for packet handling)
    ///
    /// Handles:
    /// - Crypto data (TLS messages)
    /// - New peer-initiated streams
    /// - Stream data notifications
    /// - Handshake completion
    /// - Connection close
    ///
    /// - Parameter result: The frame processing result
    /// - Returns: Outbound packets generated from TLS processing
    private func processFrameResult(_ result: FrameProcessingResult) async throws -> [Data] {
        var outboundPackets: [Data] = []

        // Handle crypto data (TLS messages)
        for (level, cryptoData) in result.cryptoData {
            let tlsOutputs = try await tlsProvider.processHandshakeData(cryptoData, at: level)
            let packets = try await processTLSOutputs(tlsOutputs)
            outboundPackets.append(contentsOf: packets)
        }

        // Handle new peer-initiated streams
        let scidForDebug = state.withLock { $0.sourceConnectionID }
        if !result.newStreams.isEmpty {
            Self.logger.debug("processFrameResult: \(result.newStreams.count) new streams: \(result.newStreams) for SCID=\(scidForDebug)")
        }
        for streamID in result.newStreams {
            let isBidirectional = StreamID.isBidirectional(streamID)
            let stream = ManagedStream(
                id: streamID,
                connection: self,
                isUnidirectional: !isBidirectional
            )
            incomingStreamState.withLock { state in
                // Don't yield if shutdown
                guard !state.isShutdown else {
                    Self.logger.trace("NOT yielding stream \(streamID) - shutdown for SCID=\(scidForDebug)")
                    return
                }

                if let continuation = state.continuation {
                    // Continuation exists, yield directly
                    Self.logger.trace("Yielding stream \(streamID) directly to continuation for SCID=\(scidForDebug)")
                    continuation.yield(stream)
                } else {
                    // Buffer the stream until incomingStreams is accessed
                    Self.logger.trace("Buffering stream \(streamID) (no continuation yet, pendingCount=\(state.pendingStreams.count)) for SCID=\(scidForDebug)")
                    state.pendingStreams.append(stream)
                }
            }
        }

        // Handle stream data
        for (streamID, data) in result.streamData {
            notifyStreamDataReceived(streamID, data: data)
        }

        // Handle received datagrams (RFC 9221)
        for datagramPayload in result.datagramsReceived {
            notifyDatagramReceived(datagramPayload)
        }

        // Handle streams whose receive side is now complete (FIN received,
        // all data consumed).  If a reader is blocked waiting for more data
        // on one of these streams, resume it with empty Data to signal
        // end-of-stream.  Otherwise record the stream so that future
        // readFromStream() calls return immediately.
        for streamID in result.finishedStreams {
            streamContinuationsState.withLock { state in
                if let continuation = state.continuations.removeValue(forKey: streamID) {
                    // A reader is already waiting — wake it with end-of-stream
                    continuation.resume(returning: Data())
                } else {
                    // No reader yet — record so next readFromStream detects it
                    state.finishedStreams.insert(streamID)
                }
            }
        }

        // Handle handshake completion (from HANDSHAKE_DONE frame)
        if result.handshakeComplete {
            try completeHandshake()
        }

        // Handle connection close
        if result.connectionClosed {
            let scid = state.withLock { s -> ConnectionID in
                s.handshakeState = .closed
                return s.sourceConnectionID
            }
            Self.logger.info("shutdown() triggered by CONNECTION_CLOSE frame for SCID=\(scid)")
            shutdown()  // Finish async streams to prevent hanging for-await loops
        }

        // Handle new connection IDs - register them with the router
        for frame in result.newConnectionIDs {
            Self.logger.debug("Registering NEW_CONNECTION_ID: \(frame.connectionID)")
            onNewConnectionID.withLock { callback in
                callback?(frame.connectionID)
            }
        }

        // Handle DPLPMTUD probe acknowledgment — a PATH_RESPONSE matched
        // an active PMTUD probe and confirmed a new path MTU.
        if let newMTU = result.discoveredPLPMTU {
            Self.logger.info("DPLPMTUD: path MTU confirmed at \(newMTU) bytes (was \(handler.maxDatagramSize))")
            // NOTE: maxDatagramSize on the handler is currently a `let`.
            // Full runtime MTU update (congestion window recalculation,
            // pacing adjustment) requires making it mutable and notifying
            // the congestion controller.  For now the discovered value is
            // recorded in the PMTUD manager's history and logged; callers
            // can query handler.pmtuDiscovery.currentPLPMTU.
        }

        return outboundPackets
    }

    /// Builds a packet header for the given level
    private func buildPacketHeader(for level: EncryptionLevel, packetNumber: UInt64) -> PacketHeader {
        let (scid, dcid, version) = state.withLock { state in
            (state.sourceConnectionID, state.destinationConnectionID, handler.version)
        }

        switch level {
        case .initial:
            Self.logger.trace("Building Initial packet: SCID=\(scid), DCID=\(dcid)")
            let longHeader = LongHeader(
                packetType: .initial,
                version: version,
                destinationConnectionID: dcid,
                sourceConnectionID: scid,
                token: nil
            )
            return .long(longHeader)

        case .handshake:
            Self.logger.trace("Building Handshake packet: SCID=\(scid), DCID=\(dcid)")
            let longHeader = LongHeader(
                packetType: .handshake,
                version: version,
                destinationConnectionID: dcid,
                sourceConnectionID: scid,
                token: nil
            )
            return .long(longHeader)

        case .application:
            Self.logger.trace("Building Application packet (1-RTT): SCID=\(scid), DCID=\(dcid)")
            let shortHeader = ShortHeader(
                destinationConnectionID: dcid,
                spinBit: false,
                keyPhase: false
            )
            return .short(shortHeader)

        default:
            // 0-RTT or other
            let longHeader = LongHeader(
                packetType: .zeroRTT,
                version: version,
                destinationConnectionID: dcid,
                sourceConnectionID: scid,
                token: nil
            )
            return .long(longHeader)
        }
    }

    // MARK: - Stream Helpers

    /// Notifies that data has been received on a stream
    ///
    /// Thread-safe: If a reader is waiting, resume it with the data.
    /// If no reader is waiting, buffer the data for later retrieval.
    ///
    /// - Parameters:
    ///   - streamID: The stream ID
    ///   - data: The received data
    private func notifyStreamDataReceived(_ streamID: UInt64, data: Data) {
        streamContinuationsState.withLock { state in
            // Don't process if shutdown
            guard !state.isShutdown else { return }

            // If someone is waiting, resume them with the data
            if let continuation = state.continuations.removeValue(forKey: streamID) {
                continuation.resume(returning: data)
            } else {
                // No reader waiting - buffer the data for later
                state.pendingData[streamID, default: []].append(data)
            }
        }
    }

    // MARK: - Transport Parameters

    /// Encodes transport parameters to wire format using RFC 9000 compliant codec
    private func encodeTransportParameters(_ params: TransportParameters) -> Data {
        // Use proper TransportParameterCodec for RFC 9000 compliant encoding
        // This includes mandatory initial_source_connection_id parameter
        return TransportParameterCodec.encode(params)
    }

    /// Decodes transport parameters from wire format
    private func decodeTransportParameters(_ data: Data) -> TransportParameters? {
        // Use proper TransportParameterCodec for RFC 9000 compliant decoding
        return try? TransportParameterCodec.decode(data)
    }
}
