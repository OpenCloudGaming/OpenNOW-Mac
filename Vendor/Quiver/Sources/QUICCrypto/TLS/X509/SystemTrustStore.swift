/// System Trust Store (Platform-Specific Root CA Loading)
///
/// Provides platform-specific loading of system-trusted root CA certificates.
/// This enables TLS connections to validate peer certificates against the
/// operating system's trust store without requiring manual CA provisioning.
///
/// ## Platform Support
///
/// - **macOS/iOS**: Uses the Security framework to enumerate trusted root CAs
///   from the System Keychain and System Roots keychain.
/// - **Linux**: Loads CA certificates from well-known filesystem paths such as
///   `/etc/ssl/certs/ca-certificates.crt` (Debian/Ubuntu),
///   `/etc/pki/tls/certs/ca-bundle.crt` (RHEL/CentOS/Fedora), etc.
/// - **Windows**: Not natively supported; users should provide trusted roots
///   explicitly via `TLSConfiguration.trustedRootCertificates`.
///
/// ## Usage
///
/// ```swift
/// // Load system roots once (cached after first load)
/// let roots = try SystemTrustStore.loadSystemRoots()
///
/// // Use with TLSConfiguration
/// var config = TLSConfiguration.client(serverName: "example.com")
/// config.trustedRootCertificates = roots
///
/// // Or use the convenience method
/// var config2 = TLSConfiguration.client(serverName: "example.com")
/// try config2.useSystemTrustStore()
/// ```
///
/// ## Thread Safety
///
/// The cached system roots are protected by `Synchronization.Mutex` and are
/// safe to access from multiple threads/tasks concurrently.

import Foundation
@preconcurrency import X509
import SwiftASN1

#if canImport(Security)
import Security
#endif

#if canImport(Synchronization)
import Synchronization
#endif

// MARK: - System Trust Store

/// Platform-specific system trust store for loading root CA certificates.
///
/// Loads and caches the operating system's trusted root CA certificates.
/// The cache is populated on first access and reused for subsequent calls.
///
/// - Important: On Linux, this reads PEM files from the filesystem. Ensure
///   the CA certificate bundle is installed (e.g., `ca-certificates` package
///   on Debian/Ubuntu, or `ca-certificates` on RHEL/CentOS/Fedora).
public enum SystemTrustStore: Sendable {

    // MARK: - Cache

    /// Cached system root certificates (populated on first load).
    private static let _cachedRoots = Mutex<[X509Certificate]?>(nil)

    /// Whether the cache has been populated.
    private static let _cachePopulated = Mutex<Bool>(false)

    // MARK: - Public API

    /// Loads the system's trusted root CA certificates.
    ///
    /// This method is safe to call from any thread. The first call loads
    /// certificates from the platform trust store; subsequent calls return
    /// the cached result.
    ///
    /// - Parameter forceReload: If `true`, bypasses the cache and reloads
    ///   from the platform trust store. Default is `false`.
    /// - Returns: An array of trusted root CA certificates.
    /// - Throws: `SystemTrustStoreError` if loading fails.
    public static func loadSystemRoots(forceReload: Bool = false) throws -> [X509Certificate] {
        if !forceReload {
            let cached = _cachedRoots.withLock { $0 }
            if let cached {
                return cached
            }
        }

        let roots = try loadPlatformRoots()

        _cachedRoots.withLock { $0 = roots }
        _cachePopulated.withLock { $0 = true }

        return roots
    }

    /// Returns `true` if the system trust store cache has been populated.
    public static var isCachePopulated: Bool {
        _cachePopulated.withLock { $0 }
    }

    /// Clears the cached system roots, forcing a reload on next access.
    public static func clearCache() {
        _cachedRoots.withLock { $0 = nil }
        _cachePopulated.withLock { $0 = false }
    }

    /// Returns the number of cached system root certificates,
    /// or `nil` if the cache has not been populated.
    public static var cachedRootCount: Int? {
        _cachedRoots.withLock { $0?.count }
    }

    // MARK: - Platform-Specific Loading

    /// Loads root certificates from the platform trust store.
    private static func loadPlatformRoots() throws -> [X509Certificate] {
        #if canImport(Security) && (os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
        return try loadApplePlatformRoots()
        #elseif os(Linux)
        return try loadLinuxRoots()
        #else
        throw SystemTrustStoreError.unsupportedPlatform
        #endif
    }

