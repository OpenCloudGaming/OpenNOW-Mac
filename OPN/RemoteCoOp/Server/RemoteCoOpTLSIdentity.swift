//
//  RemoteCoOpTLSIdentity.swift
//  OpenNOW
//
//  The TLS identity the embedded Remote Co-Op server presents.
//
//  TLS is not optional here. Browsers gate `RTCPeerConnection` and the Gamepad API behind a secure
//  context, and `http://` is only one for `localhost` - so a guest page served in plaintext to a
//  LAN address cannot build a peer connection at all, no matter how well the signaling works.
//
//  With no domain name there is no certificate a public CA will issue, so the identity is
//  self-signed and the guest accepts a browser warning once per origin. That acceptance is why the
//  page and the WebSocket must share an origin: the exception is granted on a top-level navigation
//  and then covers the socket. There is no interface for granting one to a bare WebSocket.
//
//  The identity is generated once and reused. Regenerating it invalidates every exception a guest
//  has already granted, so a fresh certificate on every launch would mean a fresh warning on every
//  launch.
//

import CryptoKit
import Foundation
import Security

enum OPNRemoteCoOpTLSIdentityError: LocalizedError {
    case opensslUnavailable
    case generationFailed(String)
    case importFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .opensslUnavailable:
            return "openssl is not available at /usr/bin/openssl, so a Remote Co-Op certificate cannot be generated."
        case .generationFailed(let message):
            return "Could not generate the Remote Co-Op certificate: \(message)"
        case .importFailed(let status):
            return "Could not load the Remote Co-Op certificate (OSStatus \(status))."
        }
    }
}

enum OPNRemoteCoOpTLSIdentity {
    /// Where the generated material lives. Application Support rather than the keychain: this is a
    /// throwaway server certificate, and adding it to the login keychain would put an entry the
    /// user did not ask for next to their real credentials.
    static func storeDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("OpenNOW/RemoteCoOp", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// Loads the stored identity, generating one for `host` if there is none.
    ///
    /// `host` becomes the certificate's subject alternative name. A browser checks the name against
    /// the address it dialled even while overriding trust, so an identity minted for `127.0.0.1`
    /// produces a second, non-overridable complaint when reached over the LAN. Changing hosts
    /// therefore regenerates.
    static func identity(for host: String) throws -> SecIdentity {
        let directory = try storeDirectory()
        let p12URL = directory.appendingPathComponent("server-identity.p12")
        let hostURL = directory.appendingPathComponent("server-identity.host")
        let storedHost = (try? String(contentsOf: hostURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)

        let passphrase = try storedOrNewPassphrase()
        if storedHost == host, let data = try? Data(contentsOf: p12URL), let identity = try? importIdentity(p12: data, passphrase: passphrase) {
            return identity
        }

        let data = try generateP12(host: host, passphrase: passphrase, directory: directory)
        try data.write(to: p12URL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12URL.path)
        try Data(host.utf8).write(to: hostURL, options: .atomic)
        return try importIdentity(p12: data, passphrase: passphrase)
    }

    /// Discards the stored identity so the next start mints a new one. Guests must accept the new
    /// certificate again.
    static func reset() {
        guard let directory = try? storeDirectory() else { return }
        for name in ["server-identity.p12", "server-identity.host"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        keychainDelete(account: passphraseAccount)
    }

    /// A short, stable fingerprint the host can read out so a guest can confirm they accepted the
    /// right certificate rather than an interception.
    static func fingerprint(for identity: SecIdentity) -> String? {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
        let data = SecCertificateCopyData(certificate) as Data
        return OPNRemoteCoOpSHA256Fingerprint.hex(of: data)
    }

    // MARK: - Generation

    private static let passphraseAccount = "tls-identity-passphrase"

    /// Generates a fresh self-signed PKCS#12 for `host`.
    ///
    /// Separate from the stored-identity path and taking an explicit passphrase, so the generate
    /// and import round trip can be exercised against the system's real `openssl` and
    /// `SecPKCS12Import` without touching the keychain or Application Support.
    static func generateP12(host: String, passphrase: String, directory: URL) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else {
            throw OPNRemoteCoOpTLSIdentityError.opensslUnavailable
        }
        let scratch = directory.appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }

        let certURL = scratch.appendingPathComponent("cert.pem")
        let keyURL = scratch.appendingPathComponent("key.pem")
        let configURL = scratch.appendingPathComponent("openssl.cnf")
        let p12URL = scratch.appendingPathComponent("identity.p12")

        // An IP literal has to be a SAN of type IP; browsers ignore a DNS entry holding an address.
        let isIPv4 = host.split(separator: ".").count == 4 && host.allSatisfy { $0.isNumber || $0 == "." }
        let altName = isIPv4 ? "IP.1 = \(host)" : "DNS.1 = \(host)"
        let config = """
        [req]
        default_bits = 2048
        prompt = no
        default_md = sha256
        distinguished_name = dn
        x509_extensions = v3_req
        [dn]
        CN = \(host)
        [v3_req]
        subjectAltName = @alt_names
        extendedKeyUsage = serverAuth
        [alt_names]
        \(altName)
        """
        try Data(config.utf8).write(to: configURL)

        try run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "825", "-sha256",
            "-keyout", keyURL.path, "-out", certURL.path, "-config", configURL.path
        ])

