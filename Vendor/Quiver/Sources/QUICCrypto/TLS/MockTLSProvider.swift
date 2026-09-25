/// Mock TLS 1.3 Provider for Testing
///
/// A mock implementation of TLS13Provider that simulates
/// TLS handshake for testing QUIC without a real TLS stack.
///
/// - Warning: This provider is only available in DEBUG builds.
///   It provides no security and must never be used in production.

import Foundation
import Crypto
import Synchronization
import QUICCore

#if DEBUG

// MARK: - Mock TLS Provider

/// Mock TLS provider for testing QUIC handshake flow
///
/// This mock simulates the TLS 1.3 handshake without actual cryptographic
/// operations. It generates deterministic secrets for testing and allows
/// configuration of various scenarios.
///
/// - Warning: This class is only available in DEBUG builds.
///   Never use MockTLSProvider in production code.
public final class MockTLSProvider: TLS13Provider, Sendable {
    /// Internal state
    private let state: Mutex<MockTLSState>

    /// Configuration
    private let configuration: TLSConfiguration

    /// Whether to simulate handshake completion immediately
    private let immediateCompletion: Bool

    /// Simulated handshake delay (for async testing)
    private let simulatedDelay: Duration?

    // MARK: - Initialization

    /// Creates a mock TLS provider
    /// - Parameters:
    ///   - configuration: TLS configuration
    ///   - immediateCompletion: If true, handshake completes in one round trip
    ///   - simulatedDelay: Optional delay to simulate network latency
    public init(
        configuration: TLSConfiguration = TLSConfiguration(),
        immediateCompletion: Bool = true,
        simulatedDelay: Duration? = nil
    ) {
        self.configuration = configuration
        self.immediateCompletion = immediateCompletion
        self.simulatedDelay = simulatedDelay
        self.state = Mutex(MockTLSState())
    }

    // MARK: - TLS13Provider Protocol

    public func startHandshake(isClient: Bool) async throws -> [TLSOutput] {
        if let delay = simulatedDelay {
            try await Task.sleep(for: delay)
        }

        // Get local transport params and forceComplete status before acquiring the lock
        let (localParams, wasForceCompleted) = state.withLock {
            ($0.localTransportParameters, $0.handshakeComplete)
        }

        return state.withLock { state in
            state.isClient = isClient
            state.handshakeStarted = true

            var outputs: [TLSOutput] = []

            // If forceComplete() was called before startHandshake(), return all outputs
            // needed to complete the handshake immediately
            if wasForceCompleted {
                // Derive keys
                let handshakeClientSecret = generateDeterministicSecret(label: "client_hs")
                let handshakeServerSecret = generateDeterministicSecret(label: "server_hs")
                outputs.append(.keysAvailable(KeysAvailableInfo(
                    level: .handshake,
                    clientSecret: handshakeClientSecret,
                    serverSecret: handshakeServerSecret
                )))

                let appClientSecret = generateDeterministicSecret(label: "client_app")
                let appServerSecret = generateDeterministicSecret(label: "server_app")
                outputs.append(.keysAvailable(KeysAvailableInfo(
                    level: .application,
                    clientSecret: appClientSecret,
                    serverSecret: appServerSecret
                )))

                // Set mock peer transport parameters
                state.peerTransportParameters = generateMockPeerTransportParameters()
                state.negotiatedALPN = configuration.alpnProtocols.first

                outputs.append(.handshakeComplete(HandshakeCompleteInfo(
                    alpn: state.negotiatedALPN,
                    zeroRTTAccepted: false,
                    resumptionTicket: nil
                )))

                return outputs
            }

            if isClient {
                // Client: Generate ClientHello (pass params to avoid nested lock)
                let clientHello = generateMockClientHello(localParams: localParams)
                outputs.append(.handshakeData(clientHello, level: .initial))
            }

            return outputs
        }
    }

