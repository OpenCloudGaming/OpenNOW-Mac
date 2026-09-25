/// TLS 1.3 Handler - Main Implementation of TLS13Provider
///
/// Implements the TLS13Provider protocol using pure Swift and swift-crypto.
/// Designed specifically for QUIC (no TLS record layer).

import Foundation
import Crypto
import Synchronization
import QUICCore

// MARK: - TLS 1.3 Handler

/// Pure Swift TLS 1.3 implementation for QUIC
public final class TLS13Handler: TLS13Provider, Sendable {

    /// Maximum size for handshake message buffers (64KB per level)
    private static let maxBufferSize = 65536

    private let state = Mutex<HandlerState>(HandlerState())
    private let configuration: TLSConfiguration

    private struct HandlerState: Sendable {
        var isClientMode: Bool = true
        var clientStateMachine: ClientStateMachine?
        var serverStateMachine: ServerStateMachine?
        var localTransportParams: Data?
        var peerTransportParams: Data?
        var negotiatedALPN: String?
        var handshakeComplete: Bool = false

        // Buffer for partial message reassembly (per encryption level)
        var messageBuffers: [EncryptionLevel: Data] = [:]

        // Application secrets for key update
        var clientApplicationSecret: SymmetricKey?
        var serverApplicationSecret: SymmetricKey?
        var keySchedule: TLSKeySchedule = TLSKeySchedule()

        // Exporter master secret (RFC 8446 Section 7.5)
        var exporterMasterSecret: SymmetricKey?

        // Key phase counter (number of key updates performed)
        var keyPhase: UInt8 = 0

        // Session resumption configuration (set before startHandshake)
        var resumptionTicket: SessionTicketData?
        var attemptEarlyData: Bool = false

        // 0-RTT state tracking
        var is0RTTAttempted: Bool = false
        var is0RTTAccepted: Bool = false
    }

    // MARK: - Initialization

    /// Creates a TLS 1.3 handler with the given configuration.
    ///
    /// If the configuration has `certificatePath` and `privateKeyPath` set but
    /// `certificateChain` and `signingKey` are not populated, they will be
    /// loaded lazily when the server processes the first ClientHello.
    ///
    /// - Parameter configuration: TLS configuration
    public init(configuration: TLSConfiguration = TLSConfiguration()) {
        self.configuration = configuration
    }

    // MARK: - TLS13Provider Protocol

    public func startHandshake(isClient: Bool) async throws -> [TLSOutput] {
        return try state.withLock { state in
            state.isClientMode = isClient

            if isClient {
                let clientMachine = ClientStateMachine()
                state.clientStateMachine = clientMachine

                // Pass session ticket and early data flag to ClientStateMachine
                let (clientHello, outputs) = try clientMachine.startHandshake(
                    configuration: configuration,
                    transportParameters: state.localTransportParams ?? Data(),
                    sessionTicket: state.resumptionTicket,
                    attemptEarlyData: state.attemptEarlyData
                )

                // Track if 0-RTT was attempted
                state.is0RTTAttempted = state.attemptEarlyData && state.resumptionTicket != nil

                var result = outputs
                result.insert(.handshakeData(clientHello, level: .initial), at: 0)
                return result
            } else {
                let serverMachine = try ServerStateMachine(configuration: configuration)
                state.serverStateMachine = serverMachine
                return []  // Server waits for ClientHello
            }
        }
    }

    public func processHandshakeData(_ data: Data, at level: EncryptionLevel) async throws -> [TLSOutput] {
        // Phase 1: Synchronous message processing (inside lock).
        // Returns outputs and a flag indicating whether a certificate message
        // was processed (so we can perform async revocation checking outside the lock).
        let (outputs, certificateProcessed) = try state.withLock { state -> ([TLSOutput], Bool) in
            // Append to level-specific buffer
            var buffer = state.messageBuffers[level] ?? Data()
            buffer.append(data)

            // Check buffer size limit to prevent DoS
            guard buffer.count <= Self.maxBufferSize else {
                throw TLSError.internalError("Handshake buffer exceeded maximum size")
            }

            var outputs: [TLSOutput] = []
            var certProcessed = false

            // Process complete messages from buffer
            while buffer.count >= 4 {
                // Parse handshake header
                let (messageType, contentLength) = try HandshakeCodec.decodeHeader(from: buffer)
                let totalLength = 4 + contentLength

                guard buffer.count >= totalLength else {
                    // Need more data
                    if outputs.isEmpty {
                        outputs.append(.needMoreData)
                    }
                    break
                }

                // Extract message content
                let content = buffer.subdata(in: 4..<totalLength)

                // Remove from buffer
                buffer = Data(buffer.dropFirst(totalLength))

                // Process the message
                let messageOutputs = try processMessage(
                    type: messageType,
                    content: content,
                    level: level,
                    state: &state
                )
                outputs.append(contentsOf: messageOutputs)

                // Track if a certificate message was processed
                if messageType == .certificate {
                    certProcessed = true
                }
            }

            // Store updated buffer
            state.messageBuffers[level] = buffer

            return (outputs, certProcessed)
        }

        // Phase 2: Async revocation check (outside lock).
        // Only performed when a certificate was just processed AND
        // revocation checking is configured (not .none).
        if certificateProcessed {
            if case .none = configuration.revocationCheckMode {
                // No revocation checking configured — skip
            } else {
                try await performRevocationCheckIfNeeded()
            }
        }

        return outputs
    }

