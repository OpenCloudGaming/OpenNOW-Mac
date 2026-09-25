import CryptoKit
import Foundation

/// The certificate a WebTransport listener presents to a browser guest.
///
/// A browser accepts a WebTransport server only when its certificate is publicly trusted or when the
/// page pins it through `serverCertificateHashes`. With no domain there is no publicly trusted
/// certificate, so this mints a self-signed one the page can pin.
///
/// Pinning puts constraints on the certificate that the HTTPS warning path does not have, which is
/// why it is generated separately from `OPNRemoteCoOpTLSIdentity`'s RSA identity:
///
/// - It must be **ECDSA**, because the pinning algorithm set is ECDSA-only.
/// - Its **validity period may not exceed 14 days**, so a long-lived certificate is rejected outright.
/// - The pin is the **SHA-256 of the real DER**, so a placeholder certificate can never match.
///
/// The material is reused across launches until it is close to expiring. Regenerating on every launch
/// would be harmless for pinning - the page is told the new hash - but it is wasted work and a new
/// certificate every launch is a new thing to trust.
struct OPNRemoteCoOpWebTransportCertificate: Sendable {
    /// PEM certificate path, as `TLSConfiguration.server(certificatePath:privateKeyPath:)` wants it.
    let certificatePath: String
    /// PEM PKCS#8 private key path.
    let privateKeyPath: String
    /// SHA-256 of the DER certificate, exactly the value the page passes as a `serverCertificateHashes`.
    let sha256: Data
    /// The host the certificate's subject alternative name covers.
    let host: String
}

extension OPNRemoteCoOpTLSIdentity {
    /// 13 days, not 14. The validity period is checked against the certificate's own window, and a
    /// certificate minted at the 14-day boundary is one clock skew away from being rejected.
    static let webTransportValidityDays = 13

    /// Returns the certificate for `host`, minting one if there is none, it names a different host, or
    /// it is close to expiring.
    static func webTransportCertificate(for host: String, directory: URL? = nil) throws -> OPNRemoteCoOpWebTransportCertificate {
        let directory = try directory ?? storeDirectory()
        let certificateURL = directory.appendingPathComponent("webtransport-cert.pem")
        let privateKeyURL = directory.appendingPathComponent("webtransport-key.pem")
        let hostURL = directory.appendingPathComponent("webtransport-cert.host")
        let createdURL = directory.appendingPathComponent("webtransport-cert.created")

        let storedHost = (try? String(contentsOf: hostURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let createdAt = (try? String(contentsOf: createdURL, encoding: .utf8))
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let isFresh = createdAt.map { Date().timeIntervalSince1970 - $0 < Double(webTransportValidityDays) * 86_400 } ?? false

        if storedHost == host, isFresh,
           let stored = try? stored(certificateURL: certificateURL, privateKeyURL: privateKeyURL, host: host) {
            return stored
        }

        let generated = try generate(certificateURL: certificateURL, privateKeyURL: privateKeyURL, host: host, directory: directory)
        try Data(host.utf8).write(to: hostURL, options: .atomic)
        try Data("\(Date().timeIntervalSince1970)".utf8).write(to: createdURL, options: .atomic)
        return generated
    }

    private static func stored(certificateURL: URL, privateKeyURL: URL, host: String) throws -> OPNRemoteCoOpWebTransportCertificate {
        guard FileManager.default.fileExists(atPath: privateKeyURL.path) else {
            throw OPNRemoteCoOpTLSIdentityError.generationFailed("the stored WebTransport private key is missing")
        }
        let pem = try String(contentsOf: certificateURL, encoding: .utf8)
        guard let der = der(fromPEM: pem) else {
            throw OPNRemoteCoOpTLSIdentityError.generationFailed("the stored WebTransport certificate is not PEM")
        }
        return OPNRemoteCoOpWebTransportCertificate(certificatePath: certificateURL.path,
                                                    privateKeyPath: privateKeyURL.path,
                                                    sha256: Data(SHA256.hash(data: der)),
                                                    host: host)
    }

    /// Mints a fresh self-signed P-256 certificate for `host`.
    ///
    /// Explicit about the EC curve: the default `req -x509 -newkey` path on this machine's LibreSSL
    /// does not take `-pkeyopt`, so the key is generated with `ecparam` and then converted to PKCS#8,
    /// which is the one private-key format Quiver's loader handles on its best-tested path.
    private static func generate(certificateURL: URL, privateKeyURL: URL, host: String, directory: URL) throws -> OPNRemoteCoOpWebTransportCertificate {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else {
            throw OPNRemoteCoOpTLSIdentityError.opensslUnavailable
        }
        let scratch = directory.appendingPathComponent("webtransport-scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sec1KeyURL = scratch.appendingPathComponent("ec-key.pem")
        let configURL = scratch.appendingPathComponent("openssl.cnf")
        let config = """
        [req]
        default_md = sha256
        prompt = no
        distinguished_name = dn
        x509_extensions = v3_req
        [dn]
        CN = \(host)
        [v3_req]
        subjectAltName = @alt_names
        extendedKeyUsage = serverAuth
        keyUsage = digitalSignature
        basicConstraints = CA:FALSE
        [alt_names]
        \(subjectAltNameEntry(for: host))
        """
        try Data(config.utf8).write(to: configURL)

        try run("/usr/bin/openssl", [
            "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", sec1KeyURL.path
        ])
        try run("/usr/bin/openssl", [
            "pkcs8", "-topk8", "-nocrypt", "-in", sec1KeyURL.path, "-out", privateKeyURL.path
        ])
        try run("/usr/bin/openssl", [
            "req", "-x509", "-new", "-key", privateKeyURL.path, "-days", "\(webTransportValidityDays)", "-sha256",
            "-out", certificateURL.path, "-config", configURL.path
        ])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyURL.path)

        let pem = try String(contentsOf: certificateURL, encoding: .utf8)
        guard let der = der(fromPEM: pem) else {
            throw OPNRemoteCoOpTLSIdentityError.generationFailed("openssl produced a certificate that is not PEM")
        }
        return OPNRemoteCoOpWebTransportCertificate(certificatePath: certificateURL.path,
                                                    privateKeyPath: privateKeyURL.path,
                                                    sha256: Data(SHA256.hash(data: der)),
                                                    host: host)
    }

    /// The DER bytes of a PEM certificate, for hashing and for the Security framework.
    static func der(fromPEM pem: String) -> Data? {
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body)
    }
}
