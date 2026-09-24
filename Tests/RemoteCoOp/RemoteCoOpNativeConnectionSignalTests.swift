import Foundation
import Testing
@testable import OpenNOW

/// The native transport's connection payload rides the same `peerSignal` the WebRTC SDP used, so the
/// invite, approval and discovery flow above it is unchanged. These pin that the new payload survives
/// the wire codec and that an SDP-shaped signal still decodes.
@Suite struct RemoteCoOpNativeConnectionSignalTests {
    @Test func theNativeConnectionSignalRoundTripsThroughTheWireCodec() throws {
        let signal = OPNRemoteCoOpWirePeerSignal(
            kind: .nativeHost,
            nativeConnection: OPNRemoteCoOpNativeConnection(mediaPort: 9000, inputPort: 9001, token: "flow-token")
        )
        let message = OPNRemoteCoOpWireMessage(kind: .peerSignal, peerSignal: signal)

        let decoded = try OPNRemoteCoOpWireCodec.decode(OPNRemoteCoOpWireCodec.encode(message))

        #expect(decoded.peerSignal == signal)
        #expect(decoded.peerSignal?.kind == .nativeHost)
        #expect(decoded.peerSignal?.nativeConnection?.mediaPort == 9000)
        #expect(decoded.peerSignal?.nativeConnection?.inputPort == 9001)
        #expect(decoded.peerSignal?.nativeConnection?.token == "flow-token")
    }

    @Test func anSdpShapedSignalStillDecodesWithoutANativePayload() throws {
        let json = #"{"protocolVersion":1,"sentAtEpochMilliseconds":0,"kind":"peerSignal","peerSignal":{"kind":"offer","sdp":"v=0..."}}"#

        let decoded = try OPNRemoteCoOpWireCodec.decode(json)

        #expect(decoded.peerSignal?.kind == .offer)
        #expect(decoded.peerSignal?.sdp == "v=0...")
        #expect(decoded.peerSignal?.nativeConnection == nil)
    }
}
