import Foundation

/// The control and configuration surfaces the browser guest and the host share over WebTransport.
///
/// Media itself reuses the native packet framings unchanged - `OPNRemoteCoOpCompressedVideoPacket`
/// for H.264 and `OPNRemoteCoOpAudioPacket` for PCM - so the wire formats stay in one place. What is
/// new for a browser guest is the shape of the conversation around that media: a control stream
/// carrying JSON the web page can read without a binary parser, and one configuration message
/// carrying the `avcC` record WebCodecs needs before it can decode anything.
enum RemoteCoOpBrowserProtocol {
    /// WebTransport serves exactly this path.
    static let mediaPath = "/remote-coop-media"
}

/// What the browser page needs to open the WebTransport session: where the QUIC listener is, which
/// path to CONNECT to, and the SHA-256 of the certificate it must pin.
///
/// The page gets this from the host's own HTTPS origin - the one whose certificate the guest has
/// already accepted - rather than from the invite link, so a guest discovered over Bonjour without a
/// link can still reach the media path.
public struct OPNRemoteCoOpBrowserWebTransportInfo: Codable, Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let path: String
    /// Base64 of the certificate's SHA-256, the `serverCertificateHashes` value.
    public let certificateHash: String

    public init(host: String, port: UInt16, path: String, certificateHash: String) {
        self.host = host
        self.port = port
        self.path = path
        self.certificateHash = certificateHash
    }
}

/// The JSON control messages exchanged on the browser guest's bidirectional stream, newline-delimited
/// so either side can parse without a binary length prefix and without re-inventing framing.
///
/// `join` is the only one a guest sends; everything else is the host telling the guest where it is in
/// the approval flow and what player slot it holds.
struct RemoteCoOpBrowserControlMessage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case join
        case joined
        case state
        case config
        case error
    }

    var kind: Kind
    /// Guest only: the signed invite token, exactly as the native and WebSocket guests present it.
    var token: String?
    /// Guest only: the display name the host shows next to the slot.
    var displayName: String?
    /// Guest only, on a reconnect: the participant ID and reconnect token the host issued on the first
    /// join, so a guest that dropped reclaims its slot rather than arriving as a stranger.
    var reconnectToken: String?
    /// Host only: the participant the guest now owns on the host session.
    var participantID: UUID?
    /// Host only: `waitingForApproval`, `connected`, or `disconnected`.
    var state: OPNRemoteCoOpParticipantConnectionState?
    /// Host only: the player slot once approved, absent while waiting.
    var playerIndex: Int?
    /// Host only: the H.264 `avcC` record, base64, that `VideoDecoder.configure` takes.
    var avcC: String?
    /// Host only: the encoded picture size, so the page can size its canvas before the first frame.
    var width: Int?
    var height: Int?
    /// Host only: a human-readable reason for `error`.
    var message: String?

    static func join(token: String, displayName: String, participantID: UUID?, reconnectToken: String?) -> RemoteCoOpBrowserControlMessage {
        RemoteCoOpBrowserControlMessage(kind: .join,
                                        token: token,
                                        displayName: displayName,
                                        reconnectToken: reconnectToken,
                                        participantID: participantID)
    }

    static func joined(_ participant: OPNRemoteCoOpParticipant) -> RemoteCoOpBrowserControlMessage {
        RemoteCoOpBrowserControlMessage(kind: .joined,
                                        reconnectToken: participant.reconnectToken,
                                        participantID: participant.id,
                                        state: participant.connectionState,
                                        playerIndex: participant.playerIndex)
    }

    static func state(_ participant: OPNRemoteCoOpParticipant) -> RemoteCoOpBrowserControlMessage {
        RemoteCoOpBrowserControlMessage(kind: .state,
                                        participantID: participant.id,
                                        state: participant.connectionState,
                                        playerIndex: participant.playerIndex)
    }

    static func error(_ message: String) -> RemoteCoOpBrowserControlMessage {
        RemoteCoOpBrowserControlMessage(kind: .error, message: message)
    }

    static func config(avcC: Data, width: Int, height: Int) -> RemoteCoOpBrowserControlMessage {
        RemoteCoOpBrowserControlMessage(kind: .config,
                                        avcC: avcC.base64EncodedString(),
                                        width: width,
                                        height: height)
    }
}

/// Newline-delimited JSON framing for the control stream.
enum RemoteCoOpBrowserControlCodec {
    static func encode(_ message: RemoteCoOpBrowserControlMessage) -> Data {
        var data = (try? JSONEncoder().encode(message)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Decodes every complete line in `buffer`, leaving a partial trailing line in place for the next
    /// read. A single read can deliver several messages or half of one.
    static func decode(from buffer: inout Data) -> [RemoteCoOpBrowserControlMessage] {
        var messages: [RemoteCoOpBrowserControlMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty, let message = try? JSONDecoder().decode(RemoteCoOpBrowserControlMessage.self, from: Data(line)) else { continue }
            messages.append(message)
        }
        return messages
    }
}
