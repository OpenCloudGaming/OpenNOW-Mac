/// CRYPTO Frame Buffer
///
/// Ordered buffer for reassembling out-of-order CRYPTO frame data.

import Foundation

/// Internal buffer for ordered CRYPTO data reassembly
struct CryptoBuffer: Sendable {
    /// Segments stored as (offset, data), not necessarily sorted or contiguous
    private var segments: [(offset: UInt64, data: Data)] = []

    /// Total bytes stored in the buffer
    private(set) var totalBytes: Int = 0

    /// Creates an empty CryptoBuffer
    init() {}

    /// Inserts data at the specified offset
    /// - Parameters:
    ///   - offset: The byte offset where this data starts
    ///   - data: The data to insert
    mutating func insert(offset: UInt64, data: Data) {
        guard !data.isEmpty else { return }

        // Find insertion point
        var insertIndex = segments.count
        for (index, segment) in segments.enumerated() {
            if offset < segment.offset {
                insertIndex = index
                break
            }
        }

        // Insert the new segment
        segments.insert((offset: offset, data: data), at: insertIndex)
        totalBytes += data.count

        // Merge overlapping and adjacent segments
        mergeSegments()
    }

    /// Merges overlapping and adjacent segments
    private mutating func mergeSegments() {
        guard segments.count > 1 else { return }

        var merged: [(offset: UInt64, data: Data)] = []
        var current = segments[0]

        for i in 1..<segments.count {
            let next = segments[i]
            let currentEnd = current.offset + UInt64(current.data.count)

            if next.offset <= currentEnd {
                // Overlapping or adjacent - merge
                if next.offset + UInt64(next.data.count) > currentEnd {
                    // Next segment extends beyond current
                    let overlap = Int(currentEnd - next.offset)
                    let newData = next.data.dropFirst(overlap)
                    var merged = current.data
                    merged.append(contentsOf: newData)
                    current = (
                        offset: current.offset,
                        data: merged
                    )
                }
                // else: next segment is completely contained within current, skip it
            } else {
                // Gap between segments
                merged.append(current)
                current = next
            }
        }
        merged.append(current)

        // Recalculate total bytes
        totalBytes = merged.reduce(0) { $0 + $1.data.count }
        segments = merged
    }

    /// Reads contiguous data starting from the given offset
    /// - Parameter offset: The starting offset to read from
    /// - Returns: Contiguous data if available, nil if there's a gap or no data
    func readContiguous(from offset: UInt64) -> Data? {
        guard let first = segments.first else { return nil }

        // Check if data starts at the requested offset
        guard first.offset == offset else { return nil }

        // Return the first segment's data
        return first.data
    }

    /// Peeks at contiguous data without consuming it
    /// - Parameter offset: The starting offset
    /// - Returns: Contiguous data if available
    func peekContiguous(from offset: UInt64) -> Data? {
        readContiguous(from: offset)
    }

    /// Consumes data up to the given offset
    /// - Parameter offset: The offset up to which data should be removed
    mutating func consume(upTo offset: UInt64) {
        guard !segments.isEmpty else { return }

        // Remove segments that are completely before the offset
        while let first = segments.first {
            let segmentEnd = first.offset + UInt64(first.data.count)
            if segmentEnd <= offset {
                totalBytes -= first.data.count
                segments.removeFirst()
            } else if first.offset < offset {
                // Partial consumption - trim the segment
                let bytesToRemove = Int(offset - first.offset)
                let remaining = first.data.dropFirst(bytesToRemove)
                totalBytes -= bytesToRemove
                segments[0] = (offset: offset, data: Data(remaining))
                break
            } else {
                break
            }
        }
    }

    /// Whether there is any data after the given offset (indicating pending gaps)
    /// - Parameter offset: The offset to check
    /// - Returns: true if there is data after offset
    func hasDataAfter(_ offset: UInt64) -> Bool {
        for segment in segments {
            if segment.offset > offset ||
               segment.offset + UInt64(segment.data.count) > offset {
                return true
            }
        }
        return false
    }

    /// Whether the buffer is empty
    var isEmpty: Bool {
        segments.isEmpty
    }

    /// The number of segments in the buffer
    var segmentCount: Int {
        segments.count
    }
}
