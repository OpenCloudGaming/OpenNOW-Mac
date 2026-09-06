import Testing
@testable import OpenNOW

/// `NvstVideoPipeline.RecentDecodeTimes` is the ring buffer behind the HUD's p99 reading — see
/// that type's doc for why a lifetime mean can't show a tail problem. Tested in isolation because
/// its wraparound and interpolation are real logic, independent of VideoToolbox.
struct NvstRecentDecodeTimesTests {
    @Test func emptyWindowReportsUnavailable() {
        let window = NvstVideoPipeline.RecentDecodeTimes()
        #expect(window.percentile(0.99) == -1)
        #expect(window.maximum == -1)
        #expect(window.sampleCount == 0)
    }

    @Test func p99IsTheTopOfARisingRun() {
        var window = NvstVideoPipeline.RecentDecodeTimes()
        for value in stride(from: 1.0, through: 100.0, by: 1.0) { window.record(value) }
        // 100 sorted values 1...100: rank 0.99*(100-1) = 98.01 sits 1% of the way from the 99th
        // value to the 100th (index 98 to 99, zero-based) — the interpolation, not an off-by-one.
        #expect(window.percentile(0.99) == 99.01)
        #expect(window.percentile(0.5) == 50.5)
        #expect(window.maximum == 100.0)
        #expect(window.sampleCount == 100)
    }

    @Test func wraparoundKeepsOnlyTheMostRecentCapacitySamples() {
        var window = NvstVideoPipeline.RecentDecodeTimes()
        // One huge early spike, then enough normal frames to push it out of the window entirely —
        // this is the exact case a lifetime mean gets wrong and this window must get right.
        window.record(2665.0)
        for _ in 0..<300 { window.record(6.0) }
        #expect(window.sampleCount == 256)
        #expect(window.maximum == 6.0)
        #expect(window.percentile(0.99) == 6.0)
    }

    @Test func aFewLateSpikesShowUpAtTheTailWhileTheMeanStaysComfortable() {
        var window = NvstVideoPipeline.RecentDecodeTimes()
        // 3 slow frames in 100 (matches the measured live shape: 372 of 22663, ~1.6%) — enough to
        // land inside the top 1% by rank, unlike a single one-off in a 256-sample window.
        for _ in 0..<97 { window.record(6.0) }
        for _ in 0..<3 { window.record(28.0) }
        let mean = ((97 * 6.0) + (3 * 28.0)) / 100
        #expect(mean < 8.3) // comfortable against a 120 fps budget
        #expect(window.percentile(0.99) == 28.0) // over budget — this is what the mean hides
        #expect(window.maximum == 28.0)
    }
}
