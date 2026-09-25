/// Server State Machine
///
/// Server-side TLS 1.3 state machine extracted from TLS13Handler.
/// Handles the full server handshake flow including PSK, HRR, and mTLS.

import Foundation
import Crypto
import Synchronization
import QUICCore

// MARK: - Server State Machine

/// Server-side TLS 1.3 state machine
public final class ServerStateMachine: Sendable {

    private let state = Mutex<ServerState>(ServerState())
    private let configuration: TLSConfiguration
    private let sessionTicketStore: SessionTicketStore?

    private struct ServerState: Sendable {
        var handshakeState: ServerHandshakeState = .start
        var context: HandshakeContext = HandshakeContext()
    }

    /// Creates a server state machine with the given configuration.
    ///
    /// If the configuration has `certificatePath` and `privateKeyPath` set but
    /// `certificateChain` and `signingKey` are not populated, this initializer
    /// will attempt to load the certificates and key from the PEM files.
    ///
    /// - Parameters:
    ///   - configuration: TLS configuration (will be resolved to load certificates if needed)
    ///   - sessionTicketStore: Optional session ticket store for resumption
    /// - Throws: `PEMLoader.PEMError` if PEM file loading fails
    public init(configuration: TLSConfiguration, sessionTicketStore: SessionTicketStore? = nil) throws {
        // Resolve configuration by loading certificates from paths if needed
        self.configuration = try configuration.withLoadedCertificates()
        self.sessionTicketStore = sessionTicketStore
    }

    /// Response from processing ClientHello
    public struct ClientHelloResponse: Sendable {
        public let messages: [(Data, EncryptionLevel)]
    }

