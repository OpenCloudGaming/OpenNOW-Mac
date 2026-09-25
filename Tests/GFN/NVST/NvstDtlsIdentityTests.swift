import CryptoKit
import Foundation
import OpenSSL
import Testing
@testable import OpenNOW

/// The DTLS identity is what the seat authenticates the bundle against, so the fingerprint has to be
/// exactly the SHA-256 of the certificate it announces, in the form ANNOUNCE writes.
@Suite struct NvstDtlsIdentityTests {
    @Test func theFingerprintIsTheSha256OfTheAnnouncedCertificate() throws {
        let identity = try NvstDtlsIdentity()
        let expected = CryptoKit.SHA256.hash(data: identity.derCertificate)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
        #expect(identity.fingerprint == expected)
        // 32 bytes as colon-separated hex is 95 characters, and the wire form is uppercase.
        #expect(identity.fingerprint.count == 95)
        #expect(identity.fingerprint == identity.fingerprint.uppercased())
    }

    @Test func theCertificateIsAWellFormedDerSequence() throws {
        let identity = try NvstDtlsIdentity()
        #expect(identity.derCertificate.count > 100, "a P-256 leaf is larger than this")
        #expect(identity.derCertificate.first == 0x30, "DER starts with a SEQUENCE tag")
    }

    @Test func eachIdentityIsFresh() throws {
        // A reused certificate would let an old fingerprint keep authenticating a new session.
        let first = try NvstDtlsIdentity()
        let second = try NvstDtlsIdentity()
        #expect(first.fingerprint != second.fingerprint)
    }

    @Test func theIdentityInstallsOnADtlsClientContextWithSrtpProfiles() throws {
        let context = try #require(SSL_CTX_new(DTLS_client_method()))
        defer { SSL_CTX_free(context) }
        // The seat negotiates one of these; the AEAD profile is what live sessions use.
        #expect(SSL_CTX_set_tlsext_use_srtp(context, "SRTP_AEAD_AES_256_GCM:SRTP_AES128_CM_SHA1_80") == 0)
        try (try NvstDtlsIdentity()).apply(to: context)
    }
}
