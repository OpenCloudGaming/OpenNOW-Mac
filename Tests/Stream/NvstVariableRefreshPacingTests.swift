import Foundation
import Testing
@testable import OpenNOW

@Suite struct NvstVariableRefreshPacingTests {
    @Test func vrrPacesTheSeatUnderTheDisplayMaximum() {
        let pacing = NvstBifrostFreeTransport.pacingIntervals(sessionFrameMicroseconds: 8333, displayRefreshRate: 120,
                                                              presentsWithVariableRefresh: true)
        #expect(pacing.frame == 8621)
        #expect(pacing.displayVsync == 8621)
    }

    @Test func vrrNeverAsksForMoreThanTheSessionRate() {
        let pacing = NvstBifrostFreeTransport.pacingIntervals(sessionFrameMicroseconds: 8333, displayRefreshRate: 144,
                                                              presentsWithVariableRefresh: true)
        #expect(pacing.frame == 8333)
        #expect(pacing.displayVsync == 8333)
    }

    @Test func otherModesKeepTheSessionAndDisplayIntervals() {
        let pacing = NvstBifrostFreeTransport.pacingIntervals(sessionFrameMicroseconds: 8333, displayRefreshRate: 120,
                                                              presentsWithVariableRefresh: false)
        #expect(pacing.frame == 8333)
        #expect(pacing.displayVsync == 8333)
    }
}
