/// QUIC Frame Encoding and Decoding (RFC 9000 Section 12)
///
/// Provides encoding and decoding for all QUIC frame types.

import Foundation
import Logging

// MARK: - Frame Codec Errors

/// Errors that can occur during frame encoding/decoding
public enum FrameCodecError: Error, Sendable {
    /// Insufficient data to decode frame
    case insufficientData
    /// Unknown or invalid frame type
    case unknownFrameType(UInt64)
    /// Invalid frame format
    case invalidFrameFormat(String)
    /// Frame too large
    case frameTooLarge(Int)
}

// MARK: - Frame Encoder Protocol

/// Protocol for encoding frames to binary data
public protocol FrameEncoder: Sendable {
    /// Encodes a single frame to data
    /// - Parameter frame: The frame to encode
    /// - Returns: The encoded frame data
    func encode(_ frame: Frame) throws -> Data

    /// Encodes multiple frames to data
    /// - Parameter frames: The frames to encode
    /// - Returns: The concatenated encoded frame data
    func encodeFrames(_ frames: [Frame]) throws -> Data
}

// MARK: - Frame Decoder Protocol

/// Protocol for decoding frames from binary data
public protocol FrameDecoder: Sendable {
    /// Decodes a single frame from a data reader
    /// - Parameter reader: The data reader positioned at the frame start
    /// - Returns: The decoded frame
    func decode(from reader: inout DataReader) throws -> Frame

    /// Decodes all frames from data
    /// - Parameter data: The data containing one or more frames
    /// - Returns: Array of decoded frames
    func decodeFrames(from data: Data) throws -> [Frame]
}

// MARK: - Standard Frame Codec

