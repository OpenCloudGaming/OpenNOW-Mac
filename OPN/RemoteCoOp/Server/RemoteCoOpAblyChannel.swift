//
//  RemoteCoOpAblyChannel.swift
//  OpenNOW
//
//  The Ably side of hosted signaling: everything that touches the SDK, and nothing that decides
//  anything.
//
//  Kept deliberately thin. `OPNRemoteCoOpHostedSignalingSession` holds the behaviour worth testing —
//  authorisation, participant binding, presence-to-disconnect — and this adapter only moves strings.
//  Anything with a decision in it belongs on the other side of the protocol, where a test can reach
//  it without a network or an account.
//

@preconcurrency import Ably
import Foundation

public final class OPNRemoteCoOpAblyChannel: OPNRemoteCoOpSignalingChannel, @unchecked Sendable {
    private let realtime: ARTRealtime
    private let channel: ARTRealtimeChannel
    private let logger: (@Sendable (String) -> Void)?

    /// Connects with the JWT alone.
    ///
    /// The host's API key never reaches this object: it stays in the keychain, signs the JWT, and the
    /// connection is made with the JWT the same way a guest's is. Nothing here can widen what that
    /// credential permits.
    public init(token: String, channelName: String, logger: (@Sendable (String) -> Void)? = nil) {
        let options = ARTClientOptions()
        options.token = token
        // Own messages are never wanted: the two directions are separated by name, and echoing them
        // back would make the host consume its own commands if that separation ever slipped.
        options.echoMessages = false
        self.realtime = ARTRealtime(options: options)
        self.channel = realtime.channels.get(channelName)
        self.logger = logger
    }

    public func publish(name: String, text: String) {
        channel.publish(name, data: text) { [logger] error in
            guard let error else { return }
            // Logged rather than thrown: a lost signaling message is recoverable - the guest retries,
            // or the host republishes on the next sync - and failing the whole session over one
            // publish would be worse than the symptom.
            logger?("Remote Co-Op hosted signaling could not publish \(name): \(error.message)")
        }
    }

    public func subscribe(name: String, handler: @escaping @Sendable (_ text: String, _ senderID: String) -> Void) {
        channel.subscribe(name) { message in
            guard let text = message.data as? String else { return }
            // `clientId` is the sender's asserted identity, and it is what the session uses as a
            // connection key. Ably guarantees it is present only when the credential carries one, so
            // a message without it is dropped here rather than being given an empty owner the gate
            // would then treat as a single shared connection.
            guard let senderID = message.clientId, !senderID.isEmpty else { return }
            handler(text, senderID)
        }
    }

    public func onLeave(handler: @escaping @Sendable (_ senderID: String) -> Void) {
        // Both, because they mean the same thing to us and Ably distinguishes them: `leave` is a
        // guest closing its connection, `absent` is one that vanished without saying so. The second
        // is the case the socket transports need a liveness sweep to notice at all.
        channel.presence.subscribe(.leave) { message in
            guard let senderID = message.clientId, !senderID.isEmpty else { return }
            handler(senderID)
        }
        channel.presence.subscribe(.absent) { message in
            guard let senderID = message.clientId, !senderID.isEmpty else { return }
            handler(senderID)
        }
    }

    public func detach() {
        channel.unsubscribe()
        channel.presence.unsubscribe()
        channel.detach()
        realtime.close()
    }
}
