import Foundation
import Testing
@testable import OpenNOW

@Suite struct OPNManualDrawGateTests {
    @Test func lowestLatencyCoalescesABurstIntoOneDraw() {
        var gate = OPNManualDrawGate()
        let first = gate.request()
        let duringDraw = gate.request()
        gate.drawFinished()
        let afterDraw = gate.request()
        #expect([first, duringDraw, afterDraw] == [true, false, true])
    }

    @Test func vrrIsOfferedAsAFramePacingChoice() {
        let values = OPNStreamPreferences.presentationModeOptions.map(\.value)
        #expect(values.compactMap(OPNVideoPresentationMode.init(rawValue:)).count == values.count)
        #expect(values.last.flatMap(OPNVideoPresentationMode.init(rawValue:)) == .vrr)
        #expect(OPNVideoPresentationMode.vrr.isDecodeDriven)
        #expect(!OPNVideoPresentationMode.smooth.isDecodeDriven)
    }
}
