/// QUICConnectionHandler — Crypto Operations
///
/// Extension containing cryptographic key management:
/// - `deriveInitialKeys` — derives and installs Initial encryption keys
/// - `installKeys` — installs keys for a given encryption level
/// - `cryptoContext` — retrieves the crypto context for an encryption level
/// - `discardLevel` — discards keys and state for an encryption level

import Foundation
import QUICCore
import QUICCrypto
import QUICRecovery

// MARK: - Crypto Operations

extension QUICConnectionHandler {

    // MARK: - Initial Key Derivation

    /// Derives and installs initial keys
    /// - Parameter connectionID: The connection ID to use for key derivation.
    ///   If nil, uses the current destination connection ID. Servers should pass
    ///   the original DCID from the client's first Initial packet.
    /// - Returns: Tuple of client and server key material
    package func deriveInitialKeys(connectionID: ConnectionID? = nil) throws -> (client: KeyMaterial, server: KeyMaterial) {
        let (defaultCID, version) = connectionState.withLock { state in
            (state.currentDestinationCID, state.version)
        }
        let cid = connectionID ?? defaultCID

        let (clientKeys, serverKeys) = try keySchedule.withLock { schedule in
            try schedule.deriveInitialKeys(connectionID: cid, version: version)
        }

        // Create and install crypto contexts
        // RFC 9001 Section 5.2: Initial keys MUST use AES-128-GCM-SHA256
        // The cipher suite for initial keys is not negotiated - it's fixed by the protocol
        let role = connectionState.withLock { $0.role }
        let (readKeys, writeKeys) = role == .client ?
            (serverKeys, clientKeys) : (clientKeys, serverKeys)

        // Initial keys always use AES-128-GCM per RFC 9001 Section 5.2
        let opener = try AES128GCMOpener(keyMaterial: readKeys)
        let sealer = try AES128GCMSealer(keyMaterial: writeKeys)

        cryptoContexts.withLock { contexts in
            contexts[.initial] = CryptoContext(opener: opener, sealer: sealer)
        }

        return (client: clientKeys, server: serverKeys)
    }

    // MARK: - Key Installation

    /// Installs keys for an encryption level
    /// - Parameter info: Information about the available keys
    package func installKeys(_ info: KeysAvailableInfo) throws {
        let role = connectionState.withLock { $0.role }
        let cipherSuite = info.cipherSuite

        // Handle 0-RTT keys specially (only one direction)
        if info.level == .zeroRTT {
            guard let clientSecret = info.clientSecret else {
                throw QUICConnectionHandlerError.missingSecret("0-RTT requires client secret")
            }
            let clientKeys = try KeyMaterial.derive(from: clientSecret, cipherSuite: cipherSuite)
            let (opener, sealer) = try clientKeys.createCrypto()

            if role == .client {
                // Client writes 0-RTT data
                cryptoContexts.withLock { contexts in
                    // 0-RTT only has sealer for client
                    contexts[info.level] = CryptoContext(opener: nil, sealer: sealer)
                }
            } else {
                // Server reads 0-RTT data
                cryptoContexts.withLock { contexts in
                    // 0-RTT only has opener for server
                    contexts[info.level] = CryptoContext(opener: opener, sealer: nil)
                }
            }
            return
        }

        // Standard bidirectional keys
        guard let clientSecret = info.clientSecret,
              let serverSecret = info.serverSecret else {
            throw QUICConnectionHandlerError.missingSecret("Both client and server secrets required")
        }

        // Determine which keys to use for read/write based on role
        let readKeys: KeyMaterial
        let writeKeys: KeyMaterial
        if role == .client {
            readKeys = try KeyMaterial.derive(from: serverSecret, cipherSuite: cipherSuite)
            writeKeys = try KeyMaterial.derive(from: clientSecret, cipherSuite: cipherSuite)
        } else {
            readKeys = try KeyMaterial.derive(from: clientSecret, cipherSuite: cipherSuite)
            writeKeys = try KeyMaterial.derive(from: serverSecret, cipherSuite: cipherSuite)
        }

        // Create opener/sealer using factory method (selects AES or ChaCha20)
        let (opener, _) = try readKeys.createCrypto()
        let (_, sealer) = try writeKeys.createCrypto()

        cryptoContexts.withLock { contexts in
            contexts[info.level] = CryptoContext(opener: opener, sealer: sealer)
        }

        // Update key schedule
        keySchedule.withLock { schedule in
            switch info.level {
            case .handshake:
                _ = try? schedule.setHandshakeSecrets(
                    clientSecret: clientSecret,
                    serverSecret: serverSecret
                )
            case .application:
                _ = try? schedule.setApplicationSecrets(
                    clientSecret: clientSecret,
                    serverSecret: serverSecret
                )
            default:
                break
            }
        }
    }

    // MARK: - Crypto Context Access

    /// Gets the crypto context for an encryption level
    /// - Parameter level: The encryption level
    /// - Returns: The crypto context, if available
    package func cryptoContext(for level: EncryptionLevel) -> CryptoContext? {
        cryptoContexts.withLock { $0[level] }
    }

    // MARK: - Level Discard

    /// Discards an encryption level
    /// - Parameter level: The level to discard
    package func discardLevel(_ level: EncryptionLevel) {
        pnSpaceManager.discardLevel(level)
        cryptoStreamManager.discardLevel(level)
        _ = cryptoContexts.withLock { $0.removeValue(forKey: level) }
        keySchedule.withLock { $0.discardKeys(for: level) }
    }
}