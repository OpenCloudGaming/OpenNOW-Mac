import Foundation
import Testing
@testable import OpenNOW

@Suite struct NvstAudioSrtpTests {
    private static let profile = NVSTSrtpProfile.aeadAes256Gcm8
    private static let masterKey = Data((0..<32).map { UInt8($0 &* 7 &+ 1) })
    private static let masterSalt = Data((0..<12).map { UInt8($0 &* 3 &+ 5) })

    @Test func aes128CounterModeMatchesTheLibsrtpReferencePacket() throws {
        try checkReferencePacket(
            profile: .aesCm128HmacSha1_80,
            masterKey: "e1f97a0d3e018be0d64fa32c06de4139",
            masterSalt: "0ec675ad498afeebb6960b3aabe6",
            protected: "800f1234decafbadcafebabe4e55dc4ce79978d88ca4d215949d2402b78d6acc99ea179b8dbb"
        )
    }

    @Test func aes128GcmMatchesTheLibsrtpReferencePacket() throws {
        try checkReferencePacket(
            profile: .aeadAes128Gcm,
            masterKey: "000102030405060708090a0b0c0d0e0f",
            masterSalt: "a0a1a2a3a4a5a6a7a8a9aaab",
            protected: "800f1234decafbadcafebabec5002ede04cfdd2eb91159e0880aa06ed2976826f796b201df3131a127e8a392"
        )
    }

    @Test func aes256GcmMatchesAnIndependentRfc7714ReferencePacket() throws {
        try checkReferencePacket(
            profile: .aeadAes256Gcm,
            masterKey: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
            masterSalt: "a0a1a2a3a4a5a6a7a8a9aaab",
            protected: "800f1234decafbadcafebabe0af7f21e8a90bdad7a425c9c31ed4bb1d90238917e7390a2793500e1681acaea"
        )
    }

    @Test func counterModeRejectsAChangedHeaderTagOrRolloverCounter() throws {
        let srtp = try NvstAudioSrtp(masterKey: bytes("e1f97a0d3e018be0d64fa32c06de4139"),
                                    masterSalt: bytes("0ec675ad498afeebb6960b3aabe6"), profile: .aesCm128HmacSha1_80)
        let packet = try bytes("800f1234decafbadcafebabe4e55dc4ce79978d88ca4d215949d2402b78d6acc99ea179b8dbb")
        for position in [4, 14, 37] {
            var tampered = packet
            tampered[position] ^= 1
            #expect(throws: SrtpCryptoError.authenticationFailed) { try srtp.unprotect(tampered) }
        }
        #expect(throws: SrtpCryptoError.authenticationFailed) { try srtp.unprotect(packet, rolloverCounter: 1) }
    }

    private func checkReferencePacket(profile: NVSTSrtpProfile, masterKey: String, masterSalt: String, protected: String) throws {
        let srtp = try NvstAudioSrtp(masterKey: bytes(masterKey), masterSalt: bytes(masterSalt), profile: profile)
        let plaintext = try bytes("800f1234decafbadcafebabe") + Data(repeating: 0xAB, count: 16)
        let expected = try bytes(protected)
        #expect(try srtp.protect(plaintext) == expected)
        #expect(try srtp.unprotect(expected).payload == Data(repeating: 0xAB, count: 16))
    }

    private func bytes(_ hexadecimal: String) throws -> Data {
        let characters = Array(hexadecimal.utf8)
        try #require(characters.count.isMultiple(of: 2))
        return try Data(stride(from: 0, to: characters.count, by: 2).map {
            try #require(UInt8(String(decoding: characters[$0..<$0 + 2], as: UTF8.self), radix: 16))
        })
    }

    private func rtpPacket(payloadType: UInt8 = 111, sequence: UInt16 = 42, timestamp: UInt32 = 96_000, ssrc: UInt32 = 1, payload: Data) -> Data {
        let header = NvstAudioRtpPacket.headerBytes(payloadType: payloadType, marker: true, sequenceNumber: sequence, timestamp: timestamp, ssrc: ssrc)
        return header + payload
    }

