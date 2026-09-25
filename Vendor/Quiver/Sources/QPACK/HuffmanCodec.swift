/// QPACK/HPACK Huffman Codec (RFC 7541 Appendix B)
///
/// Implements the Huffman coding table defined in RFC 7541 Appendix B,
/// used by both HPACK (HTTP/2) and QPACK (HTTP/3) for header compression.
///
/// The Huffman code is a static, prefix-free code that assigns shorter
/// bit sequences to more frequently occurring octets. It typically achieves
/// 20-30% compression on HTTP header values.
///
/// ## Encoding
///
/// Each input byte is replaced by its Huffman code from the static table.
/// The output is padded with the most-significant bits of the EOS (End of String)
/// symbol to the next byte boundary.
///
/// ## Decoding
///
/// The decoder uses a state-machine approach with a 256-entry lookup table
/// per state for efficient byte-at-a-time decoding, falling back to
/// bit-at-a-time decoding for correctness and simplicity.

import Foundation

// MARK: - Huffman Codec

/// Static Huffman encoder/decoder for QPACK/HPACK header compression
public enum HuffmanCodec {

    /// Pre-computed lookup table mapping (bitLength << 24 | code) → symbol index.
    /// Built once at static init time; enables O(1) symbol lookup during decoding.
    private static let lookupTable: [UInt64: Int] = {
        var table = [UInt64: Int](minimumCapacity: 257)
        for (index, entry) in huffmanTable.enumerated() {
            let key = (UInt64(entry.bitLength) << 32) | UInt64(entry.code)
            table[key] = index
        }
        return table
    }()

    // MARK: - Encoding

    /// Encodes raw bytes using the HPACK Huffman code (RFC 7541 Appendix B).
    ///
    /// - Parameter data: The raw bytes to encode
    /// - Returns: Huffman-encoded bytes
    ///
    /// ## Example
    ///
    /// ```swift
    /// let encoded = HuffmanCodec.encode(Data("www.example.com".utf8))
    /// // Encoded output is typically shorter than input
    /// ```
    public static func encode(_ data: Data) -> Data {
        var result = Data()
        // Huffman encoding typically produces ~70-80% of original size
        result.reserveCapacity(data.count)

        var currentByte: UInt8 = 0
        var bitsRemaining: Int = 8

        for byte in data {
            let entry = huffmanTable[Int(byte)]
            var code = entry.code
            var codeLength = entry.bitLength

            while codeLength > 0 {
                if codeLength >= bitsRemaining {
                    // Fill the rest of the current byte
                    currentByte |= UInt8(truncatingIfNeeded: code >> (codeLength - bitsRemaining))
                    result.append(currentByte)
                    codeLength -= bitsRemaining

                    // Mask out the bits we just used
                    if codeLength < 32 {
                        code &= (1 << codeLength) - 1
                    }

                    currentByte = 0
                    bitsRemaining = 8
                } else {
                    // Not enough bits to fill the byte
                    currentByte |= UInt8(truncatingIfNeeded: code << (bitsRemaining - codeLength))
                    bitsRemaining -= codeLength
                    codeLength = 0
                }
            }
        }

        // Pad with EOS prefix bits (all 1s) per RFC 7541 Section 5.2
        if bitsRemaining < 8 {
            currentByte |= UInt8((1 << bitsRemaining) - 1)
            result.append(currentByte)
        }

        return result
    }

    /// Returns the Huffman-encoded size of the given data without actually encoding it.
    ///
    /// - Parameter data: The raw bytes to measure
    /// - Returns: The number of bytes the Huffman-encoded output would occupy
    public static func encodedSize(of data: Data) -> Int {
        var totalBits = 0
        for byte in data {
            totalBits += huffmanTable[Int(byte)].bitLength
        }
        return (totalBits + 7) / 8  // Round up to next byte
    }

    // MARK: - Decoding

    /// Decodes Huffman-encoded bytes back to raw bytes.
    ///
    /// - Parameter data: The Huffman-encoded bytes
    /// - Returns: The decoded raw bytes
    /// - Throws: `HuffmanError` if the encoding is invalid
    ///
    /// ## Example
    ///
    /// ```swift
    /// let raw = Data("www.example.com".utf8)
    /// let encoded = HuffmanCodec.encode(raw)
    /// let decoded = try HuffmanCodec.decode(encoded)
    /// assert(decoded == raw)
    /// ```
    public static func decode(_ data: Data) throws -> Data {
        var result = Data()
        result.reserveCapacity(data.count * 2)  // Decoded is typically larger

        var state: UInt32 = 0       // Current position in the decode tree
        var bitsAccepted: Int = 0   // Bit counter for detecting EOS

        for byte in data {
            for bitIndex in stride(from: 7, through: 0, by: -1) {
                let bit = (byte >> bitIndex) & 1

                // Navigate the Huffman tree
                state = (state << 1) | UInt32(bit)
                bitsAccepted += 1

                // Check if we've accumulated a valid symbol
                if let symbol = lookupSymbol(state: state, bits: bitsAccepted) {
                    if symbol == 256 {
                        // EOS symbol found in the middle of the string is an error
                        throw HuffmanError.eosInMiddleOfString
                    }
                    result.append(UInt8(symbol))
                    state = 0
                    bitsAccepted = 0
                }

                // Prevent excessively long codes (max Huffman code is 30 bits)
                if bitsAccepted > 30 {
                    throw HuffmanError.invalidEncoding("Huffman code exceeds maximum length")
                }
            }
        }

        // Verify padding
        // Remaining bits must be all 1s and fewer than 8 bits (EOS prefix padding)
        if bitsAccepted > 0 {
            if bitsAccepted > 7 {
                throw HuffmanError.invalidPadding
            }
            // Check that remaining bits are all 1s (EOS padding)
            let mask: UInt32 = (1 << bitsAccepted) - 1
            if state != mask {
                throw HuffmanError.invalidPadding
            }
        }

        return result
    }