        // No `-legacy`: macOS ships LibreSSL (3.3.6 at time of writing), where that flag does not
        // exist and its presence fails the whole command. It is an OpenSSL 3 flag, needed there to
        // keep emitting the older PKCS#12 encryption; LibreSSL emits that by default, which is what
        // `SecPKCS12Import` accepts.
        // Handed over in the environment, not the argument vector. `pass:` puts the passphrase in
        // the process table, where any process running as this user can read it with `ps` for the
        // child's lifetime - and since the same keychain value is reused for every generation, one
        // observation plus the 0600 archive is the private key permanently. That is exactly the
        // protection `storedOrNewPassphrase` exists to provide.
        try run("/usr/bin/openssl", [
            "pkcs12", "-export",
            "-inkey", keyURL.path, "-in", certURL.path,
            "-out", p12URL.path, "-passout", "env:OPN_REMOTE_COOP_P12_PASSPHRASE"
        ], environment: ["OPN_REMOTE_COOP_P12_PASSPHRASE": passphrase])
        return try Data(contentsOf: p12URL)
    }

    /// `SecPKCS12Import` is not safe to call concurrently: overlapping imports fail with
    /// `errSecPkcs12VerifyFailure` (-26276) even when each passphrase is correct, which showed up
    /// as intermittent failures the moment two sessions started at once. Serialised here rather
    /// than at the call sites, so nothing can reach it unguarded.
    private static let importLock = NSLock()

    static func importIdentity(p12: Data, passphrase: String) throws -> SecIdentity {
        importLock.lock()
        defer { importLock.unlock() }
        var items: CFArray?
        // `kSecImportToMemoryOnly` is not optional. Without it `SecPKCS12Import` imports into the
        // default keychain on macOS - the documented behaviour, and the opposite of what the note
        // on `storeDirectory()` promises. Every start left its certificate and RSA private key in
        // the login keychain permanently: 3196 of them had accumulated by the time it was found,
        // 99% of a 13MB keychain, and since `codesign` trust-evaluates every certificate while
        // looking up a signing identity, it had grown into ~1.35s on each of the three bundles
        // signed per build. Nothing reads these back - `identity(for:)` always re-imports from the
        // stored p12 - so the keychain copy was pure leak. macOS 15 and later; the deployment
        // target is 15.0.
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: passphrase,
            kSecImportToMemoryOnly as String: true,
        ]
        let status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let identity = array.first?[kSecImportItemIdentity as String],
              CFGetTypeID(identity as CFTypeRef) == SecIdentityGetTypeID() else {
            throw OPNRemoteCoOpTLSIdentityError.importFailed(status)
        }
        // The type is checked above rather than trusted: `SecPKCS12Import` hands back an untyped CF
        // dictionary, and a partially imported archive can populate the key with something else.
        // Swift has no non-warning conditional cast to a CoreFoundation type, so the guard is the
        // check and this cast is the bridge.
        return identity as! SecIdentity
    }

    /// The passphrase protecting the PKCS#12 on disk. Kept in the keychain rather than beside the
    /// file, so the file alone is not enough to use the key.
    private static func storedOrNewPassphrase() throws -> String {
        if let existing = keychainLoad(account: passphraseAccount), !existing.isEmpty { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OPNRemoteCoOpTLSIdentityError.generationFailed("could not generate a passphrase")
        }
        let passphrase = Data(bytes).base64EncodedString()
        keychainSave(account: passphraseAccount, value: passphrase)
        return passphrase
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String], environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let errorPipe = Pipe()
        process.standardError = errorPipe
        // Read rather than discarded: nothing consuming stdout means a child that fills the pipe
        // buffer blocks on write, stderr never reaches EOF, and this hangs on the synchronous path
        // that runs before an invite can be created.
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        try process.run()
        // Drained on another thread so neither pipe can fill while the other is being read.
        let outputQueue = DispatchQueue(label: "io.github.opencloudgaming.opennow.remote-coop.tls-stdout")
        let outputBox = OPNRemoteCoOpPipeDrainBox()
        outputQueue.async { outputBox.store(outputPipe.fileHandleForReading.readDataToEndOfFile()) }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        outputQueue.sync {}
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OPNRemoteCoOpTLSIdentityError.generationFailed(String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: errorData, as: UTF8.self)
    }

    // MARK: - Keychain

    private static let keychainService = "OpenNOW.RemoteCoOp"

    private static func keychainSave(account: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess { return }
        var add = query
        attributes.forEach { add[$0.key] = $0.value }
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func keychainLoad(account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainDelete(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

/// Somewhere for the stdout drain to land. The data is not used - only the draining matters - but a
/// thread writing into a captured local is not something the compiler will allow without this.
private final class OPNRemoteCoOpPipeDrainBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }
}

enum OPNRemoteCoOpSHA256Fingerprint {
    /// Colon-separated uppercase hex, the form Safari and Chrome show in their certificate viewers,
    /// so a host reading it aloud and a guest reading it off the warning are comparing the same
    /// string.
    static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
