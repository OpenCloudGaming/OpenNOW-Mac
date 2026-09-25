import Foundation
import Testing
@testable import OpenNOW

/// The authenticated encryption over the native UDP datagrams: media and control are confidential,
/// authenticated and replay-protected, and the per-peer token never crosses the wire.
@Suite struct RemoteCoOpNativeCipherTests {
    private let token = "3F5C2E9A-1B44-4C7D-9E01-7A2B6D8F0C13"

    private func hostToGuest() -> (seal: OPNRemoteCoOpNativeCipher, open: OPNRemoteCoOpNativeCipher) {
        (OPNRemoteCoOpNativeCipher(token: token, role: .host),
         OPNRemoteCoOpNativeCipher(token: token, role: .guest))
    }

    @Test func aSealedDatagramOpensToTheSameBytes() throws {
        let (seal, open) = hostToGuest()
        let plaintext = Data("the compressed access unit".utf8)
        let sealed = try #require(seal.seal(plaintext))
        #expect(open.open(sealed) == plaintext)
    }

    @Test func theCleartextTokenIsNotOnTheWire() throws {
        let (seal, _) = hostToGuest()
        let sealed = try #require(seal.seal(Data("hello".utf8)))
        #expect(!String(decoding: sealed, as: UTF8.self).contains(token))
    }

    @Test func aTamperedDatagramIsRejected() throws {
        let (seal, open) = hostToGuest()
        var sealed = try #require(seal.seal(Data("control".utf8)))
        sealed[sealed.count - 1] ^= 0xFF
        #expect(open.open(sealed) == nil)
    }

    @Test func aDatagramFromTheWrongKeyIsRejected() throws {
        let (seal, _) = hostToGuest()
        let stranger = OPNRemoteCoOpNativeCipher(token: "not-the-token", role: .guest)
        let sealed = try #require(seal.seal(Data("control".utf8)))
        #expect(stranger.open(sealed) == nil)
    }

    @Test func aReplayedDatagramIsRejected() throws {
        let (seal, open) = hostToGuest()
        let sealed = try #require(seal.seal(Data("input".utf8)))
        #expect(open.open(sealed) == Data("input".utf8))
        #expect(open.open(sealed) == nil, "a replayed datagram was accepted a second time")
    }

    @Test func outOfOrderDatagramsWithinTheWindowAreAccepted() throws {
        let (seal, open) = hostToGuest()
        let first = try #require(seal.seal(Data("1".utf8)))
        let second = try #require(seal.seal(Data("2".utf8)))
        let third = try #require(seal.seal(Data("3".utf8)))
        #expect(open.open(third) == Data("3".utf8))
        #expect(open.open(first) == Data("1".utf8), "an in-window straggler was dropped")
        #expect(open.open(second) == Data("2".utf8))
    }

    @Test func aDatagramOlderThanTheWindowIsRejected() throws {
        let (seal, open) = hostToGuest()
        let old = try #require(seal.seal(Data("old".utf8)))
        var newest: Data?
        for index in 0..<Int(OPNRemoteCoOpNativeCipher.replayWindow + 2) {
            newest = seal.seal(Data("\(index)".utf8))
        }
        #expect(open.open(try #require(newest)) != nil)
        #expect(open.open(old) == nil, "a datagram older than the replay window was accepted")
    }

    @Test func directionsAreIndependent() throws {
        // A datagram sealed by the host must not open under the host's own open key: the two
        // directions use distinct keys, so a confused sender cannot reflect frames back.
        let host = OPNRemoteCoOpNativeCipher(token: token, role: .host)
        let guest = OPNRemoteCoOpNativeCipher(token: token, role: .guest)
        let sealed = try #require(host.seal(Data("host media".utf8)))
        #expect(guest.open(sealed) == Data("host media".utf8))
        #expect(host.open(sealed) == nil)
    }
}