    /// Process ClientHello and generate server response
    public func processClientHello(
        _ data: Data,
        transportParameters: Data
    ) throws -> (response: ClientHelloResponse, outputs: [TLSOutput]) {
        return try state.withLock { state in
            // Check if this is ClientHello2 (after HelloRetryRequest)
            let isClientHello2 = state.handshakeState == .sentHelloRetryRequest

            guard state.handshakeState == .start || isClientHello2 else {
                throw TLSHandshakeError.unexpectedMessage("Unexpected ClientHello")
            }

            let clientHello = try ClientHello.decode(from: data)

            // Verify TLS 1.3 support
            guard let supportedVersions = clientHello.supportedVersions,
                  supportedVersions.supportsTLS13 else {
                throw TLSHandshakeError.unsupportedVersion
            }

            // Find common cipher suite
            guard clientHello.cipherSuites.contains(.tls_aes_128_gcm_sha256) else {
                throw TLSHandshakeError.noCipherSuiteMatch
            }
            state.context.cipherSuite = .tls_aes_128_gcm_sha256

            // Get client's key share extension
            guard let clientKeyShare = clientHello.keyShare else {
                throw TLSHandshakeError.noKeyShareMatch
            }

            // Negotiate key exchange group
            let serverSupportedGroups = configuration.supportedGroups
            var selectedGroup: NamedGroup?
            var selectedKeyShareEntry: KeyShareEntry?

            if isClientHello2 {
                // ClientHello2: Must use the group we requested in HRR
                guard let requestedGroup = state.context.helloRetryRequestGroup,
                      let entry = clientKeyShare.keyShare(for: requestedGroup) else {
                    throw TLSHandshakeError.noKeyShareMatch
                }
                selectedGroup = requestedGroup
                selectedKeyShareEntry = entry
            } else {
                // ClientHello1: Find first server-preferred group that client offers
                for group in serverSupportedGroups {
                    if let entry = clientKeyShare.keyShare(for: group) {
                        selectedGroup = group
                        selectedKeyShareEntry = entry
                        break
                    }
                }

                // If no matching key share, try to send HelloRetryRequest
                if selectedGroup == nil {
                    // Check if client supports any of our groups
                    let clientSupportedGroups = clientHello.supportedGroups?.namedGroups ?? []
                    if let commonGroup = serverSupportedGroups.first(where: { clientSupportedGroups.contains($0) }) {
                        return try sendHelloRetryRequest(
                            clientHello: clientHello,
                            clientHelloData: data,
                            requestedGroup: commonGroup,
                            state: &state
                        )
                    }
                    throw TLSHandshakeError.noKeyShareMatch
                }
            }

            guard let selectedGroup = selectedGroup,
                  let peerKeyShareEntry = selectedKeyShareEntry else {
                throw TLSHandshakeError.noKeyShareMatch
            }

            // Extract transport parameters (required for QUIC)
            guard let peerTransportParams = clientHello.quicTransportParameters else {
                throw TLSHandshakeError.missingExtension("quic_transport_parameters")
            }
            state.context.peerTransportParameters = peerTransportParams
            state.context.localTransportParameters = transportParameters

            // Store client values
            state.context.clientRandom = clientHello.random
            state.context.sessionID = clientHello.legacySessionID

            // Try PSK validation if offered
            var pskValidationResult: PSKValidationResult = .noPskOffered
            var selectedPskIndex: UInt16? = nil

            if let offeredPsks = clientHello.preSharedKey,
               let store = self.sessionTicketStore {
                // Compute truncated transcript for binder validation
                // ClientHello without binders section
                let clientHelloMessage = HandshakeCodec.encode(type: .clientHello, content: data)
                let bindersSize = offeredPsks.bindersSize
                let truncatedLength = clientHelloMessage.count - bindersSize
                let truncatedTranscript = clientHelloMessage.prefix(truncatedLength)

                // Try each offered PSK identity
                for (index, identity) in offeredPsks.identities.enumerated() {
                    guard let session = store.lookupSession(ticketId: identity.identity) else {
                        continue
                    }

                    // Validate ticket age
                    guard session.isValidAge(obfuscatedAge: identity.obfuscatedTicketAge) else {
                        continue
                    }

                    // Get the corresponding binder
                    guard index < offeredPsks.binders.count else {
                        continue
                    }
                    let binder = offeredPsks.binders[index]

                    // Derive PSK from session using the stored ticket nonce
                    let ticketNonce = session.ticketNonce

                    // Initialize key schedule with PSK
                    var pskKeySchedule = TLSKeySchedule(cipherSuite: session.cipherSuite)
                    let psk = session.derivePSK(ticketNonce: ticketNonce, keySchedule: pskKeySchedule)
                    pskKeySchedule.deriveEarlySecret(psk: psk)

                    // Validate binder
                    if let binderKey = try? pskKeySchedule.deriveBinderKey(isResumption: true) {
                        let helper = PSKBinderHelper(cipherSuite: session.cipherSuite)
                        let binderKeyData = binderKey.withUnsafeBytes { Data($0) }
                        // Use cipher suite's hash algorithm (SHA-256 or SHA-384)
                        let transcriptHash = session.cipherSuite.transcriptHash(of: truncatedTranscript)

                        if helper.isValidBinder(forKey: binderKeyData, transcriptHash: transcriptHash, expected: binder) {
                            // PSK validated successfully
                            selectedPskIndex = UInt16(index)
                            state.context.pskUsed = true
                            state.context.selectedPskIdentity = UInt16(index)
                            state.context.cipherSuite = session.cipherSuite
                            pskValidationResult = .valid(index: UInt16(index), session: session, psk: psk)
                            break
                        }
                    }
                }
            }

            // Update transcript with ClientHello (after PSK validation which needs truncated transcript)
            let clientHelloMessage = HandshakeCodec.encode(type: .clientHello, content: data)
            state.context.transcriptHash.update(with: clientHelloMessage)

            // If PSK was validated, derive early secret in the main key schedule
            if selectedPskIndex != nil,
               case .valid(_, let session, let psk) = pskValidationResult {
                state.context.keySchedule = TLSKeySchedule(cipherSuite: session.cipherSuite)
                state.context.keySchedule.deriveEarlySecret(psk: psk)

                // Check if client offered early_data and session allows it
                if clientHello.earlyData && session.maxEarlyDataSize > 0 {
                    // Check replay protection if configured (RFC 8446 Section 8)
                    // 0-RTT data can be replayed, so servers should track ticket usage
                    var acceptEarlyData = true
                    if let replayProtection = configuration.replayProtection {
                        // Create ticket identifier from ticket nonce (unique per ticket)
                        let ticketIdentifier = ReplayProtection.createIdentifier(from: session.ticketNonce)
                        acceptEarlyData = replayProtection.shouldAcceptEarlyData(ticketIdentifier: ticketIdentifier)
                    }

                    if acceptEarlyData {
                        // Accept early data
                        state.context.earlyDataState.attemptingEarlyData = true
                        state.context.earlyDataState.earlyDataAccepted = true
                        state.context.earlyDataState.maxEarlyDataSize = session.maxEarlyDataSize

                        // Derive client early traffic secret (RFC 8446 Section 7.1)
                        let earlyTranscript = state.context.transcriptHash.currentHash()
                        if let earlyTrafficSecret = try? state.context.keySchedule.deriveClientEarlyTrafficSecret(
                            transcriptHash: earlyTranscript
                        ) {
                            state.context.clientEarlyTrafficSecret = earlyTrafficSecret
                            let secretData = earlyTrafficSecret.withUnsafeBytes { Data($0) }
                            state.context.earlyDataState.clientEarlyTrafficSecret = secretData
                        }
                    }
                    // If replay detected, early data is rejected but handshake continues with 1-RTT
                }
            } else {
                // No PSK - derive early secret with nil PSK
                state.context.keySchedule.deriveEarlySecret(psk: nil)
            }

            // Generate server key pair for selected group
            let serverKeyExchange = try KeyExchange.generate(for: selectedGroup)
            state.context.keyExchange = serverKeyExchange

            // Perform key agreement
            let sharedSecret = try serverKeyExchange.sharedSecret(with: peerKeyShareEntry.keyExchange)
            state.context.sharedSecret = sharedSecret

            // Negotiate ALPN (required for QUIC per RFC 9001)
            guard let clientALPN = clientHello.alpn else {
                throw TLSHandshakeError.noALPNMatch
            }
            if let common = configuration.alpnProtocols.isEmpty ? clientALPN.protocols.first :
                ALPNExtension(protocols: configuration.alpnProtocols).negotiate(with: clientALPN) {
                state.context.negotiatedALPN = common
            } else {
                throw TLSHandshakeError.noALPNMatch
            }

            var messages: [(Data, EncryptionLevel)] = []
            var outputs: [TLSOutput] = []

            // Build ServerHello extensions
            var serverHelloExtensions: [TLSExtension] = [
                .supportedVersionsServer(TLSConstants.version13),
                .keyShareServer(serverKeyExchange.keyShareEntry())
            ]

            // Add pre_shared_key extension if PSK was accepted
            if let pskIndex = selectedPskIndex {
                serverHelloExtensions.append(.preSharedKeyServer(selectedIdentity: pskIndex))
            }

            // Generate ServerHello
            let serverHello = ServerHello(
                legacySessionIDEcho: clientHello.legacySessionID,
                cipherSuite: state.context.cipherSuite ?? .tls_aes_128_gcm_sha256,
                extensions: serverHelloExtensions
            )

            let serverHelloMessage = serverHello.encodeAsHandshake()
            state.context.transcriptHash.update(with: serverHelloMessage)
            messages.append((serverHelloMessage, .initial))

            // Derive handshake secrets
            let transcriptHash = state.context.transcriptHash.currentHash()
            let (clientSecret, serverSecret) = try state.context.keySchedule.deriveHandshakeSecrets(
                sharedSecret: sharedSecret,
                transcriptHash: transcriptHash
            )

            state.context.clientHandshakeSecret = clientSecret
            state.context.serverHandshakeSecret = serverSecret

            // Get cipher suite for packet protection
            let cipherSuite = (state.context.cipherSuite ?? .tls_aes_128_gcm_sha256).toQUICCipherSuite

            outputs.append(.keysAvailable(KeysAvailableInfo(
                level: .handshake,
                clientSecret: clientSecret,
                serverSecret: serverSecret,
                cipherSuite: cipherSuite
            )))

            // Generate EncryptedExtensions
            var eeExtensions: [TLSExtension] = []
            if let alpn = state.context.negotiatedALPN {
                eeExtensions.append(.alpn(ALPNExtension(protocols: [alpn])))
            }
            eeExtensions.append(.quicTransportParameters(transportParameters))

            // Add early_data extension if we accepted it (RFC 8446 Section 4.2.10)
            if state.context.earlyDataState.earlyDataAccepted {
                eeExtensions.append(.earlyData(.encryptedExtensions))

                // Output 0-RTT keys
                if let earlyTrafficSecret = state.context.clientEarlyTrafficSecret {
                    outputs.append(.keysAvailable(KeysAvailableInfo(
                        level: .zeroRTT,
                        clientSecret: earlyTrafficSecret,
                        serverSecret: nil,  // Server doesn't send 0-RTT
                        cipherSuite: cipherSuite
                    )))
                }
            }

            let encryptedExtensions = EncryptedExtensions(extensions: eeExtensions)
            let eeMessage = encryptedExtensions.encodeAsHandshake()
            state.context.transcriptHash.update(with: eeMessage)
            messages.append((eeMessage, .handshake))

            // Send CertificateRequest if mutual TLS is required (RFC 8446 Section 4.3.2)
            // CertificateRequest is sent after EncryptedExtensions, before Certificate
            // Only for non-PSK handshakes (PSK implies pre-established identity)
            if !state.context.pskUsed && self.configuration.requireClientCertificate {
                let certRequest = CertificateRequest.withDefaultSignatureAlgorithms()
                let crMessage = certRequest.encodeAsHandshake()
                state.context.transcriptHash.update(with: crMessage)
                messages.append((crMessage, .handshake))

                // Remember we requested client certificate
                state.context.expectingClientCertificate = true
            }

            // Generate Certificate and CertificateVerify for non-PSK handshakes
            // RFC 8446 Section 4.4.2: Server MUST send Certificate in non-PSK handshakes
            if !state.context.pskUsed {
                guard let signingKey = self.configuration.signingKey,
                      let certChain = self.configuration.certificateChain,
                      !certChain.isEmpty else {
                    throw TLSHandshakeError.certificateRequired
                }

                // Generate Certificate message
                let certificate = Certificate(certificates: certChain)
                let certMessage = certificate.encodeAsHandshake()
                state.context.transcriptHash.update(with: certMessage)
                messages.append((certMessage, .handshake))

                // Generate CertificateVerify signature
                // The signature is over the transcript up to (but not including) CertificateVerify
                let transcriptForCV = state.context.transcriptHash.currentHash()
                let signatureContent = CertificateVerify.constructSignatureContent(
                    transcriptHash: transcriptForCV,
                    isServer: true
                )

                let signature = try signingKey.sign(signatureContent)
                let certificateVerify = CertificateVerify(
                    algorithm: signingKey.scheme,
                    signature: signature
                )
                let cvMessage = certificateVerify.encodeAsHandshake()
                state.context.transcriptHash.update(with: cvMessage)
                messages.append((cvMessage, .handshake))
            }

            // Generate server Finished
            let serverFinishedKey = state.context.keySchedule.finishedKey(from: serverSecret)
            let finishedTranscript = state.context.transcriptHash.currentHash()
            let serverVerifyData = state.context.keySchedule.finishedVerifyData(
                forKey: serverFinishedKey,
                transcriptHash: finishedTranscript
            )

            let serverFinished = Finished(verifyData: serverVerifyData)
            let serverFinishedMessage = serverFinished.encodeAsHandshake()
            state.context.transcriptHash.update(with: serverFinishedMessage)
            messages.append((serverFinishedMessage, .handshake))

            // Derive application secrets
            let appTranscriptHash = state.context.transcriptHash.currentHash()
            let (clientAppSecret, serverAppSecret) = try state.context.keySchedule.deriveApplicationSecrets(
                transcriptHash: appTranscriptHash
            )

            state.context.clientApplicationSecret = clientAppSecret
            state.context.serverApplicationSecret = serverAppSecret

            // Derive exporter master secret
            let exporterMasterSecret = try state.context.keySchedule.deriveExporterMasterSecret(
                transcriptHash: appTranscriptHash
            )
            state.context.exporterMasterSecret = exporterMasterSecret

            outputs.append(.keysAvailable(KeysAvailableInfo(
                level: .application,
                clientSecret: clientAppSecret,
                serverSecret: serverAppSecret,
                cipherSuite: cipherSuite
            )))

            // Transition state - wait for client certificate if we requested it
            if state.context.expectingClientCertificate {
                state.handshakeState = .waitClientCertificate
            } else {
                state.handshakeState = .waitFinished
            }

            return (ClientHelloResponse(messages: messages), outputs)
        }
    }