    // MARK: - Apple Platform (macOS, iOS, tvOS, watchOS, visionOS)

    #if canImport(Security) && (os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))

    /// Loads trusted root CAs from the Apple Security framework.
    ///
    /// On macOS, this uses `SecTrustSettingsCopyCertificates` to enumerate
    /// certificates in the System domain. On iOS and other Apple platforms,
    /// the system roots are managed by the OS and not directly enumerable;
    /// we attempt to use `SecTrustCopyAnchorCertificates` where available.
    private static func loadApplePlatformRoots() throws -> [X509Certificate] {
        var roots: [X509Certificate] = []

        #if os(macOS)
        // macOS: Use SecTrustCopyAnchorCertificates to get system anchors
        var anchors: CFArray?
        let status = SecTrustCopyAnchorCertificates(&anchors)
        guard status == errSecSuccess, let anchorArray = anchors as? [SecCertificate] else {
            throw SystemTrustStoreError.securityFrameworkError(
                "SecTrustCopyAnchorCertificates failed with status \(status)"
            )
        }

        for secCert in anchorArray {
            let derData = SecCertificateCopyData(secCert) as Data
            do {
                let cert = try X509Certificate.parse(from: derData)
                roots.append(cert)
            } catch {
                // Skip certificates that fail to parse (e.g., unsupported key types).
                // This is intentional: we want to load as many roots as possible
                // without failing the entire operation due to one bad certificate.
                continue
            }
        }
        #else
        // iOS, tvOS, watchOS, visionOS:
        // SecTrustCopyAnchorCertificates is not available on these platforms.
        // The system trust evaluation handles roots internally.
        // We return an empty array and rely on SecTrust-based validation
        // at the TLS layer, or users must provide roots explicitly.
        //
        // Note: Applications targeting iOS that need explicit root loading
        // should bundle their CA certificates or use TLSConfiguration.loadTrustedCAs().
        throw SystemTrustStoreError.platformRootsNotEnumerable(
            "System root certificates cannot be enumerated on this Apple platform. " +
            "Use TLSConfiguration.loadTrustedCAs(fromPEMFile:) to load CA certificates explicitly, " +
            "or rely on the platform's SecTrust evaluation."
        )
        #endif

        guard !roots.isEmpty else {
            throw SystemTrustStoreError.noRootsFound(
                "No root certificates were loaded from the system trust store"
            )
        }

        return roots
    }
    #endif

    // MARK: - Linux

    #if os(Linux)

    /// Well-known paths for CA certificate bundles on Linux distributions.
    ///
    /// These paths are checked in order. The first path that exists and
    /// contains parseable certificates is used.
    private static let linuxCertBundlePaths: [String] = [
        // Debian, Ubuntu, Arch, Gentoo
        "/etc/ssl/certs/ca-certificates.crt",
        // RHEL, CentOS, Fedora
        "/etc/pki/tls/certs/ca-bundle.crt",
        // OpenSUSE
        "/etc/ssl/ca-bundle.pem",
        // Alpine Linux
        "/etc/ssl/cert.pem",
        // RHEL 7+
        "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
        // Older SUSE
        "/etc/ssl/certs/ca-certificates.crt",
    ]

    /// Well-known directories containing individual CA certificate files.
    ///
    /// Used as a fallback when no bundle file is found.
    private static let linuxCertDirectories: [String] = [
        "/etc/ssl/certs",
        "/etc/pki/tls/certs",
        "/usr/share/ca-certificates",
        "/usr/local/share/ca-certificates",
    ]

    /// Loads trusted root CAs from Linux filesystem paths.
    ///
    /// First attempts to load from well-known PEM bundle files (most efficient).
    /// Falls back to scanning certificate directories for individual PEM files.
    private static func loadLinuxRoots() throws -> [X509Certificate] {
        // Try bundle files first (most efficient — single file with all CAs)
        for bundlePath in linuxCertBundlePaths {
            if FileManager.default.fileExists(atPath: bundlePath) {
                do {
                    let roots = try loadCertificatesFromPEMFile(bundlePath)
                    if !roots.isEmpty {
                        return roots
                    }
                } catch {
                    // Try next path
                    continue
                }
            }
        }

        // Fall back to scanning certificate directories
        for directory in linuxCertDirectories {
            if FileManager.default.fileExists(atPath: directory) {
                do {
                    let roots = try loadCertificatesFromDirectory(directory)
                    if !roots.isEmpty {
                        return roots
                    }
                } catch {
                    continue
                }
            }
        }

        throw SystemTrustStoreError.noRootsFound(
            "No CA certificate bundle or directory found. " +
            "Install the ca-certificates package (e.g., `apt install ca-certificates` " +
            "or `yum install ca-certificates`)."
        )
    }

