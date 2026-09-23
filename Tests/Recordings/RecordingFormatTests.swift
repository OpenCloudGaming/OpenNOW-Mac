//  The quality label the recordings rows show, for both a library recording and a retained replay
//  window that only knows its encoded shape.
//

import Foundation
import Testing
@testable import OpenNOW

@Suite("Recording format")
struct RecordingFormatTests {
    @Test("a quality label names the tier the encoded shape falls into")
    func qualityLabelsNameTheEncodedTier() {
        #expect(RecordingFormat.qualityText(width: 3840, height: 2160) == "4K")
        #expect(RecordingFormat.qualityText(width: 2560, height: 1440) == "1440p")
        #expect(RecordingFormat.qualityText(width: 1920, height: 1080) == "1080p")
        #expect(RecordingFormat.qualityText(width: 1280, height: 720) == "720p")
        // The 480p replay tier scales 16:9 down to an even 852x480 rather than a round number.
        #expect(RecordingFormat.qualityText(width: 852, height: 480) == "480p")
        #expect(RecordingFormat.qualityText(width: 0, height: 0) == "Auto")
    }
}
