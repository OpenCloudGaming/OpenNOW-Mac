//
//  RemoteCoOpNativeFraming.swift
//  OpenNOW
//
//  Framing for native Remote Co-Op guests: `OPNRemoteCoOpWireMessage` values over a plain stream
//  socket instead of the browser's WebSocket.
//
//  Frames are newline-delimited JSON. The encoder escapes every control character in strings, so
//  a bare LF can only ever appear as a delimiter - no length prefixes or escaping layer to keep
//  in sync. Signaling rates are a handful of messages per second, so the byte copies below are
//  never on a hot path.
//

import Foundation

public enum OPNRemoteCoOpNativeFrameError: LocalizedError, Equatable, Sendable {
    case frameTooLarge

    public var errorDescription: String? {
        switch self {
        case .frameTooLarge: "A native Remote Co-Op signaling frame exceeded the maximum size."
        }
    }
}

public struct OPNRemoteCoOpNativeFrameCodec: Sendable {
    /// Frames that arrived intact but did not decode - a message kind this build does not know, most
    /// likely a host on a newer release. Counted rather than thrown: newline framing means a bad frame
    /// cannot desynchronise the stream, and dropping the session over one would disconnect every
    /// native guest where the WebSocket transport would simply have ignored it.
    public private(set) var skippedFrameCount = 0

    public static let frameDelimiter: UInt8 = 0x0A
    /// SDP offers are the largest frames and stay well under 100 KB; a megabyte is headroom, not
    /// a budget the protocol is expected to use.
    public static let maximumFrameBytes = 1_048_576

    private var buffer = Data()

    public init() {}

    public static func encode(_ message: OPNRemoteCoOpWireMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(message)
        data.append(frameDelimiter)
        return data
    }

    /// Feeds received bytes in and returns every frame completed by them, in order.
    public mutating func append(_ bytes: Data) throws -> [OPNRemoteCoOpWireMessage] {
        buffer.append(bytes)
        var messages: [OPNRemoteCoOpWireMessage] = []
        while let delimiterIndex = buffer.firstIndex(of: Self.frameDelimiter) {
            let frame = Data(buffer[..<delimiterIndex])
            buffer = Data(buffer[buffer.index(after: delimiterIndex)...])
            guard !frame.isEmpty else { continue }
            guard let message = try? JSONDecoder().decode(OPNRemoteCoOpWireMessage.self, from: frame) else {
                skippedFrameCount += 1
                continue
            }
            messages.append(message)
        }
        guard buffer.count <= Self.maximumFrameBytes else { throw OPNRemoteCoOpNativeFrameError.frameTooLarge }
        return messages
    }
}
