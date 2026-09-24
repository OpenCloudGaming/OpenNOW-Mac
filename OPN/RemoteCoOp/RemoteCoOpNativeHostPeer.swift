import Foundation

/// The native transport's host peer. Where the WebRTC peer negotiated SDP and encoded per guest, this
/// one hands the guest the media port and a token and lets the broadcaster do the rest: the host
/// forwards its source video and PCM audio to every bound guest, and input arrives on the same port.
struct OPNRemoteCoOpNativeHostPeerFactory: OPNRemoteCoOpHostPeerFactory {
    let broadcaster: RemoteCoOpNativeMediaBroadcaster

    func makePeer(participantID: UUID,
                  networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                  qualityPreset: OPNRemoteCoOpQualityPreset,
                  latencyMode: OPNRemoteCoOpLatencyMode,
                  callbacks: OPNRemoteCoOpHostPeerCallbacks) -> any OPNRemoteCoOpHostPeer {
        OPNRemoteCoOpNativeHostPeer(participantID: participantID,
                                    broadcaster: broadcaster,
                                    callbacks: callbacks)
    }
}

final class OPNRemoteCoOpNativeHostPeer: OPNRemoteCoOpHostPeer, @unchecked Sendable {
    let participantID: UUID

    private let broadcaster: RemoteCoOpNativeMediaBroadcaster
    private let callbacks: OPNRemoteCoOpHostPeerCallbacks
    /// Bound to this guest's flow at the broadcaster. Opaque to the guest; it only echoes it.
    private let token = UUID().uuidString

    init(participantID: UUID,
         broadcaster: RemoteCoOpNativeMediaBroadcaster,
         callbacks: OPNRemoteCoOpHostPeerCallbacks) {
        self.participantID = participantID
        self.broadcaster = broadcaster
        self.callbacks = callbacks
    }

    func start() async throws {
        let mediaPort = try await broadcaster.start()
        broadcaster.register(participantID: participantID, token: token) { [callbacks] packet in
            Task { await callbacks.receiveInput(packet) }
        }
        let connection = OPNRemoteCoOpNativeConnection(mediaPort: mediaPort,
                                                       inputPort: mediaPort,
                                                       token: token,
                                                       hostAddress: OPNRemoteCoOpLocalAddress.tailscaleIPv4() ?? OPNRemoteCoOpLocalAddress.advertisedHost())
        await callbacks.sendSignal(OPNRemoteCoOpWirePeerSignal(kind: .nativeHost, nativeConnection: connection))
    }

    /// Native guests have nothing to apply back: the media flow is established by the guest's hello,
    /// which reaches the broadcaster directly.
    func apply(_ signal: OPNRemoteCoOpWirePeerSignal) async throws {}

    func updateQualityPreset(_ preset: OPNRemoteCoOpQualityPreset) async -> Bool { true }

    func close() async {
        broadcaster.unregister(participantID: participantID)
    }
}