    // MARK: - Internal

    /// Looks up whether the accumulated bits form a valid Huffman symbol.
    ///
    /// Uses a pre-computed dictionary for O(1) lookup instead of linear search,
    /// preventing CPU exhaustion under heavy decoding loads.
    ///
    /// - Parameters:
    ///   - state: The accumulated bits
    ///   - bits: The number of accumulated bits
    /// - Returns: The symbol (0-255 for data bytes, 256 for EOS), or nil if no match
    private static func lookupSymbol(state: UInt32, bits: Int) -> Int? {
        let key = (UInt64(bits) << 32) | UInt64(state)
        return lookupTable[key]
    }
}

// MARK: - Huffman Table Entry

/// A single entry in the Huffman table
public struct HuffmanEntry: Sendable {
    /// The Huffman code (right-aligned)
    public let code: UInt32
    /// Number of bits in the code
    public let bitLength: Int

    @inlinable
    public init(code: UInt32, bitLength: Int) {
        self.code = code
        self.bitLength = bitLength
    }
}

// MARK: - Errors

/// Errors that can occur during Huffman decoding
public enum HuffmanError: Error, Sendable, CustomStringConvertible {
    /// The Huffman encoding is invalid
    case invalidEncoding(String)

    /// The padding at the end of the Huffman-encoded string is invalid
    case invalidPadding

    /// The EOS symbol was found in the middle of the string
    case eosInMiddleOfString

    public var description: String {
        switch self {
        case .invalidEncoding(let reason):
            return "Invalid Huffman encoding: \(reason)"
        case .invalidPadding:
            return "Invalid Huffman padding (must be EOS prefix, all 1s, < 8 bits)"
        case .eosInMiddleOfString:
            return "EOS symbol found in middle of Huffman-encoded string"
        }
    }
}

// MARK: - RFC 7541 Appendix B Huffman Table

