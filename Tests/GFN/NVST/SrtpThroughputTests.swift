import Foundation
import Testing
@testable import OpenNOW

/// The receive path is packet-rate bound, not link bound: at 5120x2160@120 the drain loop measured
/// 3217 packets/s while burning 92% of wall clock, which capped the stream at ~33 Mbps and made the
/// seat's extra bitrate arrive as loss. 100 Mbps at the announced 1280-byte packet size needs about
/// 9800 packets/s, so this pins the per-packet SRTP cost that budget has to fit inside.
@Suite struct SrtpThroughputTests {
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

        // Best of several batches, not one long run. The whole test suite runs in parallel, so a
        // single batch measures this core's share of a loaded machine rather than the per-packet
        // cost — the reason a healthy 4 us/packet reported 120 Mbps and failed. Noise can only make
        // a batch slower, so the fastest batch is the closest estimate of the real cost and the
        // 200 Mbps floor keeps its meaning.
        let iterations = 400
        let batches = 5
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

        // One core must sustain well past 100 Mbps so the rest of the receive path (FEC, assembly,
        // the decoder handoff) still fits in the budget.
        #expect(megabitsPerSecond > 200)
    }
}
