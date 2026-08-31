//
//  RemoteCoOpWebSocketFrame.swift
//  OpenNOW
//
//  RFC 6455 framing for the embedded Remote Co-Op server.
//
//  Network.framework does ship `NWProtocolWebSocket`, but it wants the whole listener to be a
//  WebSocket endpoint. Remote Co-Op needs one port serving both the guest page over HTTPS and the
//  signaling socket over WSS: same origin is what lets a guest accept the self-signed certificate
//  once, on a top-level navigation, and have that exception cover the socket too. Split across two
//  ports the browser would refuse the socket with no way to grant an exception for it.
//
//  So the listener is plain TLS over TCP, and the HTTP and WebSocket layers are ours.
//

import CryptoKit
import Foundation

enum OPNRemoteCoOpWebSocketOpcode: UInt8 {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

struct OPNRemoteCoOpWebSocketFrame: Equatable {
    let opcode: OPNRemoteCoOpWebSocketOpcode
    let payload: Data
    let isFinal: Bool
}

enum OPNRemoteCoOpWebSocketError: Error, Equatable {
    /// A client frame arrived without a mask. RFC 6455 requires clients to mask; an unmasked frame
    /// is either a broken client or an attempt to smuggle bytes past a proxy, and the spec says to
    /// fail the connection rather than guess.
    case unmaskedClientFrame
    case unsupportedOpcode(UInt8)
    case frameTooLarge(UInt64)
}

enum OPNRemoteCoOpWebSocketCodec {
    /// The largest single frame accepted from a guest. Signaling messages are SDP at worst, a few
    /// tens of kilobytes; anything approaching this is a client trying to make the host allocate.
    static let maximumPayloadBytes: UInt64 = 1 << 20

    /// The RFC 6455 accept value: the client's key concatenated with the protocol's fixed GUID,
    /// SHA-1'd, base64'd. SHA-1 here is not a security decision - it is the handshake the spec
    /// defines, and the browser will reject anything else.
    static func acceptToken(forKey key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    /// Decodes as many whole frames as `buffer` holds, removing them from it. A partial frame is
    /// left in place for the next read - TCP gives no message boundaries, so a frame routinely
    /// arrives split across reads, and treating a short buffer as an error would drop traffic that
    /// is merely still in flight.
    static func decodeFrames(from buffer: inout Data) throws -> [OPNRemoteCoOpWebSocketFrame] {
        var frames: [OPNRemoteCoOpWebSocketFrame] = []
        while true {
            guard let (frame, consumed) = try decodeFrame(buffer) else { return frames }
            buffer.removeFirst(consumed)
            frames.append(frame)
        }
    }

    /// Returns nil when `data` does not yet hold a whole frame.
    static func decodeFrame(_ data: Data) throws -> (frame: OPNRemoteCoOpWebSocketFrame, consumed: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let isFinal = bytes[0] & 0x80 != 0
        let rawOpcode = bytes[0] & 0x0F
        let isMasked = bytes[1] & 0x80 != 0
        var length = UInt64(bytes[1] & 0x7F)
        var cursor = 2

        if length == 126 {
            guard bytes.count >= cursor + 2 else { return nil }
            length = (UInt64(bytes[cursor]) << 8) | UInt64(bytes[cursor + 1])
            cursor += 2
        } else if length == 127 {
            guard bytes.count >= cursor + 8 else { return nil }
            length = bytes[cursor..<(cursor + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            cursor += 8
        }
        guard length <= maximumPayloadBytes else { throw OPNRemoteCoOpWebSocketError.frameTooLarge(length) }
        // Checked before the mask key and payload are read, so an oversized declared length is
        // rejected without waiting for bytes that would never be allowed anyway.
        guard isMasked else { throw OPNRemoteCoOpWebSocketError.unmaskedClientFrame }
        guard bytes.count >= cursor + 4 else { return nil }
        let mask = Array(bytes[cursor..<(cursor + 4)])
        cursor += 4

        let payloadLength = Int(length)
        guard bytes.count >= cursor + payloadLength else { return nil }
        var payload = Array(bytes[cursor..<(cursor + payloadLength)])
        for index in 0..<payload.count { payload[index] ^= mask[index % 4] }
        cursor += payloadLength

        guard let opcode = OPNRemoteCoOpWebSocketOpcode(rawValue: rawOpcode) else {
            throw OPNRemoteCoOpWebSocketError.unsupportedOpcode(rawOpcode)
        }
        return (OPNRemoteCoOpWebSocketFrame(opcode: opcode, payload: Data(payload), isFinal: isFinal), cursor)
    }

    /// Server-to-client frames are never masked, per RFC 6455.
    static func encodeFrame(opcode: OPNRemoteCoOpWebSocketOpcode, payload: Data) -> Data {
        var frame = Data([0x80 | opcode.rawValue])
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(truncatingIfNeeded: count >> 8))
            frame.append(UInt8(truncatingIfNeeded: count))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8(truncatingIfNeeded: count >> shift))
            }
        }
        frame.append(payload)
        return frame
    }

    static func encodeText(_ text: String) -> Data {
        encodeFrame(opcode: .text, payload: Data(text.utf8))
    }
}