    public func processHandshakeData(_ data: Data, at level: EncryptionLevel) async throws -> [TLSOutput] {
        if let delay = simulatedDelay {
            try await Task.sleep(for: delay)
        }

        return state.withLock { state in
            var outputs: [TLSOutput] = []

            if state.isClient {
                // Client processing server messages
                outputs.append(contentsOf: processAsClient(&state, data: data, level: level))
            } else {
                // Server processing client messages
                outputs.append(contentsOf: processAsServer(&state, data: data, level: level))
            }

            return outputs
        }
    }

    public func getLocalTransportParameters() -> Data {
        state.withLock { state in
            state.localTransportParameters ?? Data()
        }
    }

    public func setLocalTransportParameters(_ params: Data) throws {
        state.withLock { state in
            state.localTransportParameters = params
        }
    }

    public func getPeerTransportParameters() -> Data? {
        state.withLock { state in
            state.peerTransportParameters
        }
    }

    public var isHandshakeComplete: Bool {
        state.withLock { $0.handshakeComplete }
    }

    public var isClient: Bool {
        state.withLock { $0.isClient }
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

    public func requestKeyUpdate() async throws -> [TLSOutput] {
        state.withLock { state in
            state.keyUpdateCount += 1

            // Generate new application secrets
            let newClientSecret = generateDeterministicSecret(
                label: "client_app_\(state.keyUpdateCount)"
            )
            let newServerSecret = generateDeterministicSecret(
                label: "server_app_\(state.keyUpdateCount)"
            )

            return [
                .keysAvailable(KeysAvailableInfo(
                    level: .application,
                    clientSecret: newClientSecret,
                    serverSecret: newServerSecret
                ))
            ]
        }
    }

    public func exportKeyingMaterial(
        label: String,
        context: Data?,
        length: Int
    ) throws -> Data {
        // Generate deterministic keying material based on label
        let seed = label + (context.map { $0.base64EncodedString() } ?? "")
        return generateDeterministicData(seed: seed, length: length)
    }

    // MARK: - Mock Specific Methods

    /// Sets peer transport parameters (for testing)
    public func setPeerTransportParameters(_ params: Data) {
        state.withLock { state in
            state.peerTransportParameters = params
        }
    }

    /// Forces handshake completion (for testing)
    ///
    /// Sets the handshake as complete and generates proper peer transport parameters
    /// using RFC 9000 compliant encoding. This ensures that:
    /// 1. `isHandshakeComplete` returns true
    /// 2. `getPeerTransportParameters()` returns valid encoded parameters
    /// 3. Stream limits are properly configured (initialMaxStreamsBidi = 100, etc.)
    public func forceComplete() {
        state.withLock { state in
            state.handshakeComplete = true
            // Set peer transport parameters with RFC-compliant encoding
            // This is critical for stream opening to work (stream limit checks)
            if state.peerTransportParameters == nil {
                state.peerTransportParameters = generateMockPeerTransportParameters()
            }
            state.negotiatedALPN = configuration.alpnProtocols.first
        }
    }

    /// Resets the mock state
    public func reset() {
        state.withLock { state in
            state = MockTLSState()
        }
    }

    // MARK: - Private Helpers

    private func processAsClient(
        _ state: inout MockTLSState,
        data: Data,
        level: EncryptionLevel
    ) -> [TLSOutput] {
        var outputs: [TLSOutput] = []

        switch level {
        case .initial:
            // Received ServerHello - derive handshake keys
            let handshakeClientSecret = generateDeterministicSecret(label: "client_hs")
            let handshakeServerSecret = generateDeterministicSecret(label: "server_hs")

            outputs.append(.keysAvailable(KeysAvailableInfo(
                level: .handshake,
                clientSecret: handshakeClientSecret,
                serverSecret: handshakeServerSecret
            )))

            state.handshakeKeysAvailable = true

        case .handshake:
            // Received EncryptedExtensions, Certificate, etc.
            // Extract transport parameters from "server" data
            state.peerTransportParameters = extractMockTransportParameters(from: data)

            if immediateCompletion {
                // Generate Finished and application keys
                let clientFinished = generateMockFinished()
                outputs.append(.handshakeData(clientFinished, level: .handshake))

                let appClientSecret = generateDeterministicSecret(label: "client_app")
                let appServerSecret = generateDeterministicSecret(label: "server_app")

                outputs.append(.keysAvailable(KeysAvailableInfo(
                    level: .application,
                    clientSecret: appClientSecret,
                    serverSecret: appServerSecret
                )))

                state.handshakeComplete = true
                state.negotiatedALPN = configuration.alpnProtocols.first

                outputs.append(.handshakeComplete(HandshakeCompleteInfo(
                    alpn: state.negotiatedALPN,
                    zeroRTTAccepted: false,
                    resumptionTicket: nil
                )))
            }

        case .application:
            // Post-handshake messages (NewSessionTicket, etc.)
            break

        default:
            break
        }

        return outputs
    }

    private func processAsServer(
        _ state: inout MockTLSState,
        data: Data,
        level: EncryptionLevel
    ) -> [TLSOutput] {
        var outputs: [TLSOutput] = []

        switch level {
        case .initial:
            // Received ClientHello
            state.peerTransportParameters = extractMockTransportParameters(from: data)

            // Send ServerHello
            let serverHello = generateMockServerHello()
            outputs.append(.handshakeData(serverHello, level: .initial))

            // Derive handshake keys
            let handshakeClientSecret = generateDeterministicSecret(label: "client_hs")
            let handshakeServerSecret = generateDeterministicSecret(label: "server_hs")

            outputs.append(.keysAvailable(KeysAvailableInfo(
                level: .handshake,
                clientSecret: handshakeClientSecret,
                serverSecret: handshakeServerSecret
            )))

            state.handshakeKeysAvailable = true

            // Send EncryptedExtensions, Certificate, CertificateVerify, Finished
            let handshakeMessages = generateMockServerHandshakeMessages(localParams: state.localTransportParameters)
            outputs.append(.handshakeData(handshakeMessages, level: .handshake))

            if immediateCompletion {
                // Derive application keys
                let appClientSecret = generateDeterministicSecret(label: "client_app")
                let appServerSecret = generateDeterministicSecret(label: "server_app")

                outputs.append(.keysAvailable(KeysAvailableInfo(
                    level: .application,
                    clientSecret: appClientSecret,
                    serverSecret: appServerSecret
                )))
            }

        case .handshake:
            // Received client Finished
            if !state.handshakeComplete {
                state.handshakeComplete = true
                state.negotiatedALPN = configuration.alpnProtocols.first

                if !immediateCompletion {
                    let appClientSecret = generateDeterministicSecret(label: "client_app")
                    let appServerSecret = generateDeterministicSecret(label: "server_app")

                    outputs.append(.keysAvailable(KeysAvailableInfo(
                        level: .application,
                        clientSecret: appClientSecret,
                        serverSecret: appServerSecret
                    )))
                }

                outputs.append(.handshakeComplete(HandshakeCompleteInfo(
                    alpn: state.negotiatedALPN,
                    zeroRTTAccepted: false,
                    resumptionTicket: nil
                )))
            }

        case .application:
            break

        default:
            break
        }

        return outputs
    }

    /// Header markers used in mock TLS messages
    private static let clientHelloMarker = Data("MOCK_CLIENT_HELLO".utf8)       // 17 bytes
    private static let serverHelloMarker = Data("MOCK_SERVER_HELLO".utf8)       // 17 bytes
    private static let encExtMarker = Data("MOCK_ENCRYPTED_EXTENSIONS".utf8)    // 25 bytes
    private static let certificateMarker = Data("MOCK_CERTIFICATE".utf8)        // 16 bytes
    private static let certVerifyMarker = Data("MOCK_CERT_VERIFY".utf8)         // 15 bytes
    private static let finishedMarker = Data("MOCK_FINISHED".utf8)              // 13 bytes
    private static let clientFinishedMarker = Data("MOCK_CLIENT_FINISHED".utf8) // 20 bytes

    /// Appends a length-prefixed transport parameter block to a Data buffer.
    /// Format: [4-byte big-endian length][transport parameter bytes]
    private func appendLengthPrefixedParams(_ buffer: inout Data, params: Data?) {
        if let params = params {
            var len = UInt32(params.count).bigEndian
            buffer.append(Data(bytes: &len, count: 4))
            buffer.append(params)
        } else {
            // Zero-length block
            buffer.append(contentsOf: [0, 0, 0, 0])
        }
    }

    /// Reads a length-prefixed transport parameter block from `data`,
    /// starting at byte offset `headerLength` (relative to the first byte).
    /// Returns the extracted parameters, or empty Data on failure.
    private func readLengthPrefixedParams(from data: Data, headerLength: Int) -> Data {
        // We need at least header + 4-byte length field
        guard data.count >= headerLength + 4 else { return Data() }

        // Use dropFirst for correct behaviour with Data slices whose startIndex != 0
        let afterHeader = Data(data.dropFirst(headerLength))
        guard afterHeader.count >= 4 else { return Data() }

        // Read 4-byte big-endian length
        let length: Int = afterHeader.withUnsafeBytes { buf in
            Int(UInt32(bigEndian: buf.load(as: UInt32.self)))
        }
        guard length > 0, afterHeader.count >= 4 + length else { return Data() }

        return Data(afterHeader.dropFirst(4).prefix(length))
    }

    private func generateMockClientHello(localParams: Data?) -> Data {
        // Format: "MOCK_CLIENT_HELLO" | len(4) | params
        var data = Self.clientHelloMarker
        appendLengthPrefixedParams(&data, params: localParams)
        return data
    }

    private func generateMockServerHello() -> Data {
        Self.serverHelloMarker
    }

    private func generateMockServerHandshakeMessages(localParams: Data?) -> Data {
        // Format: "MOCK_ENCRYPTED_EXTENSIONS" | len(4) | params | "MOCK_CERTIFICATE" | "MOCK_CERT_VERIFY" | "MOCK_FINISHED"
        var data = Self.encExtMarker
        appendLengthPrefixedParams(&data, params: localParams)
        data.append(Self.certificateMarker)
        data.append(Self.certVerifyMarker)
        data.append(Self.finishedMarker)
        return data
    }

    private func generateMockFinished() -> Data {
        Self.clientFinishedMarker
    }

    private func extractMockTransportParameters(from data: Data) -> Data {
        // Detect which mock message this is and extract the length-prefixed params.
        // Use prefix comparison via dropFirst-safe slicing.
        let bytes = Data(data) // normalise to startIndex == 0

        if bytes.count >= Self.encExtMarker.count,
           bytes.prefix(Self.encExtMarker.count) == Self.encExtMarker {
            // Server handshake message – header is 25 bytes
            return readLengthPrefixedParams(from: bytes, headerLength: Self.encExtMarker.count)
        }

        if bytes.count >= Self.clientHelloMarker.count,
           bytes.prefix(Self.clientHelloMarker.count) == Self.clientHelloMarker {
            // Client hello – header is 17 bytes
            return readLengthPrefixedParams(from: bytes, headerLength: Self.clientHelloMarker.count)
        }

        // Unknown format – return empty
        return Data()
    }

    private func generateMockPeerTransportParameters() -> Data {
        // Generate mock peer transport parameters with RFC 9000 compliant encoding
        // Uses TransportParameterCodec for proper wire format that can be decoded
        // by ManagedConnection when processing handshake completion
        let params = TransportParameters()  // Uses default values with stream limits
        return TransportParameterCodec.encode(params)
    }

    private func generateDeterministicSecret(label: String) -> SymmetricKey {
        let data = generateDeterministicData(seed: label, length: 32)
        return SymmetricKey(data: data)
    }

    private func generateDeterministicData(seed: String, length: Int) -> Data {
        // Generate deterministic bytes from seed for reproducible tests
        var result = Data(count: length)
        let seedData = Data(seed.utf8)
        for i in 0..<length {
            result[i] = seedData[i % seedData.count] ^ UInt8(i & 0xFF)
        }
        return result
    }
}

// MARK: - Mock State

/// Internal state for MockTLSProvider
private struct MockTLSState: Sendable {
    var isClient: Bool = true
    var handshakeStarted: Bool = false
    var handshakeKeysAvailable: Bool = false
    var handshakeComplete: Bool = false
    var negotiatedALPN: String? = nil
    var localTransportParameters: Data? = nil
    var peerTransportParameters: Data? = nil
    var keyUpdateCount: Int = 0

