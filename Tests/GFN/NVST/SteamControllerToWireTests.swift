import Foundation
import Testing
@testable import OpenNOW

/// End-to-end replay of the SC2 (Ibex) input path with NO hardware: a raw Ibex HID report goes
/// through the real parse (`SteamControllerReport`) and out the real wire encoder
/// (`NvstBifrostFreeTransport.wireButtons`), and the final XInput mask the seat would receive is
/// asserted. This is the autopilot for the half the transport autopilot cannot reach — it exercises
/// the button masks, the steam/quickAccess labels and the trackpad-click gate straight from the
/// kernel-verified Ibex layout, so a regression in any of those layers fails here instead of on a
/// controller in someone's hands.
@Suite struct SteamControllerToWireTests {
    /// Builds a 54-byte Ibex report (ID 0x42) with the given button u32 and reads it back out as the
    /// XInput wire mask that would reach the seat.
    private func wireMask(ibexButtons: UInt32) -> UInt16 {
        var report = [UInt8](repeating: 0, count: 54)
        report[0] = 0x42
        report[2] = UInt8(truncatingIfNeeded: ibexButtons)
        report[3] = UInt8(truncatingIfNeeded: ibexButtons >> 8)
        report[4] = UInt8(truncatingIfNeeded: ibexButtons >> 16)
        report[5] = UInt8(truncatingIfNeeded: ibexButtons >> 24)
        guard case .state(let snapshot) = SteamControllerReport.parse(report, previous: SteamControllerInputSnapshot(), model: .triton) else {
            Issue.record("Expected a state event")
            return 0
        }
        return NvstBifrostFreeTransport.wireButtons(snapshot.buttons)
    }

    /// One row per physical button: its Ibex bit (Linux hid-steam.c) and the XInput bit the game
    /// must ultimately see. Grips have no XInput bit and must reach the wire as 0.
    @Test func everyIbexButtonReachesTheCorrectXInputBit() {
        typealias B = NvstGamepadPacket.Button
        let cases: [(name: String, ibex: UInt32, wire: UInt16)] = [
            ("A",              0x0000_0001, B.a),
            ("B",              0x0000_0002, B.b),
            ("X",              0x0000_0004, B.x),
            ("Y",              0x0000_0008, B.y),
            ("Quick-access …", 0x0000_0010, 0),            // no XInput bit
            ("Right stick",    0x0000_0020, B.rightThumb),
            ("Start",          0x0000_0040, B.start),
            ("Right bumper",   0x0000_0200, B.rightShoulder),
            ("Select/Back",    0x0000_4000, B.back),
            ("Left stick",     0x0000_8000, B.leftThumb),
            ("Steam/Guide",    0x0001_0000, B.guide),
            ("Left bumper",    0x0008_0000, B.leftShoulder),
            ("Left grip",      0x0002_0000, 0),            // grips have no XInput bit
            ("Right grip",     0x0000_0080, 0),
        ]
        for c in cases {
            #expect(wireMask(ibexButtons: c.ibex) == c.wire, "\(c.name)")
        }
    }

    /// The Steam button and the "…" button are distinct Ibex bits and must not be confused — the
    /// swap that had them backwards is exactly what made "…" open the guide overlay.
    @Test func steamAndQuickAccessMatchThisHardware() {
        // Hardware-confirmed on the Puck (opposite of the kernel's Ibex table — see the report parser).
        #expect(wireMask(ibexButtons: 0x0001_0000) == NvstGamepadPacket.Button.guide)  // Steam -> Guide
        #expect(wireMask(ibexButtons: 0x0000_0010) == 0)                               // "…" -> client-side only
    }

    /// The Ibex D-pad bits come from the LEFT TRACKPAD and reach the wire on touch alone. A gate
    /// requiring the pad click (bit 0x0400_0000) was tried and reverted: its premise — a character
    /// walking from a resting thumb — was the MOUSE path, and gamepad input was dead at the time
    /// for an unrelated reason (a malformed state-packet envelope). The gate only dropped the
    /// directions this pad can actually produce.
    @Test func trackpadDpadReachesTheWireOnTouch() {
        typealias B = NvstGamepadPacket.Button
        let down: UInt32 = 0x0000_0400   // Ibex D-pad Down
        let up: UInt32   = 0x0000_2000   // Ibex D-pad Up
        let click: UInt32 = 0x0400_0000  // left pad click

        #expect(wireMask(ibexButtons: down | up) == (B.dPadDown | B.dPadUp))
        // The click itself carries no XInput bit, so it changes nothing on the wire.
        #expect(wireMask(ibexButtons: down | up | click) == (B.dPadDown | B.dPadUp))
        #expect(wireMask(ibexButtons: 0x0000_0001) == B.a)
    }
}
