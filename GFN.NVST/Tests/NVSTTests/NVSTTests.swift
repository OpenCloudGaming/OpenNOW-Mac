import Foundation
import Testing
@testable import NVST

@Test func nvstBuildsSignInURLFromServerAndSession() throws {
    let configuration = NVSTSignalingConfiguration(signalingServer: "66-22-138-138.cloudmatchbeta.nvidiagrid.net", sessionID: "session-123")

    let url = try #require(configuration.signInURL(peerName: "peer-42"))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

    #expect(components.scheme == "wss")
    #expect(components.host == "66-22-138-138.cloudmatchbeta.nvidiagrid.net")
    #expect(components.port == 443)
    #expect(components.path == "/nvst/sign_in")
    #expect(query["peer_id"] == "peer-42")
    #expect(query["version"] == "2")
    #expect(query["peer_role"] == "1")
    #expect(query["pairing_id"] == "session-123")
    #expect(configuration.webSocketSubprotocol == "x-nv-sessionid.session-123")
}

@Test func nvstBuildsSignInURLFromExplicitSignalingURL() throws {
    let configuration = NVSTSignalingConfiguration(signalingServer: "unused.example", sessionID: "sid", signalingURL: "https://edge.example.test/custom/nvst")

    let url = try #require(configuration.signInURL(peerName: "peer"))

    #expect(url.absoluteString.contains("wss://edge.example.test/custom/nvst/sign_in"))
    #expect(url.absoluteString.contains("pairing_id=sid"))
}

@Test func nvstParsesPeerInfoAckHeartbeatOfferAndIce() throws {
    let peerInfoText = try jsonString([
        "ackid": 9,
        "peer_info": ["id": 42, "name": "peer-local"],
    ])
    let peerInfo = try #require(NVSTSignalingMessageParser.parse(text: peerInfoText, peerName: "peer-local", currentPeerID: 0))
    #expect(peerInfo.assignedPeerID == 42)
    #expect(peerInfo.ackIDToSend == 9)

    let heartbeat = try #require(NVSTSignalingMessageParser.parse(text: "{\"hb\":1}", peerName: "peer-local", currentPeerID: 42))
    #expect(heartbeat.shouldRespondToHeartbeat)

    let offerEnvelope = try #require(NVSTSignalingMessageParser.peerMessageEnvelope(payload: [
        "type": "offer",
        "sdp": "v=0\n",
        "nvstSdp": "a=video.maxFPS:60",
        "nvstServerOverrides": "override",
    ], from: 7, to: 42, ackID: 10))
    let offer = try #require(NVSTSignalingMessageParser.parse(text: jsonString(offerEnvelope), peerName: "peer-local", currentPeerID: 42))
    #expect(offer.remotePeerID == 7)
    #expect(offer.offer?.sdp == "v=0\n")
    #expect(offer.offer?.nvstSdp == "a=video.maxFPS:60")
    #expect(offer.offer?.nvstServerOverrides == "override")

    let iceEnvelope = try #require(NVSTSignalingMessageParser.peerMessageEnvelope(payload: [
        "candidate": "candidate:1 1 udp 1 127.0.0.1 47998 typ host",
        "sdpMid": "video",
        "sdpMLineIndex": 0,
        "usernameFragment": "ufrag",
    ], from: 7, to: 42, ackID: 11))
    let ice = try #require(NVSTSignalingMessageParser.parse(text: jsonString(iceEnvelope), peerName: "peer-local", currentPeerID: 42))
    #expect(ice.iceCandidate?.candidate == "candidate:1 1 udp 1 127.0.0.1 47998 typ host")
    #expect(ice.iceCandidate?.sdpMid == "video")
    #expect(ice.iceCandidate?.sdpMLineIndex == 0)
    #expect(ice.iceCandidate?.usernameFragment == "ufrag")
}

@Test func nvstBuildsAnswerExtensionFromSettingsAndIceCredentials() {
    let answerSdp = """
    v=0
    a=ice-ufrag:localUfrag
    a=ice-pwd:localPwd
    a=fingerprint:sha-256 AA:BB:CC
    """
    let credentials = NVSTSessionDescriptionBuilder.iceCredentials(from: answerSdp)
    let settings = NVSTSessionDescriptionSettings(
        resolution: "3840x2160",
        fps: 120,
        maxBitrateMbps: 75,
        colorQuality: "10bit_420",
        codec: "av1",
        prefilterMode: 5,
        prefilterSharpness: 12,
        prefilterDenoise: -1,
        prefilterModel: 3
    )

    let nvstSdp = NVSTSessionDescriptionBuilder.buildAnswerExtension(settings: settings, credentials: credentials)

    #expect(credentials.usernameFragment == "localUfrag")
    #expect(credentials.password == "localPwd")
    #expect(credentials.fingerprint == "sha-256 AA:BB:CC")
    #expect(nvstSdp.contains("a=general.icePassword:localPwd"))
    #expect(nvstSdp.contains("a=general.iceUserNameFragment:localUfrag"))
    #expect(nvstSdp.contains("a=video.clientViewportWd:3840"))
    #expect(nvstSdp.contains("a=video.clientViewportHt:2160"))
    #expect(nvstSdp.contains("a=video.maxFPS:120"))
    #expect(nvstSdp.contains("a=vqos.bw.maximumBitrateKbps:75000"))
    #expect(nvstSdp.contains("a=vqos.bw.minimumBitrateKbps:26250"))
    #expect(nvstSdp.contains("a=packetPacing.numGroups:3"))
    #expect(nvstSdp.contains("a=video.bitDepth:10"))
    #expect(nvstSdp.contains("a=video.scalingFeature1:1"))
    #expect(nvstSdp.contains("a=video.prefilterParams.prefilterMode:2"))
    #expect(nvstSdp.contains("a=video.prefilterParams.sharpnessLevel:10"))
    #expect(nvstSdp.contains("a=video.prefilterParams.denoiseLevel:0"))
    #expect(nvstSdp.contains("a=video.prefilterParams.prefilterModel:3"))
    #expect(nvstSdp.contains("a=ri.partialReliableThresholdMs:5"))
    #expect(nvstSdp.hasSuffix("\n\n"))
}

@Test func geronimoInputConstantsMatchExistingWireProtocol() {
    #expect(GeronimoInputEventType.heartbeat.rawValue == 2)
    #expect(GeronimoInputEventType.keyDown.rawValue == 3)
    #expect(GeronimoInputEventType.utf8Text.rawValue == 23)
    #expect(GeronimoInputChannel.reliableLabel == "input_channel_v1")
    #expect(GeronimoInputChannel.partiallyReliableLabel == "input_channel_partially_reliable")
    #expect(GeronimoInputEnvelope.headerByte == 0x23)
    #expect(GeronimoInputEnvelope.lengthPrefixedPayloadTag == 0x21)
    #expect(GeronimoInputEnvelope.singleReliablePayloadTag == 0x22)
    #expect(GeronimoInputEnvelope.partiallyReliablePayloadTag == 0x26)
    #expect(GeronimoInputHandshake.littleEndianVersionMarker == 526)
    #expect(GeronimoInputHandshake.leadingVersionByte == 0x0e)
}

private func jsonString(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8) ?? ""
}