    /// Send HelloRetryRequest when client's key_share doesn't contain a supported group
    /// RFC 8446 Section 4.1.4
    private func sendHelloRetryRequest(
        clientHello: ClientHello,
        clientHelloData: Data,
        requestedGroup: NamedGroup,
        state: inout ServerState
    ) throws -> (response: ClientHelloResponse, outputs: [TLSOutput]) {
        // Prevent multiple HRRs (RFC 8446: at most one HRR per connection)
        guard !state.context.sentHelloRetryRequest else {
            throw TLSHandshakeError.unexpectedMessage("Multiple HelloRetryRequest not allowed")
        }

        // Mark that we're sending HRR
        state.context.sentHelloRetryRequest = true
        state.context.helloRetryRequestGroup = requestedGroup

        // RFC 8446 Section 4.4.1: Transcript hash special handling for HRR
        // First, compute hash of ClientHello1
        let clientHelloMessage = HandshakeCodec.encode(type: .clientHello, content: clientHelloData)
        state.context.transcriptHash.update(with: clientHelloMessage)
        let ch1Hash = state.context.transcriptHash.currentHash()

        // Replace transcript with message_hash synthetic message
        // message_hash = Handshake(254) + 00 00 Hash.length + Hash(ClientHello1)
        state.context.transcriptHash = TranscriptHash.fromMessageHash(
            clientHello1Hash: ch1Hash,
            cipherSuite: .tls_aes_128_gcm_sha256
        )

        // Generate HelloRetryRequest
        // HRR is a ServerHello with special random (SHA-256 of "HelloRetryRequest")
        let hrr = ServerHello.helloRetryRequest(
            legacySessionIDEcho: clientHello.legacySessionID,
            cipherSuite: .tls_aes_128_gcm_sha256,
            extensions: [
                .supportedVersionsServer(TLSConstants.version13),
                .keyShare(.helloRetryRequest(KeyShareHelloRetryRequest(selectedGroup: requestedGroup)))
            ]
        )

        let hrrMessage = hrr.encodeAsHandshake()
        state.context.transcriptHash.update(with: hrrMessage)

        // Store cipher suite for later
        state.context.cipherSuite = .tls_aes_128_gcm_sha256

        // Transition state to wait for ClientHello2
        state.handshakeState = .sentHelloRetryRequest

        return (
            ClientHelloResponse(messages: [(hrrMessage, .initial)]),
            []  // No keys available yet, handshake continues after ClientHello2
        )
    }

