import Foundation
import Testing
@testable import OpenNOW

@Suite struct NvstVariableRefreshPacingTests {
    @Test func vrrPacesTheSeatUnderTheDisplayMaximum() {
        let pacing = NvstBifrostFreeTransport.pacingIntervals(sessionFrameMicroseconds: 8333, displayRefreshRate: 120,
                                                              isVrrPresentation: true)
        #expect(pacing.frameMicroseconds == 8621)
        #expect(pacing.displayVsyncMicroseconds == 8621)
    }

    @Test func vrrNeverAsksForMoreThanTheSessionRate() {
        let pacing = NvstBifrostFreeTransport.pacingIntervals(sessionFrameMicroseconds: 8333, displayRefreshRate: 144,
                                                              isVrrPresentation: true)
        #expect(pacing.frameMicroseconds == 8333)
        #expect(pacing.displayVsyncMicroseconds == 8333)
    }

    @Test func anUnreportedDisplayRefreshKeepsTheSessionFrameInterval() {
        let pacing = NvstBifrostFreeTransport.pacingIntervals(sessionFrameMicroseconds: 8333,
                                                              displayRefreshRate: 0,
                                                              isVrrPresentation: true)
        #expect(pacing.frameMicroseconds == 8333)
    }

    @Test func anUnreportedDisplayRefreshFallsBackToTheDefaultDisplayInterval() {
        let pacing = NvstBifrostFreeTransport.pacingIntervals(sessionFrameMicroseconds: 8333,
                                                              displayRefreshRate: 0,
                                                              isVrrPresentation: true)
        #expect(pacing.displayVsyncMicroseconds == NvstBifrostFreeTransport.fallbackVsyncMicroseconds)
    }

    @Test func aRefreshRateWithNoVariableRefreshMarginPacesFromTheDisplayInterval() {
        let pacing = NvstBifrostFreeTransport.pacingIntervals(sessionFrameMicroseconds: 8333,
                                                              displayRefreshRate: 3600,
                                                              isVrrPresentation: true)
        #expect(pacing.frameMicroseconds == 8333)
        #expect(pacing.displayVsyncMicroseconds == 277)
    }

    @Test func otherModesLeavePacingUnchanged() {
        let pacing = NvstBifrostFreeTransport.pacingIntervals(sessionFrameMicroseconds: 8333, displayRefreshRate: 144,
                                                              isVrrPresentation: false)
        #expect(pacing.frameMicroseconds == 8333)
        #expect(pacing.displayVsyncMicroseconds == 6944)
    }
}