    public func getLocalTransportParameters() -> Data {
        state.withLock { $0.localTransportParams ?? Data() }
    }

    public func setLocalTransportParameters(_ params: Data) throws {
        state.withLock { $0.localTransportParams = params }
    }

    public func getPeerTransportParameters() -> Data? {
        state.withLock { $0.peerTransportParams }
    }

    public var isHandshakeComplete: Bool {
        state.withLock { $0.handshakeComplete }
    }

    public var isClient: Bool {
        state.withLock { $0.isClientMode }
    }

    public var negotiatedALPN: String? {
        state.withLock { $0.negotiatedALPN }
    }

    public func configureResumption(ticket: SessionTicketData, attemptEarlyData: Bool) throws {
        state.withLock { state in
            state.resumptionTicket = ticket
            state.attemptEarlyData = attemptEarlyData
        }
    }

    public var is0RTTAccepted: Bool {
        state.withLock { $0.is0RTTAccepted }
    }

    public var is0RTTAttempted: Bool {
        state.withLock { $0.is0RTTAttempted }
    }

    /// Peer certificates (raw DER data, leaf certificate first)
    /// Available after receiving peer's Certificate message.
    /// For client mode: returns server's certificates
    /// For server mode (mTLS): returns client's certificates
    public var peerCertificates: [Data]? {
        state.withLock { state -> [Data]? in
            if state.isClientMode {
                return state.clientStateMachine?.peerCertificates
            } else {
                // For server in mTLS, the peer is the client
                // Client certificates are stored in clientCertificates, not peerCertificates
                return state.serverStateMachine?.clientCertificates
            }
        }
    }

    /// Parsed peer leaf certificate
    /// Available after receiving peer's Certificate message.
    /// For client mode: returns server's certificate
    /// For server mode (mTLS): returns client's certificate
    public var peerCertificate: X509Certificate? {
        state.withLock { state -> X509Certificate? in
            if state.isClientMode {
                return state.clientStateMachine?.peerCertificate
            } else {
                // For server in mTLS, the peer is the client
                return state.serverStateMachine?.clientCertificate
            }
        }
    }

    /// Validated peer info from certificate validator callback.
    ///
    /// This contains the value returned by `TLSConfiguration.certificateValidator`
    /// after successful certificate validation (e.g., application-specific peer identity).
    public var validatedPeerInfo: (any Sendable)? {
        state.withLock { state in
            if state.isClientMode {
                return state.clientStateMachine?.validatedPeerInfo
            } else {
                return state.serverStateMachine?.validatedPeerInfo
            }
        }
    }

    // MARK: - Revocation Checking

    /// Performs async revocation checking on the most recently validated certificate chain.
    ///
    /// Called after synchronous certificate processing succeeds and exits the state lock.
    /// Takes (consumes) the validated chain from the appropriate state machine so the
    /// check is performed exactly once per certificate.
    ///
    /// - Throws: `TLSHandshakeError.certificateVerificationFailed` if the certificate is revoked
    private func performRevocationCheckIfNeeded() async throws {
        // Determine which state machine has the validated chain
        let validatedChain: ValidatedChain? = state.withLock { state in
            if state.isClientMode {
                return state.clientStateMachine?.takeValidatedChain()
            } else {
                return state.serverStateMachine?.takeValidatedChain()
            }
        }

        guard let chain = validatedChain else {
            // No validated chain available (e.g., verifyPeer was false,
            // or expectedPeerPublicKey was used). Nothing to check.
            return
        }

        guard let issuer = chain.leafIssuer else {
            // Self-signed or single-cert chain — OCSP/CRL requires an issuer.
            // Skip revocation check.
            return
        }

        let checker = RevocationChecker(
            mode: configuration.revocationCheckMode,
            httpClient: configuration.revocationHTTPClient
        )

        let status = try await checker.checkRevocation(
            chain.leaf,
            issuer: issuer
        )

        switch status {
        case .good, .undetermined:
            // Good or soft-fail: allow the handshake to continue
            return
        case .revoked(let reason, _):
            let reasonStr = reason.map { "\($0)" } ?? "unspecified"
            throw TLSHandshakeError.certificateVerificationFailed(
                "Certificate revoked (reason: \(reasonStr))"
            )
        case .unknown:
            // Unknown status from the responder — treat as failure
            throw TLSHandshakeError.certificateVerificationFailed(
                "Certificate revocation status unknown"
            )
        }
    }

