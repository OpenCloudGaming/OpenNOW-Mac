import Foundation
import Testing
@testable import OpenNOW

/// Surround sound is one channel count threaded through four places that must agree: the
/// resolver, the session request, the SDP the decoder is built from, and the NVST announce.
@Suite struct SurroundAudioTests {
    private typealias Resolver = WebRTCMediaStreamSettingsResolver

    @Test func theChannelCountFollowsDeviceEntitlementAndMode() {
        #expect(Resolver.audioChannelCount(surroundMode: "auto", deviceOutputChannels: 2, entitledChannels: 0) == 2)
        #expect(Resolver.audioChannelCount(surroundMode: "auto", deviceOutputChannels: 6, entitledChannels: 0) == 6)
        #expect(Resolver.audioChannelCount(surroundMode: "auto", deviceOutputChannels: 8, entitledChannels: 0) == 8)
        // No 4-channel format exists on the wire.
        #expect(Resolver.audioChannelCount(surroundMode: "auto", deviceOutputChannels: 4, entitledChannels: 0) == 2)
        #expect(Resolver.audioChannelCount(surroundMode: "stereo", deviceOutputChannels: 8, entitledChannels: 8) == 2)
        #expect(Resolver.audioChannelCount(surroundMode: "5.1", deviceOutputChannels: 8, entitledChannels: 0) == 6)
        // A stereo device can never take a surround decode: libwebrtc cannot fold it down.
        #expect(Resolver.audioChannelCount(surroundMode: "5.1", deviceOutputChannels: 2, entitledChannels: 8) == 2)
        #expect(Resolver.audioChannelCount(surroundMode: "7.1", deviceOutputChannels: 6, entitledChannels: 0) == 6)
        #expect(Resolver.audioChannelCount(surroundMode: "7.1", deviceOutputChannels: 8, entitledChannels: 6) == 6)
        #expect(Resolver.audioChannelCount(surroundMode: "7.1", deviceOutputChannels: 8, entitledChannels: 2) == 2)
    }

    @Test func resolvedSettingsCarryTheChannelCountAndMode() {
        let resolved = Resolver.resolve(
            profile: WebRTCMediaStreamProfile(surroundMode: "5.1"),
            capabilities: WebRTCMediaDeviceCapabilities(audioOutputChannelCount: 8)
        )
        #expect(resolved.audioChannelCount == 6)
        let dictionary = resolved.dictionary(gameLanguage: "en_US", accountLinked: true, selectedStore: "STEAM")
        #expect(dictionary["audioChannelCount"] as? Int == 6)
        #expect(dictionary["surroundMode"] as? String == "5.1")
        // The dictionary round-trips through the bridge without losing the mode.
        #expect(webRTCMediaProfile(from: dictionary).surroundMode == "5.1")
    }

    @Test func theSessionRequestNamesTheAudioFormatTheWayTheOfficialClientDoes() {
        let manager = OPNSessionManager()
        #expect(manager.requestedAudioFormat([:]) == 1)
        #expect(manager.requestedAudioFormat(["audioChannelCount": 2]) == 1)
        #expect(manager.requestedAudioFormat(["audioChannelCount": 6]) == 2)
        #expect(manager.requestedAudioFormat(["audioChannelCount": 8]) == 3)
        #expect(manager.requestedAudioChannelCount(["audioChannelCount": 7]) == 6)
    }

