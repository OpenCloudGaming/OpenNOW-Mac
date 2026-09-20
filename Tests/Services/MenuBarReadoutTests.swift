import Foundation
import Testing
@testable import OpenNOW

/// The menu bar surface's readout wording: the queue count the status item adds, and the Continue
/// Playing rows' last-played subtitle.
@MainActor @Suite(.serialized) struct MenuBarReadoutTests {
    @Test func theStatusLabelNamesTheQueuePositionWithoutTheETA() {
        #expect(OPNMenuBarSessionPhase.queued(position: 4).menuBarQueueCountText == "4")
        #expect(OPNMenuBarSessionPhase.queued(position: 0).menuBarQueueCountText == nil)
        #expect(OPNMenuBarSessionPhase.starting.menuBarQueueCountText == nil)
        #expect(OPNMenuBarSessionPhase.streaming.menuBarQueueCountText == nil)
        // The ETA is untouched; it still lives in the popover readout, not the status item.
        #expect(OPNMenuBarReadout.detailText(for: .queued(position: 4), estimatedSeconds: 120) == "Queue #4 · ~2 min")
    }

    @Test func theContinuePlayingRowHasNoSubtitleWithoutAPlayedDate() {
        // A game the history has no timestamp for renders as a title-only row rather than a
        // placeholder line repeating the card's header.
        #expect(OPNMenuBarReadout.lastPlayedText(for: nil) == nil)
        #expect(OPNMenuBarReadout.lastPlayedText(for: Date())?.isEmpty == false)
    }
}