    // 0-RTT state
    var resumptionTicket: SessionTicketData? = nil
    var attemptEarlyData: Bool = false
    var is0RTTAttempted: Bool = false
    var is0RTTAccepted: Bool = false
}

#else

// MARK: - Release Build Stub

/// MockTLSProvider stub for release builds
///
/// This stub exists only to provide compile-time errors if testing mode
/// is accidentally used in release builds. All methods will cause a
/// fatal error if somehow called.
///
/// - Warning: This type should never be instantiated in release builds.
public final class MockTLSProvider: TLS13Provider, Sendable {
    public init(
        configuration: TLSConfiguration = TLSConfiguration(),
        immediateCompletion: Bool = true,
        simulatedDelay: Duration? = nil
    ) {
        fatalError("MockTLSProvider is not available in release builds. Configure a real TLS provider using QUICConfiguration.production() or QUICConfiguration.development().")
    }

    public func startHandshake(isClient: Bool) async throws -> [TLSOutput] {
        fatalError("MockTLSProvider is not available in release builds")
    }

    public func processHandshakeData(_ data: Data, at level: EncryptionLevel) async throws -> [TLSOutput] {
        fatalError("MockTLSProvider is not available in release builds")
    }

    public func getLocalTransportParameters() -> Data {
        fatalError("MockTLSProvider is not available in release builds")
    }

