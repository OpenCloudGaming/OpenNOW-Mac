import Foundation
import Testing
@testable import OpenNOW

@Suite struct NvstVsyncModeTests {
    /// The mode decides whether the client sends `0x203` reports and which interval they claim —
    /// the client-facing half of the pacer, verified by `NvstVideoPipeline` at report time.
    @Test func thePacingReportFlowFollowsTheVsyncMode() {
        #expect(!NvstVsyncMode.off.isSendingFramePacingReports)
        #expect(!NvstVsyncMode.on.isSendingFramePacingReports)
        #expect(NvstVsyncMode.adaptive.isSendingFramePacingReports)

        #expect(!NvstVsyncMode.off.isReportingDisplayVsync)
        #expect(!NvstVsyncMode.on.isReportingDisplayVsync)
        #expect(NvstVsyncMode.adaptive.isReportingDisplayVsync)
    }

    /// The mode names the Settings row, the HUD and the transient message show, in the official
    /// trio's order.
    @Test func theVsyncModesCarryTheOfficialLabels() {
        #expect(NvstVsyncMode.allCases.map(\.label) == ["Off", "On", "Adaptive"])
    }
}
