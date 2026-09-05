import Foundation
import Testing
@testable import OpenNOW

/// The receive path is packet-rate bound, not link bound: before the 2026-08-25 fix the drain loop
/// measured 3217 packets/s while burning 92% of wall clock, which capped the stream at ~33 Mbps
/// and made the seat's extra bitrate arrive as loss (129 us per packet in software GHASH; 4.1 us
/// after). 100 Mbps at the announced 1280-byte packet size needs about 9800 packets/s, so this
/// pins the per-packet SRTP cost that budget has to fit inside. A regression here does not fail
/// loudly in a session — it looks exactly like network loss — which is why the guard exists.
///
/// Re-added 2026-09-05 after being dropped in an unrelated commit. Kept deliberately generous
/// (a 4 us packet reports ~2500 Mbps; the failure it guards against reports ~80) and measured as
/// the best of several batches, so a loaded CI core cannot fail it on noise alone.
@Suite(.serialized) struct SrtpThroughputTests {
    /// Well under the healthy ceiling, well over the regression's.
    static let minimumMegabitsPerSecond = 300.0

    @Test func decryptCostPerPacketSupportsTheTargetPacketRate() throws {
        let key = Data((0..<32).map { UInt8($0 &* 7 &+ 1) })
        let gcm = try SrtpGcm8(key: key)
        let iv = Data((0..<12).map { UInt8($0 &+ 3) })
        let aad = Data((0..<12).map { UInt8($0 &+ 9) })
        let payload = Data((0..<1180).map { UInt8($0 & 0xff) })

        let sealed = try gcm.seal(iv: iv, aad: aad, plaintext: payload, tagLength: 8)
        let ciphertext = sealed.prefix(sealed.count - 8)
        let tag = sealed.suffix(8)

        // Warm up so first-call setup does not dominate the sample.
        for _ in 0..<50 {
            _ = try gcm.decrypt(iv: iv, aad: aad, ciphertext: ciphertext, authenticationTag: tag)
        }

        // Best of several batches, not one long run: noise can only make a batch slower, so the
        // fastest batch is the closest estimate of the real per-packet cost.
        let iterations = 400
        let batches = 7
        var bestElapsed = UInt64.max
        for _ in 0..<batches {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations {
                _ = try gcm.decrypt(iv: iv, aad: aad, ciphertext: ciphertext, authenticationTag: tag)
            }
            bestElapsed = min(bestElapsed, DispatchTime.now().uptimeNanoseconds - start)
        }
        let perPacketMicroseconds = Double(bestElapsed) / Double(iterations) / 1000
        let packetsPerSecond = 1_000_000 / perPacketMicroseconds
        let megabitsPerSecond = packetsPerSecond * 1280 * 8 / 1_000_000

        print("SRTP decrypt: \(String(format: "%.1f", perPacketMicroseconds)) us/packet "
              + "-> \(Int(packetsPerSecond)) packets/s -> \(Int(megabitsPerSecond)) Mbps ceiling")

        #expect(megabitsPerSecond > Self.minimumMegabitsPerSecond,
                "SRTP decrypt at \(String(format: "%.1f", perPacketMicroseconds)) us/packet caps the receive path at \(Int(megabitsPerSecond)) Mbps; the software-GHASH regression looked like network loss in a live session")
    }
}