    /// Process client Certificate message (for mutual TLS)
    ///
    /// RFC 8446 Section 4.4.2: Client sends Certificate in response to CertificateRequest.
    /// The certificate_request_context MUST match what was sent in CertificateRequest.
    public func processClientCertificate(_ data: Data) throws -> [TLSOutput] {
        return try state.withLock { state in
            guard state.handshakeState == .waitClientCertificate else {
                throw TLSHandshakeError.unexpectedMessage("Unexpected client Certificate")
            }

            let certificate = try Certificate.decode(from: data)

            // Verify certificate_request_context matches (should be empty for post-handshake auth)
            // For initial handshake, context is typically empty

            // Check if client sent any certificates
            guard !certificate.certificates.isEmpty else {
                // Client sent empty certificate - fail if we require client auth
                if configuration.requireClientCertificate {
                    throw TLSHandshakeError.certificateRequired
                }
                // No client cert, skip to waiting for Finished
                state.handshakeState = .waitFinished

                // Update transcript
                let message = HandshakeCodec.encode(type: .certificate, content: data)
                state.context.transcriptHash.update(with: message)

                return []
            }

            // Store client certificates
            state.context.clientCertificates = certificate.certificates

            // Parse leaf certificate for verification
            guard let leafCertData = certificate.certificates.first else {
                throw TLSHandshakeError.certificateVerificationFailed("No leaf certificate")
            }

            let leafCert: X509Certificate
            do {
                leafCert = try X509Certificate.parse(from: leafCertData)
            } catch {
                throw TLSHandshakeError.certificateVerificationFailed("Failed to parse client certificate: \(error)")
            }
            state.context.clientCertificate = leafCert

            // ================================================================
            // GAP-1 FIX: X.509 chain validation for client certificates (mTLS)
            //
            // RFC 5280 Section 4.2.1.12: Client certificates used for TLS
            // client authentication MUST have the id-kp-clientAuth EKU.
            //
            // Previously only the public key was extracted without any chain
            // or policy validation. This mirrors the validation performed in
            // ClientStateMachine.processCertificate() for server certificates.
            // ================================================================
            if configuration.verifyPeer {
                // Parse intermediate certificates
                let intermediateCerts: [X509Certificate] = try certificate.certificates.dropFirst().compactMap { certData in
                    try X509Certificate.parse(from: certData)
                }

                // Set up validation options for client certificate
                var validationOptions = X509ValidationOptions()
                validationOptions.allowSelfSigned = configuration.allowSelfSigned
                // RFC 5280 Section 4.2.1.12: clientAuth EKU required for mTLS
                validationOptions.requiredEKU = .clientAuth
                // No hostname validation for client certificates (clients don't have hostnames)
                validationOptions.hostname = nil

                // Create validator with effective trusted roots.
                // effectiveTrustedRoots resolves trustedRootCertificates first,
                // then falls back to parsing trustedCACertificates (DER) if set.
                let validator = X509Validator(
                    trustedRoots: configuration.effectiveTrustedRoots,
                    options: validationOptions
                )

                // Validate the certificate chain and store the validated chain
                // for subsequent revocation checking (Phase B integration).
                do {
                    let validatedChain = try validator.buildValidatedChain(
                        certificate: leafCert,
                        intermediates: intermediateCerts
                    )
                    // Store chain for async revocation check
                    state.context.validatedChain = validatedChain
                } catch let error as X509Error {
                    throw TLSHandshakeError.certificateVerificationFailed(
                        "Client certificate validation failed: \(error.description)"
                    )
                }
            }

            // Extract verification key from certificate
            do {
                state.context.clientVerificationKey = try leafCert.extractPublicKey()
            } catch {
                throw TLSHandshakeError.certificateVerificationFailed(
                    "Failed to extract public key from client certificate: \(error)"
                )
            }

            // Update transcript
            let message = HandshakeCodec.encode(type: .certificate, content: data)
            state.context.transcriptHash.update(with: message)

            // Transition to wait for CertificateVerify
            state.handshakeState = .waitClientCertificateVerify

            return []
        }
    }

