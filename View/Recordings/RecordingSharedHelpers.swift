//  Small pieces the recording editor uses in several places.
//

import Foundation

/// Tracks how many views still want a recording's derived media.
///
/// The filmstrip's frame grids and the waveform's peaks are both built in the background, shared by
/// every clip of one recording, and thrown away when the editor closes. Both had grown their own
/// copy of the same count-up/count-down, and one of them had it wrong for a while.
struct RecordingInterestCounter {
    private var counts: [UUID: Int] = [:]

    /// True when this is the first interest in the recording, so the caller should start building.
    mutating func retain(_ recordingID: UUID) -> Bool {
        let previous = counts[recordingID] ?? 0
        counts[recordingID] = previous + 1
        return previous == 0
    }

    /// True when the last interest has gone, so the caller should cancel and discard.
    mutating func release(_ recordingID: UUID) -> Bool {
        let remaining = (counts[recordingID] ?? 1) - 1
        guard remaining <= 0 else {
            counts[recordingID] = remaining
            return false
        }
        counts[recordingID] = nil
        return true
    }
}

/// The entry in `values` whose `key` is closest to `target`, by binary search.
///
/// Runs for every tile of every clip on every redraw, and the timeline redraws several times a
/// second while the preview plays; a linear scan of a few hundred frames was thousands of
/// comparisons a frame. `values` must be sorted ascending by `key`.
func recordingNearestIndex<Element>(in values: [Element], to target: Double, key: (Element) -> Double) -> Int? {
    guard !values.isEmpty else { return nil }
    var low = 0
    var high = values.count - 1
    while low < high {
        let mid = (low + high) / 2
        if key(values[mid]) < target { low = mid + 1 } else { high = mid }
    }
    if low > 0, abs(key(values[low - 1]) - target) < abs(key(values[low]) - target) {
        return low - 1
    }
    return low
}

extension Comparable {
    /// Order-safe clamping. Several call sites compute an upper bound that can fall below the lower
    /// one - `1 - cropWidth` once the crop fills the frame - and `ClosedRange` traps on that, so
    /// this takes the bounds loose rather than as a range.
    func clampedBetween(_ lower: Self, _ upper: Self) -> Self {
        min(max(self, lower), max(lower, upper))
    }
}

/// Space reserved at one end of the timeline while a trim handle is dragged outward.
///
/// The track fits its clips exactly, so there is no room to grow into until some is made. Both
/// values are fixed for the duration of a drag, which is what keeps the scale - and so the
/// handle's tracking of the pointer - constant while it happens.
struct RecordingTrimHeadroom: Equatable {
    var leading: Double = 0
    var trailing: Double = 0

    static let none = RecordingTrimHeadroom()

    /// How far a drag may restore in one go.
    ///
    /// Bounded by what the source actually holds, and by the timeline's own length so the clips are
    /// never squeezed past half their width. A longer restore takes a second drag, which is a fair
    /// trade for the handle staying under the pointer.
    static func forDrag(
        isLeading: Bool,
        segmentStart: Double,
        segmentEnd: Double,
        sourceDuration: Double,
        committedDuration: Double
    ) -> RecordingTrimHeadroom {
        let cap = max(5, committedDuration)
        if isLeading {
            return RecordingTrimHeadroom(leading: min(max(0, segmentStart), cap), trailing: 0)
        }
        return RecordingTrimHeadroom(leading: 0, trailing: min(max(0, sourceDuration - segmentEnd), cap))
    }
}
