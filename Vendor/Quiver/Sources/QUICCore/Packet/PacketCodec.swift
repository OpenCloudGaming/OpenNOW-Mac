/// QUIC Packet Encoding and Decoding (RFC 9000 Section 12, 17)
///
/// Provides complete packet assembly and disassembly including:
/// - Header construction
/// - Payload encryption/decryption
/// - Header protection application/removal

import Foundation
import Logging

// MARK: - Packet Codec Errors

/// Errors that can occur during packet encoding/decoding
public enum PacketCodecError: Error, Sendable {
    /// Insufficient data to decode packet
    case insufficientData
    /// Invalid packet format
    case invalidPacketFormat(String)
    /// Decryption failed
    case decryptionFailed
    /// No opener available for decryption
    case noOpener
    /// No sealer available for encryption
    case noSealer
    /// Packet too large for MTU
    case packetTooLarge(size: Int, maxSize: Int)
    /// Header protection failed
    case headerProtectionFailed
}

// MARK: - Parsed Packet

/// A fully parsed and decrypted QUIC packet
package struct ParsedPacket: Sendable {
    /// The packet header
    package let header: PacketHeader

    /// The decoded packet number
    package let packetNumber: UInt64

    /// The decrypted frames
    package let frames: [Frame]

    /// The encryption level of this packet
    package let encryptionLevel: EncryptionLevel

    /// Total size of the packet in bytes
    package let packetSize: Int

    package init(
        header: PacketHeader,
        packetNumber: UInt64,
        frames: [Frame],
        encryptionLevel: EncryptionLevel,
        packetSize: Int
    ) {
        self.header = header
        self.packetNumber = packetNumber
        self.frames = frames
        self.encryptionLevel = encryptionLevel
        self.packetSize = packetSize
    }
}

// MARK: - Packet Opener Protocol

/// Protocol for packet decryption operations
public protocol PacketOpenerProtocol: Sendable {
    /// Removes header protection and returns unprotected first byte and packet number bytes
    func removeHeaderProtection(
        sample: Data,
        firstByte: UInt8,
        packetNumberBytes: Data
    ) throws -> (UInt8, Data)

    /// Decrypts packet payload
    func open(ciphertext: Data, packetNumber: UInt64, header: Data) throws -> Data
}

// MARK: - Packet Sealer Protocol

/// Protocol for packet encryption operations
public protocol PacketSealerProtocol: Sendable {
    /// Applies header protection
    func applyHeaderProtection(
        sample: Data,
        firstByte: UInt8,
        packetNumberBytes: Data
    ) throws -> (UInt8, Data)

    /// Encrypts packet payload
    func seal(plaintext: Data, packetNumber: UInt64, header: Data) throws -> Data
}

// MARK: - Packet Constants

/// Non-generic constants for QUIC packet encoding/decoding.
///
/// These are extracted from the generic `PacketEncoder` / `PacketDecoder` types
/// so they can be referenced without specifying a generic parameter
/// (e.g. `PacketConstants.minimumMTU` instead of `PacketEncoder<…>.minimumMTU`).
package enum PacketConstants {
    /// Minimum MTU that all QUIC paths MUST support (RFC 9000 Section 14).
    ///
    /// This is an RFC constant — the absolute floor for packet sizing.
    /// The **active** MTU used at runtime is supplied by configuration
    /// (`QUICConfiguration.maxUDPPayloadSize`) and may be larger when
    /// the path supports it (e.g. after DPLPMTUD).
    package static let minimumMTU = ProtocolLimits.minimumMaximumDatagramSize

    /// AEAD tag size (16 bytes for AES-GCM)
    package static let aeadTagSize = 16

    /// Minimum UDP datagram size for Initial packets (RFC 9000 Section 14.1).
    ///
    /// Initial packets MUST be padded to at least this size.
    /// References the same RFC constant as ``minimumMTU``.
    package static let initialPacketMinSize = ProtocolLimits.minimumInitialPacketSize
}

// MARK: - Packet Encoder