    /// Process client CertificateVerify message (for mutual TLS)
    ///
    /// RFC 8446 Section 4.4.3: Verifies client's signature over the transcript.
    /// The signature context is "TLS 1.3, client CertificateVerify".
    public func processClientCertificateVerify(_ data: Data) throws -> [TLSOutput] {
        return try state.withLock { state in
            guard state.handshakeState == .waitClientCertificateVerify else {
                throw TLSHandshakeError.unexpectedMessage("Unexpected client CertificateVerify")
            }

            let certificateVerify = try CertificateVerify.decode(from: data)

            // Get verification key from client's certificate
            guard let verificationKey = state.context.clientVerificationKey else {
                throw TLSHandshakeError.internalError("Missing client verification key")
            }

            // Verify the signature scheme matches the key type
            guard verificationKey.scheme == certificateVerify.algorithm else {
                throw TLSHandshakeError.signatureVerificationFailed
            }

            // Construct signature content (transcript hash + context string)
            // isServer: false because this is CLIENT's CertificateVerify
            let transcriptHash = state.context.transcriptHash.currentHash()
            let signatureContent = TLSSignature.certificateVerifyContent(
                transcriptHash: transcriptHash,
                isServer: false
            )

            // Verify signature
            let isValid = try verificationKey.verify(
                signature: certificateVerify.signature,
                for: signatureContent
            )

            guard isValid else {
                throw TLSHandshakeError.signatureVerificationFailed
            }

            // Update transcript AFTER using it for signature verification
            let message = HandshakeCodec.encode(type: .certificateVerify, content: data)
            state.context.transcriptHash.update(with: message)

            // Call custom certificate validator if configured
            if let validator = configuration.certificateValidator,
               let clientCerts = state.context.clientCertificates {
                let peerInfo = try validator(clientCerts)
                state.context.validatedPeerInfo = peerInfo
            }

            // Transition to wait for Finished
            state.handshakeState = .waitFinished

            return []
        }
    }

