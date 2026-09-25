import Crypto
import Foundation
import Security
import Testing
@testable import OpenNOW

/// The browser accepts a WebTransport server only through `serverCertificateHashes`, so the
/// certificate it presents has to satisfy the pinning rules that the HTTPS warning path does not:
/// ECDSA, a validity period of at most 14 days, and a real DER whose SHA-256 is the pin. This
/// exercises the generator against those rules without needing the QUIC stack.
@Suite(.serialized) struct RemoteCoOpTLSIdentityWebTransportTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wt-cert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func generatedCertificateIsPinnable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let certificate = try OPNRemoteCoOpTLSIdentity.webTransportCertificate(for: "127.0.0.1", directory: directory)

        #expect(FileManager.default.fileExists(atPath: certificate.certificatePath))
        #expect(FileManager.default.fileExists(atPath: certificate.privateKeyPath))
        #expect(certificate.sha256.count == 32)
        #expect(certificate.host == "127.0.0.1")

        let pem = try String(contentsOfFile: certificate.certificatePath, encoding: .utf8)
        let der = try #require(OPNRemoteCoOpTLSIdentity.der(fromPEM: pem))
        #expect(SecCertificateCreateWithData(nil, der as CFData) != nil)

        let (notBefore, notAfter) = try #require(Self.validity(of: der))
        let now = Date()
        #expect(notBefore <= now)
        #expect(notAfter > now)
        #expect(notAfter.timeIntervalSince(notBefore) <= 14 * 86_400)
    }

    @Test func privateKeyIsPKCS8P256() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let certificate = try OPNRemoteCoOpTLSIdentity.webTransportCertificate(for: "192.168.1.20", directory: directory)
        let pem = try String(contentsOfFile: certificate.privateKeyPath, encoding: .utf8)
        #expect(pem.contains("BEGIN PRIVATE KEY"))

        guard let der = OPNRemoteCoOpTLSIdentity.der(fromPEM: pem) else {
            Issue.record("private key was not PEM")
            return
        }
        let key = try P256.Signing.PrivateKey(derRepresentation: der)
        #expect(key.publicKey.derRepresentation.count > 0)
    }

    @Test func certificateIsReusedUntilItExpires() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try OPNRemoteCoOpTLSIdentity.webTransportCertificate(for: "10.0.0.5", directory: directory)
        Thread.sleep(forTimeInterval: 1.1)
        let second = try OPNRemoteCoOpTLSIdentity.webTransportCertificate(for: "10.0.0.5", directory: directory)

        #expect(first.sha256 == second.sha256)
        let firstModified = try FileManager.default.attributesOfItem(atPath: first.certificatePath)[.modificationDate] as? Date
        let secondModified = try FileManager.default.attributesOfItem(atPath: second.certificatePath)[.modificationDate] as? Date
        #expect(firstModified == secondModified)

        let otherHost = try OPNRemoteCoOpTLSIdentity.webTransportCertificate(for: "10.0.0.6", directory: directory)
        #expect(otherHost.sha256 != first.sha256)
    }

    private static func validity(of der: Data) -> (notBefore: Date, notAfter: Date)? {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [CFString: Any] else { return nil }
        guard let notBefore = date(values[kSecOIDX509V1ValidityNotBefore]),
              let notAfter = date(values[kSecOIDX509V1ValidityNotAfter]) else { return nil }
        return (notBefore, notAfter)
    }

    private static func date(_ entry: Any?) -> Date? {
        guard let entry = entry as? [CFString: Any], let raw = entry[kSecPropertyKeyValue] else { return nil }
        if let date = raw as? Date { return date }
        if let number = raw as? NSNumber { return Date(timeIntervalSinceReferenceDate: number.doubleValue) }
        return nil
    }
}