    public func requestKeyUpdate() async throws -> [TLSOutput] {
        // Key update implementation (RFC 9001 Section 6 for QUIC)
        return try state.withLock { state in
            guard state.handshakeComplete else {
                throw TLSError.unexpectedMessage("Cannot request key update before handshake complete")
            }

            guard let currentClientSecret = state.clientApplicationSecret,
                  let currentServerSecret = state.serverApplicationSecret else {
                throw TLSError.internalError("Application secrets not available for key update")
            }

            // Derive next application traffic secrets
            let nextClientSecret = state.keySchedule.nextApplicationSecret(
                from: currentClientSecret
            )
            let nextServerSecret = state.keySchedule.nextApplicationSecret(
                from: currentServerSecret
            )

            // Update stored secrets
            state.clientApplicationSecret = nextClientSecret
            state.serverApplicationSecret = nextServerSecret
            state.keyPhase = (state.keyPhase + 1) % 2  // Toggle key phase bit

            // Get cipher suite from key schedule
            let cipherSuite = state.keySchedule.cipherSuite.toQUICCipherSuite

            return [
                .keysAvailable(KeysAvailableInfo(
                    level: .application,
                    clientSecret: nextClientSecret,
                    serverSecret: nextServerSecret,
                    cipherSuite: cipherSuite
                ))
            ]
        }
    }

    /// Current key phase (0 or 1, toggles with each key update)
    public var keyPhase: UInt8 {
        state.withLock { $0.keyPhase }
    }

    public func exportKeyingMaterial(
        label: String,
        context: Data?,
        length: Int
    ) throws -> Data {
        // RFC 8446 Section 7.5: Exporters
        // 1. Derive-Secret(exporter_master_secret, label, "") = derived_secret
        // 2. HKDF-Expand-Label(derived_secret, "exporter", Hash(context), length)
        try state.withLock { state in
            guard state.handshakeComplete else {
                throw TLSError.unexpectedMessage("Cannot export keying material before handshake complete")
            }

            guard let exporterMasterSecret = state.exporterMasterSecret else {
                throw TLSError.internalError("Exporter master secret not available")
            }

            // Step 1: Derive-Secret(exporter_master_secret, label, "")
            // = HKDF-Expand-Label(exporter_master_secret, label, Hash(""), Hash.length)
            let emptyHash = Data(SHA256.hash(data: Data()))
            let derivedSecret = hkdfExpandLabel(
                secret: exporterMasterSecret,
                label: label,
                context: emptyHash,
                length: 32
            )

            // Step 2: HKDF-Expand-Label(derived_secret, "exporter", Hash(context), length)
            let contextHash = context.map { Data(SHA256.hash(data: $0)) } ?? emptyHash
            let output = hkdfExpandLabel(
                secret: SymmetricKey(data: derivedSecret),
                label: "exporter",
                context: contextHash,
                length: length
            )

            return output
        }
    }

    /// HKDF-Expand-Label helper
    private func hkdfExpandLabel(
        secret: SymmetricKey,
        label: String,
        context: Data,
        length: Int
    ) -> Data {
        let fullLabel = "tls13 " + label
        let labelBytes = Data(fullLabel.utf8)

        var hkdfLabel = Data()
        hkdfLabel.append(UInt8(length >> 8))
        hkdfLabel.append(UInt8(length & 0xFF))
        hkdfLabel.append(UInt8(labelBytes.count))
        hkdfLabel.append(labelBytes)
        hkdfLabel.append(UInt8(context.count))
        hkdfLabel.append(context)

        let output = HKDF<SHA256>.expand(
            pseudoRandomKey: secret,
            info: hkdfLabel,
            outputByteCount: length
        )

        return output.withUnsafeBytes { Data($0) }
    }

    // MARK: - Private Helpers

    /// Validates that a handshake message is received at the correct encryption level
    /// per RFC 9001 Section 4.2
    private func validateEncryptionLevel(
        type: HandshakeType,
        level: EncryptionLevel,
        isClient: Bool
    ) throws {
        let expectedLevel: EncryptionLevel
        switch type {
        case .clientHello, .serverHello:
            expectedLevel = .initial
        case .encryptedExtensions, .certificateRequest, .certificate, .certificateVerify, .finished:
            expectedLevel = .handshake
        case .keyUpdate, .newSessionTicket:
            expectedLevel = .application
        default:
            // Unknown types are handled elsewhere
            return
        }

        guard level == expectedLevel else {
            throw TLSError.unexpectedMessage(
                "Message \(type) received at \(level) level, expected \(expectedLevel)"
            )
        }
    }

