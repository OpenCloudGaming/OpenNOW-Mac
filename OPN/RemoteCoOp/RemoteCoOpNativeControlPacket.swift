import Foundation

/// The guest→host control datagrams for the native transport: a `hello` that binds the guest's UDP
/// flow to a participant, and `input` packets carrying controller state. Both carry the token the
/// host put in its `.nativeHost` signal, so a stray datagram cannot open a media flow or inject input.
///
/// Datagrams are told apart by their kind byte: media flows host→guest and never appears here.
enum OPNRemoteCoOpNativeControlPacket {
    enum Kind: UInt8 {
        case hello = 0x48
        case input = 0x49
    }

    static let magic: UInt8 = 0x4F
    static let version: UInt8 = 1
    /// magic, kind, version, token length.
    static let headerBytes = 4
    static let maximumTokenBytes = 255

    struct Packet: Equatable {
        var kind: Kind
        var token: String
        var payload: Data
    }

    static func hello(token: String) -> Data {
        encode(kind: .hello, token: token, payload: Data())
    }

    static func input(token: String, payload: Data) -> Data {
        encode(kind: .input, token: token, payload: payload)
    }

    static func encode(kind: Kind, token: String, payload: Data) -> Data {
        let tokenBytes = Array(token.utf8.prefix(maximumTokenBytes))
        var bytes = [UInt8]()
        bytes.reserveCapacity(headerBytes + tokenBytes.count + payload.count)
        bytes.append(magic)
        bytes.append(kind.rawValue)
        bytes.append(version)
        bytes.append(UInt8(tokenBytes.count))
        bytes.append(contentsOf: tokenBytes)
        bytes.append(contentsOf: payload)
        return Data(bytes)
    }

    static func decode(_ datagram: Data) -> Packet? {
        let bytes = [UInt8](datagram)
        guard bytes.count >= headerBytes, bytes[0] == magic, bytes[2] == version else { return nil }
        guard let kind = Kind(rawValue: bytes[1]) else { return nil }
        let tokenLength = Int(bytes[3])
        guard bytes.count >= headerBytes + tokenLength else { return nil }
        let token = String(decoding: bytes[headerBytes..<headerBytes + tokenLength], as: UTF8.self)
        let payload = Data(bytes[(headerBytes + tokenLength)...])
        return Packet(kind: kind, token: token, payload: payload)
    }

    /// True when a datagram is guest→host control rather than host→guest media, so one socket can
    /// carry both directions without the sender having to be told which side it is.
    static func isControlDatagram(_ datagram: Data) -> Bool {
        let bytes = [UInt8](datagram.prefix(3))
        guard bytes.count == 3 else { return false }
        return bytes[0] == magic && (bytes[1] == Kind.hello.rawValue || bytes[1] == Kind.input.rawValue)
    }
}