    public func setLocalTransportParameters(_ params: Data) throws {
        fatalError("MockTLSProvider is not available in release builds")
    }

    public func getPeerTransportParameters() -> Data? {
        fatalError("MockTLSProvider is not available in release builds")
    }

    public var isHandshakeComplete: Bool {
        fatalError("MockTLSProvider is not available in release builds")
    }

    public var isClient: Bool {
        fatalError("MockTLSProvider is not available in release builds")
    }

    public var negotiatedALPN: String? {
        fatalError("MockTLSProvider is not available in release builds")
    }

    public func configureResumption(ticket: SessionTicketData, attemptEarlyData: Bool) throws {
        fatalError("MockTLSProvider is not available in release builds")
    }

    public var is0RTTAccepted: Bool {
        fatalError("MockTLSProvider is not available in release builds")
    }

    public var is0RTTAttempted: Bool {
        fatalError("MockTLSProvider is not available in release builds")
    }

    public func requestKeyUpdate() async throws -> [TLSOutput] {
        fatalError("MockTLSProvider is not available in release builds")
    }

    public func exportKeyingMaterial(label: String, context: Data?, length: Int) throws -> Data {
        fatalError("MockTLSProvider is not available in release builds")
    }

    // Mock-specific methods that will fail in release builds
    public func setPeerTransportParameters(_ params: Data) {
        fatalError("MockTLSProvider is not available in release builds")
    }

    public func forceComplete() {
        fatalError("MockTLSProvider is not available in release builds")
    }

    public func reset() {
        fatalError("MockTLSProvider is not available in release builds")
    }
}

#endif