/// The complete Huffman code table from RFC 7541 Appendix B.
///
/// This table maps each byte value (0-255) plus the EOS symbol (256)
/// to its Huffman code. Entries are indexed by symbol value.
///
/// The codes are listed as (code, bit_length) pairs where the code
/// is right-aligned in the UInt32.
///
/// Reference: https://www.rfc-editor.org/rfc/rfc7541#appendix-B
public let huffmanTable: [HuffmanEntry] = [
    //   (   0) |11111111|11000                          1ff8  [13]
    HuffmanEntry(code: 0x1ff8, bitLength: 13),
    //   (   1) |11111111|11111111|1011000                7fffd8  [23]
    HuffmanEntry(code: 0x7fffd8, bitLength: 23),
    //   (   2) |11111111|11111111|11111110|0010          fffffe2  [28]
    HuffmanEntry(code: 0xfffffe2, bitLength: 28),
    //   (   3) |11111111|11111111|11111110|0011          fffffe3  [28]
    HuffmanEntry(code: 0xfffffe3, bitLength: 28),
    //   (   4) |11111111|11111111|11111110|0100          fffffe4  [28]
    HuffmanEntry(code: 0xfffffe4, bitLength: 28),
    //   (   5) |11111111|11111111|11111110|0101          fffffe5  [28]
    HuffmanEntry(code: 0xfffffe5, bitLength: 28),
    //   (   6) |11111111|11111111|11111110|0110          fffffe6  [28]
    HuffmanEntry(code: 0xfffffe6, bitLength: 28),
    //   (   7) |11111111|11111111|11111110|0111          fffffe7  [28]
    HuffmanEntry(code: 0xfffffe7, bitLength: 28),
    //   (   8) |11111111|11111111|11111110|1000          fffffe8  [28]
    HuffmanEntry(code: 0xfffffe8, bitLength: 28),
    //   (   9) |11111111|11111111|11101010                ffffea  [24]
    HuffmanEntry(code: 0xffffea, bitLength: 24),
    //   (  10) |11111111|11111111|11111111|111100        3ffffffc  [30]
    HuffmanEntry(code: 0x3ffffffc, bitLength: 30),
    //   (  11) |11111111|11111111|11111110|1001          fffffe9  [28]
    HuffmanEntry(code: 0xfffffe9, bitLength: 28),
    //   (  12) |11111111|11111111|11111110|1010          fffffea  [28]
    HuffmanEntry(code: 0xfffffea, bitLength: 28),
    //   (  13) |11111111|11111111|11111111|111101        3ffffffd  [30]
    HuffmanEntry(code: 0x3ffffffd, bitLength: 30),
    //   (  14) |11111111|11111111|11111110|1011          fffffeb  [28]
    HuffmanEntry(code: 0xfffffeb, bitLength: 28),
    //   (  15) |11111111|11111111|11111110|1100          fffffec  [28]
    HuffmanEntry(code: 0xfffffec, bitLength: 28),
    //   (  16) |11111111|11111111|11111110|1101          fffffed  [28]
    HuffmanEntry(code: 0xfffffed, bitLength: 28),
    //   (  17) |11111111|11111111|11111110|1110          fffffee  [28]
    HuffmanEntry(code: 0xfffffee, bitLength: 28),
    //   (  18) |11111111|11111111|11111110|1111          fffffef  [28]
    HuffmanEntry(code: 0xfffffef, bitLength: 28),
    //   (  19) |11111111|11111111|11111111|0000          ffffff0  [28]
    HuffmanEntry(code: 0xffffff0, bitLength: 28),
    //   (  20) |11111111|11111111|11111111|0001          ffffff1  [28]
    HuffmanEntry(code: 0xffffff1, bitLength: 28),
    //   (  21) |11111111|11111111|11111111|0010          ffffff2  [28]
    HuffmanEntry(code: 0xffffff2, bitLength: 28),
    //   (  22) |11111111|11111111|11111111|111110        3ffffffe  [30]
    HuffmanEntry(code: 0x3ffffffe, bitLength: 30),
    //   (  23) |11111111|11111111|11111111|0011          ffffff3  [28]
    HuffmanEntry(code: 0xffffff3, bitLength: 28),
    //   (  24) |11111111|11111111|11111111|0100          ffffff4  [28]
    HuffmanEntry(code: 0xffffff4, bitLength: 28),
    //   (  25) |11111111|11111111|11111111|0101          ffffff5  [28]
    HuffmanEntry(code: 0xffffff5, bitLength: 28),
    //   (  26) |11111111|11111111|11111111|0110          ffffff6  [28]
    HuffmanEntry(code: 0xffffff6, bitLength: 28),
    //   (  27) |11111111|11111111|11111111|0111          ffffff7  [28]
    HuffmanEntry(code: 0xffffff7, bitLength: 28),
    //   (  28) |11111111|11111111|11111111|1000          ffffff8  [28]
    HuffmanEntry(code: 0xffffff8, bitLength: 28),
    //   (  29) |11111111|11111111|11111111|1001          ffffff9  [28]
    HuffmanEntry(code: 0xffffff9, bitLength: 28),
    //   (  30) |11111111|11111111|11111111|1010          ffffffa  [28]
    HuffmanEntry(code: 0xffffffa, bitLength: 28),
    //   (  31) |11111111|11111111|11111111|1011          ffffffb  [28]
    HuffmanEntry(code: 0xffffffb, bitLength: 28),
    //   (  32) ' ' |010100                                14  [6]
    HuffmanEntry(code: 0x14, bitLength: 6),
    //   (  33) '!' |11111110|00                           3f8  [10]
    HuffmanEntry(code: 0x3f8, bitLength: 10),
    //   (  34) '"' |11111110|01                           3f9  [10]
    HuffmanEntry(code: 0x3f9, bitLength: 10),
    //   (  35) '#' |11111111|1010                         ffa  [12]
    HuffmanEntry(code: 0xffa, bitLength: 12),
    //   (  36) '$' |11111111|11001                        1ff9  [13]
    HuffmanEntry(code: 0x1ff9, bitLength: 13),
    //   (  37) '%' |010101                                15  [6]
    HuffmanEntry(code: 0x15, bitLength: 6),
    //   (  38) '&' |11111000                              f8  [8]
    HuffmanEntry(code: 0xf8, bitLength: 8),
    //   (  39) ''' |11111111|010                           7fa  [11]
    HuffmanEntry(code: 0x7fa, bitLength: 11),
    //   (  40) '(' |11111110|10                           3fa  [10]
    HuffmanEntry(code: 0x3fa, bitLength: 10),
    //   (  41) ')' |11111110|11                           3fb  [10]
    HuffmanEntry(code: 0x3fb, bitLength: 10),
    //   (  42) '*' |11111001                              f9  [8]
    HuffmanEntry(code: 0xf9, bitLength: 8),
    //   (  43) '+' |11111111|011                           7fb  [11]
    HuffmanEntry(code: 0x7fb, bitLength: 11),
    //   (  44) ',' |11111010                              fa  [8]
    HuffmanEntry(code: 0xfa, bitLength: 8),
    //   (  45) '-' |010110                                16  [6]
    HuffmanEntry(code: 0x16, bitLength: 6),
    //   (  46) '.' |010111                                17  [6]
    HuffmanEntry(code: 0x17, bitLength: 6),
    //   (  47) '/' |011000                                18  [6]
    HuffmanEntry(code: 0x18, bitLength: 6),
    //   (  48) '0' |00000                                 0  [5]
    HuffmanEntry(code: 0x0, bitLength: 5),
    //   (  49) '1' |00001                                 1  [5]
    HuffmanEntry(code: 0x1, bitLength: 5),
    //   (  50) '2' |00010                                 2  [5]
    HuffmanEntry(code: 0x2, bitLength: 5),
    //   (  51) '3' |011001                                19  [6]
    HuffmanEntry(code: 0x19, bitLength: 6),
    //   (  52) '4' |011010                                1a  [6]
    HuffmanEntry(code: 0x1a, bitLength: 6),
    //   (  53) '5' |011011                                1b  [6]
    HuffmanEntry(code: 0x1b, bitLength: 6),
    //   (  54) '6' |011100                                1c  [6]
    HuffmanEntry(code: 0x1c, bitLength: 6),
    //   (  55) '7' |011101                                1d  [6]
    HuffmanEntry(code: 0x1d, bitLength: 6),
    //   (  56) '8' |011110                                1e  [6]
    HuffmanEntry(code: 0x1e, bitLength: 6),
    //   (  57) '9' |011111                                1f  [6]
    HuffmanEntry(code: 0x1f, bitLength: 6),
    //   (  58) ':' |1011100                               5c  [7]
    HuffmanEntry(code: 0x5c, bitLength: 7),
    //   (  59) ';' |11111011                              fb  [8]
    HuffmanEntry(code: 0xfb, bitLength: 8),
    //   (  60) '<' |11111111|11111100                     7ffc  [15]
    HuffmanEntry(code: 0x7ffc, bitLength: 15),
    //   (  61) '=' |100000                                20  [6]
    HuffmanEntry(code: 0x20, bitLength: 6),
    //   (  62) '>' |11111111|1011                         ffb  [12]
    HuffmanEntry(code: 0xffb, bitLength: 12),
    //   (  63) '?' |11111111|00                           3fc  [10]
    HuffmanEntry(code: 0x3fc, bitLength: 10),
    //   (  64) '@' |11111111|11010                        1ffa  [13]
    HuffmanEntry(code: 0x1ffa, bitLength: 13),
    //   (  65) 'A' |100001                                21  [6]
    HuffmanEntry(code: 0x21, bitLength: 6),
    //   (  66) 'B' |1011101                               5d  [7]
    HuffmanEntry(code: 0x5d, bitLength: 7),
    //   (  67) 'C' |1011110                               5e  [7]
    HuffmanEntry(code: 0x5e, bitLength: 7),
    //   (  68) 'D' |1011111                               5f  [7]
    HuffmanEntry(code: 0x5f, bitLength: 7),
    //   (  69) 'E' |1100000                               60  [7]
    HuffmanEntry(code: 0x60, bitLength: 7),
    //   (  70) 'F' |1100001                               61  [7]
    HuffmanEntry(code: 0x61, bitLength: 7),
    //   (  71) 'G' |1100010                               62  [7]
    HuffmanEntry(code: 0x62, bitLength: 7),
    //   (  72) 'H' |1100011                               63  [7]
    HuffmanEntry(code: 0x63, bitLength: 7),
    //   (  73) 'I' |1100100                               64  [7]
    HuffmanEntry(code: 0x64, bitLength: 7),
    //   (  74) 'J' |1100101                               65  [7]
    HuffmanEntry(code: 0x65, bitLength: 7),
    //   (  75) 'K' |1100110                               66  [7]
    HuffmanEntry(code: 0x66, bitLength: 7),
    //   (  76) 'L' |1100111                               67  [7]
    HuffmanEntry(code: 0x67, bitLength: 7),
    //   (  77) 'M' |1101000                               68  [7]
    HuffmanEntry(code: 0x68, bitLength: 7),
    //   (  78) 'N' |1101001                               69  [7]
    HuffmanEntry(code: 0x69, bitLength: 7),
    //   (  79) 'O' |1101010                               6a  [7]
    HuffmanEntry(code: 0x6a, bitLength: 7),
    //   (  80) 'P' |1101011                               6b  [7]
    HuffmanEntry(code: 0x6b, bitLength: 7),
    //   (  81) 'Q' |1101100                               6c  [7]
    HuffmanEntry(code: 0x6c, bitLength: 7),
    //   (  82) 'R' |1101101                               6d  [7]
    HuffmanEntry(code: 0x6d, bitLength: 7),
    //   (  83) 'S' |1101110                               6e  [7]
    HuffmanEntry(code: 0x6e, bitLength: 7),
    //   (  84) 'T' |1101111                               6f  [7]
    HuffmanEntry(code: 0x6f, bitLength: 7),
    //   (  85) 'U' |1110000                               70  [7]
    HuffmanEntry(code: 0x70, bitLength: 7),
    //   (  86) 'V' |1110001                               71  [7]
    HuffmanEntry(code: 0x71, bitLength: 7),
    //   (  87) 'W' |1110010                               72  [7]
    HuffmanEntry(code: 0x72, bitLength: 7),
    //   (  88) 'X' |11111100                              fc  [8]
    HuffmanEntry(code: 0xfc, bitLength: 8),
    //   (  89) 'Y' |1110011                               73  [7]
    HuffmanEntry(code: 0x73, bitLength: 7),
    //   (  90) 'Z' |11111101                              fd  [8]
    HuffmanEntry(code: 0xfd, bitLength: 8),
    //   (  91) '[' |11111111|11011                        1ffb  [13]
    HuffmanEntry(code: 0x1ffb, bitLength: 13),
    //   (  92) '\' |11111111|11111110|000                 7fff0  [19]
    HuffmanEntry(code: 0x7fff0, bitLength: 19),
    //   (  93) ']' |11111111|11100                        1ffc  [13]
    HuffmanEntry(code: 0x1ffc, bitLength: 13),
    //   (  94) '^' |11111111|111100                       3ffc  [14]
    HuffmanEntry(code: 0x3ffc, bitLength: 14),
    //   (  95) '_' |100010                                22  [6]
    HuffmanEntry(code: 0x22, bitLength: 6),
    //   (  96) '`' |11111111|11111101                     7ffd  [15]
    HuffmanEntry(code: 0x7ffd, bitLength: 15),
    //   (  97) 'a' |00011                                 3  [5]
    HuffmanEntry(code: 0x3, bitLength: 5),
    //   (  98) 'b' |100011                                23  [6]
    HuffmanEntry(code: 0x23, bitLength: 6),
    //   (  99) 'c' |00100                                 4  [5]
    HuffmanEntry(code: 0x4, bitLength: 5),
    //   ( 100) 'd' |100100                                24  [6]
    HuffmanEntry(code: 0x24, bitLength: 6),
    //   ( 101) 'e' |00101                                 5  [5]
    HuffmanEntry(code: 0x5, bitLength: 5),
    //   ( 102) 'f' |100101                                25  [6]
    HuffmanEntry(code: 0x25, bitLength: 6),
    //   ( 103) 'g' |100110                                26  [6]
    HuffmanEntry(code: 0x26, bitLength: 6),
    //   ( 104) 'h' |100111                                27  [6]
    HuffmanEntry(code: 0x27, bitLength: 6),
    //   ( 105) 'i' |00110                                 6  [5]
    HuffmanEntry(code: 0x6, bitLength: 5),
    //   ( 106) 'j' |1110100                               74  [7]
    HuffmanEntry(code: 0x74, bitLength: 7),
    //   ( 107) 'k' |1110101                               75  [7]
    HuffmanEntry(code: 0x75, bitLength: 7),
    //   ( 108) 'l' |101000                                28  [6]
    HuffmanEntry(code: 0x28, bitLength: 6),
    //   ( 109) 'm' |101001                                29  [6]
    HuffmanEntry(code: 0x29, bitLength: 6),
    //   ( 110) 'n' |101010                                2a  [6]
    HuffmanEntry(code: 0x2a, bitLength: 6),
    //   ( 111) 'o' |00111                                 7  [5]
    HuffmanEntry(code: 0x7, bitLength: 5),
    //   ( 112) 'p' |101011                                2b  [6]
    HuffmanEntry(code: 0x2b, bitLength: 6),
    //   ( 113) 'q' |1110110                               76  [7]
    HuffmanEntry(code: 0x76, bitLength: 7),
    //   ( 114) 'r' |101100                                2c  [6]
    HuffmanEntry(code: 0x2c, bitLength: 6),
    //   ( 115) 's' |01000                                 8  [5]
    HuffmanEntry(code: 0x8, bitLength: 5),
    //   ( 116) 't' |01001                                 9  [5]
    HuffmanEntry(code: 0x9, bitLength: 5),
    //   ( 117) 'u' |101101                                2d  [6]
    HuffmanEntry(code: 0x2d, bitLength: 6),
    //   ( 118) 'v' |1110111                               77  [7]
    HuffmanEntry(code: 0x77, bitLength: 7),
    //   ( 119) 'w' |1111000                               78  [7]
    HuffmanEntry(code: 0x78, bitLength: 7),
    //   ( 120) 'x' |1111001                               79  [7]
    HuffmanEntry(code: 0x79, bitLength: 7),
    //   ( 121) 'y' |1111010                               7a  [7]
    HuffmanEntry(code: 0x7a, bitLength: 7),
    //   ( 122) 'z' |1111011                               7b  [7]
    HuffmanEntry(code: 0x7b, bitLength: 7),
    //   ( 123) '{' |11111111|1111110                      7ffe  [15]
    HuffmanEntry(code: 0x7ffe, bitLength: 15),
    //   ( 124) '|' |11111111|100                          7fc  [11]
    HuffmanEntry(code: 0x7fc, bitLength: 11),
    //   ( 125) '}' |11111111|111101                       3ffd  [14]
    HuffmanEntry(code: 0x3ffd, bitLength: 14),
    //   ( 126) '~' |11111111|11101                        1ffd  [13]
    HuffmanEntry(code: 0x1ffd, bitLength: 13),
    //   ( 127)     |11111111|11111111|11111111|1100       ffffffc  [28]
    HuffmanEntry(code: 0xffffffc, bitLength: 28),
    //   ( 128)     |11111111|11111110|0110                fffe6  [20]
    HuffmanEntry(code: 0xfffe6, bitLength: 20),
    //   ( 129)     |11111111|11111111|010010              3fffd2  [22]
    HuffmanEntry(code: 0x3fffd2, bitLength: 22),
    //   ( 130)     |11111111|11111110|0111                fffe7  [20]
    HuffmanEntry(code: 0xfffe7, bitLength: 20),
    //   ( 131)     |11111111|11111110|1000                fffe8  [20]
    HuffmanEntry(code: 0xfffe8, bitLength: 20),
    //   ( 132)     |11111111|11111111|010011              3fffd3  [22]
    HuffmanEntry(code: 0x3fffd3, bitLength: 22),
    //   ( 133)     |11111111|11111111|010100              3fffd4  [22]
    HuffmanEntry(code: 0x3fffd4, bitLength: 22),
    //   ( 134)     |11111111|11111111|010101              3fffd5  [22]
    HuffmanEntry(code: 0x3fffd5, bitLength: 22),
    //   ( 135)     |11111111|11111111|1011001             7fffd9  [23]
    HuffmanEntry(code: 0x7fffd9, bitLength: 23),
    //   ( 136)     |11111111|11111111|010110              3fffd6  [22]
    HuffmanEntry(code: 0x3fffd6, bitLength: 22),
    //   ( 137)     |11111111|11111111|1011010             7fffda  [23]
    HuffmanEntry(code: 0x7fffda, bitLength: 23),
    //   ( 138)     |11111111|11111111|1011011             7fffdb  [23]
    HuffmanEntry(code: 0x7fffdb, bitLength: 23),
    //   ( 139)     |11111111|11111111|1011100             7fffdc  [23]
    HuffmanEntry(code: 0x7fffdc, bitLength: 23),
    //   ( 140)     |11111111|11111111|1011101             7fffdd  [23]
    HuffmanEntry(code: 0x7fffdd, bitLength: 23),
    //   ( 141)     |11111111|11111111|1011110             7fffde  [23]
    HuffmanEntry(code: 0x7fffde, bitLength: 23),
    //   ( 142)     |11111111|11111111|11101011            ffffeb  [24]
    HuffmanEntry(code: 0xffffeb, bitLength: 24),
    //   ( 143)     |11111111|11111111|1011111             7fffdf  [23]
    HuffmanEntry(code: 0x7fffdf, bitLength: 23),
    //   ( 144)     |11111111|11111111|11101100            ffffec  [24]
    HuffmanEntry(code: 0xffffec, bitLength: 24),
    //   ( 145)     |11111111|11111111|11101101            ffffed  [24]
    HuffmanEntry(code: 0xffffed, bitLength: 24),
    //   ( 146)     |11111111|11111111|010111              3fffd7  [22]
    HuffmanEntry(code: 0x3fffd7, bitLength: 22),
    //   ( 147)     |11111111|11111111|1100000             7fffe0  [23]
    HuffmanEntry(code: 0x7fffe0, bitLength: 23),
    //   ( 148)     |11111111|11111111|11101110            ffffee  [24]
    HuffmanEntry(code: 0xffffee, bitLength: 24),
    //   ( 149)     |11111111|11111111|1100001             7fffe1  [23]
    HuffmanEntry(code: 0x7fffe1, bitLength: 23),
    //   ( 150)     |11111111|11111111|1100010             7fffe2  [23]
    HuffmanEntry(code: 0x7fffe2, bitLength: 23),
    //   ( 151)     |11111111|11111111|1100011             7fffe3  [23]
    HuffmanEntry(code: 0x7fffe3, bitLength: 23),
    //   ( 152)     |11111111|11111111|1100100             7fffe4  [23]
    HuffmanEntry(code: 0x7fffe4, bitLength: 23),
    //   ( 153)     |11111111|11111110|11100               1fffdc  [21]
    HuffmanEntry(code: 0x1fffdc, bitLength: 21),
    //   ( 154)     |11111111|11111111|011000              3fffd8  [22]
    HuffmanEntry(code: 0x3fffd8, bitLength: 22),
    //   ( 155)     |11111111|11111111|1100101             7fffe5  [23]
    HuffmanEntry(code: 0x7fffe5, bitLength: 23),
    //   ( 156)     |11111111|11111111|011001              3fffd9  [22]
    HuffmanEntry(code: 0x3fffd9, bitLength: 22),
    //   ( 157)     |11111111|11111111|1100110             7fffe6  [23]
    HuffmanEntry(code: 0x7fffe6, bitLength: 23),
    //   ( 158)     |11111111|11111111|1100111             7fffe7  [23]
    HuffmanEntry(code: 0x7fffe7, bitLength: 23),
    //   ( 159)     |11111111|11111111|11101111            ffffef  [24]
    HuffmanEntry(code: 0xffffef, bitLength: 24),
    //   ( 160)     |11111111|11111111|011010              3fffda  [22]
    HuffmanEntry(code: 0x3fffda, bitLength: 22),
    //   ( 161)     |11111111|11111110|11101               1fffdd  [21]
    HuffmanEntry(code: 0x1fffdd, bitLength: 21),
    //   ( 162)     |11111111|11111110|1001                fffe9  [20]
    HuffmanEntry(code: 0xfffe9, bitLength: 20),
    //   ( 163)     |11111111|11111111|011011              3fffdb  [22]
    HuffmanEntry(code: 0x3fffdb, bitLength: 22),
    //   ( 164)     |11111111|11111111|011100              3fffdc  [22]
    HuffmanEntry(code: 0x3fffdc, bitLength: 22),
    //   ( 165)     |11111111|11111111|1101000             7fffe8  [23]
    HuffmanEntry(code: 0x7fffe8, bitLength: 23),
    //   ( 166)     |11111111|11111111|1101001             7fffe9  [23]
    HuffmanEntry(code: 0x7fffe9, bitLength: 23),
    //   ( 167)     |11111111|11111110|11110               1fffde  [21]
    HuffmanEntry(code: 0x1fffde, bitLength: 21),
    //   ( 168)     |11111111|11111111|1101010             7fffea  [23]
    HuffmanEntry(code: 0x7fffea, bitLength: 23),
    //   ( 169)     |11111111|11111111|011101              3fffdd  [22]
    HuffmanEntry(code: 0x3fffdd, bitLength: 22),
    //   ( 170)     |11111111|11111111|011110              3fffde  [22]
    HuffmanEntry(code: 0x3fffde, bitLength: 22),
    //   ( 171)     |11111111|11111111|11110000            fffff0  [24]
    HuffmanEntry(code: 0xfffff0, bitLength: 24),
    //   ( 172)     |11111111|11111110|11111               1fffdf  [21]
    HuffmanEntry(code: 0x1fffdf, bitLength: 21),
    //   ( 173)     |11111111|11111111|011111              3fffdf  [22]
    HuffmanEntry(code: 0x3fffdf, bitLength: 22),
    //   ( 174)     |11111111|11111111|1101011             7fffeb  [23]
    HuffmanEntry(code: 0x7fffeb, bitLength: 23),
    //   ( 175)     |11111111|11111111|1101100             7fffec  [23]
    HuffmanEntry(code: 0x7fffec, bitLength: 23),
    //   ( 176)     |11111111|11111111|00000               1fffe0  [21]
    HuffmanEntry(code: 0x1fffe0, bitLength: 21),
    //   ( 177)     |11111111|11111111|00001               1fffe1  [21]
    HuffmanEntry(code: 0x1fffe1, bitLength: 21),
    //   ( 178)     |11111111|11111111|100000              3fffe0  [22]
    HuffmanEntry(code: 0x3fffe0, bitLength: 22),
    //   ( 179)     |11111111|11111111|00010               1fffe2  [21]
    HuffmanEntry(code: 0x1fffe2, bitLength: 21),
    //   ( 180)     |11111111|11111111|1101101             7fffed  [23]
    HuffmanEntry(code: 0x7fffed, bitLength: 23),
    //   ( 181)     |11111111|11111111|100001              3fffe1  [22]
    HuffmanEntry(code: 0x3fffe1, bitLength: 22),
    //   ( 182)     |11111111|11111111|1101110             7fffee  [23]
    HuffmanEntry(code: 0x7fffee, bitLength: 23),
    //   ( 183)     |11111111|11111111|1101111             7fffef  [23]
    HuffmanEntry(code: 0x7fffef, bitLength: 23),
    //   ( 184)     |11111111|11111110|1010                fffea  [20]
    HuffmanEntry(code: 0xfffea, bitLength: 20),
    //   ( 185)     |11111111|11111111|100010              3fffe2  [22]
    HuffmanEntry(code: 0x3fffe2, bitLength: 22),
    //   ( 186)     |11111111|11111111|100011              3fffe3  [22]
    HuffmanEntry(code: 0x3fffe3, bitLength: 22),
    //   ( 187)     |11111111|11111111|100100              3fffe4  [22]
    HuffmanEntry(code: 0x3fffe4, bitLength: 22),
    //   ( 188)     |11111111|11111111|1110000             7ffff0  [23]
    HuffmanEntry(code: 0x7ffff0, bitLength: 23),
    //   ( 189)     |11111111|11111111|100101              3fffe5  [22]
    HuffmanEntry(code: 0x3fffe5, bitLength: 22),
    //   ( 190)     |11111111|11111111|100110              3fffe6  [22]
    HuffmanEntry(code: 0x3fffe6, bitLength: 22),
    //   ( 191)     |11111111|11111111|1110001             7ffff1  [23]
    HuffmanEntry(code: 0x7ffff1, bitLength: 23),
    //   ( 192)     |11111111|11111111|11111000|00        3ffffe0  [26]
    HuffmanEntry(code: 0x3ffffe0, bitLength: 26),
    //   ( 193)     |11111111|11111111|11111000|01        3ffffe1  [26]
    HuffmanEntry(code: 0x3ffffe1, bitLength: 26),
    //   ( 194)     |11111111|11111110|1011                fffeb  [20]
    HuffmanEntry(code: 0xfffeb, bitLength: 20),
    //   ( 195)     |11111111|11111110|001                 7fff1  [19]
    HuffmanEntry(code: 0x7fff1, bitLength: 19),
    //   ( 196)     |11111111|11111111|100111              3fffe7  [22]
    HuffmanEntry(code: 0x3fffe7, bitLength: 22),
    //   ( 197)     |11111111|11111111|1110010             7ffff2  [23]
    HuffmanEntry(code: 0x7ffff2, bitLength: 23),
    //   ( 198)     |11111111|11111111|101000              3fffe8  [22]
    HuffmanEntry(code: 0x3fffe8, bitLength: 22),
    //   ( 199)     |11111111|11111111|11110110|0         1ffffec  [25]
    HuffmanEntry(code: 0x1ffffec, bitLength: 25),
    //   ( 200)     |11111111|11111111|11111000|10        3ffffe2  [26]
    HuffmanEntry(code: 0x3ffffe2, bitLength: 26),
    //   ( 201)     |11111111|11111111|11111000|11        3ffffe3  [26]
    HuffmanEntry(code: 0x3ffffe3, bitLength: 26),
    //   ( 202)     |11111111|11111111|11111001|00        3ffffe4  [26]
    HuffmanEntry(code: 0x3ffffe4, bitLength: 26),
    //   ( 203)     |11111111|11111111|11111011|110       7ffffde  [27]
    HuffmanEntry(code: 0x7ffffde, bitLength: 27),
    //   ( 204)     |11111111|11111111|11111011|111       7ffffdf  [27]
    HuffmanEntry(code: 0x7ffffdf, bitLength: 27),
    //   ( 205)     |11111111|11111111|11111001|01        3ffffe5  [26]
    HuffmanEntry(code: 0x3ffffe5, bitLength: 26),
    //   ( 206)     |11111111|11111111|11110001            fffff1  [24]
    HuffmanEntry(code: 0xfffff1, bitLength: 24),
    //   ( 207)     |11111111|11111111|11110110|1         1ffffed  [25]
    HuffmanEntry(code: 0x1ffffed, bitLength: 25),
    //   ( 208)     |11111111|11111110|010                 7fff2  [19]
    HuffmanEntry(code: 0x7fff2, bitLength: 19),
    //   ( 209)     |11111111|11111111|00011               1fffe3  [21]
    HuffmanEntry(code: 0x1fffe3, bitLength: 21),
    //   ( 210)     |11111111|11111111|11111001|10        3ffffe6  [26]
    HuffmanEntry(code: 0x3ffffe6, bitLength: 26),
    //   ( 211)     |11111111|11111111|11111100|000       7ffffe0  [27]
    HuffmanEntry(code: 0x7ffffe0, bitLength: 27),
    //   ( 212)     |11111111|11111111|11111100|001       7ffffe1  [27]
    HuffmanEntry(code: 0x7ffffe1, bitLength: 27),
    //   ( 213)     |11111111|11111111|11111001|11        3ffffe7  [26]
    HuffmanEntry(code: 0x3ffffe7, bitLength: 26),
    //   ( 214)     |11111111|11111111|11111100|010       7ffffe2  [27]
    HuffmanEntry(code: 0x7ffffe2, bitLength: 27),
    //   ( 215)     |11111111|11111111|11110010            fffff2  [24]
    HuffmanEntry(code: 0xfffff2, bitLength: 24),
    //   ( 216)     |11111111|11111111|00100               1fffe4  [21]
    HuffmanEntry(code: 0x1fffe4, bitLength: 21),
    //   ( 217)     |11111111|11111111|00101               1fffe5  [21]
    HuffmanEntry(code: 0x1fffe5, bitLength: 21),
    //   ( 218)     |11111111|11111111|11111010|00        3ffffe8  [26]
    HuffmanEntry(code: 0x3ffffe8, bitLength: 26),
    //   ( 219)     |11111111|11111111|11111010|01        3ffffe9  [26]
    HuffmanEntry(code: 0x3ffffe9, bitLength: 26),
    //   ( 220)     |11111111|11111111|11111111|1101      ffffffd  [28]
    HuffmanEntry(code: 0xffffffd, bitLength: 28),
    //   ( 221)     |11111111|11111111|11111100|011       7ffffe3  [27]
    HuffmanEntry(code: 0x7ffffe3, bitLength: 27),
    //   ( 222)     |11111111|11111111|11111100|100       7ffffe4  [27]
    HuffmanEntry(code: 0x7ffffe4, bitLength: 27),
    //   ( 223)     |11111111|11111111|11111100|101       7ffffe5  [27]
    HuffmanEntry(code: 0x7ffffe5, bitLength: 27),
    //   ( 224)     |11111111|11111110|1100                fffec  [20]
    HuffmanEntry(code: 0xfffec, bitLength: 20),
    //   ( 225)     |11111111|11111111|11110011            fffff3  [24]
    HuffmanEntry(code: 0xfffff3, bitLength: 24),
    //   ( 226)     |11111111|11111110|1101                fffed  [20]
    HuffmanEntry(code: 0xfffed, bitLength: 20),
    //   ( 227)     |11111111|11111111|00110               1fffe6  [21]
    HuffmanEntry(code: 0x1fffe6, bitLength: 21),
    //   ( 228)     |11111111|11111111|101001              3fffe9  [22]
    HuffmanEntry(code: 0x3fffe9, bitLength: 22),
    //   ( 229)     |11111111|11111111|00111               1fffe7  [21]
    HuffmanEntry(code: 0x1fffe7, bitLength: 21),
    //   ( 230)     |11111111|11111111|01000               1fffe8  [21]
    HuffmanEntry(code: 0x1fffe8, bitLength: 21),
    //   ( 231)     |11111111|11111111|1110011             7ffff3  [23]
    HuffmanEntry(code: 0x7ffff3, bitLength: 23),
    //   ( 232)     |11111111|11111111|101010              3fffea  [22]
    HuffmanEntry(code: 0x3fffea, bitLength: 22),
    //   ( 233)     |11111111|11111111|101011              3fffeb  [22]
    HuffmanEntry(code: 0x3fffeb, bitLength: 22),
    //   ( 234)     |11111111|11111111|11110111|0         1ffffee  [25]
    HuffmanEntry(code: 0x1ffffee, bitLength: 25),
    //   ( 235)     |11111111|11111111|11110111|1         1ffffef  [25]
    HuffmanEntry(code: 0x1ffffef, bitLength: 25),
    //   ( 236)     |11111111|11111111|11110100            fffff4  [24]
    HuffmanEntry(code: 0xfffff4, bitLength: 24),
    //   ( 237)     |11111111|11111111|11110101            fffff5  [24]
    HuffmanEntry(code: 0xfffff5, bitLength: 24),
    //   ( 238)     |11111111|11111111|11111010|10        3ffffea  [26]
    HuffmanEntry(code: 0x3ffffea, bitLength: 26),
    //   ( 239)     |11111111|11111111|1110100             7ffff4  [23]
    HuffmanEntry(code: 0x7ffff4, bitLength: 23),
    //   ( 240)     |11111111|11111111|11111010|11        3ffffeb  [26]
    HuffmanEntry(code: 0x3ffffeb, bitLength: 26),
    //   ( 241)     |11111111|11111111|11111100|110       7ffffe6  [27]
    HuffmanEntry(code: 0x7ffffe6, bitLength: 27),
    //   ( 242)     |11111111|11111111|11111011|00        3ffffec  [26]
    HuffmanEntry(code: 0x3ffffec, bitLength: 26),
    //   ( 243)     |11111111|11111111|11111011|01        3ffffed  [26]
    HuffmanEntry(code: 0x3ffffed, bitLength: 26),
    //   ( 244)     |11111111|11111111|11111100|111       7ffffe7  [27]
    HuffmanEntry(code: 0x7ffffe7, bitLength: 27),
    //   ( 245)     |11111111|11111111|11111101|000       7ffffe8  [27]
    HuffmanEntry(code: 0x7ffffe8, bitLength: 27),
    //   ( 246)     |11111111|11111111|11111101|001       7ffffe9  [27]
    HuffmanEntry(code: 0x7ffffe9, bitLength: 27),
    //   ( 247)     |11111111|11111111|11111101|010       7ffffea  [27]
    HuffmanEntry(code: 0x7ffffea, bitLength: 27),
    //   ( 248)     |11111111|11111111|11111101|011       7ffffeb  [27]
    HuffmanEntry(code: 0x7ffffeb, bitLength: 27),
    //   ( 249)     |11111111|11111111|11111111|1110      ffffffe  [28]
    HuffmanEntry(code: 0xffffffe, bitLength: 28),
    //   ( 250)     |11111111|11111111|11111101|100       7ffffec  [27]
    HuffmanEntry(code: 0x7ffffec, bitLength: 27),
    //   ( 251)     |11111111|11111111|11111101|101       7ffffed  [27]
    HuffmanEntry(code: 0x7ffffed, bitLength: 27),
    //   ( 252)     |11111111|11111111|11111101|110       7ffffee  [27]
    HuffmanEntry(code: 0x7ffffee, bitLength: 27),
    //   ( 253)     |11111111|11111111|11111101|111       7ffffef  [27]
    HuffmanEntry(code: 0x7ffffef, bitLength: 27),
    //   ( 254)     |11111111|11111111|11111110|000       7fffff0  [27]
    HuffmanEntry(code: 0x7fffff0, bitLength: 27),
    //   ( 255)     |11111111|11111111|11111011|10        3ffffee  [26]
    HuffmanEntry(code: 0x3ffffee, bitLength: 26),
    //   ( 256) EOS |11111111|11111111|11111111|111111     3fffffff  [30]
    HuffmanEntry(code: 0x3fffffff, bitLength: 30),
]