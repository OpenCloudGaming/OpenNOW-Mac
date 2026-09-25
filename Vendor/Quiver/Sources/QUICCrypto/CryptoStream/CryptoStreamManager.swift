/// CRYPTO Stream Manager
///
/// Manages CRYPTO streams for all encryption levels.

import Foundation
import Synchronization
import QUICCore

/// Manages CRYPTO streams for all encryption levels
public final class CryptoStreamManager: Sendable {
    /// Receive streams per encryption level
    private let receiveStreams: Mutex<[EncryptionLevel: CryptoStream]>

    /// Send offsets per encryption level
    private let sendOffsets: Mutex<[EncryptionLevel: UInt64]>

    /// Sent data buffer per encryption level (for Retry handling)
    /// RFC 9000 Section 8.1.2: Client needs to resend CRYPTO data after Retry
    private let sentDataBuffers: Mutex<[EncryptionLevel: Data]>

    /// Maximum buffer size per stream
    private let maxBufferSize: UInt64

    /// Creates a new CryptoStreamManager
    /// - Parameter maxBufferSize: Maximum buffer size per stream (default 16KB)
    public init(maxBufferSize: UInt64 = CryptoStream.defaultMaxBufferSize) {
        self.maxBufferSize = maxBufferSize

        var streams: [EncryptionLevel: CryptoStream] = [:]
        var offsets: [EncryptionLevel: UInt64] = [:]
        var sentBuffers: [EncryptionLevel: Data] = [:]

        // Initialize for levels that use CRYPTO frames
        for level in [EncryptionLevel.initial, .handshake, .application] {
            streams[level] = CryptoStream(maxBufferSize: maxBufferSize)
            offsets[level] = 0
            sentBuffers[level] = Data()
        }

        self.receiveStreams = Mutex(streams)
        self.sendOffsets = Mutex(offsets)
        self.sentDataBuffers = Mutex(sentBuffers)
    }

    /// Receive a CRYPTO frame at the specified level
    /// - Parameters:
    ///   - frame: The CRYPTO frame to receive
    ///   - level: The encryption level
    /// - Throws: `CryptoStreamError` on buffer overflow
    public func receive(_ frame: CryptoFrame, at level: EncryptionLevel) throws {
        try receiveStreams.withLock { streams in
            try streams[level]?.receive(frame)
        }
    }

    /// Read available contiguous data for a level
    /// - Parameter level: The encryption level
    /// - Returns: Contiguous data if available, nil otherwise
    public func read(at level: EncryptionLevel) -> Data? {
        receiveStreams.withLock { streams in
            streams[level]?.read()
        }
    }

    /// Peek at available data without consuming
    /// - Parameter level: The encryption level
    /// - Returns: Contiguous data if available
    public func peek(at level: EncryptionLevel) -> Data? {
        receiveStreams.withLock { streams in
            streams[level]?.peek()
        }
    }

    /// Whether there is pending data with gaps at a level
    /// - Parameter level: The encryption level
    /// - Returns: true if there are gaps in the buffered data
    public func hasPendingGaps(at level: EncryptionLevel) -> Bool {
        receiveStreams.withLock { streams in
            streams[level]?.hasPendingGaps ?? false
        }
    }

    /// Whether the receive buffer is empty at a level
    /// - Parameter level: The encryption level
    /// - Returns: true if empty
    public func isReceiveBufferEmpty(at level: EncryptionLevel) -> Bool {
        receiveStreams.withLock { streams in
            streams[level]?.isEmpty ?? true
        }
    }

    /// The current read offset for a level
    /// - Parameter level: The encryption level
    /// - Returns: The current read offset
    public func readOffset(at level: EncryptionLevel) -> UInt64 {
        receiveStreams.withLock { streams in
            streams[level]?.currentOffset ?? 0
        }
    }

    /// Create CRYPTO frames for sending data
    /// - Parameters:
    ///   - data: Data to send
    ///   - level: Encryption level
    ///   - maxFrameSize: Maximum frame payload size.  Callers must supply
    ///     the configured path MTU (`QUICConfiguration.maxUDPPayloadSize`).
    /// - Returns: Array of CryptoFrames to send
    public func createFrames(
        for data: Data,
        at level: EncryptionLevel,
        maxFrameSize: Int
    ) -> [CryptoFrame] {
        // Store the sent data for potential Retry handling
        sentDataBuffers.withLock { buffers in
            if buffers[level] == nil {
                buffers[level] = Data()
            }
            buffers[level]!.append(data)
        }

        return sendOffsets.withLock { offsets in
            var frames: [CryptoFrame] = []
            var remaining = data
            var offset = offsets[level] ?? 0

            while !remaining.isEmpty {
                let chunkSize = min(remaining.count, maxFrameSize)
                let chunk = Data(remaining.prefix(chunkSize))
                remaining = Data(remaining.dropFirst(chunkSize))

                frames.append(CryptoFrame(offset: offset, data: chunk))
                offset += UInt64(chunkSize)
            }

            offsets[level] = offset
            return frames
        }
    }

    /// The current send offset for a level
    /// - Parameter level: The encryption level
    /// - Returns: The current send offset
    public func sendOffset(at level: EncryptionLevel) -> UInt64 {
        sendOffsets.withLock { offsets in
            offsets[level] ?? 0
        }
    }

    /// Gets sent CRYPTO data for Retry packet handling
    ///
    /// RFC 9000 Section 8.1.2: After receiving a Retry packet, the client
    /// needs to resend its Initial CRYPTO data with the retry token.
    ///
    /// - Parameter level: The encryption level
    /// - Returns: All CRYPTO data that has been sent at this level
    public func getDataForRetry(level: EncryptionLevel) -> Data {
        sentDataBuffers.withLock { buffers in
            buffers[level] ?? Data()
        }
    }

    /// Discards the stream for a level (e.g., when encryption level is discarded)
    /// - Parameter level: The encryption level to discard
    public func discardLevel(_ level: EncryptionLevel) {
        receiveStreams.withLock { streams in
            streams[level] = CryptoStream(maxBufferSize: maxBufferSize)
        }
        sendOffsets.withLock { offsets in
            offsets[level] = 0
        }
        sentDataBuffers.withLock { buffers in
            buffers[level] = Data()
        }
    }
}