    /// Process client Finished message
    public func processClientFinished(_ data: Data) throws -> [TLSOutput] {
        return try state.withLock { state in
            guard state.handshakeState == .waitFinished else {
                throw TLSHandshakeError.unexpectedMessage("Unexpected client Finished")
            }

            let clientFinished = try Finished.decode(from: data)

            // Verify client Finished
            guard let clientHandshakeSecret = state.context.clientHandshakeSecret else {
                throw TLSHandshakeError.internalError("Missing client handshake secret")
            }

            let clientFinishedKey = state.context.keySchedule.finishedKey(from: clientHandshakeSecret)
            let transcriptHash = state.context.transcriptHash.currentHash()
            let expectedVerifyData = state.context.keySchedule.finishedVerifyData(
                forKey: clientFinishedKey,
                transcriptHash: transcriptHash
            )

            guard clientFinished.verify(expected: expectedVerifyData) else {
                throw TLSHandshakeError.finishedVerificationFailed
            }

            // Update transcript
            let message = HandshakeCodec.encode(type: .finished, content: data)
            state.context.transcriptHash.update(with: message)

            // Derive resumption master secret (RFC 8446 Section 7.1)
            let resumptionTranscript = state.context.transcriptHash.currentHash()
            let resumptionMasterSecret = try state.context.keySchedule.deriveResumptionMasterSecret(
                transcriptHash: resumptionTranscript
            )
            state.context.resumptionMasterSecret = resumptionMasterSecret

            // Transition state
            state.handshakeState = .connected

            return [
                .handshakeComplete(HandshakeCompleteInfo(
                    alpn: state.context.negotiatedALPN,
                    zeroRTTAccepted: state.context.earlyDataState.earlyDataAccepted,
                    resumptionTicket: nil
                ))
            ]
        }
    }