    /// Loads certificates from a PEM bundle file.
    ///
    /// PEM bundle files contain multiple certificates separated by
    /// `-----BEGIN CERTIFICATE-----` / `-----END CERTIFICATE-----` markers.
    private static func loadCertificatesFromPEMFile(_ path: String) throws -> [X509Certificate] {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return parsePEMCertificates(from: content)
    }

    /// Loads certificates from a directory of individual PEM/DER files.
    ///
    /// Scans all `.pem`, `.crt`, and `.cer` files in the directory.
    /// Subdirectories are not scanned recursively.
    private static func loadCertificatesFromDirectory(_ directory: String) throws -> [X509Certificate] {
        let fileManager = FileManager.default
        let validExtensions: Set<String> = ["pem", "crt", "cer"]

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        var roots: [X509Certificate] = []
        // Track SPKI to avoid duplicate root certificates
        var seenSPKI: Set<Data> = []

        while let fileURL = enumerator.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            guard validExtensions.contains(ext) else { continue }

            // Skip symlinks to avoid processing the same certificate twice
            // (common in /etc/ssl/certs where hash-named symlinks point to certs)
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if resourceValues?.isSymbolicLink == true {
                continue
            }

            do {
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                let certs = parsePEMCertificates(from: content)
                for cert in certs {
                    let spki = cert.subjectPublicKeyInfoDER
                    if !spki.isEmpty && !seenSPKI.contains(spki) {
                        seenSPKI.insert(spki)
                        roots.append(cert)
                    }
                }
            } catch {
                // Skip files that fail to parse
                continue
            }
        }

        return roots
    }
    #endif

    // MARK: - PEM Parsing (Shared)

    /// Parses X.509 certificates from PEM-encoded content.
    ///
    /// Extracts all `-----BEGIN CERTIFICATE-----` blocks and parses each one.
    /// Certificates that fail to parse are silently skipped.
    ///
    /// - Parameter content: PEM-encoded string potentially containing multiple certificates.
    /// - Returns: An array of successfully parsed certificates.
    private static func parsePEMCertificates(from content: String) -> [X509Certificate] {
        let beginMarker = "-----BEGIN CERTIFICATE-----"
        let endMarker = "-----END CERTIFICATE-----"

        var certificates: [X509Certificate] = []
        var searchRange = content.startIndex..<content.endIndex

        while let beginRange = content.range(of: beginMarker, range: searchRange) {
            guard let endRange = content.range(of: endMarker, range: beginRange.upperBound..<content.endIndex) else {
                break
            }

            let base64Content = content[beginRange.upperBound..<endRange.lowerBound]
            let cleaned = base64Content
                .replacingOccurrences(of: "\r\n", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: " ", with: "")

            if let derData = Data(base64Encoded: cleaned) {
                do {
                    let cert = try X509Certificate.parse(from: derData)
                    certificates.append(cert)
                } catch {
                    // Skip unparseable certificates
                }
            }

            searchRange = endRange.upperBound..<content.endIndex
        }

        return certificates
    }
}

// MARK: - System Trust Store Errors

/// Errors that can occur when loading system trust store certificates.
public enum SystemTrustStoreError: Error, Sendable, CustomStringConvertible {
    /// The current platform is not supported for system trust store loading.
    case unsupportedPlatform

    /// No root CA certificates were found in the system trust store.
    case noRootsFound(String)

    /// Platform root certificates cannot be enumerated (iOS, tvOS, etc.).
    case platformRootsNotEnumerable(String)

    /// Security framework error (Apple platforms).
    case securityFrameworkError(String)

    /// File system error during certificate loading.
    case fileSystemError(String)

    /// Certificate parsing error.
    case parseError(String)

