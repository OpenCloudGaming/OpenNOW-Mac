import Foundation
import Testing
@testable import OpenNOW

/// What an empty read says. In Selection mode the fix is usually the other mode, so the flash points
/// at it rather than leaving the reader at a dead end.
struct StreamClipboardEmptyReadAdviceTests {
    private typealias Message = NativeNVSTHostViewModel.StreamTextCaptureMessage
    private typealias Reason = StreamTextCaptureEmptyReason

    private func notice(_ reason: Reason, _ mode: StreamTextCaptureMode) -> Message.EmptyReadNotice {
        Message.EmptyReadNotice.make(reason: reason, mode: mode)
    }

    @Test func aSelectionReadThatFoundNothingAdvisesRegion() {
        #expect(notice(.noSelection, .selection).message == Message.regionAdvice)
        #expect(notice(.noTextInSelection, .selection).message == Message.regionAdvice)
        #expect(notice(.noSelection, .selection).advisesRegionMode)
    }

    /// Region mode cannot help when there was no frame to read, so that failure stays plain.
    @Test func aMissingFrameDoesNotAdviseRegion() {
        #expect(notice(.noFrame, .selection).message == Message.empty)
        #expect(notice(.noFrame, .region).message == Message.empty)
        #expect(!notice(.noFrame, .selection).advisesRegionMode)
    }

    /// Already in Region mode: there is no other mode to point at.
    @Test func regionModeDoesNotAdviseItself() {
        #expect(notice(.noTextInSelection, .region).message == Message.empty)
        #expect(notice(.noSelection, .region).message == Message.empty)
    }

    /// The advice is the only failure whose fix takes a second act, so it stays up longer.
    @Test func theAdviceStaysUpLongerThanAPlainEmptyRead() {
        #expect(notice(.noSelection, .selection).duration == .seconds(4))
        #expect(notice(.noTextInSelection, .region).duration == .seconds(2))
    }

    @Test func everyReasonNamesItself() {
        #expect(Reason.noFrame.label == "no-frame")
        #expect(Reason.noSelection.label == "no-selection")
        #expect(Reason.noTextInSelection.label == "no-selection-text")
    }
}