/// Encodes QUIC packets from frames
///
/// Generic over the frame codec type. The default codec is `StandardFrameCodec`,
/// so existing callers using `PacketEncoder()` continue to work without changes.
/// Pass a custom `FrameEncoder & FrameDecoder` implementation for testing or
/// alternative frame encoding strategies.
package struct PacketEncoder<Codec: FrameEncoder & FrameDecoder & Sendable>: Sendable {
    private let frameCodec: Codec

    /// Minimum MTU for QUIC (RFC 9000 Section 14).
    ///
    /// Forwarded from ``PacketConstants/minimumMTU``.  At runtime prefer
    /// the configured `maxDatagramSize` value over this constant.
    package static var minimumMTU: Int { PacketConstants.minimumMTU }

    /// AEAD tag size (16 bytes for AES-GCM)
    package static var aeadTagSize: Int { PacketConstants.aeadTagSize }

    /// Creates a packet encoder with the given frame codec.
    package init(frameCodec: Codec) {
        self.frameCodec = frameCodec
    }

    /// Minimum UDP datagram size for Initial packets (RFC 9000 Section 14.1)
    package static var initialPacketMinSize: Int { PacketConstants.initialPacketMinSize }

    /// Encodes a Long Header packet
    /// - Parameters:
    ///   - frames: Frames to include in the packet
    ///   - header: The long header (will be modified with packet number)
    ///   - packetNumber: The packet number to use
    ///   - sealer: The sealer for encryption
    ///   - maxPacketSize: Maximum packet size.  Callers MUST supply the
    ///     configured path MTU; there is no default so that hardcoded
    ///     values do not silently creep in.
    ///   - padToMinimum: If true and this is an Initial packet, pad to
    ///     ``PacketConstants/initialPacketMinSize`` bytes (default: true)
    /// - Returns: The fully encoded and protected packet
    package func encodeLongHeaderPacket(
        frames: [Frame],
        header: LongHeader,
        packetNumber: UInt64,
        sealer: any PacketSealerProtocol,
        maxPacketSize: Int,
        padToMinimum: Bool = true
    ) throws -> Data {
        var header = header
        header.packetNumber = packetNumber

        // Encode frames to payload
        var payload = try frameCodec.encodeFrames(frames)

        // RFC 9000 Section 14.1: Initial packets MUST be padded to at least 1200 bytes
        // Calculate if padding is needed
        if padToMinimum && header.packetType == .initial {
            // Estimate final packet size: header + PN + payload + AEAD tag
            let estimatedHeaderSize = estimateLongHeaderSize(header)
            let currentSize = estimatedHeaderSize + header.packetNumberLength + payload.count + Self.aeadTagSize

            if currentSize < Self.initialPacketMinSize {
                let paddingNeeded = Self.initialPacketMinSize - currentSize
                // Add PADDING frames (0x00 bytes) - Data(count:) is zero-initialized
                payload.append(Data(count: paddingNeeded))
            }
        }

        // Calculate length field value
        // Length = packet number length + payload length + AEAD tag
        let lengthValue = header.packetNumberLength + payload.count + Self.aeadTagSize

        // Build complete header with length
        let headerWithLength = buildLongHeaderWithLength(header, length: UInt64(lengthValue))

        // Build packet number bytes
        let pnBytes = encodePacketNumber(packetNumber, length: header.packetNumberLength)

        // RFC 9001 Section 5.3: AAD includes header up to and including the unprotected packet number
        var aad = headerWithLength
        aad.append(pnBytes)

        // Encrypt payload with AAD that includes PN bytes
        let ciphertext = try sealer.seal(
            plaintext: payload,
            packetNumber: packetNumber,
            header: aad
        )

        // Combine header + PN + ciphertext (before header protection)
        var packet = headerWithLength
        packet.append(pnBytes)
        packet.append(ciphertext)

        // Apply header protection
        // Sample starts at PN offset + 4 bytes
        let pnOffset = headerWithLength.count
        let sampleOffset = pnOffset + 4

        guard packet.count >= sampleOffset + 16 else {
            throw PacketCodecError.invalidPacketFormat("Packet too short for header protection sample")
        }

        let sample = packet[sampleOffset..<(sampleOffset + 16)]
        let (protectedFirstByte, protectedPN) = try sealer.applyHeaderProtection(
            sample: Data(sample),
            firstByte: packet[0],
            packetNumberBytes: pnBytes
        )

        // Apply protected values
        packet[0] = protectedFirstByte
        packet.replaceSubrange(pnOffset..<(pnOffset + header.packetNumberLength), with: protectedPN)

        guard packet.count <= maxPacketSize else {
            throw PacketCodecError.packetTooLarge(size: packet.count, maxSize: maxPacketSize)
        }

        return packet
    }

    /// Encodes a Short Header packet
    /// - Parameters:
    ///   - frames: Frames to include in the packet
    ///   - header: The short header
    ///   - packetNumber: The packet number to use
    ///   - sealer: The sealer for encryption
    ///   - maxPacketSize: Maximum packet size.  Callers MUST supply the
    ///     configured path MTU; there is no default so that hardcoded
    ///     values do not silently creep in.
    /// - Returns: The fully encoded and protected packet
    package func encodeShortHeaderPacket(
        frames: [Frame],
        header: ShortHeader,
        packetNumber: UInt64,
        sealer: any PacketSealerProtocol,
        maxPacketSize: Int
    ) throws -> Data {
        var header = header
        header.packetNumber = packetNumber

        // Encode frames to payload
        let payload = try frameCodec.encodeFrames(frames)

        // Build unprotected header (first byte + DCID)
        var unprotectedHeader = Data()
        unprotectedHeader.append(header.firstByte)
        unprotectedHeader.append(header.destinationConnectionID.bytes)

        // Build packet number bytes
        let pnBytes = encodePacketNumber(packetNumber, length: header.packetNumberLength)

        // RFC 9001 Section 5.3: AAD includes header up to and including the unprotected packet number
        var aad = unprotectedHeader
        aad.append(pnBytes)

        // Encrypt payload with AAD that includes PN bytes
        let ciphertext = try sealer.seal(
            plaintext: payload,
            packetNumber: packetNumber,
            header: aad
        )

        // Combine header + PN + ciphertext
        var packet = unprotectedHeader
        packet.append(pnBytes)
        packet.append(ciphertext)

        // Apply header protection
        let pnOffset = unprotectedHeader.count
        let sampleOffset = pnOffset + 4

        guard packet.count >= sampleOffset + 16 else {
            throw PacketCodecError.invalidPacketFormat("Packet too short for header protection sample")
        }

        let sample = packet[sampleOffset..<(sampleOffset + 16)]
        let (protectedFirstByte, protectedPN) = try sealer.applyHeaderProtection(
            sample: Data(sample),
            firstByte: packet[0],
            packetNumberBytes: pnBytes
        )

        // Apply protected values
        packet[0] = protectedFirstByte
        packet.replaceSubrange(pnOffset..<(pnOffset + header.packetNumberLength), with: protectedPN)

        guard packet.count <= maxPacketSize else {
            throw PacketCodecError.packetTooLarge(size: packet.count, maxSize: maxPacketSize)
        }

        return packet
    }

    // MARK: - Private Helpers

    private func buildLongHeader(_ header: LongHeader) -> Data {
        var data = Data()
        data.append(header.firstByte)
        header.version.encode(to: &data)
        header.destinationConnectionID.encode(to: &data)
        header.sourceConnectionID.encode(to: &data)

        // Token for Initial packets
        if header.packetType == .initial {
            let tokenLength = header.token?.count ?? 0
            Varint(UInt64(tokenLength)).encode(to: &data)
            if let token = header.token {
                data.append(token)
            }
        }

        return data
    }

    private func buildLongHeaderWithLength(_ header: LongHeader, length: UInt64) -> Data {
        var data = buildLongHeader(header)

        // Add Length field (for Initial, Handshake, 0-RTT)
        if header.hasPacketNumber {
            Varint(length).encode(to: &data)
        }

        return data
    }

    private func encodePacketNumber(_ packetNumber: UInt64, length: Int) -> Data {
        var bytes = Data(capacity: length)
        for i in (0..<length).reversed() {
            bytes.append(UInt8((packetNumber >> (i * 8)) & 0xFF))
        }
        return bytes
    }

    /// Estimates the header size (without Length field) for Initial packet padding calculation
    private func estimateLongHeaderSize(_ header: LongHeader) -> Int {
        var size = 1  // First byte
        size += 4     // Version
        size += 1 + header.destinationConnectionID.length  // DCID length + DCID
        size += 1 + header.sourceConnectionID.length       // SCID length + SCID

        // Token (Initial packets only)
        if header.packetType == .initial {
            let tokenLength = header.token?.count ?? 0
            size += Varint(UInt64(tokenLength)).encodedLength
            size += tokenLength
        }

        // Length field (estimate 2 bytes for typical packet sizes)
        size += 2

        return size
    }
}

