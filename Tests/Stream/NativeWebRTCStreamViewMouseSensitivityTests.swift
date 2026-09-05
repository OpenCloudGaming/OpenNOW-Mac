import CoreGraphics
import Foundation
import Testing
@testable import OpenNOW

struct NativeWebRTCStreamViewMouseSensitivityTests {
    private func run(_ deltas: [(CGFloat, CGFloat)], sensitivity: Double) -> (x: Int, y: Int) {
        var remainder = CGPoint.zero
        var total = (x: 0, y: 0)
        for (dx, dy) in deltas {
            let scaled = NativeWebRTCStreamView.scaledMouseDelta(deltaX: dx, deltaY: dy, sensitivity: sensitivity, remainder: &remainder)
            total.x += Int(scaled.x)
            total.y += Int(scaled.y)
        }
        return total
    }

    @Test func oneHundredPercentPassesDeltasThrough() {
        #expect(run([(3, -2), (5, 7), (-4, 0)], sensitivity: 1.0) == (x: 4, y: 5))
    }

    @Test func fractionsCarryAcrossEventsSoTheSumIsExact() {
        // 25%: four one-count nudges make exactly one count, not zero.
        #expect(run([(1, 0), (1, 0), (1, 0), (1, 0)], sensitivity: 0.25) == (x: 1, y: 0))
        // 150%: ten counts become fifteen, whichever way they are split.
        #expect(run([(3, 0), (3, 0), (4, 0)], sensitivity: 1.5) == (x: 15, y: 0))
        // 300% doubles and more, sign preserved.
        #expect(run([(-2, 1)], sensitivity: 3.0) == (x: -6, y: 3))
    }

    @Test func remainderNeverExceedsOneCount() {
        var remainder = CGPoint.zero
        for _ in 0..<50 { _ = NativeWebRTCStreamView.scaledMouseDelta(deltaX: 1, deltaY: 1, sensitivity: 0.3, remainder: &remainder) }
        #expect(abs(remainder.x) < 1 && abs(remainder.y) < 1)
    }
}
