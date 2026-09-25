/// MTU-Aware Frame Packer
///
/// Pure frame-batching logic that splits a list of frames into batches
/// where each batch's total encoded size fits within a given payload budget.
///
/// This is intentionally separated from encryption so the splitting
/// algorithm can be unit-tested without requiring crypto contexts.

import Foundation

// MARK: - MTU Frame Packer

/// Splits frames into MTU-respecting batches.
///
/// Each batch produced by ``pack(frames:maxPayload:)`` satisfies:
///
///     batch.reduce(0) { $0 + FrameSize.frame($1) } <= maxPayload
///
/// with the sole exception of a single frame whose encoded size already
/// exceeds `maxPayload` -- such a frame is emitted alone so that
/// subsequent frames are not lost when the encoder rejects the oversized
/// packet (RC4 protection).
package enum MTUFramePacker {

    /// A single batch of frames whose total wire size is at most `maxPayload`,
    /// except when a single frame is inherently oversized.
    package struct Batch: Sendable {
        /// Frames in this batch.
        package let frames: [Frame]
        /// Sum of `FrameSize.frame(_:)` for every frame in `frames`.
        package let totalSize: Int
        /// Whether this batch contains a single frame that exceeds the
        /// payload budget.  Callers should expect the encoder to reject it.
        package let isOversized: Bool
    }

    /// Packs `frames` into the minimum number of batches such that each
    /// batch's total encoded frame size is at most `maxPayload` bytes.
    ///
    /// - Parameters:
    ///   - frames: Ordered list of frames to pack.
    ///   - maxPayload: Maximum sum of encoded frame bytes per batch
    ///     (i.e. `maxDatagramSize - packetOverhead`).
    /// - Returns: Array of ``Batch`` values in the same frame order.
    ///   Returns an empty array when `frames` is empty.
    ///
    /// ## Invariants
    ///
    /// 1. Every non-oversized batch satisfies `totalSize <= maxPayload`.
    /// 2. An oversized batch contains exactly one frame and has
    ///    `isOversized == true`.
    /// 3. Concatenating all batches' `frames` arrays in order yields the
    ///    original `frames` array (order-preserving, lossless).
    package static func pack(frames: [Frame], maxPayload: Int) -> [Batch] {
        guard !frames.isEmpty else { return [] }

        var result: [Batch] = []
        var currentFrames: [Frame] = []
        var currentSize = 0

        for frame in frames {
            let frameSize = FrameSize.frame(frame)

            // Case 1: Single frame exceeds budget and current batch is empty.
            // Emit it alone as an oversized batch.
            if frameSize > maxPayload && currentFrames.isEmpty {
                result.append(Batch(
                    frames: [frame],
                    totalSize: frameSize,
                    isOversized: true
                ))
                continue
            }

            // Case 2: Single frame exceeds budget but current batch is
            // non-empty.  Flush the current batch first, then emit the
            // oversized frame alone.
            if frameSize > maxPayload {
                result.append(Batch(
                    frames: currentFrames,
                    totalSize: currentSize,
                    isOversized: false
                ))
                currentFrames = []
                currentSize = 0

                result.append(Batch(
                    frames: [frame],
                    totalSize: frameSize,
                    isOversized: true
                ))
                continue
            }

            // Case 3: Adding this frame would exceed the budget.
            // Flush current batch, start a new one.
            if currentSize + frameSize > maxPayload && !currentFrames.isEmpty {
                result.append(Batch(
                    frames: currentFrames,
                    totalSize: currentSize,
                    isOversized: false
                ))
                currentFrames = []
                currentSize = 0
            }

            // Accumulate into current batch.
            currentFrames.append(frame)
            currentSize += frameSize
        }

        // Flush remaining frames.
        if !currentFrames.isEmpty {
            result.append(Batch(
                frames: currentFrames,
                totalSize: currentSize,
                isOversized: false
            ))
        }

        return result
    }

    // MARK: - Overhead Helpers

    /// Computes the wire overhead (header + AEAD tag) for a packet at the
    /// given encryption level.
    ///
    /// This is a pure function: it does not touch any connection state
    /// beyond the supplied connection-ID lengths.
    ///
    /// - Parameters:
    ///   - level: The encryption level of the packet.
    ///   - dcidLength: Destination Connection ID length in bytes.
    ///   - scidLength: Source Connection ID length in bytes.
    /// - Returns: Overhead in bytes.
    package static func packetOverhead(
        for level: EncryptionLevel,
        dcidLength: Int,
        scidLength: Int
    ) -> Int {
        switch level {
        case .initial:
            // Long header: 1 (flags) + 4 (version) + 1+DCID + 1+SCID
            //            + 1 (token length varint for 0) + 2 (length) + 4 (PN) + 16 (AEAD)
            return 1 + 4 + 1 + dcidLength + 1 + scidLength + 1 + 2 + 4 + PacketConstants.aeadTagSize
        case .handshake:
            // Long header: 1 (flags) + 4 (version) + 1+DCID + 1+SCID
            //            + 2 (length) + 4 (PN) + 16 (AEAD)
            return 1 + 4 + 1 + dcidLength + 1 + scidLength + 2 + 4 + PacketConstants.aeadTagSize
        case .application:
            // Short header: 1 (flags) + DCID + 4 (PN) + 16 (AEAD)
            return 1 + dcidLength + 4 + PacketConstants.aeadTagSize
        default:
            // 0-RTT or other -- use long header estimate (same as handshake).
            return 1 + 4 + 1 + dcidLength + 1 + scidLength + 2 + 4 + PacketConstants.aeadTagSize
        }
    }

    /// Convenience: computes `maxDatagramSize - packetOverhead` clamped to >= 0.
    package static func maxPayload(
        for level: EncryptionLevel,
        maxDatagramSize: Int,
        dcidLength: Int,
        scidLength: Int
    ) -> Int {
        max(0, maxDatagramSize - packetOverhead(
            for: level,
            dcidLength: dcidLength,
            scidLength: scidLength
        ))
    }
}