/// Standard implementation of frame encoding and decoding
///
/// ## パフォーマンス最適化
/// - `@inlinable` アノテーションにより、モジュール境界を越えてインライン展開可能
/// - 関数呼び出しオーバーヘッドを削減し、さらなるコンパイラ最適化を有効化
/// - 特に小さなフレーム（PING, ACK）で効果的
package struct StandardFrameCodec: FrameEncoder, FrameDecoder, Sendable {
    private static let logger = QuiverLogging.logger(label: "quic.core.frame-codec")

    @inlinable
    package init() {}

    // MARK: - Encoding

    /// フレームをバイナリデータにエンコード
    ///
    /// ## 最適化
    /// - `@inlinable` により呼び出し元でインライン展開可能
    /// - 事前サイズ計算により再割り当てを回避
    @inlinable
    package func encode(_ frame: Frame) throws -> Data {
        // Pre-calculate frame size and allocate exact capacity to avoid reallocations
        let frameSize = FrameSize.frame(frame)
        var writer = DataWriter(capacity: frameSize)
        try encodeFrame(frame, to: &writer)
        return writer.toData()
    }

    /// 複数フレームをバイナリデータにエンコード
    @inlinable
    package func encodeFrames(_ frames: [Frame]) throws -> Data {
        // Pre-calculate total size for all frames to avoid reallocations
        let totalSize = frames.reduce(0) { $0 + FrameSize.frame($1) }
        var writer = DataWriter(capacity: totalSize)
        for frame in frames {
            try encodeFrame(frame, to: &writer)
        }
        return writer.toData()
    }

    /// 内部エンコード実装（@inlinable から呼ばれるため @usableFromInline が必要）
    @usableFromInline
    @inline(__always)
    internal func encodeFrame(_ frame: Frame, to writer: inout DataWriter) throws {
        switch frame {
        case .padding(let count):
            // PADDING frames are just 0x00 bytes
            // Use optimized zero-byte writer which uses Data(count:) internally
            // (faster than Data(repeating: 0x00, count:) for large counts)
            writer.writeZeroBytes(count)

        case .ping:
            // PING frame: just type byte
            writer.writeByte(0x01)

        case .ack(let ackFrame):
            try encodeAckFrame(ackFrame, to: &writer)

        case .resetStream(let resetFrame):
            writer.writeByte(0x04)
            writer.writeVarint(resetFrame.streamID)
            writer.writeVarint(resetFrame.applicationErrorCode)
            writer.writeVarint(resetFrame.finalSize)

        case .stopSending(let stopFrame):
            writer.writeByte(0x05)
            writer.writeVarint(stopFrame.streamID)
            writer.writeVarint(stopFrame.applicationErrorCode)

        case .crypto(let cryptoFrame):
            writer.writeByte(0x06)
            writer.writeVarint(cryptoFrame.offset)
            writer.writeVarint(UInt64(cryptoFrame.data.count))
            writer.writeBytes(cryptoFrame.data)

        case .newToken(let token):
            writer.writeByte(0x07)
            writer.writeVarint(UInt64(token.count))
            writer.writeBytes(token)

        case .stream(let streamFrame):
            try encodeStreamFrame(streamFrame, to: &writer)

        case .maxData(let maxData):
            writer.writeByte(0x10)
            writer.writeVarint(maxData)

        case .maxStreamData(let maxStreamData):
            writer.writeByte(0x11)
            writer.writeVarint(maxStreamData.streamID)
            writer.writeVarint(maxStreamData.maxStreamData)

        case .maxStreams(let maxStreams):
            writer.writeByte(maxStreams.isBidirectional ? 0x12 : 0x13)
            writer.writeVarint(maxStreams.maxStreams)

        case .dataBlocked(let limit):
            writer.writeByte(0x14)
            writer.writeVarint(limit)

        case .streamDataBlocked(let blocked):
            writer.writeByte(0x15)
            writer.writeVarint(blocked.streamID)
            writer.writeVarint(blocked.streamDataLimit)

        case .streamsBlocked(let blocked):
            writer.writeByte(blocked.isBidirectional ? 0x16 : 0x17)
            writer.writeVarint(blocked.streamLimit)

        case .newConnectionID(let newCID):
            writer.writeByte(0x18)
            writer.writeVarint(newCID.sequenceNumber)
            writer.writeVarint(newCID.retirePriorTo)
            writer.writeByte(UInt8(newCID.connectionID.length))
            writer.writeBytes(newCID.connectionID.bytes)
            writer.writeBytes(newCID.statelessResetToken)

        case .retireConnectionID(let sequenceNumber):
            writer.writeByte(0x19)
            writer.writeVarint(sequenceNumber)

        case .pathChallenge(let data):
            // RFC 9000 Section 19.17: PATH_CHALLENGE carries exactly 8 bytes
            guard data.count == 8 else {
                throw FrameCodecError.invalidFrameFormat(
                    "PATH_CHALLENGE data must be exactly 8 bytes, got \(data.count)"
                )
            }
            writer.writeByte(0x1a)
            writer.writeBytes(data)

        case .pathResponse(let data):
            // RFC 9000 Section 19.18: PATH_RESPONSE carries exactly 8 bytes
            guard data.count == 8 else {
                throw FrameCodecError.invalidFrameFormat(
                    "PATH_RESPONSE data must be exactly 8 bytes, got \(data.count)"
                )
            }
            writer.writeByte(0x1b)
            writer.writeBytes(data)

        case .connectionClose(let closeFrame):
            try encodeConnectionCloseFrame(closeFrame, to: &writer)

        case .handshakeDone:
            writer.writeByte(0x1e)

        case .datagram(let datagramFrame):
            if datagramFrame.hasLength {
                writer.writeByte(0x31)
                writer.writeVarint(UInt64(datagramFrame.data.count))
            } else {
                writer.writeByte(0x30)
            }
            writer.writeBytes(datagramFrame.data)
        }
    }

    /// ACKフレームのエンコード
    ///
    /// ## 最適化
    /// - `@usableFromInline` により @inlinable 関数からインライン展開可能
    /// - インデックスベースのループで ArraySlice 作成を回避
    @usableFromInline
    @inline(__always)
    internal func encodeAckFrame(_ ack: AckFrame, to writer: inout DataWriter) throws {
        // Type byte: 0x02 (ACK) or 0x03 (ACK with ECN)
        let hasECN = ack.ecnCounts != nil
        writer.writeByte(hasECN ? 0x03 : 0x02)

        // Largest Acknowledged
        writer.writeVarint(ack.largestAcknowledged)

        // ACK Delay
        writer.writeVarint(ack.ackDelay)

        // ACK Range Count (number of Gap and ACK Range fields)
        let rangeCount = ack.ackRanges.isEmpty ? 0 : ack.ackRanges.count - 1
        writer.writeVarint(UInt64(rangeCount))

        // First ACK Range (from largest acknowledged)
        if let firstRange = ack.ackRanges.first {
            writer.writeVarint(firstRange.rangeLength)
        } else {
            writer.writeVarint(UInt64(0))
        }

        // Additional ACK Ranges (Gap + Range pairs)
        // Use index-based iteration to avoid ArraySlice overhead from dropFirst()
        let ranges = ack.ackRanges
        if ranges.count > 1 {
            for i in 1..<ranges.count {
                writer.writeVarint(ranges[i].gap)
                writer.writeVarint(ranges[i].rangeLength)
            }
        }

        // ECN Counts (if present)
        if let ecn = ack.ecnCounts {
            writer.writeVarint(ecn.ect0Count)
            writer.writeVarint(ecn.ect1Count)
            writer.writeVarint(ecn.ecnCECount)
        }
    }

    /// STREAMフレームのエンコード
    @usableFromInline
    @inline(__always)
    internal func encodeStreamFrame(_ stream: StreamFrame, to writer: inout DataWriter) throws {
        // Build type byte with flags
        var typeByte: UInt8 = 0x08
        let hasOffset = stream.offset > 0

        if hasOffset { typeByte |= 0x04 }          // OFF bit
        if stream.hasLength { typeByte |= 0x02 }   // LEN bit
        if stream.fin { typeByte |= 0x01 }         // FIN bit

        Self.logger.trace("Encoding STREAM frame: streamID=\(stream.streamID), offset=\(stream.offset), dataLen=\(stream.data.count), fin=\(stream.fin), hasLength=\(stream.hasLength)")
        Self.logger.trace("Type byte: 0x\(String(format: "%02X", typeByte)) (OFF=\(hasOffset), LEN=\(stream.hasLength), FIN=\(stream.fin))")

        let startSize = writer.count

        writer.writeByte(typeByte)
        writer.writeVarint(stream.streamID)

        if hasOffset {
            writer.writeVarint(stream.offset)
        }

        // RFC 9000 Section 12.4: If LEN bit is not set, the frame consumes
        // all remaining bytes in the packet and MUST be the last frame.
        // The caller is responsible for ensuring this constraint.
        if stream.hasLength {
            writer.writeVarint(UInt64(stream.data.count))
        }

        writer.writeBytes(stream.data)

        let frameSize = writer.count - startSize
        Self.logger.trace("STREAM frame encoded: \(frameSize) bytes total")
    }

    /// CONNECTION_CLOSEフレームのエンコード
    @usableFromInline
    @inline(__always)
    internal func encodeConnectionCloseFrame(_ close: ConnectionCloseFrame, to writer: inout DataWriter) throws {
        // Type: 0x1c (transport) or 0x1d (application)
        writer.writeByte(close.isApplicationError ? 0x1d : 0x1c)

        writer.writeVarint(close.errorCode)

        // Frame Type (only for transport errors)
        if !close.isApplicationError {
            writer.writeVarint(close.frameType ?? 0)
        }

        // Reason Phrase
        let reasonBytes = Data(close.reasonPhrase.utf8)
        writer.writeVarint(UInt64(reasonBytes.count))
        writer.writeBytes(reasonBytes)
    }

    // MARK: - Decoding

    /// バイナリデータからフレームをデコード
    ///
    /// ## 最適化
    /// - `@inlinable` により呼び出し元でインライン展開可能
    /// - 1バイトvarint（フレームタイプ0x00-0x3F）の高速パス
    @inlinable
    package func decode(from reader: inout DataReader) throws -> Frame {
        guard let firstByte = reader.peekByte() else {
            throw FrameCodecError.insufficientData
        }

        // Optimization: Most frame types fit in a single byte (0x00-0x3F)
        // Check if this is a single-byte varint (MSB prefix 00)
        let frameType: UInt64
        if (firstByte & 0xC0) == 0x00 {
            // Single-byte varint: value is the byte itself
            _ = reader.readByte()
            frameType = UInt64(firstByte)
        } else {
            // Multi-byte varint for extended frame types
            frameType = try reader.readVarintValue()
        }

        // Handle STREAM frames (0x08-0x0f) - type byte contains flags
        if frameType >= 0x08 && frameType <= 0x0f {
            return try decodeStreamFrame(from: &reader, typeByte: UInt8(frameType))
        }

        switch frameType {
        case 0x00:
            // PADDING - count consecutive padding bytes
            var count = 1
            while reader.peekByte() == 0x00 {
                _ = reader.readByte()
                count += 1
            }
            return .padding(count: count)

        case 0x01:
            return .ping

        case 0x02, 0x03:
            return try decodeAckFrame(from: &reader, hasECN: frameType == 0x03)

        case 0x04:
            return try decodeResetStreamFrame(from: &reader)

        case 0x05:
            return try decodeStopSendingFrame(from: &reader)

        case 0x06:
            return try decodeCryptoFrame(from: &reader)

        case 0x07:
            return try decodeNewTokenFrame(from: &reader)

        case 0x10:
            let maxData = try reader.readVarintValue()
            return .maxData(maxData)

        case 0x11:
            return try decodeMaxStreamDataFrame(from: &reader)

        case 0x12, 0x13:
            return try decodeMaxStreamsFrame(from: &reader, isBidi: frameType == 0x12)

        case 0x14:
            let limit = try reader.readVarintValue()
            return .dataBlocked(limit)

        case 0x15:
            return try decodeStreamDataBlockedFrame(from: &reader)

        case 0x16, 0x17:
            return try decodeStreamsBlockedFrame(from: &reader, isBidi: frameType == 0x16)

        case 0x18:
            return try decodeNewConnectionIDFrame(from: &reader)

        case 0x19:
            let seqNum = try reader.readVarintValue()
            return .retireConnectionID(seqNum)

        case 0x1a:
            guard let data = reader.readBytes(8) else {
                throw FrameCodecError.insufficientData
            }
            return .pathChallenge(data)

        case 0x1b:
            guard let data = reader.readBytes(8) else {
                throw FrameCodecError.insufficientData
            }
            return .pathResponse(data)

        case 0x1c, 0x1d:
            return try decodeConnectionCloseFrame(from: &reader, isApp: frameType == 0x1d)

        case 0x1e:
            return .handshakeDone

        case 0x30, 0x31:
            return try decodeDatagramFrame(from: &reader, hasLength: frameType == 0x31)

        default:
            // Unknown or extended frame type
            throw FrameCodecError.unknownFrameType(frameType)
        }
    }

    /// 複数フレームをデコード
    @inlinable
    package func decodeFrames(from data: Data) throws -> [Frame] {
        var reader = DataReader(data)
        var frames: [Frame] = []
        var lastFrameHadNoLength = false

        while reader.hasRemaining {
            // RFC 9000 Section 12.4: Frames without length field must be last
            if lastFrameHadNoLength {
                throw FrameCodecError.invalidFrameFormat(
                    "Frame without length field must be last in packet"
                )
            }

            let frame = try decode(from: &reader)
            frames.append(frame)

            // Check if this frame consumed remaining bytes without explicit length
            lastFrameHadNoLength = isFrameWithoutExplicitLength(frame)
        }

        return frames
    }

    /// Checks if a frame consumed remaining bytes without an explicit length field.
    /// Per RFC 9000 Section 12.4, such frames must be the last frame in a packet.
    @usableFromInline
    @inline(__always)
    internal func isFrameWithoutExplicitLength(_ frame: Frame) -> Bool {
        switch frame {
        case .stream(let sf):
            return !sf.hasLength
        case .datagram(let df):
            return !df.hasLength
        default:
            return false
        }
    }

    // MARK: - Frame-Specific Decoders
    // 以下のデコーダは @inlinable な decode() から呼び出されるため
    // @usableFromInline でモジュール境界を越えたインライン展開を有効化

    /// ACKフレームのデコード
    @usableFromInline
    @inline(__always)
    internal func decodeAckFrame(from reader: inout DataReader, hasECN: Bool) throws -> Frame {
        let largestAcked = try reader.readVarintValue()
        let ackDelay = try reader.readVarintValue()
        let rangeCount = try reader.readVarintValue()
        let firstRangeLength = try reader.readVarintValue()

        // Validate rangeCount against remaining data
        // Each ACK range requires at least 2 bytes (minimum size of 2 varints)
        // Also apply protocol limit to prevent memory exhaustion attacks
        let maxReasonableRangeCount = min(
            UInt64(reader.remainingCount / 2),
            ProtocolLimits.maxAckRanges
        )
        guard rangeCount <= maxReasonableRangeCount else {
            throw FrameCodecError.invalidFrameFormat(
                "ACK range count \(rangeCount) exceeds maximum allowed value \(maxReasonableRangeCount)"
            )
        }

        // Pre-allocate array capacity for performance
        // Safe conversion: rangeCount is validated above to be <= maxAckRanges (256)
        let safeRangeCount = try SafeConversions.toInt(
            rangeCount,
            maxAllowed: Int(ProtocolLimits.maxAckRanges),
            context: "ACK range count"
        )
        var ranges: [AckRange] = []
        ranges.reserveCapacity(safeRangeCount + 1)
        ranges.append(AckRange(gap: 0, rangeLength: firstRangeLength))

        for _ in 0..<safeRangeCount {
            let gap = try reader.readVarintValue()
            let rangeLength = try reader.readVarintValue()
            ranges.append(AckRange(gap: gap, rangeLength: rangeLength))
        }

        var ecnCounts: ECNCounts? = nil
        if hasECN {
            let ect0 = try reader.readVarintValue()
            let ect1 = try reader.readVarintValue()
            let ecnCE = try reader.readVarintValue()
            ecnCounts = ECNCounts(ect0Count: ect0, ect1Count: ect1, ecnCECount: ecnCE)
        }

        return .ack(AckFrame(
            largestAcknowledged: largestAcked,
            ackDelay: ackDelay,
            ackRanges: ranges,
            ecnCounts: ecnCounts
        ))
    }

    @usableFromInline
    @inline(__always)
    internal func decodeResetStreamFrame(from reader: inout DataReader) throws -> Frame {
        let streamID = try reader.readVarintValue()
        let errorCode = try reader.readVarintValue()
        let finalSize = try reader.readVarintValue()
        return .resetStream(ResetStreamFrame(
            streamID: streamID,
            applicationErrorCode: errorCode,
            finalSize: finalSize
        ))
    }

    @usableFromInline
    @inline(__always)
    internal func decodeStopSendingFrame(from reader: inout DataReader) throws -> Frame {
        let streamID = try reader.readVarintValue()
        let errorCode = try reader.readVarintValue()
        return .stopSending(StopSendingFrame(
            streamID: streamID,
            applicationErrorCode: errorCode
        ))
    }

    @usableFromInline
    @inline(__always)
    internal func decodeCryptoFrame(from reader: inout DataReader) throws -> Frame {
        let offset = try reader.readVarintValue()
        let length = try reader.readVarintValue()
        let safeLength = try SafeConversions.toInt(
            length,
            maxAllowed: ProtocolLimits.maxCryptoDataLength,
            context: "CRYPTO frame data length"
        )
        guard let data = reader.readBytes(safeLength) else {
            throw FrameCodecError.insufficientData
        }
        return .crypto(CryptoFrame(offset: offset, data: data))
    }

    @usableFromInline
    @inline(__always)
    internal func decodeNewTokenFrame(from reader: inout DataReader) throws -> Frame {
        let length = try reader.readVarintValue()
        let safeLength = try SafeConversions.toInt(
            length,
            maxAllowed: ProtocolLimits.maxNewTokenLength,
            context: "NEW_TOKEN frame token length"
        )
        guard let token = reader.readBytes(safeLength) else {
            throw FrameCodecError.insufficientData
        }
        return .newToken(token)
    }

    @usableFromInline
    @inline(__always)
    internal func decodeStreamFrame(from reader: inout DataReader, typeByte: UInt8) throws -> Frame {
        let hasOffset = (typeByte & 0x04) != 0
        let hasLength = (typeByte & 0x02) != 0
        let hasFin = (typeByte & 0x01) != 0

        let streamID = try reader.readVarintValue()

        let offset: UInt64
        if hasOffset {
            offset = try reader.readVarintValue()
        } else {
            offset = 0
        }

        let data: Data
        if hasLength {
            let length = try reader.readVarintValue()
            let safeLength = try SafeConversions.toInt(
                length,
                maxAllowed: ProtocolLimits.maxStreamDataLength,
                context: "STREAM frame data length"
            )
            guard let bytes = reader.readBytes(safeLength) else {
                throw FrameCodecError.insufficientData
            }
            data = bytes
        } else {
            // No length means data extends to end of packet
            // Per RFC 9000 Section 12.4, this frame must be last in packet
            data = reader.readRemainingBytes()
        }

        return .stream(StreamFrame(
            streamID: streamID,
            offset: offset,
            data: data,
            fin: hasFin,
            hasLength: hasLength
        ))
    }

    @usableFromInline
    @inline(__always)
    internal func decodeMaxStreamDataFrame(from reader: inout DataReader) throws -> Frame {
        let streamID = try reader.readVarintValue()
        let maxStreamData = try reader.readVarintValue()
        return .maxStreamData(MaxStreamDataFrame(
            streamID: streamID,
            maxStreamData: maxStreamData
        ))
    }

    @usableFromInline
    @inline(__always)
    internal func decodeMaxStreamsFrame(from reader: inout DataReader, isBidi: Bool) throws -> Frame {
        let maxStreams = try reader.readVarintValue()
        return .maxStreams(MaxStreamsFrame(
            maxStreams: maxStreams,
            isBidirectional: isBidi
        ))
    }

    @usableFromInline
    @inline(__always)
    internal func decodeStreamDataBlockedFrame(from reader: inout DataReader) throws -> Frame {
        let streamID = try reader.readVarintValue()
        let limit = try reader.readVarintValue()
        return .streamDataBlocked(StreamDataBlockedFrame(
            streamID: streamID,
            streamDataLimit: limit
        ))
    }

    @usableFromInline
    @inline(__always)
    internal func decodeStreamsBlockedFrame(from reader: inout DataReader, isBidi: Bool) throws -> Frame {
        let limit = try reader.readVarintValue()
        return .streamsBlocked(StreamsBlockedFrame(
            streamLimit: limit,
            isBidirectional: isBidi
        ))
    }

    @usableFromInline
    @inline(__always)
    internal func decodeNewConnectionIDFrame(from reader: inout DataReader) throws -> Frame {
        let seqNum = try reader.readVarintValue()
        let retirePriorTo = try reader.readVarintValue()

        guard let cidLength = reader.readByte() else {
            throw FrameCodecError.insufficientData
        }

        guard cidLength <= ConnectionID.maxLength else {
            throw FrameCodecError.invalidFrameFormat("Connection ID too long: \(cidLength)")
        }

        guard let cidBytes = reader.readBytes(Int(cidLength)) else {
            throw FrameCodecError.insufficientData
        }

        guard let resetToken = reader.readBytes(16) else {
            throw FrameCodecError.insufficientData
        }

        return .newConnectionID(try NewConnectionIDFrame(
            sequenceNumber: seqNum,
            retirePriorTo: retirePriorTo,
            connectionID: try ConnectionID(bytes: cidBytes),
            statelessResetToken: resetToken
        ))
    }

    @usableFromInline
    @inline(__always)
    internal func decodeConnectionCloseFrame(from reader: inout DataReader, isApp: Bool) throws -> Frame {
        let errorCode = try reader.readVarintValue()

        var frameType: UInt64? = nil
        if !isApp {
            frameType = try reader.readVarintValue()
        }

        let reasonLength = try reader.readVarintValue()
        let reasonPhrase: String
        if reasonLength > 0 {
            let safeLength = try SafeConversions.toInt(
                reasonLength,
                maxAllowed: ProtocolLimits.maxReasonPhraseLength,
                context: "CONNECTION_CLOSE reason phrase length"
            )
            guard let reasonBytes = reader.readBytes(safeLength) else {
                throw FrameCodecError.insufficientData
            }
            reasonPhrase = String(decoding: reasonBytes, as: UTF8.self)
        } else {
            reasonPhrase = ""
        }

        return .connectionClose(ConnectionCloseFrame(
            errorCode: errorCode,
            frameType: frameType,
            reasonPhrase: reasonPhrase,
            isApplicationError: isApp
        ))
    }

    @usableFromInline
    @inline(__always)
    internal func decodeDatagramFrame(from reader: inout DataReader, hasLength: Bool) throws -> Frame {
        let data: Data
        if hasLength {
            let length = try reader.readVarintValue()
            let safeLength = try SafeConversions.toInt(
                length,
                maxAllowed: ProtocolLimits.maxDatagramLength,
                context: "DATAGRAM frame data length"
            )
            guard let bytes = reader.readBytes(safeLength) else {
                throw FrameCodecError.insufficientData
            }
            data = bytes
        } else {
            data = reader.readRemainingBytes()
        }

        return .datagram(DatagramFrame(data: data, hasLength: hasLength))
    }
}