    @Test func aPlainRtpHeaderParsesIntoItsFields() throws {
        let payload = Data("opus-payload".utf8)
        let packet = try #require(NvstAudioRtpPacket.parse(rtpPacket(payload: payload), tagLength: 0))
        #expect(packet.marker)
        #expect(packet.payloadType == 111)
        #expect(packet.sequenceNumber == 42)
        #expect(packet.timestamp == 96_000)
        #expect(packet.ssrc == 1)
        #expect(packet.encryptedPayload == payload)
        #expect(packet.authenticationTag.isEmpty)
        #expect(packet.authenticatedHeader.count == 12)
    }

    @Test func aProtectedPacketUnprotectsToTheSamePayload() throws {
        let srtp = try NvstAudioSrtp(masterKey: Self.masterKey, masterSalt: Self.masterSalt, profile: Self.profile)
        let payload = Data("the-seat-sends-this".utf8)
        let protected = try srtp.protect(rtpPacket(payload: payload))
        #expect(protected.count == 12 + payload.count + Self.profile.authenticationTagLength)

        let (packet, recovered) = try srtp.unprotect(protected)
        #expect(recovered == payload)
        #expect(packet.sequenceNumber == 42)
        #expect(packet.ssrc == 1)
        #expect(packet.payloadType == 111)
    }

    @Test func aTamperedPayloadFailsItsTag() throws {
        let srtp = try NvstAudioSrtp(masterKey: Self.masterKey, masterSalt: Self.masterSalt, profile: Self.profile)
        var protected = [UInt8](try srtp.protect(rtpPacket(payload: Data("audio".utf8))))
        // Flip a payload bit, leaving the tag in place.
        protected[13] ^= 0x01
        #expect(throws: SrtpCryptoError.authenticationFailed) {
            try srtp.unprotect(Data(protected))
        }
    }

    @Test func aReplayedPacketIsRejectedByTheWindow() throws {
        let srtp = try NvstAudioSrtp(masterKey: Self.masterKey, masterSalt: Self.masterSalt, profile: Self.profile)
        let protected = try srtp.protect(rtpPacket(payload: Data("audio".utf8)))
        // The window is what a stream keeps, so it is exercised directly. `accept` mutates, so the
        // calls cannot sit inside the expectation macro.
        var window = SrtpReplayWindow()
        let first = try srtp.unprotect(protected)
        let index = window.estimatedIndex(for: first.packet.sequenceNumber)
        let acceptedOnce = window.accept(index)
        let acceptedTwice = window.accept(index)
        #expect(acceptedOnce)
        #expect(!acceptedTwice)
    }

    @Test func twoEndpointsOfTheHandshakeUseOppositeKeys() throws {
        let keys = try NvstBundleSrtpKeys.split(Data((0..<88).map { UInt8($0) }), profile: Self.profile)
        let directions = NvstAudioSrtpDirection.directions(from: keys)
        #expect(directions.outbound.key == keys.clientMasterKey)
        #expect(directions.inbound.key == keys.serverMasterKey)
        #expect(directions.outbound.salt == keys.clientMasterSalt)
        #expect(directions.inbound.salt == keys.serverMasterSalt)
        // The two directions must not share material, or a stream would protect with the key it
        // unprotects with and neither end would authenticate the other.
        #expect(directions.outbound.key != directions.inbound.key)
    }

    @Test func anExtensionHeaderIsAuthenticatedWhole() throws {
        // An RTP header with a one-word extension: the authentication must cover it, so the parser
        // has to advance past it rather than treating the extension as payload.
        var bytes = [UInt8](NvstAudioRtpPacket.headerBytes(payloadType: 63, marker: false, sequenceNumber: 7, timestamp: 240, ssrc: 1))
        bytes[0] |= 0x10                     // extension present
        bytes += [0xBE, 0xDE, 0x00, 0x01]    // profile + one word
        bytes += [0x01, 0x02, 0x03, 0x04]    // the extension word
        let payload = Data("red-block".utf8)
        bytes += [UInt8](payload)
        let packet = try #require(NvstAudioRtpPacket.parse(Data(bytes), tagLength: 0))
        #expect(packet.authenticatedHeader.count == 20)
        #expect(packet.encryptedPayload == payload)
    }
}