// MARK: - Packet Decoder

/// Decodes QUIC packets
///
/// Generic over the frame codec type. The default codec is `StandardFrameCodec`,
/// so existing callers using `PacketDecoder()` continue to work without changes.
package struct PacketDecoder<Codec: FrameEncoder & FrameDecoder & Sendable>: Sendable {
    private static var logger: Logger { QuiverLogging.logger(label: "quic.core.packet-codec") }
    private let frameCodec: Codec

    /// Creates a packet decoder with the given frame codec.
    package init(frameCodec: Codec) {
        self.frameCodec = frameCodec
    }

    /// Decodes a packet from raw data
    /// - Parameters:
    ///   - data: The raw packet data
    ///   - dcidLength: Expected DCID length (for short headers)
    ///   - opener: The opener for decryption (nil for unprotected packets)
    ///   - largestPN: Largest packet number received (for PN decoding)
    /// - Returns: The parsed packet
    package func decodePacket(
        data: Data,
        dcidLength: Int,
        opener: (any PacketOpenerProtocol)?,
        largestPN: UInt64 = 0
    ) throws -> ParsedPacket {
        guard !data.isEmpty else {
            throw PacketCodecError.insufficientData
        }

        let firstByte = data[data.startIndex]
        let isLongHeader = (firstByte & 0x80) != 0

        if isLongHeader {
            Self.logger.trace("Decoding Long Header packet (firstByte: 0x\(String(format: "%02X", firstByte)))")
            return try decodeLongHeaderPacket(data: data, opener: opener, largestPN: largestPN)
        } else {
            Self.logger.trace("Decoding Short Header packet (1-RTT) (firstByte: 0x\(String(format: "%02X", firstByte)))")
            return try decodeShortHeaderPacket(data: data, dcidLength: dcidLength, opener: opener, largestPN: largestPN)
        }
    }

    /// Decodes a Long Header packet
    private func decodeLongHeaderPacket(
        data: Data,
        opener: (any PacketOpenerProtocol)?,
        largestPN: UInt64
    ) throws -> ParsedPacket {
        // Step 1: Parse protected header (no validation of protected bits)
        let (protectedHeader, headerLength) = try ProtectedLongHeader.parse(from: data)

        // Handle special packets without encryption
        if protectedHeader.packetType == .versionNegotiation || protectedHeader.packetType == .retry {
            // For unprotected packets, create header directly
            let actualPacketType: PacketType
            switch protectedHeader.packetType {
            case .initial: actualPacketType = .initial
            case .zeroRTT: actualPacketType = .zeroRTT
            case .handshake: actualPacketType = .handshake
            case .retry: actualPacketType = .retry
            case .versionNegotiation: actualPacketType = .versionNegotiation
            }

            var header = LongHeader(
                packetType: actualPacketType,
                version: protectedHeader.version,
                destinationConnectionID: protectedHeader.destinationConnectionID,
                sourceConnectionID: protectedHeader.sourceConnectionID,
                token: protectedHeader.token,
                retryIntegrityTag: protectedHeader.retryIntegrityTag,
                length: protectedHeader.length,
                packetNumber: 0,
                packetNumberLength: 0
            )
            header.firstByte = protectedHeader.protectedFirstByte

            return ParsedPacket(
                header: .long(header),
                packetNumber: 0,
                frames: [],
                encryptionLevel: .initial,
                packetSize: data.count
            )
        }

        guard let opener = opener else {
            throw PacketCodecError.noOpener
        }

        // Step 2: Calculate offsets and extract sample
        let pnOffset = headerLength
        let sampleOffset = pnOffset + 4  // Sample starts 4 bytes after PN offset (RFC 9001 5.4.2)

        guard data.count >= sampleOffset + 16 else {
            throw PacketCodecError.insufficientData
        }

        // RFC 9001 Section 5.4.1: ALWAYS read 4 PN bytes before header protection removal
        // We cannot know the actual PN length until after unmasking the first byte
        let maxPNLength = 4
        let protectedPNBytesEnd = min(data.startIndex + pnOffset + maxPNLength, data.endIndex)
        let protectedPNBytes = data[(data.startIndex + pnOffset)..<protectedPNBytesEnd]

        // Extract sample
        let sample = data[(data.startIndex + sampleOffset)..<(data.startIndex + sampleOffset + 16)]

        // Step 3: Remove header protection
        let (unprotectedFirstByte, unprotectedPNBytes) = try opener.removeHeaderProtection(
            sample: sample,
            firstByte: protectedHeader.protectedFirstByte,
            packetNumberBytes: protectedPNBytes
        )

        // Step 4: Decode packet number
        let actualPNLength = Int((unprotectedFirstByte & 0x03) + 1)

        var truncatedPN: UInt64 = 0
        for i in 0..<actualPNLength {
            truncatedPN = (truncatedPN << 8) | UInt64(unprotectedPNBytes[unprotectedPNBytes.startIndex + i])
        }
        let packetNumber = PacketNumberEncoding.decode(
            truncated: truncatedPN,
            length: actualPNLength,
            largestPN: largestPN
        )

        // Step 5: Create validated header (validation happens here, AFTER HP removal)
        let longHeader = try protectedHeader.unprotect(
            unprotectedFirstByte: unprotectedFirstByte,
            packetNumber: packetNumber,
            packetNumberLength: actualPNLength
        )

        // Step 6: Build AAD and decrypt payload
        var aad = Data()
        aad.append(unprotectedFirstByte)
        aad.append(data[(data.startIndex + 1)..<(data.startIndex + pnOffset)])
        aad.append(unprotectedPNBytes.prefix(actualPNLength))

        // RFC 9000 Section 17.2: Use Length field to determine ciphertext boundary
        let ciphertextStart = data.startIndex + pnOffset + actualPNLength
        let ciphertextEnd: Data.Index
        if let lengthValue = protectedHeader.length {
            let safeLengthValue = try SafeConversions.toInt(
                lengthValue,
                maxAllowed: ProtocolLimits.maxLongHeaderLength,
                context: "Long header length field"
            )
            let payloadLength = try SafeConversions.subtract(safeLengthValue, actualPNLength)
            ciphertextEnd = ciphertextStart + payloadLength
            guard ciphertextEnd <= data.endIndex else {
                throw PacketCodecError.invalidPacketFormat(
                    "Length field exceeds available data: \(lengthValue) bytes, but only \(data.endIndex - pnOffset) available"
                )
            }
        } else {
            ciphertextEnd = data.endIndex
        }
        let ciphertext = data[ciphertextStart..<ciphertextEnd]

        // Decrypt payload
        let plaintext = try opener.open(
            ciphertext: Data(ciphertext),
            packetNumber: packetNumber,
            header: aad
        )

        // Step 7: Decode frames
        let frames = try frameCodec.decodeFrames(from: plaintext)

        // Calculate actual packet size (header + PN + ciphertext)
        let actualPacketSize = pnOffset + actualPNLength + ciphertext.count

        return ParsedPacket(
            header: .long(longHeader),
            packetNumber: packetNumber,
            frames: frames,
            encryptionLevel: longHeader.packetType.encryptionLevel,
            packetSize: actualPacketSize
        )
    }

    /// Decodes a Short Header packet
    private func decodeShortHeaderPacket(
        data: Data,
        dcidLength: Int,
        opener: (any PacketOpenerProtocol)?,
        largestPN: UInt64
    ) throws -> ParsedPacket {
        guard let opener = opener else {
            throw PacketCodecError.noOpener
        }

        // Step 1: Parse protected header (no validation of protected bits)
        let (protectedHeader, headerLength) = try ProtectedShortHeader.parse(from: data, dcidLength: dcidLength)

        guard data.count >= headerLength + 4 + 16 else {  // header + max PN (4) + sample (16)
            throw PacketCodecError.insufficientData
        }

        // Step 2: Calculate offsets and extract sample
        let pnOffset = headerLength
        let sampleOffset = pnOffset + 4  // Sample starts 4 bytes after PN offset (RFC 9001 5.4.2)

        guard data.count >= sampleOffset + 16 else {
            throw PacketCodecError.insufficientData
        }

        // RFC 9001 Section 5.4.1: ALWAYS read 4 PN bytes before header protection removal
        let maxPNLength = 4
        let protectedPNBytesEnd = min(data.startIndex + pnOffset + maxPNLength, data.endIndex)
        let protectedPNBytes = data[(data.startIndex + pnOffset)..<protectedPNBytesEnd]

        // Extract sample
        let sample = data[(data.startIndex + sampleOffset)..<(data.startIndex + sampleOffset + 16)]

        // Step 3: Remove header protection
        let (unprotectedFirstByte, unprotectedPNBytes) = try opener.removeHeaderProtection(
            sample: sample,
            firstByte: protectedHeader.protectedFirstByte,
            packetNumberBytes: protectedPNBytes
        )

        // Step 4: Decode packet number
        let actualPNLength = Int((unprotectedFirstByte & 0x03) + 1)

        var truncatedPN: UInt64 = 0
        for i in 0..<actualPNLength {
            truncatedPN = (truncatedPN << 8) | UInt64(unprotectedPNBytes[unprotectedPNBytes.startIndex + i])
        }
        let packetNumber = PacketNumberEncoding.decode(
            truncated: truncatedPN,
            length: actualPNLength,
            largestPN: largestPN
        )

        // Step 5: Create validated header (validation happens here, AFTER HP removal)
        let shortHeader = try protectedHeader.unprotect(
            unprotectedFirstByte: unprotectedFirstByte,
            packetNumber: packetNumber,
            packetNumberLength: actualPNLength
        )

        // Step 6: Build AAD and decrypt payload
        var aad = Data()
        aad.append(unprotectedFirstByte)
        aad.append(protectedHeader.destinationConnectionID.bytes)
        aad.append(unprotectedPNBytes.prefix(actualPNLength))

        // Get ciphertext (Short header packets have no Length field, consume rest of datagram)
        let ciphertextStart = data.startIndex + pnOffset + actualPNLength
        let ciphertext = data[ciphertextStart...]

        // Decrypt payload
        let plaintext = try opener.open(
            ciphertext: Data(ciphertext),
            packetNumber: packetNumber,
            header: aad
        )

        // Step 7: Decode frames
        let frames = try frameCodec.decodeFrames(from: plaintext)

        return ParsedPacket(
            header: .short(shortHeader),
            packetNumber: packetNumber,
            frames: frames,
            encryptionLevel: .application,
            packetSize: data.count
        )
    }

}