    private func processMessage(
        type: HandshakeType,
        content: Data,
        level: EncryptionLevel,
        state: inout HandlerState
    ) throws -> [TLSOutput] {
        // Validate encryption level per RFC 9001
        try validateEncryptionLevel(type: type, level: level, isClient: state.isClientMode)

        if state.isClientMode {
            return try processClientMessage(type: type, content: content, level: level, state: &state)
        } else {
            return try processServerMessage(type: type, content: content, level: level, state: &state)
        }
    }

    private func processClientMessage(
        type: HandshakeType,
        content: Data,
        level: EncryptionLevel,
        state: inout HandlerState
    ) throws -> [TLSOutput] {
        guard let clientMachine = state.clientStateMachine else {
            throw TLSError.internalError("Client state machine not initialized")
        }

        var outputs: [TLSOutput] = []

        switch type {
        case .serverHello:
            outputs = try clientMachine.processServerHello(content)

        case .encryptedExtensions:
            outputs = try clientMachine.processEncryptedExtensions(content)
            // Extract peer transport params
            if let params = clientMachine.peerTransportParameters {
                state.peerTransportParams = params
            }
            // Update 0-RTT acceptance status from client state machine
            if state.is0RTTAttempted {
                state.is0RTTAccepted = clientMachine.earlyDataAccepted
            }

        case .certificateRequest:
            // Server requesting client certificate (mutual TLS)
            outputs = try clientMachine.processCertificateRequest(content)

        case .certificate:
            outputs = try clientMachine.processCertificate(content)

        case .certificateVerify:
            outputs = try clientMachine.processCertificateVerify(content)

        case .finished:
            let (finishedOutputs, clientFinished) = try clientMachine.processServerFinished(content)
            outputs = finishedOutputs

            // Insert client Finished data
            outputs.insert(.handshakeData(clientFinished, level: .handshake), at: 0)

            // Extract application secrets from outputs for key update support
            for output in finishedOutputs {
                if case .keysAvailable(let info) = output, info.level == .application {
                    state.clientApplicationSecret = info.clientSecret
                    state.serverApplicationSecret = info.serverSecret
                }
            }

            // Extract exporter master secret
            state.exporterMasterSecret = clientMachine.exporterMasterSecret

            // Update state
            state.negotiatedALPN = clientMachine.negotiatedALPN
            state.handshakeComplete = true

        default:
            throw TLSError.unexpectedMessage("Unexpected message type \(type) for client")
        }

        return outputs
    }

    private func processServerMessage(
        type: HandshakeType,
        content: Data,
        level: EncryptionLevel,
        state: inout HandlerState
    ) throws -> [TLSOutput] {
        guard let serverMachine = state.serverStateMachine else {
            throw TLSError.internalError("Server state machine not initialized")
        }

        var outputs: [TLSOutput] = []

        switch type {
        case .clientHello:
            let (response, clientHelloOutputs) = try serverMachine.processClientHello(
                content,
                transportParameters: state.localTransportParams ?? Data()
            )
            outputs = clientHelloOutputs

            // Extract peer transport params
            if let params = serverMachine.peerTransportParameters {
                state.peerTransportParams = params
            }

            // Extract application secrets from outputs for key update support
            for output in clientHelloOutputs {
                if case .keysAvailable(let info) = output, info.level == .application {
                    state.clientApplicationSecret = info.clientSecret
                    state.serverApplicationSecret = info.serverSecret
                }
            }

            // Extract exporter master secret
            state.exporterMasterSecret = serverMachine.exporterMasterSecret

            // Add all server messages to outputs
            for (data, msgLevel) in response.messages {
                outputs.insert(.handshakeData(data, level: msgLevel), at: outputs.count - clientHelloOutputs.count)
            }

        case .certificate:
            // Client's certificate (for mutual TLS)
            outputs = try serverMachine.processClientCertificate(content)

        case .certificateVerify:
            // Client's CertificateVerify (for mutual TLS)
            outputs = try serverMachine.processClientCertificateVerify(content)

        case .finished:
            let finishedOutputs = try serverMachine.processClientFinished(content)
            outputs = finishedOutputs

            // Update state
            state.negotiatedALPN = serverMachine.negotiatedALPN
            state.handshakeComplete = true

        default:
            throw TLSError.unexpectedMessage("Unexpected message type \(type) for server")
        }

        return outputs
    }
}
