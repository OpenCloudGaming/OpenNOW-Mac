import Foundation
import Testing
@testable import OpenNOW

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

    let initialPeerInfoFallbackText = try jsonString([
        "peer_info": ["id": 43, "name": "peer-server"],
    ])
    let initialPeerInfoFallback = try #require(NVSTSignalingMessageParser.parse(text: initialPeerInfoFallbackText, peerName: "peer-local", currentPeerID: 0))
    #expect(initialPeerInfoFallback.assignedPeerID == 43)

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

@Test func nvstParsesTransportProfileFromVendorExtension() {
    let remoteNVSTSdp = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=general.turnInfo:turn:relay.example.test:3478,user,pass|turns:relay2.example.test:443,user2,pass2
    a=general.iceTransportPolicy:1
    m=application 0 RTP/AVP
    a=msid:input_1
    a=ri.partialReliableThresholdMs:12
    a=ri.hidDeviceMask:255
    a=ri.enablePartiallyReliableTransferGamepad:3
    a=ri.enablePartiallyReliableTransferHid:7
    """

    let profile = NVSTTransportProfile(sdp: remoteNVSTSdp)

    #expect(profile.turnServers.count == 2)
    #expect(profile.turnServers.first?.urls == ["turn:relay.example.test:3478"])
    #expect(profile.turnServers.first?.username == "user")
    #expect(profile.turnServers.first?.credential == "pass")
    #expect(profile.iceTransportPolicy == .relay)
    #expect(profile.input.partialReliableThresholdMs == 12)
    #expect(profile.input.hidDeviceMask == 255)
    #expect(profile.input.partiallyReliableGamepadMask == 3)
    #expect(profile.input.partiallyReliableHIDMask == 7)
}

@Test func nvstParsesSessionAndMediaAttributesBySection() throws {
    let description = NVSTSessionDescription(sdp: vendorLikeNVSTSdp)

    #expect(description.preambleLines.contains("v=0"))
    #expect(description.sessionAttributesByKey["general.turnInfo"]?.contains("turn:relay.example.test:3478") == true)
    #expect(description.mediaSections.map(\.mediaKind) == ["video", "audio", "mic", "application"])

    let video = try #require(description.mediaSections.first { $0.mediaKind == "video" })
    #expect(video.attributesByKey["video.maxFPS"] == "60")
    #expect(video.attributesByKey["vqos.bw.maximumBitrateKbps"] == "50000")

    let application = try #require(description.mediaSections.first { $0.mediaKind == "application" })
    #expect(application.attributesByKey["ri.partialReliableThresholdMs"] == "5")
    #expect(application.attributesByKey["ri.enablePartiallyReliableTransferGamepad"] == "15")
}

@Test func nvstAnswerExtensionAppliesSectionAwareVendorOverrides() throws {
    let overrides = """
    a=general.clientCapture:1
    m=video 0 RTP/AVP
    a=video.maxFPS:120
    a=vqos.bw.maximumBitrateKbps:75000
    m=application 0 RTP/AVP
    a=ri.partialReliableThresholdMs:12
    """
    let credentials = NVSTIceCredentials(usernameFragment: "localUfrag", password: "localPwd", fingerprint: "sha-256 AA:BB")

    let answer = try #require(NVSTSessionDescriptionBuilder.buildAnswerExtension(remoteNVSTSdp: vendorLikeNVSTSdp, serverOverrides: overrides, credentials: credentials))
    let description = NVSTSessionDescription(sdp: answer)
    let video = try #require(description.mediaSections.first { $0.mediaKind == "video" })
    let application = try #require(description.mediaSections.first { $0.mediaKind == "application" })

    #expect(description.sessionAttributesByKey["general.clientCapture"] == "1")
    #expect(description.sessionAttributesByKey["general.icePassword"] == "localPwd")
    #expect(description.sessionAttributesByKey["general.iceUserNameFragment"] == "localUfrag")
    #expect(description.sessionAttributesByKey["general.dtlsFingerprint"] == "sha-256 AA:BB")
    #expect(video.attributesByKey["video.maxFPS"] == "120")
    #expect(video.attributesByKey["vqos.bw.maximumBitrateKbps"] == "75000")
    #expect(application.attributesByKey["ri.partialReliableThresholdMs"] == "12")
    #expect(application.attributesByKey["ri.enablePartiallyReliableTransferHid"] == "4294967295")
    #expect(!answer.contains("serverPwd"))
}

@Test func nvstBuildsAnswerExtensionFromRemoteVendorExtension() throws {
    let remoteNVSTSdp = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=general.clientCapture:0
    a=general.icePassword:serverPwd
    m=application 0 RTP/AVP
    a=msid:input_1
    a=ri.partialReliableThresholdMs:5
    """
    let overrides = "a=general.clientCapture:1"
    let credentials = NVSTIceCredentials(usernameFragment: "localUfrag", password: "localPwd", fingerprint: "sha-256 AA:BB")

    let answer = try #require(NVSTSessionDescriptionBuilder.buildAnswerExtension(remoteNVSTSdp: remoteNVSTSdp, serverOverrides: overrides, credentials: credentials))

    #expect(answer.contains("a=general.clientCapture:1"))
    #expect(answer.contains("a=general.icePassword:localPwd"))
    #expect(answer.contains("a=general.iceUserNameFragment:localUfrag"))
    #expect(answer.contains("a=general.dtlsFingerprint:sha-256 AA:BB"))
    #expect(!answer.contains("serverPwd"))
    #expect(answer.contains("a=ri.partialReliableThresholdMs:5"))
}

@Test func nvstLimitsH265ReferenceFramesForLowDecodeLatency() {
    let settings = NVSTSessionDescriptionSettings(codec: "H265")

    let nvstSdp = NVSTSessionDescriptionBuilder.buildAnswerExtension(settings: settings, credentials: NVSTIceCredentials())

    #expect(nvstSdp.contains("a=video.maxNumReferenceFrames:1"))
}

@Test func nvstPreservesH264ReferenceFrameContract() {
    let settings = NVSTSessionDescriptionSettings(codec: "H264")

    let nvstSdp = NVSTSessionDescriptionBuilder.buildAnswerExtension(settings: settings, credentials: NVSTIceCredentials())

    #expect(nvstSdp.contains("a=video.maxNumReferenceFrames:4"))
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

private let vendorLikeNVSTSdp = """
v=0
o=- 0 0 IN IP4 127.0.0.1
s=-
t=0 0
a=general.clientCapture:0
a=general.icePassword:serverPwd
a=general.iceUserNameFragment:serverUfrag
a=general.dtlsFingerprint:sha-256 SERVER
a=general.turnInfo:turn:relay.example.test:3478,user,pass
a=general.iceTransportPolicy:1
m=video 0 RTP/AVP
a=msid:fbc-video-0
a=video.maxFPS:60
a=vqos.bw.maximumBitrateKbps:50000
a=video.bitDepth:8
m=audio 0 RTP/AVP
a=msid:audio
m=mic 0 RTP/AVP
a=msid:mic
m=application 0 RTP/AVP
a=msid:input_1
a=ri.partialReliableThresholdMs:5
a=ri.hidDeviceMask:4294967295
a=ri.enablePartiallyReliableTransferGamepad:15
a=ri.enablePartiallyReliableTransferHid:4294967295
"""