    /// Generate a NewSessionTicket for the client
    /// Call this after handshake completion to enable session resumption
    public func generateNewSessionTicket(
        maxEarlyDataSize: UInt32 = 0,
        lifetime: UInt32 = 86400
    ) throws -> (ticket: NewSessionTicket, data: Data) {
        return try state.withLock { state in
            guard state.handshakeState == .connected else {
                throw TLSHandshakeError.internalError("Cannot generate ticket before handshake completion")
            }

            guard let store = sessionTicketStore else {
                throw TLSHandshakeError.internalError("No session ticket store configured")
            }

            guard let resumptionMasterSecret = state.context.resumptionMasterSecret else {
                throw TLSHandshakeError.internalError("Missing resumption master secret")
            }

            // Generate random ticket_age_add
            var rng = SystemRandomNumberGenerator()
            let ticketAgeAdd = UInt32.random(in: UInt32.min...UInt32.max, using: &rng)

            // Create stored session
            let session = SessionTicketStore.StoredSession(
                resumptionMasterSecret: resumptionMasterSecret,
                cipherSuite: state.context.cipherSuite ?? .tls_aes_128_gcm_sha256,
                lifetime: lifetime,
                ticketAgeAdd: ticketAgeAdd,
                alpn: state.context.negotiatedALPN,
                maxEarlyDataSize: maxEarlyDataSize
            )

            // Generate ticket through store
            let ticket = store.generateTicket(for: session)

            // Encode as handshake message
            let ticketData = ticket.encodeMessage()

            return (ticket, ticketData)
        }
    }

