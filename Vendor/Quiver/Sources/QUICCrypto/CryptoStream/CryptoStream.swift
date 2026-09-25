/// CRYPTO Stream Reassembly
///
/// Reassembles out-of-order CRYPTO frames for TLS handshake data.

import Foundation
import QUICCore

/// Error thrown by CryptoStream operations
public enum CryptoStreamError: Error, Sendable {
    /// Buffer size limit exceeded
    case bufferExceeded(currentSize: Int, maxSize: Int)
    /// Invalid offset (negative or overflow)
    case invalidOffset(UInt64)
}

/// Reassembles out-of-order CRYPTO frames for a single encryption level
public struct CryptoStream: Sendable {
    /// Ordered buffer of received data
    private var buffer: CryptoBuffer

    /// Next expected offset (for in-order delivery)
    private var readOffset: UInt64

    /// Total bytes received (including consumed)
    private var totalReceived: UInt64

    /// Maximum buffer size (crypto buffer limit)
    private let maxBufferSize: UInt64

    /// Default maximum buffer size (16KB per RFC recommendation)
    public static let defaultMaxBufferSize: UInt64 = 16_384

    /// Creates a new CryptoStream
    /// - Parameter maxBufferSize: Maximum buffer size in bytes (default 16KB)
    public init(maxBufferSize: UInt64 = CryptoStream.defaultMaxBufferSize) {
        self.buffer = CryptoBuffer()
        self.readOffset = 0
        self.totalReceived = 0
        self.maxBufferSize = maxBufferSize
    }

    /// Receives a CRYPTO frame and buffers its data
    /// - Parameter frame: The received CRYPTO frame
    /// - Throws: `CryptoStreamError.bufferExceeded` if buffer limit exceeded
    public mutating func receive(_ frame: CryptoFrame) throws {
        guard !frame.data.isEmpty else { return }

        // Calculate end offset
        let endOffset = frame.offset + UInt64(frame.data.count)

        // Check if this would exceed buffer limit
        // Buffer limit is measured from read offset to end of buffered data
        if endOffset > readOffset + maxBufferSize {
            throw CryptoStreamError.bufferExceeded(
                currentSize: buffer.totalBytes,
                maxSize: Int(maxBufferSize)
            )
        }

        // Skip data we've already read
        if endOffset <= readOffset {
            // Entirely duplicate data - ignore
            return
        }

        // Trim leading bytes if they overlap with already-read data
        var dataToInsert = frame.data
        var insertOffset = frame.offset
        if frame.offset < readOffset {
            let skip = Int(readOffset - frame.offset)
            dataToInsert = Data(frame.data.dropFirst(skip))
            insertOffset = readOffset
        }

        // Insert into buffer
        buffer.insert(offset: insertOffset, data: dataToInsert)
        totalReceived += UInt64(dataToInsert.count)
    }

    /// Returns contiguous data available for reading from readOffset
    /// - Returns: Data if contiguous bytes available, nil otherwise
    public mutating func read() -> Data? {
        guard let data = buffer.readContiguous(from: readOffset) else {
            return nil
        }

        // Consume the data
        let newOffset = readOffset + UInt64(data.count)
        buffer.consume(upTo: newOffset)
        readOffset = newOffset

        return data
    }

    /// Peek at next contiguous data without consuming
    /// - Returns: Contiguous data if available
    public func peek() -> Data? {
        buffer.peekContiguous(from: readOffset)
    }

    /// Current read offset
    public var currentOffset: UInt64 { readOffset }

    /// Whether there is pending data that cannot yet be read (gap exists)
    public var hasPendingGaps: Bool {
        buffer.hasDataAfter(readOffset) && peek() == nil
    }

    /// Whether the buffer is empty (all data has been read)
    public var isEmpty: Bool {
        buffer.isEmpty
    }

    /// The amount of buffered data not yet read
    public var bufferedBytes: Int {
        buffer.totalBytes
    }
}