    public var description: String {
        switch self {
        case .unsupportedPlatform:
            return "System trust store loading is not supported on this platform"
        case .noRootsFound(let detail):
            return "No system root certificates found: \(detail)"
        case .platformRootsNotEnumerable(let detail):
            return "Platform roots not enumerable: \(detail)"
        case .securityFrameworkError(let detail):
            return "Security framework error: \(detail)"
        case .fileSystemError(let detail):
            return "File system error: \(detail)"
        case .parseError(let detail):
            return "Certificate parse error: \(detail)"
        }
    }
}

extension SystemTrustStoreError: LocalizedError {
    public var errorDescription: String? { description }
}

// MARK: - TLSConfiguration Integration

extension TLSConfiguration {

    /// Loads system trust store root certificates and sets them as trusted roots.
    ///
    /// This is a convenience method that calls `SystemTrustStore.loadSystemRoots()`
    /// and sets the result on `trustedRootCertificates`. Previously set trusted
    /// roots are replaced.
    ///
    /// ## Platform Behavior
    ///
    /// - **macOS**: Loads from the Security framework (System Keychain).
    /// - **Linux**: Loads from `/etc/ssl/certs/ca-certificates.crt` or similar.
    /// - **iOS/tvOS/watchOS**: Not supported (throws `SystemTrustStoreError.platformRootsNotEnumerable`).
    ///   Use `loadTrustedCAs(fromPEMFile:)` instead.
    ///
    /// ## Example
    ///
    /// ```swift
    /// var config = TLSConfiguration.client(serverName: "example.com")
    /// try config.useSystemTrustStore()
    /// // config.trustedRootCertificates now contains system CAs
    /// ```
    ///
    /// - Parameter forceReload: If `true`, bypasses the cache and reloads
    ///   from the platform trust store. Default is `false`.
    /// - Throws: `SystemTrustStoreError` if loading fails.
    public mutating func useSystemTrustStore(forceReload: Bool = false) throws {
        let roots = try SystemTrustStore.loadSystemRoots(forceReload: forceReload)
        self.trustedRootCertificates = roots
    }

    /// Appends system trust store root certificates to the existing trusted roots.
    ///
    /// Unlike `useSystemTrustStore()`, this method preserves any previously set
    /// trusted roots and appends the system roots to them. This is useful when
    /// you have custom CA certificates that should be trusted in addition to
    /// the system roots.
    ///
    /// ## Example
    ///
    /// ```swift
    /// var config = TLSConfiguration.client(serverName: "internal.corp.com")
    /// try config.loadTrustedCAs(fromPEMFile: "/path/to/internal-ca.pem")
    /// try config.addSystemTrustStore()  // Also trust system CAs
    /// ```
    ///
    /// - Parameter forceReload: If `true`, bypasses the cache and reloads
    ///   from the platform trust store. Default is `false`.
    /// - Throws: `SystemTrustStoreError` if loading fails.
    public mutating func addSystemTrustStore(forceReload: Bool = false) throws {
        let roots = try SystemTrustStore.loadSystemRoots(forceReload: forceReload)
        if trustedRootCertificates == nil {
            trustedRootCertificates = roots
        } else {
            trustedRootCertificates?.append(contentsOf: roots)
        }
    }

    /// Returns the effective trusted roots, falling back to the system trust
    /// store if no explicit roots are configured and `verifyPeer` is `true`.
    ///
    /// Resolution order:
    /// 1. `trustedRootCertificates` (explicit parsed certificates)
    /// 2. `trustedCACertificates` (DER bytes, parsed on demand)
    /// 3. System trust store (loaded and cached on first access)
    /// 4. Empty array (if system trust store is unavailable)
    ///
    /// - Note: This method never throws. If the system trust store cannot
    ///   be loaded, it silently returns an empty array. Use `useSystemTrustStore()`
    ///   for explicit error handling.
    public var effectiveTrustedRootsWithSystemFallback: [X509Certificate] {
        // 1. Explicit parsed roots
        if let roots = trustedRootCertificates, !roots.isEmpty {
            return roots
        }

        // 2. DER-encoded CA certificates (parsed on demand)
        if let derCerts = trustedCACertificates, !derCerts.isEmpty {
            return derCerts.compactMap { try? X509Certificate.parse(from: $0) }
        }

        // 3. System trust store (cached, no-throw)
        if verifyPeer {
            if let roots = try? SystemTrustStore.loadSystemRoots() {
                return roots
            }
        }

        // 4. Empty (no roots available)
        return []
    }
}