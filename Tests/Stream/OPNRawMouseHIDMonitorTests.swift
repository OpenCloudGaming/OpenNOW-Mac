import CoreGraphics
import Foundation
import Testing
@testable import OpenNOW

struct OPNRawMouseHIDMonitorTests {
    @Test func separateAxisCallbacksCoalesceIntoOnePair() {
        var accumulator = OPNRawMouseDeltaAccumulator()
        accumulator.add(x: 4)
        accumulator.add(y: -3)
        #expect(accumulator.drain() == OPNRawMouseDelta(x: 4, y: -3))
        #expect(accumulator.drain() == nil)
    }

    @Test func reportsBetweenDrainsSum() {
        var accumulator = OPNRawMouseDeltaAccumulator()
        for _ in 0..<8 {
            accumulator.add(x: 3)
            accumulator.add(y: 1)
        }
        #expect(accumulator.drain() == OPNRawMouseDelta(x: 24, y: 8))
    }

    /// A single-axis flick is a complete movement, not half of one: a mouse pushed straight up
    /// reports Y only, and waiting for an X that never comes would stall it.
    @Test func singleAxisMotionDrainsOnItsOwn() {
        var accumulator = OPNRawMouseDeltaAccumulator()
        accumulator.add(y: 9)
        #expect(accumulator.drain() == OPNRawMouseDelta(x: 0, y: 9))
    }

    @Test func stillnessProducesNoDelta() {
        var accumulator = OPNRawMouseDeltaAccumulator()
        #expect(accumulator.drain() == nil)
        accumulator.add(x: 5)
        accumulator.add(x: -5)
        #expect(accumulator.drain() == nil)
    }

    @Test func resetDropsUndrainedCounts() {
        var accumulator = OPNRawMouseDeltaAccumulator()
        accumulator.add(x: 120)
        accumulator.reset()
        #expect(accumulator.drain() == nil)
    }

    @Test func sumsSaturateInsteadOfTrapping() {
        #expect(OPNRawMouseDeltaAccumulator.saturatingSum(Int.max, 1) == Int(Int32.max))
        #expect(OPNRawMouseDeltaAccumulator.saturatingSum(Int.min, -1) == Int(Int32.min))
        #expect(OPNRawMouseDeltaAccumulator.saturatingSum(Int(Int32.max), 1000) == Int(Int32.max))
        #expect(OPNRawMouseDeltaAccumulator.saturatingSum(Int(Int32.min), -1000) == Int(Int32.min))
        #expect(OPNRawMouseDeltaAccumulator.saturatingSum(-7, 3) == -4)
    }

    @Test func acceptsOrdinaryMiceAndRejectsTheDevicesWithTheirOwnPath() {
        // Logitech: an ordinary USB mouse, the case the whole feature exists for.
        #expect(OPNRawMouseHIDMonitor.acceptsDevice(vendorID: 0x046D, isBuiltIn: false))
        // Steam Controller in lizard mode — its trackpad already reaches the seat as Int16 deltas.
        #expect(!OPNRawMouseHIDMonitor.acceptsDevice(vendorID: SteamControllerReport.vendorID, isBuiltIn: false))
        // Apple pointing devices publish driver-processed deltas, built in or not.
        #expect(!OPNRawMouseHIDMonitor.acceptsDevice(vendorID: 0x05AC, isBuiltIn: false))
        #expect(!OPNRawMouseHIDMonitor.acceptsDevice(vendorID: 0x046D, isBuiltIn: true))
    }

    /// The fallback decision: with no HID manager running there is nothing raw to offer, so
    /// `emitMouseMove` takes the `.unavailable` branch and sends the AppKit delta.
    @Test func idleReaderLeavesTheAppKitPathInCharge() {
        #expect(!OPNRawMouseHIDMonitor.shared.isCapturing)
        #expect(OPNRawMouseHIDMonitor.shared.takeMotion() == .unavailable)
    }

    /// Sensitivity and its carried remainder behave the same on raw counts as on AppKit deltas —
    /// the counts go through the identical scaling helper.
    @MainActor @Test func sensitivityAppliesToRawCountsWithTheSameCarry() {
        var remainder = CGPoint.zero
        var total = (x: 0, y: 0)
        let reports = [OPNRawMouseDelta(x: 7, y: -2), OPNRawMouseDelta(x: 1, y: 0), OPNRawMouseDelta(x: 2, y: -2)]
        for report in reports {
            let scaled = NativeWebRTCStreamView.scaledMouseDelta(deltaX: CGFloat(report.x),
                                                                 deltaY: CGFloat(report.y),
                                                                 sensitivity: 0.5,
                                                                 remainder: &remainder)
            total.x += Int(scaled.x)
            total.y += Int(scaled.y)
        }
        // 10 counts at 50% is exactly 5, and -4 counts exactly -2, with nothing lost to rounding.
        #expect(total == (x: 5, y: -2))
    }

    @MainActor @Test func rawCountsSaturateAtTheSeatsInt16Limit() {
        var remainder = CGPoint.zero
        let scaled = NativeWebRTCStreamView.scaledMouseDelta(deltaX: CGFloat(Int32.max),
                                                             deltaY: CGFloat(Int32.min),
                                                             sensitivity: 1.0,
                                                             remainder: &remainder)
        #expect(scaled.x == Int16.max)
        #expect(scaled.y == Int16.min)
    }

    /// The in-flight window is global — `NSEvent` carries no HID identity for a motion event, so
    /// there is nothing to match a report against — and every nanosecond of it is time in which a
    /// second pointing device's movement is swallowed as somebody else's counts arriving late. It
    /// still has to outlast one report period of a 125 Hz mouse, whose in-flight report is
    /// routinely 8-9 ms old by the time the motion event asks for it.
    @Test func inFlightWindowOutlastsAReportPeriodWithoutSwallowingASecondDevice() {
        let last: UInt64 = 1_000_000_000
        #expect(OPNRawMouseHIDMonitor.inFlightWindowNanoseconds == 25_000_000)
        #expect(OPNRawMouseHIDMonitor.isReportInFlight(lastReportUptimeNanoseconds: last, uptimeNanoseconds: last + 9_000_000))
        #expect(OPNRawMouseHIDMonitor.isReportInFlight(lastReportUptimeNanoseconds: last, uptimeNanoseconds: last + 24_999_999))
        #expect(!OPNRawMouseHIDMonitor.isReportInFlight(lastReportUptimeNanoseconds: last, uptimeNanoseconds: last + 25_000_000))
        #expect(!OPNRawMouseHIDMonitor.isReportInFlight(lastReportUptimeNanoseconds: last, uptimeNanoseconds: last + 100_000_000))
    }

    /// Before any report has landed there is nothing in flight, so an AppKit motion event from a
    /// device the filter rejected is never mistaken for counts on their way.
    @Test func noReportYetMeansNothingIsInFlight() {
        #expect(!OPNRawMouseHIDMonitor.isReportInFlight(lastReportUptimeNanoseconds: 0, uptimeNanoseconds: 5_000_000_000))
    }
}