    /// Negotiated ALPN protocol
    public var negotiatedALPN: String? {
        state.withLock { $0.context.negotiatedALPN }
    }

    /// Peer transport parameters
    public var peerTransportParameters: Data? {
        state.withLock { $0.context.peerTransportParameters }
    }

    /// Whether handshake is complete
    public var isConnected: Bool {
        state.withLock { $0.handshakeState == .connected }
    }

    /// Exporter master secret (available after handshake completion)
    public var exporterMasterSecret: SymmetricKey? {
        state.withLock { $0.context.exporterMasterSecret }
    }

    /// Whether PSK was used for authentication
    public var pskUsed: Bool {
        state.withLock { $0.context.pskUsed }
    }

    /// Resumption master secret (available after handshake completion)
    public var resumptionMasterSecret: SymmetricKey? {
        state.withLock { $0.context.resumptionMasterSecret }
    }

    /// Peer certificates (raw DER data, leaf certificate first)
    public var peerCertificates: [Data]? {
        state.withLock { $0.context.peerCertificates }
    }

    /// Validated peer info from certificate validator callback.
    ///
    /// This contains the value returned by `TLSConfiguration.certificateValidator`
    /// after successful certificate validation (e.g., application-specific peer identity).
    public var validatedPeerInfo: (any Sendable)? {
        state.withLock { $0.context.validatedPeerInfo }
    }

    /// Client certificates received from peer (server-side, for mTLS).
    public var clientCertificates: [Data]? {
        state.withLock { $0.context.clientCertificates }
    }

    /// Parsed client leaf certificate (server-side, for mTLS).
    public var clientCertificate: X509Certificate? {
        state.withLock { $0.context.clientCertificate }
    }

    /// Parsed peer leaf certificate
    public var peerCertificate: X509Certificate? {
        state.withLock { $0.context.peerCertificate }
    }

    /// The validated certificate chain from the most recent client certificate processing.
    ///
    /// Available after `processClientCertificate()` succeeds with `verifyPeer == true`.
    /// Used by `TLS13Handler` to perform async revocation checks.
    public var validatedChain: ValidatedChain? {
        state.withLock { $0.context.validatedChain }
    }

    /// Takes (removes and returns) the validated chain from context.
    ///
    /// This ensures the revocation check is performed exactly once per
    /// certificate processing — the chain is consumed on first access.
    public func takeValidatedChain() -> ValidatedChain? {
        state.withLock { state in
            let chain = state.context.validatedChain
            state.context.validatedChain = nil
            return chain
        }
    }
}

// MARK: - Cipher Suite Conversion

extension CipherSuite {
    /// Converts TLS CipherSuite to QUICCipherSuite for packet protection
    public var toQUICCipherSuite: QUICCipherSuite {
        switch self {
        case .tls_chacha20_poly1305_sha256:
            return .chacha20Poly1305Sha256
        case .tls_aes_128_gcm_sha256, .tls_aes_256_gcm_sha384:
            // AES-256-GCM uses SHA-384 for TLS key derivation but
            // QUIC packet protection still uses AES-128-GCM key sizes
            // per RFC 9001 (QUIC only supports AES-128-GCM and ChaCha20)
            return .aes128GcmSha256
        }
    }

    /// Computes transcript hash using the appropriate hash algorithm for this cipher suite
    ///
    /// RFC 8446 Section 4.4.1: The Hash function used for transcript hashing
    /// is the one associated with the cipher suite.
    /// - AES-128-GCM-SHA256, ChaCha20-Poly1305-SHA256: SHA-256
    /// - AES-256-GCM-SHA384: SHA-384
    func transcriptHash(of data: Data) -> Data {
        switch self {
        case .tls_aes_256_gcm_sha384:
            return Data(SHA384.hash(data: data))
        case .tls_aes_128_gcm_sha256, .tls_chacha20_poly1305_sha256:
            return Data(SHA256.hash(data: data))
        }
    }
}