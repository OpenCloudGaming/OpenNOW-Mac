import Testing
@testable import OpenNOW

/// The hovered tile's caption is lifted to its section, and a tile that is not hovered must not
/// clear a caption another tile is already supplying.
struct StreamHUDHoveredCaptionTests {
    @Test func aHoveredTileSuppliesItsCaption() {
        var value: String?
        StreamHUDHoveredCaptionKey.reduce(value: &value, nextValue: { "Mute microphone · Voice Activity" })
        #expect(value == "Mute microphone · Voice Activity")
    }

    @Test func anUnhoveredTileDoesNotClearTheHoveredOne() {
        var value: String? = "Mute microphone"
        StreamHUDHoveredCaptionKey.reduce(value: &value, nextValue: { nil })
        #expect(value == "Mute microphone")
    }
}
