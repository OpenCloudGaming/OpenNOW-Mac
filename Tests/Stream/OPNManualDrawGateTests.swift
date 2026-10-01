import Foundation
import Testing
@testable import OpenNOW

@Suite struct OPNManualDrawGateTests {
    /// Replays gate events and returns each one's answer, since `#expect` cannot hold a mutating call.
    private enum Event {
        case request(waitsForPresent: Bool, now: CFTimeInterval)
        case presentStarted(CFTimeInterval)
        case presentCompleted
        case drawFinished
    }

    private func answers(_ events: [Event]) -> [Bool] {
        var gate = OPNManualDrawGate()
        return events.compactMap { event in
            switch event {
            case .request(let waits, let now):
                return gate.request(waitsForPresent: waits, now: now)
            case .presentStarted(let now):
                gate.presentStarted(at: now)
                return nil
            case .presentCompleted:
                return gate.presentCompleted()
            case .drawFinished:
                return gate.drawFinished()
            }
        }
    }

    @Test func lowestLatencyCoalescesABurstIntoOneDraw() {
        #expect(answers([
            .request(waitsForPresent: false, now: 0),
            .request(waitsForPresent: false, now: 0.001),
            .drawFinished,
            .request(waitsForPresent: false, now: 0.002),
        ]) == [true, false, false, true])
    }

    @Test func vrrDrawsTheNextFrameWhenThePreviousPresentLands() {
        #expect(answers([
            .request(waitsForPresent: true, now: 0),
            .presentStarted(0.001),
            .drawFinished,
            .request(waitsForPresent: true, now: 0.004),
            .request(waitsForPresent: true, now: 0.006),
            .presentCompleted,
            .request(waitsForPresent: true, now: 0.009),
        ]) == [true, false, false, false, true, true])
    }

    @Test func aFrameArrivingMidDrawWaitsForThatDrawsPresent() {
        #expect(answers([
            .request(waitsForPresent: true, now: 0),
            .request(waitsForPresent: true, now: 0.001),
            .presentStarted(0.002),
            .drawFinished,
            .presentCompleted,
            .presentCompleted,
        ]) == [true, false, false, true, false])
    }

    @Test func aPresentThatNeverLandsStopsHoldingDrawsBack() {
        #expect(answers([
            .request(waitsForPresent: true, now: 1),
            .presentStarted(1),
            .drawFinished,
            .request(waitsForPresent: true, now: 1.02),
            .request(waitsForPresent: true, now: 1 + OPNManualDrawGate.presentTimeoutSeconds),
        ]) == [true, false, false, true])
    }

    @Test func vrrIsOfferedAsAFramePacingChoice() {
        let values = OPNStreamPreferences.presentationModeOptions.map(\.value)
        #expect(values.compactMap(OPNVideoPresentationMode.init(rawValue:)).count == values.count)
        #expect(values.last.flatMap(OPNVideoPresentationMode.init(rawValue:)) == .vrr)
        #expect(OPNVideoPresentationMode.vrr.drawsOnDecode)
        #expect(!OPNVideoPresentationMode.smooth.drawsOnDecode)
    }
}
