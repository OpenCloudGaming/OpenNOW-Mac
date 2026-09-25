/// Frame Size Calculator (RFC 9000)
///
/// Provides accurate frame size calculations for QUIC frames.
/// This is the single source of truth for frame sizes, used by both
/// frame encoding and capacity planning.

import Foundation

/// Frame size calculation utilities
public enum FrameSize {

    // MARK: - STREAM Frame

    /// Calculates the encoded size of a STREAM frame
    ///
    /// STREAM frame format:
    /// - Type (1 byte): 0x08-0x0f with flags
    /// - Stream ID (1-8 bytes): varint
    /// - Offset (0-8 bytes): varint, present if offset > 0
    /// - Length (0-8 bytes): varint, present if hasLength
    /// - Data (variable): the actual data
    ///
    /// - Parameters:
    ///   - streamID: The stream identifier
    ///   - offset: The data offset (0 means no offset field)
    ///   - dataLength: Length of the data payload
    ///   - hasLength: Whether the length field is included
    /// - Returns: Total encoded size in bytes
    @inlinable
    public static func streamFrame(
        streamID: UInt64,
        offset: UInt64,
        dataLength: Int,
        hasLength: Bool
    ) -> Int {
        streamFrameOverhead(
            streamID: streamID,
            offset: offset,
            dataLength: dataLength,
            hasLength: hasLength
        ) + dataLength
    }

    /// Calculates just the overhead (excluding data) of a STREAM frame
    ///
    /// - Parameters:
    ///   - streamID: The stream identifier
    ///   - offset: The data offset
    ///   - dataLength: Length of the data (needed for length field size calculation)
    ///   - hasLength: Whether the length field is included
    /// - Returns: Overhead in bytes (frame size minus data)
    @inlinable
    public static func streamFrameOverhead(
        streamID: UInt64,
        offset: UInt64,
        dataLength: Int,
        hasLength: Bool
    ) -> Int {
        var size = 1  // Type byte
        size += Varint.encodedLength(for: streamID)

        if offset > 0 {
            size += Varint.encodedLength(for: offset)
        }

        if hasLength {
            size += Varint.encodedLength(for: UInt64(dataLength))
        }

        return size
    }

    /// Calculates the maximum overhead for a STREAM frame (worst case)
    ///
    /// Use this when you need a conservative estimate before knowing exact values.
    /// Overhead = 1 (type) + 8 (stream ID) + 8 (offset) + 8 (length) = 25 bytes
    public static let maxStreamFrameOverhead = 25

    // MARK: - ACK Frame

    /// Calculates the encoded size of an ACK frame
    ///
    /// ACK frame format:
    /// - Type (1 byte): 0x02 or 0x03 (with ECN)
    /// - Largest Acknowledged (1-8 bytes): varint
    /// - ACK Delay (1-8 bytes): varint
    /// - ACK Range Count (1-8 bytes): varint
    /// - First ACK Range (1-8 bytes): varint
    /// - ACK Ranges (variable): gap + range pairs
    /// - ECN Counts (optional): 3 varints
    ///
    /// - Parameter frame: The ACK frame
    /// - Returns: Total encoded size in bytes
    @inlinable
    public static func ackFrame(_ frame: AckFrame) -> Int {
        var size = 1  // Type byte
        size += Varint.encodedLength(for: frame.largestAcknowledged)
        size += Varint.encodedLength(for: frame.ackDelay)

        let rangeCount = frame.ackRanges.isEmpty ? 0 : frame.ackRanges.count - 1
        size += Varint.encodedLength(for: UInt64(rangeCount))

        // First ACK Range
        if let firstRange = frame.ackRanges.first {
            size += Varint.encodedLength(for: firstRange.rangeLength)
        } else {
            size += 1  // Zero-length first range
        }

        // Additional ACK Ranges (gap + range pairs)
        // インデックスベースのループで ArraySlice 作成を回避
        // dropFirst() は ArraySlice を返すため、iterator 生成コストが発生する
        let ranges = frame.ackRanges
        if ranges.count > 1 {
            for i in 1..<ranges.count {
                size += Varint.encodedLength(for: ranges[i].gap)
                size += Varint.encodedLength(for: ranges[i].rangeLength)
            }
        }

        // ECN Counts (if present)
        if let ecn = frame.ecnCounts {
            size += Varint.encodedLength(for: ecn.ect0Count)
            size += Varint.encodedLength(for: ecn.ect1Count)
            size += Varint.encodedLength(for: ecn.ecnCECount)
        }

        return size
    }

    // MARK: - CRYPTO Frame

    /// Calculates the encoded size of a CRYPTO frame
    ///
    /// CRYPTO frame format:
    /// - Type (1 byte): 0x06
    /// - Offset (1-8 bytes): varint
    /// - Length (1-8 bytes): varint
    /// - Data (variable): the actual data
    ///
    /// - Parameter frame: The CRYPTO frame
    /// - Returns: Total encoded size in bytes
    @inlinable
    public static func cryptoFrame(offset: UInt64, dataLength: Int) -> Int {
        cryptoFrameOverhead(offset: offset, dataLength: dataLength) + dataLength
    }

