//  Two accounts can stream at once, and both windows remember the same placement, so a second one
//  would open exactly on top of the first and read as a replacement. Pure, so the rule is assertable
//  without a window server.

import AppKit
import Testing
@testable import OpenNOW

@MainActor
@Suite struct StreamWindowPlacementTests {
    private static let remembered = NSRect(x: 200, y: 200, width: 1280, height: 720)

    @Test func theFirstWindowKeepsTheRememberedPlacement() {
        let frame = OPNStreamWindowPresenter.cascadedFrame(for: Self.remembered, taken: [])

        #expect(frame == Self.remembered)
    }

    @Test func aSecondWindowIsCascadedClearOfTheFirst() {
        let frame = OPNStreamWindowPresenter.cascadedFrame(for: Self.remembered, taken: [Self.remembered])

        #expect(frame.origin.x > Self.remembered.origin.x)
        #expect(frame.origin.y < Self.remembered.origin.y)
        #expect(frame.size == Self.remembered.size)
    }

    /// Cascading steps past every window already open, not just the last one.
    @Test func aThirdWindowStepsPastBothWindowsAlreadyOpen() {
        let first = Self.remembered
        let second = OPNStreamWindowPresenter.cascadedFrame(for: first, taken: [first])

        let third = OPNStreamWindowPresenter.cascadedFrame(for: first, taken: [first, second])

        #expect(third.origin.x > second.origin.x)
        #expect(third.origin.y < second.origin.y)
    }
}
