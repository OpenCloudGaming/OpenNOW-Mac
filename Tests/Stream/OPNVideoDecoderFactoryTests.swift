import Testing
@preconcurrency import WebRTC
@testable import MacForceNow

@Suite("Video decoder factory")
struct OPNVideoDecoderFactoryTests {
    // Regression guard: the default factory advertises H265 with EMPTY params, which makes libwebrtc
    // drop H265 from the SDP answer and fall back to AV1 (undecodable before Apple M3 → black screen).
    // OPNVideoDecoderFactory must advertise H265 with a decodable level so HEVC negotiates instead.
    @Test("advertises H265 with decodable params so SDP does not fall back to AV1")
    func advertisesH265WithDecodableParams() {
        let codecs = OPNVideoDecoderFactory().supportedCodecs()
        let h265 = codecs.filter { ["H265", "HEVC"].contains($0.name.uppercased()) }

        // No advertised H265 entry may carry an empty/zero level-id (the empty-param entry is exactly
        // what caused the AV1 fallback). Vacuously true if the framework ships no H265 decoder.
        #expect(h265.allSatisfy { (Int($0.parameters["level-id"] ?? "") ?? 0) > 0 })

        // When H265 is available, advertise both Main (profile-id 1) and Main10 (profile-id 2) at high
        // tier so both offered profiles negotiate.
        if !h265.isEmpty {
            #expect(h265.contains { $0.parameters["profile-id"] == "1" })
            #expect(h265.contains { $0.parameters["profile-id"] == "2" })
            #expect(h265.allSatisfy { $0.parameters["tier-flag"] == "1" })
        }
    }
}