    @Test func theAnswerIsMungedToMultiopusLikeTheOfficialClient() {
        let answer = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111 63",
            "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 minptime=10;useinbandfec=1",
            "a=rtpmap:63 red/48000/2",
            "a=fmtp:63 111/111",
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "a=rtpmap:96 H264/90000",
            "a=fmtp:96 packetization-mode=1",
            "",
        ].joined(separator: "\r\n")
        let surround = WebRTCSdp.applyingSurroundAudio(answer, channels: 6).components(separatedBy: "\r\n")
        #expect(surround.contains("a=rtpmap:111 multiopus/48000/6"))
        #expect(surround.contains("a=fmtp:111 minptime=10;useinbandfec=1;channel_mapping=0,4,1,2,3,5;num_streams=4;coupled_streams=2"))
        #expect(surround.contains("a=rtpmap:63 red/48000/2"))
        #expect(surround.contains("a=fmtp:63 111/111"))
        #expect(surround.contains("a=fmtp:96 packetization-mode=1"))
        let sevenOne = WebRTCSdp.applyingSurroundAudio(answer, channels: 8).components(separatedBy: "\r\n")
        #expect(sevenOne.contains("a=rtpmap:111 multiopus/48000/8"))
        #expect(sevenOne.contains("a=fmtp:111 minptime=10;useinbandfec=1;channel_mapping=0,6,1,2,3,4,5,7;num_streams=5;coupled_streams=3"))
        #expect(WebRTCSdp.applyingSurroundAudio(answer, channels: 2) == answer)
        #expect(WebRTCSdp.applyingSurroundAudio(answer, channels: 4) == answer)
    }

    @Test func theSynthesizedBundleOfferStaysStereoAndTheAnswerCarriesSurround() {
        // libwebrtc rejects a remote offer naming multiopus (never advertised locally), which took
        // the SCTP section down with it live; the offer stays stereo and the answer is munged.
        let offer = NvstWebRtcBundle.synthesizedRemoteOffer(
            remoteUsernameFragment: "u", remotePassword: "p", remoteFingerprint: "AA:BB",
            peerIP: "10.0.0.1", peerPort: 5004
        )
        let offerLines = offer.components(separatedBy: "\r\n")
        #expect(offerLines.contains("a=rtpmap:111 opus/48000/2"))
        #expect(!offer.contains("multiopus"))
        let answer = [
            "v=0",
            "a=group:BUNDLE 0 1",
            "m=audio 9 UDP/TLS/RTP/SAVPF 63 111",
            "a=mid:0",
            "a=recvonly",
            "a=rtpmap:63 red/48000/2",
            "a=fmtp:63 111/111",
            "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 minptime=5;stereo=1;sprop-stereo=1;useinbandfec=1",
            "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
            "a=mid:1",
            "",
        ].joined(separator: "\r\n")
        let munged = WebRTCSdp.applyingSurroundAudio(answer, channels: 6).components(separatedBy: "\r\n")
        #expect(munged.contains("a=rtpmap:111 multiopus/48000/6"))
        #expect(munged.contains("a=fmtp:111 minptime=10;useinbandfec=1;channel_mapping=0,4,1,2,3,5;num_streams=4;coupled_streams=2"))
        #expect(munged.contains("a=rtpmap:63 red/48000/2"))
        #expect(munged.contains("m=application 9 UDP/DTLS/SCTP webrtc-datachannel"))
    }

    @Test func theAnnounceCarriesTheSurroundBlockOnlyAboveStereo() {
        let stereo = NvstRtspSdp.buildAnnounceSdp(NvstRtspSdp.AnnounceOptions())
        #expect(!stereo.contains("x-nv-audio.surround.enable"))
        #expect(stereo.contains("a=x-nv-audio.surround.version:2"))
        let fiveOne = NvstRtspSdp.buildAnnounceSdp(NvstRtspSdp.AnnounceOptions(audioChannelCount: 6))
        #expect(fiveOne.contains("a=x-nv-audio.surround.enable:1"))
        #expect(fiveOne.contains("a=x-nv-audio.surround.numChannels:6"))
        #expect(fiveOne.contains("a=x-nv-audio.surround.channelMask:63"))
        let sevenOne = NvstRtspSdp.buildAnnounceSdp(NvstRtspSdp.AnnounceOptions(audioChannelCount: 8))
        #expect(sevenOne.contains("a=x-nv-audio.surround.numChannels:8"))
        #expect(sevenOne.contains("a=x-nv-audio.surround.channelMask:1599"))
    }

    @Test func theSeatsSurroundInfoParses() {
        var writer = NvstByteWriter(capacity: 24)
        writer.u32LE(6)
        writer.u32LE(4)
        writer.u32LE(2)
        writer.u32LE(0)
        for value in [0, 4, 1, 2, 3, 5] as [UInt8] { writer.u8(value) }
        let info = NvstAudioSurroundInfo.parse(NvstControlCommand(code: .audioSurroundInfo, payload: writer.data))
        #expect(info?.channels == 6)
        #expect(info?.streams == 4)
        #expect(info?.coupledStreams == 2)
        #expect(info?.usesMultiMappingMode == false)
        #expect(info?.channelMapping == [0, 4, 1, 2, 3, 5])
        #expect(NvstAudioSurroundInfo.parse(NvstControlCommand(code: .remoteInput, payload: writer.data)) == nil)
        #expect(NvstAudioSurroundInfo.parse(NvstControlCommand(code: .audioSurroundInfo, payload: Data([1, 2]))) == nil)
    }

    @Test func theStereoTeeFoldsEveryChannelWithoutBlowingUp() {
        for channels in [6, 8] {
            let weights = OPNCoreAudioRTCDevice.stereoDownmixWeights(channels: channels)
            #expect(weights.count == channels)
            // Front left and right stay on their own side; LFE (index 3) is dropped.
            #expect(weights[0].left > 0 && weights[0].right == 0)
            #expect(weights[1].right > 0 && weights[1].left == 0)
            #expect(weights[3].left == 0 && weights[3].right == 0)
            let left = weights.reduce(Float(0)) { $0 + $1.left }
            let right = weights.reduce(Float(0)) { $0 + $1.right }
            #expect(left <= 1.25 && right <= 1.25)
            #expect(abs(left - right) < 0.0001)
        }
        #expect(OPNCoreAudioRTCDevice.supportedPlayoutChannelCount(6) == 6)
        #expect(OPNCoreAudioRTCDevice.supportedPlayoutChannelCount(8) == 8)
        #expect(OPNCoreAudioRTCDevice.supportedPlayoutChannelCount(4) == 2)
        #expect(OPNCoreAudioRTCDevice.supportedPlayoutChannelCount(0) == 2)
    }

    /// The HUD is the only place a listener can confirm what the seat actually sent, so it has to
    /// name the negotiated layout, and say what was asked for when the two differ.
    @Test func theHudNamesTheNegotiatedLayoutAndFlagsAShortfall() {
        func snapshot(negotiated: Int, requested: Int) -> NativeNVSTPerformanceSnapshot {
            NativeNVSTPerformanceSnapshot(
                available: true, gameFramesPerSecond: 0, streamFramesPerSecond: 0,
                latencyMilliseconds: 0, jitterMilliseconds: 0, frameLoss: 0, totalFrameLoss: 0,
                packetLoss: 0, totalPacketLoss: 0, bitrateMegabitsPerSecond: 0,
                bandwidthUtilizationPercent: 0, resolution: "", codec: "", serverLocation: "",
                audioChannelCount: negotiated, requestedAudioChannelCount: requested
            )
        }
        #expect(snapshot(negotiated: 6, requested: 6).audioFormatSummary == "5.1")
        #expect(snapshot(negotiated: 8, requested: 8).audioFormatSummary == "7.1")
        #expect(snapshot(negotiated: 2, requested: 2).audioFormatSummary == "Stereo")
        // A request the seat did not honour reads as what arrived, plus what was asked.
        #expect(snapshot(negotiated: 2, requested: 6).audioFormatSummary == "Stereo (5.1 asked)")
        #expect(snapshot(negotiated: 6, requested: 8).audioFormatSummary == "5.1 (7.1 asked)")
        // Nothing negotiated yet is not a claim about the layout.
        #expect(snapshot(negotiated: 0, requested: 6).audioFormatSummary == "-")
    }

    @Test func theSubscriptionFeatureMapsToAChannelCount() {
        let service = OPNGameService()
        #expect(service.entitledAudioChannelCount(features: nil) == 0)
        #expect(service.entitledAudioChannelCount(features: [["key": "HDR_ENABLED", "textValue": "true"]]) == 0)
        #expect(service.entitledAudioChannelCount(features: [["key": "SUPPORTED_AUDIO_FORMATS", "textValue": "STEREO"]]) == 2)
        #expect(service.entitledAudioChannelCount(features: [["key": "SUPPORTED_AUDIO_FORMATS", "textValue": "UP_TO_5_1_SURROUND_PCM"]]) == 6)
        #expect(service.entitledAudioChannelCount(features: [["key": "SUPPORTED_AUDIO_FORMATS", "textValue": "UP_TO_7_1_SURROUND_PCM"]]) == 8)
    }

    @Test func hdrLiftsTheColourTierAndNeedsAModernCodec() {
        let capabilities = WebRTCMediaDeviceCapabilities(h265HardwareDecodeSupported: true, hdrDisplaySupported: true)
        let hevc = Resolver.resolve(profile: WebRTCMediaStreamProfile(codec: "H265", colorQuality: "8bit_420", enableHdr: true), capabilities: capabilities)
        #expect(hevc.enableHdr)
        #expect(hevc.colorQuality == "10bit_420")
        let hevcFull = Resolver.resolve(profile: WebRTCMediaStreamProfile(codec: "H265", colorQuality: "10bit_444", enableHdr: true), capabilities: capabilities)
        #expect(hevcFull.colorQuality == "10bit_444")
        let h264 = Resolver.resolve(profile: WebRTCMediaStreamProfile(codec: "H264", colorQuality: "8bit_420", enableHdr: true), capabilities: capabilities)
        #expect(!h264.enableHdr)
        #expect(h264.colorQuality == "8bit_420")
        let sdrDisplay = Resolver.resolve(profile: WebRTCMediaStreamProfile(codec: "H265", enableHdr: true), capabilities: WebRTCMediaDeviceCapabilities(h265HardwareDecodeSupported: true))
        #expect(!sdrDisplay.enableHdr)
        #expect(sdrDisplay.colorQuality == "8bit_420")
    }
}
