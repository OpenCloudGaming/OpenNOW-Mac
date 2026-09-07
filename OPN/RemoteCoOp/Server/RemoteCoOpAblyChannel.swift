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
    /// Host writes here; guests hold only `subscribe` on it.
    private let hostChannel: ARTRealtimeChannel
    /// Guests write here; the host reads it and watches its presence set.
    private let guestChannel: ARTRealtimeChannel
    private let logger: (@Sendable (String) -> Void)?

    /// Connects with the JWT alone.
    ///
    /// The host's API key never reaches this object: it stays in the keychain, signs the JWT, and the
    /// connection is made with the JWT the same way a guest's is. Nothing here can widen what that
    /// credential permits.
    ///
    /// Two channels, not one, and the direction is enforced by the token's capability rather than by
    /// message naming. Sharing one channel meant guests held channel-wide `publish`, so any invite
    /// holder could publish under the name the host uses and be believed by every other guest.
    public init(token: String, channelName: String, logger: (@Sendable (String) -> Void)? = nil) {
        let options = ARTClientOptions()
        options.token = token
        // Own messages are never wanted: the host reads only the guest channel, but echo would still
        // be wasted delivery, and it kept a host from consuming its own commands back when both
        // directions shared a channel.
        options.echoMessages = false
        self.realtime = ARTRealtime(options: options)
        self.hostChannel = realtime.channels.get(OPNRemoteCoOpAblyJWT.hostChannelName(base: channelName))
        self.guestChannel = realtime.channels.get(OPNRemoteCoOpAblyJWT.guestChannelName(base: channelName))
        self.logger = logger
    }

    public func publish(name: String, text: String) {
        hostChannel.publish(name, data: text) { [logger] error in
            guard let error else { return }
            // Logged rather than thrown: a lost signaling message is recoverable - the guest retries,
            // or the host republishes on the next sync - and failing the whole session over one
            // publish would be worse than the symptom.
            logger?("Remote Co-Op hosted signaling could not publish \(name): \(error.message)")
        }
    }

    public func subscribe(name: String, handler: @escaping @Sendable (_ text: String, _ senderID: String) -> Void) {
        guestChannel.subscribe(name) { message in
            guard let text = message.data as? String else { return }
            // `connectionId` is the Ably-assigned connection identifier, not the `clientId` the guest
            // asserts. Using `clientId` would let any invite holder claim to be any other guest on the
            // shared channel; `connectionId` is assigned by Ably and cannot be forged by the client.
            let senderID = message.connectionId
            guard !senderID.isEmpty else { return }
            handler(text, senderID)
        }
    }

    public func onLeave(handler: @escaping @Sendable (_ senderID: String) -> Void) {
        // Both, because they mean the same thing to us and Ably distinguishes them: `leave` is a
        // guest closing its connection, `absent` is one that vanished without saying so. The second
        // is the case the socket transports need a liveness sweep to notice at all.
        let notify: (ARTPresenceMessage) -> Void = { message in
            let senderID = message.connectionId
            guard !senderID.isEmpty else { return }
            handler(senderID)
        }
        guestChannel.presence.subscribe(.leave, callback: notify)
        guestChannel.presence.subscribe(.absent, callback: notify)
    }

    public func detach() {
        hostChannel.unsubscribe()
        hostChannel.detach()
        guestChannel.unsubscribe()
        guestChannel.presence.unsubscribe()
        guestChannel.detach()
        realtime.close()
    }
}
