import Foundation
import Testing
@testable import OpenNOW

/// What an empty read says. In Selection mode the fix is usually the other mode, so the flash points
/// at it rather than leaving the reader at a dead end.
struct StreamClipboardEmptyReadAdviceTests {
    private typealias Message = NativeNVSTHostViewModel.StreamTextCaptureMessage

    @Test func aSelectionReadThatFoundNothingAdvisesRegion() {
        #expect(Message.emptyReadMessage(reason: "no-selection", mode: .selection) == Message.regionAdvice)
        #expect(Message.emptyReadMessage(reason: "no-selection-text", mode: .selection) == Message.regionAdvice)
        #expect(Message.emptyReadMessage(reason: "no-text", mode: .selection) == Message.regionAdvice)
    }

    /// Region mode cannot help when there was no frame to read, so that failure stays plain.
    @Test func aMissingFrameDoesNotAdviseRegion() {
        #expect(Message.emptyReadMessage(reason: "no-frame", mode: .selection) == Message.empty)
        #expect(Message.emptyReadMessage(reason: "no-frame", mode: .region) == Message.empty)
    }

    /// Already in Region mode: there is no other mode to point at.
    @Test func regionModeDoesNotAdviseItself() {
        #expect(Message.emptyReadMessage(reason: "no-selection-text", mode: .region) == Message.empty)
        #expect(Message.emptyReadMessage(reason: "no-text", mode: .region) == Message.empty)
    }

    /// The advice is the only failure whose fix takes a second act, so it stays up longer.
    @Test func theAdviceStaysUpLongerThanAPlainEmptyRead() {
        #expect(Message.emptyReadDuration(reason: "no-selection", mode: .selection) == .seconds(4))
        #expect(Message.emptyReadDuration(reason: "no-text", mode: .region) == .seconds(2))
    }
}