// MARK: - Default Convenience Initializers

extension PacketEncoder where Codec == StandardFrameCodec {
    /// Creates a packet encoder with the default `StandardFrameCodec`.
    package init() {
        self.init(frameCodec: StandardFrameCodec())
    }
}

extension PacketDecoder where Codec == StandardFrameCodec {
    /// Creates a packet decoder with the default `StandardFrameCodec`.
    package init() {
        self.init(frameCodec: StandardFrameCodec())
    }
}

// MARK: - Packet Size Utilities

extension PacketEncoder {
    /// Calculates the overhead for a Long Header packet
    /// - Parameters:
    ///   - dcidLength: Destination connection ID length
    ///   - scidLength: Source connection ID length
    ///   - tokenLength: Token length (for Initial packets)
    ///   - packetNumberLength: Packet number length (1-4)
    ///   - payloadLength: Expected payload length (for accurate Length field size calculation)
    /// - Returns: Total header + crypto overhead in bytes
    package static func longHeaderOverhead(
        dcidLength: Int,
        scidLength: Int,
        tokenLength: Int = 0,
        packetNumberLength: Int = 4,
        payloadLength: Int = 0
    ) -> Int {
        var overhead = 1  // First byte
        overhead += 4     // Version
        overhead += 1 + dcidLength  // DCID length + DCID
        overhead += 1 + scidLength  // SCID length + SCID

        // Token length varint + token (Initial only)
        if tokenLength > 0 {
            overhead += Varint(UInt64(tokenLength)).encodedLength
            overhead += tokenLength
        } else {
            overhead += 1  // Zero-length token
        }

        // Length field (varint): PN length + payload + AEAD tag
        // Use actual varint length based on expected payload size
        let lengthValue = packetNumberLength + payloadLength + aeadTagSize
        overhead += Varint(UInt64(lengthValue)).encodedLength

        // Packet number
        overhead += packetNumberLength

        // AEAD tag
        overhead += aeadTagSize

        return overhead
    }

    /// Calculates the overhead for a Short Header packet
    /// - Parameters:
    ///   - dcidLength: Destination connection ID length
    ///   - packetNumberLength: Packet number length (1-4)
    /// - Returns: Total header + crypto overhead in bytes
    package static func shortHeaderOverhead(
        dcidLength: Int,
        packetNumberLength: Int = 4
    ) -> Int {
        var overhead = 1  // First byte
        overhead += dcidLength
        overhead += packetNumberLength
        overhead += aeadTagSize
        return overhead
    }
}