    /// Calculates just the overhead of a CRYPTO frame
    @inlinable
    public static func cryptoFrameOverhead(offset: UInt64, dataLength: Int) -> Int {
        var size = 1  // Type byte
        size += Varint.encodedLength(for: offset)
        size += Varint.encodedLength(for: UInt64(dataLength))
        return size
    }

    // MARK: - Control Frames

    /// Calculates the encoded size of a MAX_DATA frame (1 + varint)
    @inlinable
    public static func maxDataFrame(maxData: UInt64) -> Int {
        1 + Varint.encodedLength(for: maxData)
    }

    /// Calculates the encoded size of a MAX_STREAM_DATA frame
    @inlinable
    public static func maxStreamDataFrame(streamID: UInt64, maxData: UInt64) -> Int {
        1 + Varint.encodedLength(for: streamID) + Varint.encodedLength(for: maxData)
    }

    /// Calculates the encoded size of a MAX_STREAMS frame
    @inlinable
    public static func maxStreamsFrame(maxStreams: UInt64) -> Int {
        1 + Varint.encodedLength(for: maxStreams)
    }

    /// Calculates the encoded size of a RESET_STREAM frame
    @inlinable
    public static func resetStreamFrame(streamID: UInt64, errorCode: UInt64, finalSize: UInt64) -> Int {
        1 + Varint.encodedLength(for: streamID)
          + Varint.encodedLength(for: errorCode)
          + Varint.encodedLength(for: finalSize)
    }

    /// Calculates the encoded size of a STOP_SENDING frame
    @inlinable
    public static func stopSendingFrame(streamID: UInt64, errorCode: UInt64) -> Int {
        1 + Varint.encodedLength(for: streamID) + Varint.encodedLength(for: errorCode)
    }

    // MARK: - Fixed-Size Frames

    /// PING frame size (always 1 byte)
    public static let pingFrame = 1

    /// HANDSHAKE_DONE frame size (always 1 byte)
    public static let handshakeDoneFrame = 1

    /// PATH_CHALLENGE frame size (1 type + 8 data = 9 bytes)
    public static let pathChallengeFrame = 9

    /// PATH_RESPONSE frame size (1 type + 8 data = 9 bytes)
    public static let pathResponseFrame = 9

    // MARK: - Generic Frame Size

    /// Calculates the encoded size of any frame
    ///
    /// This is a convenience method that dispatches to the appropriate
    /// specialized calculator. For hot paths, prefer using the specific
    /// methods directly to avoid the switch overhead.
    ///
    /// - Parameter frame: The frame to calculate size for
    /// - Returns: Total encoded size in bytes
    public static func frame(_ frame: Frame) -> Int {
        switch frame {
        case .padding(let count):
            return count

        case .ping:
            return pingFrame

        case .ack(let ackFrame):
            return self.ackFrame(ackFrame)

        case .resetStream(let f):
            return resetStreamFrame(
                streamID: f.streamID,
                errorCode: f.applicationErrorCode,
                finalSize: f.finalSize
            )

        case .stopSending(let f):
            return stopSendingFrame(streamID: f.streamID, errorCode: f.applicationErrorCode)

        case .crypto(let f):
            return cryptoFrame(offset: f.offset, dataLength: f.data.count)

        case .newToken(let token):
            return 1 + Varint.encodedLength(for: UInt64(token.count)) + token.count

        case .stream(let f):
            return streamFrame(
                streamID: f.streamID,
                offset: f.offset,
                dataLength: f.data.count,
                hasLength: f.hasLength
            )

        case .maxData(let maxData):
            return maxDataFrame(maxData: maxData)

        case .maxStreamData(let f):
            return maxStreamDataFrame(streamID: f.streamID, maxData: f.maxStreamData)

        case .maxStreams(let f):
            return maxStreamsFrame(maxStreams: f.maxStreams)

        case .dataBlocked(let limit):
            return 1 + Varint.encodedLength(for: limit)

        case .streamDataBlocked(let f):
            return 1 + Varint.encodedLength(for: f.streamID)
                     + Varint.encodedLength(for: f.streamDataLimit)

        case .streamsBlocked(let f):
            return 1 + Varint.encodedLength(for: f.streamLimit)

        case .newConnectionID(let f):
            // 1 (type) + seqNum + retirePriorTo + 1 (CID length) + CID + 16 (reset token)
            return 1 + Varint.encodedLength(for: f.sequenceNumber)
                     + Varint.encodedLength(for: f.retirePriorTo)
                     + 1 + f.connectionID.length + 16

        case .retireConnectionID(let seqNum):
            return 1 + Varint.encodedLength(for: seqNum)

        case .pathChallenge:
            return pathChallengeFrame

        case .pathResponse:
            return pathResponseFrame

        case .connectionClose(let f):
            let reasonBytes = f.reasonPhrase.utf8.count
            var size = 1  // Type
            size += Varint.encodedLength(for: f.errorCode)
            if !f.isApplicationError {
                size += Varint.encodedLength(for: f.frameType ?? 0)
            }
            size += Varint.encodedLength(for: UInt64(reasonBytes))
            size += reasonBytes
            return size

        case .handshakeDone:
            return handshakeDoneFrame

        case .datagram(let f):
            if f.hasLength {
                return 1 + Varint.encodedLength(for: UInt64(f.data.count)) + f.data.count
            } else {
                return 1 + f.data.count
            }
        }
    }
}
