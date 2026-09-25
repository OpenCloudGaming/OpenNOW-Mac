import Foundation
import Testing
@testable import OpenNOW

/// The SESSION panel's elapsed clock reads as `M:SS` under an hour, `H:MM:SS` above it, and never
/// as a negative time.
struct StreamSessionElapsedTimeTests {
    private let start = Date(timeIntervalSince1970: 0)

    @Test func itReadsAsAShortClockUnderAnHour() {
        #expect(StreamSessionElapsedTime.text(since: start, at: start.addingTimeInterval(59)) == "0:59")
        #expect(StreamSessionElapsedTime.text(since: start, at: start.addingTimeInterval(600)) == "10:00")
    }

    @Test func itGrowsToHoursAndMinutesPastAnHour() {
        #expect(StreamSessionElapsedTime.text(since: start, at: start.addingTimeInterval(3661)) == "1:01:01")
    }

    @Test func itShowsNoTimeUntilTheSessionStarts() {
        #expect(StreamSessionElapsedTime.text(since: nil, at: Date()) == "--")
    }

    @Test func aClockThatRunsBackwardsDoesNotReadAsNegative() {
        #expect(StreamSessionElapsedTime.text(since: start, at: start.addingTimeInterval(-5)) == "0:00")
    }
}
